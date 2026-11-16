// smoke <extDir>: does the extension load and can the popup reach the
// (stubbed) app through the background page, in this system language?
import AppKit
import Foundation
import WebKit

/// Collects named pass/fail checks for the RESULT line.
struct Checks {
  private(set) var list: [[String: Any]] = []
  var ok: Bool { list.allSatisfy { ($0["ok"] as? Bool) == true } }

  mutating func add(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
    var c: [String: Any] = ["name": name, "ok": ok]
    if let detail { c["detail"] = detail }
    list.append(c)
    Out.log((ok ? "ok    " : "FAIL  ") + name + (detail.map { ": \($0)" } ?? ""))
  }
}

/// The encoding WebKit falls back to for a page that declares none: the
/// "legacy default" that follows the system language.
@MainActor
func legacyDefaultEncoding() async -> String {
  let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("multisub-harness-\(getpid())")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("plain.html")
  try? Data("<!DOCTYPE html><html><body>ascii only</body></html>".utf8).write(to: file)
  defer { try? FileManager.default.removeItem(at: dir) }
  let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
  let waiter = NavigationWaiter()
  wv.navigationDelegate = waiter
  do {
    try await waiter.wait { wv.loadFileURL(file, allowingReadAccessTo: dir) }
    return (try await wv.evaluateJavaScript("document.characterSet") as? String) ?? "?"
  } catch {
    return "?"
  }
}

/// Minimal navigation delegate for web views outside the extension host.
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, Error>?

  func wait(_ start: () -> Void) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      continuation = c
      start()
    }
  }

  private func settle(_ error: Error?) {
    guard let c = continuation else { return }
    continuation = nil
    if let error { c.resume(throwing: error) } else { c.resume() }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated { settle(nil) }
  }
  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated { settle(error) }
  }
  nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated { settle(error) }
  }
}

/// The background page's web view. WebKit has no public accessor for it, so
/// this uses the `_backgroundWebView` SPI when it exists and returns nil
/// otherwise; the checks that need it are then reported as skipped.
@MainActor
func backgroundWebView(_ context: WKWebExtensionContext) -> WKWebView? {
  let sel = NSSelectorFromString("_backgroundWebView")
  guard context.responds(to: sel) else { return nil }
  return context.perform(sel)?.takeUnretainedValue() as? WKWebView
}

@MainActor
struct Smoke {
  let options: Options

  func run() async {
    guard let dirArg = options.positional.first else { Out.fail("smoke needs <extDir>\n" + usage) }
    let dir = fileURL(dirArg)
    let lang = Locale.preferredLanguages.first ?? "?"
    var checks = Checks()
    var result: [String: Any] = ["command": "smoke", "extension": dir.path, "language": lang]

    let encoding = await legacyDefaultEncoding()
    result["legacyEncoding"] = encoding
    Out.log("system language \(lang), WebKit legacy default encoding \(encoding)")

    let native = NativeStub()
    let host = ExtensionHost(extensionDir: dir, native: native)
    do {
      try await host.load()
    } catch {
      checks.add("extension loads", false, host.describe(error))
      result["checks"] = checks.list
      Out.finish(result, ok: false)
    }
    let ext = host.webExtension!
    result["manifestVersion"] = ext.manifestVersion
    checks.add("extension loads without errors", host.extensionErrors.isEmpty, host.extensionErrors.isEmpty ? nil : host.extensionErrors)

    let bgError = await host.loadBackground()
    checks.add("background content loads", bgError == nil, bgError.map { host.describe($0) })

    // A plain tab in the window, so the popup's tabs.query has an answer.
    let tab = host.openTab()
    do {
      try await host.navigate(tab.webView) { tab.webView.loadHTMLString("<!DOCTYPE html><title>blank</title>", baseURL: URL(string: "https://example.com/")) }
    } catch {
      Out.log("blank tab: \(host.describe(error))")
    }

    if let bg = backgroundWebView(host.context) {
      let probe = try? await bg.evalJSON("return JSON.stringify({ charset: document.characterSet, ms: typeof MS, url: location.pathname });")
      let info = probe as? [String: Any] ?? [:]
      result["background"] = info
      let charset = info["charset"] as? String ?? "?"
      checks.add("background page is decoded as UTF-8", charset == "UTF-8", charset)
      checks.add("background page sees shared.js (MS)", (info["ms"] as? String) == "object", info["ms"] ?? "?")
    } else {
      result["background"] = "unavailable (no _backgroundWebView)"
      Out.log("skip  background page checks: _backgroundWebView is not available")
    }

    do {
      let popup = try await host.openExtensionPage("popup.html")
      let probe = """
        const out = { charset: document.characterSet, ms: typeof MS };
        try { out.ping = await browser.runtime.sendMessage({ type: 'ping-native' }); }
        catch (e) { out.pingError = String(e && e.message || e); }
        try { const tabs = await browser.tabs.query({ active: true, currentWindow: true }); out.activeTab = tabs.length ? tabs[0].url : null; }
        catch (e) { out.tabsError = String(e && e.message || e); }
        // popup.js's own startup ping finishes the loading state
        const end = Date.now() + 5000;
        while (document.body.classList.contains('loading') && Date.now() < end) await new Promise((r) => setTimeout(r, 50));
        out.loading = document.body.classList.contains('loading');
        out.title = document.title;
        return JSON.stringify(out);
        """
      let info = try await popup.evalJSON(probe) as? [String: Any] ?? [:]
      result["popup"] = info
      let charset = info["charset"] as? String ?? "?"
      checks.add("popup is decoded as UTF-8", charset == "UTF-8", charset)
      checks.add("popup sees shared.js (MS)", (info["ms"] as? String) == "object", info["ms"] ?? "?")
      let ping = info["ping"] as? [String: Any]
      let pingOk = (ping?["ok"] as? Bool) == true
      checks.add("ping-native round trip (popup -> background -> native)", pingOk,
                 pingOk ? nil : (ping.map { Out.json($0) } ?? (info["pingError"] as? String ?? "no reply")))
      checks.add("tabs.query from the popup", info["tabsError"] == nil, info["tabsError"] ?? (info["activeTab"] ?? NSNull()))
      checks.add("popup finished loading", (info["loading"] as? Bool) == false)
    } catch {
      checks.add("popup loads", false, host.describe(error))
    }
    checks.add("native stub received ping", (native.counts["ping"] ?? 0) > 0, native.counts)

    await sleep(ms: 200)
    checks.add("no extension context errors", host.contextErrors.isEmpty, host.contextErrors.isEmpty ? nil : host.contextErrors)
    if !host.notes.isEmpty { result["notes"] = host.notes }
    result["nativeCalls"] = native.counts
    result["checks"] = checks.list
    Out.finish(result, ok: checks.ok)
  }
}
