// watch <extDir> <scenario.json> [--snapshot out.png] [--video auto|none|<file>] [--scheme http|https]
//
// End-to-end run of the content scripts on a mock Netflix watch page:
// storage.local gets the scenario's settings, the page is served at
// http(s)://www.netflix.com/watch/<movieId> in a tab whose web view belongs
// to the extension controller (so shared.js, content.js and inject.js are
// injected as in Safari), the manifest and subtitles come from a loopback
// server (or data: URLs for an https page), and native messages go to
// NativeStub. At every checkpoint the video is seeked to the given media time
// and the overlay is read back until it matches the expectations or the wait
// runs out.
//
// Scenario JSON:
// {
//   "name": "...",
//   "settings": { "mode": "translate", "targetLang": "zh-TW", ... },   // storage.local.settings
//   "storage": { "key": ... },       // optional: more storage.local items (e.g. cached results)
//   "engine": { ... },               // optional: engine object the stub's ping reports
//   "nativeErrors": { "translate": "auth-failed" }, // optional: stub answers these actions with an error
//   "fixtures": "..",                // optional: fixture dir, absolute or relative to the scenario file
//   "movieId": "80000001",           // optional
//   "manifestVia": "json" | "parse", // optional: Response.json (default) or JSON.parse
//   "scheme": "https" | "http",      // optional, default https; --scheme overrides
//   "checkpoints": [
//     { "time": 2, "waitMs": 10000, "snapshot": true,
//       "expect": { "original": "...", "text": "...", "plain": "...",
//                   "terms": [{ "term": "...", "gloss": "..." }], "hint": "...", "nativeHidden": true } }
//   ],
//   "status": { "mode": "translate", "status": "done", ... },  // partial match of content.js get-status
//   "native": { "translate": ">=1", "annotate": 0 },             // stub call counts
//   "manifest": { "webvttRequested": true },
//   "probe": "return JSON.stringify(...)"   // optional: async JS run in the page after the checkpoints; result in RESULT.probe
// }
// "original" and "text" are the lines of #multisub-original / #multisub-text
// joined with "\n" ("" when the line is hidden); "plain" is #multisub-text
// without its glosses; "terms" are the .ms-term/.ms-gloss pairs in order.
import AppKit
import Foundation
import WebKit

@MainActor
struct WatchRunner {
  let options: Options

  func run() async {
    guard options.positional.count >= 2 else { Out.fail("watch needs <extDir> <scenario.json>\n" + usage) }
    let extDir = fileURL(options.positional[0])
    let scenarioURL = fileURL(options.positional[1])
    guard let data = try? Data(contentsOf: scenarioURL),
          let scenario = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { Out.fail("cannot read scenario \(scenarioURL.path)") }
    let fixturesArg = scenario["fixtures"] as? String ?? ".."
    let fixtures = fixturesArg.hasPrefix("/") ? fileURL(fixturesArg)
      : fileURL(scenarioURL.deletingLastPathComponent().appendingPathComponent(fixturesArg).path)
    let movieId = scenario["movieId"] as? String ?? "80000001"
    var result: [String: Any] = ["command": "watch", "scenario": scenario["name"] ?? scenarioURL.lastPathComponent,
                                 "language": Locale.preferredLanguages.first ?? "?"]
    var checks = Checks()

    // Fixtures. With an http page they come from a loopback server (real
    // cross-origin fetches with CORS, byte ranges for the video). WebKit
    // blocks http loads from an https page as mixed content, loopback
    // included, so with an https page they are inlined as data: URLs.
    let scheme = options.values["scheme"] ?? scenario["scheme"] as? String ?? "https"
    guard scheme == "http" || scheme == "https" else { Out.fail("--scheme must be http or https") }
    result["scheme"] = scheme
    var files: [String: (file: URL, type: String)] = [
      "/subs/en.vtt": (fixtures.appendingPathComponent("en.vtt"), "text/vtt;charset=utf-8"),
      "/subs/zh-Hant.dfxp": (fixtures.appendingPathComponent("zh-Hant.dfxp"), "application/ttml+xml"),
      "/subs/zh-Hant-forced.dfxp": (fixtures.appendingPathComponent("zh-Hant-forced.dfxp"), "application/ttml+xml"),
    ]
    if let video = prepareVideo(options.values["video"] ?? scenario["video"] as? String ?? "auto") {
      files["/video.mp4"] = (video, "video/mp4")
    }
    result["video"] = files["/video.mp4"] == nil ? "scripted currentTime" : "media file"
    let server = FixtureServer()
    if scheme == "http" {
      do { try await server.start() } catch { Out.fail("fixture server: \(error)") }
      for (path, f) in files { server.serveFile(path, file: f.file, contentType: f.type) }
    }
    func resourceURL(_ path: String) -> String {
      if scheme == "http" { return server.origin + path }
      guard let f = files[path], let d = try? Data(contentsOf: f.file) else { return "https://cdn.invalid" + path }
      return "data:\(f.type);base64," + d.base64EncodedString()
    }
    var manifest = ((try? String(contentsOf: fixtures.appendingPathComponent("manifest.json"), encoding: .utf8)) ?? "")
      .replacingOccurrences(of: "{{MOVIE_ID}}", with: movieId)
    let token = try! NSRegularExpression(pattern: "\\{\\{URL:([^}]+)\\}\\}")
    for m in token.matches(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)).reversed() {
      guard let whole = Range(m.range, in: manifest), let path = Range(m.range(at: 1), in: manifest) else { continue }
      manifest.replaceSubrange(whole, with: resourceURL(String(manifest[path])))
    }
    let manifestData = Data(manifest.utf8)
    let manifestURL: String
    if scheme == "http" {
      server.route("/manifest") { _ in .init(status: 200, contentType: "application/json", body: manifestData) }
      manifestURL = server.origin + "/manifest?movieId=" + movieId
    } else {
      manifestURL = "data:application/json;base64," + manifestData.base64EncodedString()
    }

    // Extension
    let native = NativeStub(engine: scenario["engine"] as? [String: Any])
    native.errors = scenario["nativeErrors"] as? [String: String] ?? [:]
    let host = ExtensionHost(extensionDir: extDir, native: native)
    do { try await host.load() } catch { Out.fail("extension does not load: \(host.describe(error))") }
    checks.add("extension loads without errors", host.extensionErrors.isEmpty, host.extensionErrors.isEmpty ? nil : host.extensionErrors)
    var storage = scenario["storage"] as? [String: Any] ?? [:]
    if let settings = scenario["settings"] { storage["settings"] = settings }
    do {
      result["storageSeededVia"] = try await seedStorage(host, storage)
    } catch {
      Out.fail("could not write storage.local: \(host.describe(error))")
    }
    let bgError = await host.loadBackground()
    checks.add("background content loads", bgError == nil, bgError.map { host.describe($0) })

    // The watch page
    guard var html = try? String(contentsOf: fixtures.appendingPathComponent("netflix-watch.html"), encoding: .utf8)
    else { Out.fail("missing fixture netflix-watch.html in \(fixtures.path)") }
    var fx: [String: Any] = ["movieId": movieId, "manifestURL": manifestURL, "manifestMethod": scheme == "http" ? "POST" : "GET",
                             "subsURL": resourceURL("/subs/en.vtt"),
                             "video": files["/video.mp4"] == nil ? NSNull() : resourceURL("/video.mp4")]
    if let via = scenario["manifestVia"] { fx["manifestVia"] = via }
    if let r1 = html.range(of: "/*FIXTURE*/"), let r2 = html.range(of: "/*END*/", range: r1.upperBound..<html.endIndex) {
      html.replaceSubrange(r1.lowerBound..<r2.upperBound, with: Out.json(fx))
    }
    let pageURL = URL(string: "\(scheme)://www.netflix.com/watch/\(movieId)?trackId=14277281")!
    let tab = host.openTab()
    let wv = tab.webView
    do {
      try await host.navigate(wv) { wv.loadSimulatedRequest(URLRequest(url: pageURL), responseHTML: html) }
    } catch {
      Out.fail("watch page did not load: \(host.describe(error))")
    }
    checks.add("extension has content scripts for \(pageURL.host ?? "")", host.context.hasInjectedContent(for: pageURL))

    // The mock player asks for its manifest a moment after the page loads;
    // checkpoints only mean something once it has.
    let bootDeadline = Date().addingTimeInterval(10)
    var booted = false
    while Date() < bootDeadline {
      let st = (try? await wv.evalJSON("return JSON.stringify({ ok: !!window.__fixture.manifestFetched, events: window.__fixture.events });")) as? [String: Any]
      if (st?["ok"] as? Bool) == true { booted = true; break }
      if let ev = st?["events"] as? [String], ev.contains(where: { $0.hasPrefix("manifest failed") }) { break }
      await sleep(ms: 50)
    }
    checks.add("the player loaded its manifest", booted)

    // Checkpoints
    let cps = scenario["checkpoints"] as? [[String: Any]] ?? []
    var cpResults: [[String: Any]] = []
    var snapshotDone = false
    let snapshotIndex = cps.firstIndex { ($0["snapshot"] as? Bool) == true } ?? (cps.count - 1)
    for (i, cp) in cps.enumerated() {
      let t = (cp["time"] as? NSNumber)?.doubleValue ?? 0
      let expect = cp["expect"] as? [String: Any] ?? [:]
      let waitMs = (cp["waitMs"] as? NSNumber)?.intValue ?? (i == 0 ? 12000 : 4000)
      let seek = (try? await wv.evalJSON("return JSON.stringify(await window.__fixture.seek(\(t)));")) as? [String: Any] ?? [:]
      // content.js renders on a 100 ms tick: let a few pass after the seek so
      // what is read back belongs to the new time.
      await sleep(ms: 300)
      let deadline = Date().addingTimeInterval(Double(waitMs) / 1000)
      var observed: [String: Any] = [:]
      var mismatches: [String] = []
      repeat {
        observed = await observe(wv)
        mismatches = compare(expect, observed)
        if mismatches.isEmpty { break }
        await sleep(ms: 100)
      } while Date() < deadline
      let leaks = entityLeaks(observed)
      var entry: [String: Any] = ["time": t, "seek": seek, "observed": observed.filter { $0.key != "bodyText" }]
      if !mismatches.isEmpty { entry["mismatches"] = mismatches }
      checks.add(String(format: "overlay at %.1f s", t), mismatches.isEmpty, mismatches.isEmpty ? nil : mismatches.joined(separator: "; "))
      checks.add(String(format: "no literal entities on the page at %.1f s", t), leaks.isEmpty, leaks.isEmpty ? nil : leaks)
      cpResults.append(entry)
      if i == snapshotIndex, let out = options.values["snapshot"] {
        snapshotDone = await writeSnapshot(wv, to: fileURL(out))
        result["snapshot"] = snapshotDone ? fileURL(out).path : "failed"
      }
    }
    if cps.isEmpty, let out = options.values["snapshot"] {
      await sleep(ms: 3000)
      snapshotDone = await writeSnapshot(wv, to: fileURL(out))
      result["snapshot"] = snapshotDone ? fileURL(out).path : "failed"
    }
    result["checkpoints"] = cpResults

    // What the page and the server saw
    let fixtureState = (try? await wv.evalJSON("""
      return JSON.stringify({ hookedBeforePage: window.__fixture.hookedBeforePage,
        manifestFetched: window.__fixture.manifestFetched, manifestRequestBody: window.__fixture.manifestRequestBody || null,
        events: window.__fixture.events, injected: !!window.__multisubInjected });
      """)) as? [String: Any] ?? [:]
    result["page"] = fixtureState.filter { $0.key != "manifestRequestBody" }
    // inject.js's JSON.stringify hook adds the WebVTT profile to the
    // player's manifest request.
    let webvttRequested = (fixtureState["manifestRequestBody"] as? String ?? "").contains("webvtt-lssdh-ios8")
    result["manifest"] = ["fetched": fixtureState["manifestFetched"] ?? false, "webvttRequested": webvttRequested]
    if scheme == "http" {
      result["serverRequests"] = server.requests
      result["serverRangeRequests"] = server.rangeRequests
    }
    checks.add("inject.js ran in the page world", (fixtureState["injected"] as? Bool) == true)
    if let m = scenario["manifest"] as? [String: Any], let want = m["webvttRequested"] as? Bool {
      checks.add("manifest request \(want ? "asks" : "does not ask") for WebVTT (JSON.stringify hook)", webvttRequested == want)
    }

    // Optional free-form probe for exploring a scenario.
    if let probe = scenario["probe"] as? String {
      do { result["probe"] = try await wv.evalJSON(probe) ?? NSNull() } catch { result["probe"] = "error: \(host.describe(error))" }
    }

    // The popup's view of the tab (tabs.query + tabs.sendMessage get-status)
    let popupInfo = await popupStatus(host)
    result["popup"] = popupInfo
    if let want = scenario["status"] as? [String: Any] {
      let status = popupInfo["status"] as? [String: Any] ?? [:]
      let diff = want.compactMap { k, v -> String? in
        jsonEqual(status[k], v) ? nil : "\(k): want \(Out.json([v])) got \(Out.json([status[k] ?? NSNull()]))"
      }.sorted()
      checks.add("get-status from the popup", popupInfo["status"] != nil && diff.isEmpty,
                 popupInfo["error"] ?? (diff.isEmpty ? nil : diff.joined(separator: "; ")))
    }

    // Native calls
    result["nativeCalls"] = native.counts
    result["nativeLog"] = native.log
    if let want = scenario["native"] as? [String: Any] {
      for (action, rule) in want.sorted(by: { $0.key < $1.key }) {
        let n = native.counts[action] ?? 0
        checks.add("native \(action) calls \(rule)", countMatches(n, rule), n)
      }
    }

    await sleep(ms: 200)
    checks.add("no extension context errors", host.contextErrors.isEmpty, host.contextErrors.isEmpty ? nil : host.contextErrors)
    if !host.notes.isEmpty { result["notes"] = host.notes }
    if options.values["snapshot"] != nil && !snapshotDone { checks.add("snapshot written", false) }
    server.stop()
    result["checks"] = checks.list
    Out.finish(result, ok: checks.ok)
  }

  // MARK: - Steps

  /// Writes storage.local before any content script runs: from a blank page
  /// at the extension's origin when WebKit grants it the extension APIs,
  /// otherwise from the background page.
  func seedStorage(_ host: ExtensionHost, _ items: [String: Any]) async throws -> String {
    let body = "await browser.storage.local.set(\(Out.json(items))); return JSON.stringify(Object.keys(await browser.storage.local.get(null)));"
    if let cfg = host.context.webViewConfiguration {
      let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: cfg)
      let waiter = NavigationWaiter()
      wv.navigationDelegate = waiter
      let url = host.context.baseURL.appendingPathComponent("__harness_seed__.html")
      try? await waiter.wait { wv.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<!DOCTYPE html><meta charset=\"utf-8\"><title>seed</title>") }
      if let keys = try? await wv.evalJSON(body) as? [String] {
        Out.debug("storage.local keys after seeding: \(keys)")
        return "extension page"
      }
    }
    _ = await host.loadBackground()
    guard let bg = backgroundWebView(host.context) else { throw HostError.setup("no extension page or background page to write storage from") }
    _ = try await bg.evalJSON(body)
    return "background page"
  }

  /// The overlay as the viewer would read it.
  func observe(_ wv: WKWebView) async -> [String: Any] {
    let js = """
      const $ = (id) => document.getElementById(id);
      const shown = (el) => !!el && getComputedStyle(el).display !== 'none';
      const lineEls = (el) => el ? Array.from(el.children).filter((c) => c.classList.contains('ms-line')) : [];
      const text = (el) => shown(el) ? lineEls(el).map((l) => l.textContent).join('\\n') : '';
      const t = $('multisub-text');
      const plain = shown(t) ? lineEls(t).map((l) => Array.from(l.childNodes)
        .filter((n) => !(n.nodeType === 1 && n.classList.contains('ms-gloss'))).map((n) => n.textContent).join('')).join('\\n') : '';
      const terms = shown(t) ? Array.from(t.querySelectorAll('.ms-term')).map((el) => {
        const g = el.nextElementSibling;
        return { term: el.textContent, gloss: g && g.classList.contains('ms-gloss') ? g.textContent : null };
      }) : [];
      const hint = $('multisub-hint');
      const video = document.querySelector('video');
      const overlay = $('multisub-overlay');
      return JSON.stringify({
        overlay: !!overlay,
        overlayParent: overlay && overlay.parentElement ? overlay.parentElement.className : null,
        original: text($('multisub-original')),
        text: text(t),
        plain: plain,
        terms: terms,
        hint: shown(hint) ? hint.textContent : '',
        nativeHidden: document.documentElement.classList.contains('multisub-native-hidden'),
        currentTime: video ? video.currentTime : null,
        overlayText: overlay ? overlay.textContent : '',
        bodyText: document.body ? document.body.innerText : ''
      });
      """
    return ((try? await wv.evalJSON(js)) as? [String: Any]) ?? ["error": "page did not answer"]
  }

  /// Expectation keys that don't match, as readable strings.
  func compare(_ expect: [String: Any], _ observed: [String: Any]) -> [String] {
    var out: [String] = []
    for (key, want) in expect.sorted(by: { $0.key < $1.key }) {
      let got = observed[key]
      if !jsonEqual(got, want) {
        out.append("\(key): want \(Out.json([want])) got \(Out.json([got ?? NSNull()]))")
      }
    }
    return out
  }

  /// HTML entities that reached the screen as text, e.g. "&lrm;".
  func entityLeaks(_ observed: [String: Any]) -> [String] {
    let texts = [observed["overlayText"] as? String ?? "", observed["bodyText"] as? String ?? ""]
    var found = Set<String>()
    let re = try! NSRegularExpression(pattern: "&(?:[a-z]{2,8}|#[0-9]{1,6}|#x[0-9a-f]{1,6});", options: [.caseInsensitive])
    for s in texts {
      for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        if let r = Range(m.range, in: s) { found.insert(String(s[r])) }
      }
    }
    return found.sorted()
  }

  func popupStatus(_ host: ExtensionHost) async -> [String: Any] {
    do {
      let popup = try await host.openExtensionPage("popup.html")
      let js = """
        const out = {};
        const tabs = await browser.tabs.query({ active: true, currentWindow: true });
        out.tabUrl = tabs.length ? tabs[0].url : null;
        try { out.status = tabs.length ? await browser.tabs.sendMessage(tabs[0].id, { type: 'get-status' }) : null; }
        catch (e) { out.error = 'tabs.sendMessage: ' + String(e && e.message || e); }
        const end = Date.now() + 5000;
        while (document.body.classList.contains('loading') && Date.now() < end) await new Promise((r) => setTimeout(r, 50));
        await new Promise((r) => setTimeout(r, 300));
        const st = document.getElementById('statusText');
        out.statusText = st ? st.textContent : null;
        return JSON.stringify(out);
        """
      return (try await popup.evalJSON(js) as? [String: Any]) ?? [:]
    } catch {
      return ["error": host.describe(error)]
    }
  }

  func writeSnapshot(_ wv: WKWebView, to url: URL) async -> Bool {
    await sleep(ms: 150)
    let cfg = WKSnapshotConfiguration()
    cfg.afterScreenUpdates = true
    guard let image = try? await wv.takeSnapshot(configuration: cfg),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { Out.log("snapshot failed"); return false }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.write(to: url)
      Out.log("snapshot written to \(url.path)")
      return true
    } catch {
      Out.log("snapshot not written: \(error.localizedDescription)")
      return false
    }
  }

  /// A short silent video for the player: "none" for no media (scripted
  /// currentTime), a file path, or "auto" to generate one with ffmpeg once
  /// (kept next to the harness binary) and fall back to none without it.
  func prepareVideo(_ mode: String) -> URL? {
    if mode == "none" { return nil }
    if mode != "auto" { return fileURL(mode) }
    let dir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).deletingLastPathComponent()
    let out = dir.appendingPathComponent("fixture-video-30s.mp4")
    if FileManager.default.fileExists(atPath: out.path) { return out }
    let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] +
      (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffmpeg" }
    guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      Out.log("ffmpeg not found: driving currentTime without media")
      return nil
    }
    let tmp = dir.appendingPathComponent("fixture-video-\(getpid()).mp4")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg)
    p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x1d2330:s=640x360:r=10:d=30",
                   "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", "-movflags", "+faststart", "-an", tmp.path]
    do {
      try p.run()
      p.waitUntilExit()
    } catch {
      Out.log("ffmpeg failed to start: \(error.localizedDescription)")
      return nil
    }
    guard p.terminationStatus == 0, (try? FileManager.default.moveItem(at: tmp, to: out)) != nil else {
      try? FileManager.default.removeItem(at: tmp)
      Out.log("ffmpeg could not make the fixture video: driving currentTime without media")
      return nil
    }
    Out.log("generated \(out.path)")
    return out
  }
}

/// JSON-level equality (numbers compare by value, arrays and objects deeply).
func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
  func norm(_ v: Any?) -> Any { v ?? NSNull() }
  guard let da = try? JSONSerialization.data(withJSONObject: [norm(a)], options: [.sortedKeys]),
        let db = try? JSONSerialization.data(withJSONObject: [norm(b)], options: [.sortedKeys])
  else { return false }
  return da == db
}

/// `rule` is an exact count or a string like ">=1", ">0", "<=2".
func countMatches(_ n: Int, _ rule: Any) -> Bool {
  if let exact = rule as? NSNumber { return n == exact.intValue }
  guard let s = rule as? String else { return false }
  let ops: [(String, (Int, Int) -> Bool)] = [(">=", (>=)), ("<=", (<=)), (">", (>)), ("<", (<)), ("=", (==))]
  for (op, f) in ops where s.hasPrefix(op) {
    if let v = Int(s.dropFirst(op.count).trimmingCharacters(in: .whitespaces)) { return f(n, v) }
  }
  return Int(s).map { $0 == n } ?? false
}
