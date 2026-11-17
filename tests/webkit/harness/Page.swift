// page <file.html | file:// URL>: loads a local page in a plain WKWebView
// (no extension) and prints what the page writes between @@OUT@@ and
// @@END@@ in its DOM. tests/extension/popup/runner.js uses it to run the
// popup scenarios in WebKit.
import AppKit
import Foundation
import WebKit

@MainActor
struct PageRunner {
  let options: Options

  func run() async {
    guard let arg = options.positional.first else { Out.fail("page needs <file.html>\n" + usage) }
    let url: URL
    if arg.hasPrefix("file://") {
      guard let u = URL(string: arg) else { Out.fail("not a valid URL: \(arg)") }
      url = u
    } else {
      url = fileURL(arg)
    }
    let dir = url.deletingLastPathComponent()

    let cfg = WKWebViewConfiguration()
    cfg.preferences.inactiveSchedulingPolicy = .none
    cfg.websiteDataStore = .nonPersistent()
    // Uncaught errors, kept for the diagnostics printed on a timeout.
    let errorTrap = """
      window.__harnessErrors = [];
      addEventListener('error', (e) => __harnessErrors.push(String(e.message) + ' @ ' + String(e.filename).split('/').pop() + ':' + e.lineno));
      addEventListener('unhandledrejection', (e) => __harnessErrors.push('unhandled rejection: ' + String(e.reason && e.reason.message || e.reason)));
      """
    cfg.userContentController.addUserScript(WKUserScript(source: errorTrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 640), configuration: cfg)
    let waiter = NavigationWaiter()
    wv.navigationDelegate = waiter
    do {
      try await waiter.wait { wv.loadFileURL(url, allowingReadAccessTo: dir) }
    } catch {
      Out.fail("could not load \(url.path): \(error.localizedDescription)")
    }

    let poll = """
      (() => {
        const t = document.documentElement ? document.documentElement.textContent : '';
        const m = t.match(/@@OUT@@([\\s\\S]*?)@@END@@/);
        return m ? m[1] : null;
      })()
      """
    let deadline = Date().addingTimeInterval(max(1, timeout - 1))
    while Date() < deadline {
      if let out = try? await wv.evaluateJavaScript(poll) as? String {
        Out.stdout(out)
        exit(0)
      }
      await sleep(ms: 50)
    }
    let errors = (try? await wv.evaluateJavaScript("JSON.stringify(window.__harnessErrors || [])")) as? String ?? "?"
    let tail = (try? await wv.evaluateJavaScript("(document.body ? document.body.innerText : '').slice(-400)")) as? String ?? ""
    Out.log("no @@OUT@@ result in the page after \(Int(timeout - 1)) s")
    Out.log("page errors: \(errors)")
    Out.log("page text (end): \(tail.replacingOccurrences(of: "\n", with: " | "))")
    exit(3)
  }
}
