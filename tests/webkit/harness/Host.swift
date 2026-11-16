// The extension host: one WKWebExtensionController with the extension
// loaded, a window with tabs for tabs.query / tabs.sendMessage / sender.tab,
// and the stub that answers native messages.
import AppKit
import Foundation
import WebKit

// MARK: - Native stub

/// Answers runtime.sendNativeMessage the way SafariWebExtensionHandler.swift
/// does, with deterministic results and no AI: 'translate' prefixes each
/// line, 'annotate' glosses the first word longer than six letters.
@MainActor
final class NativeStub {
  var engine: [String: Any]
  var translatePrefix = "[zh] "
  var glossPrefix = "zh:"
  /// action -> error code to answer with ({ok: false, error: code}).
  var errors: [String: String] = [:]
  /// action -> number of calls
  private(set) var counts: [String: Int] = [:]
  /// Every request in order: action plus a short summary.
  private(set) var log: [[String: Any]] = []

  static let defaultEngine: [String: Any] = [
    "configured": "cloud", "active": "cloud", "provider": "openai", "providerName": "OpenAI",
    "model": "stub-model", "hasKey": true, "localModelId": "stub/local-model",
    "localModelDownloaded": false, "localModelLoaded": false,
  ]

  init(engine: [String: Any]? = nil) {
    self.engine = engine ?? NativeStub.defaultEngine
  }

  func handle(_ message: Any) -> [String: Any] {
    let msg = message as? [String: Any] ?? [:]
    let action = msg["action"] as? String ?? "?"
    counts[action, default: 0] += 1
    let lines = (msg["lines"] as? [Any])?.map { ($0 as? String) ?? "" } ?? []
    var entry: [String: Any] = ["action": action]
    if !lines.isEmpty { entry["lines"] = lines.count }
    log.append(entry)
    Out.debug("native \(action)\(lines.isEmpty ? "" : " lines=\(lines.count)")")
    if let code = errors[action] { return ["ok": false, "error": code, "detail": "stubbed error"] }
    switch action {
    case "ping":
      return ["ok": true, "engine": engine, "modelId": engine["localModelId"] ?? "",
              "modelDownloaded": false, "modelLoaded": false]
    case "translate":
      return ["ok": true, "translations": lines.map { translatePrefix + $0 }]
    case "annotate":
      return ["ok": true, "annotations": lines.map { line -> [[String: String]] in
        guard let word = NativeStub.firstLongWord(line) else { return [] }
        return [["term": word, "gloss": glossPrefix + word.lowercased()]]
      }]
    case "extract-glossary":
      return ["ok": true, "glossary": [String: String]()]
    case "set-prefs", "unload", "open-app", "save-transcript":
      return ["ok": true]
    case "get-engine-options":
      return ["ok": true, "providers": [Any](), "engine": engine]
    case "set-engine", "test-engine", "list-models":
      return ["ok": false, "error": "bad-request", "detail": "not supported by the harness stub"]
    default:
      return ["ok": false, "error": "unknown-action"]
    }
  }

  /// The first run of letters longer than six, as it appears in the line.
  static func firstLongWord(_ line: String) -> String? {
    var word = ""
    for ch in line + " " {
      if ch.isLetter { word.append(ch); continue }
      if word.count > 6 { return word }
      word = ""
    }
    return nil
  }
}

// MARK: - Windows and tabs

@MainActor
final class HostTab: NSObject, WKWebExtensionTab {
  let webView: WKWebView
  weak var window: HostWindow?

  init(webView: WKWebView) { self.webView = webView }

  nonisolated func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
    MainActor.assumeIsolated { window }
  }
  nonisolated func indexInWindow(for context: WKWebExtensionContext) -> Int {
    MainActor.assumeIsolated { window?.tabs.firstIndex(of: self) ?? 0 }
  }
  nonisolated func webView(for context: WKWebExtensionContext) -> WKWebView? {
    MainActor.assumeIsolated { webView }
  }
  nonisolated func title(for context: WKWebExtensionContext) -> String? {
    MainActor.assumeIsolated { webView.title }
  }
  nonisolated func url(for context: WKWebExtensionContext) -> URL? {
    MainActor.assumeIsolated { webView.url }
  }
  nonisolated func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
    MainActor.assumeIsolated { !webView.isLoading }
  }
  nonisolated func isSelected(for context: WKWebExtensionContext) -> Bool {
    MainActor.assumeIsolated { window?.activeTab === self }
  }
  nonisolated func size(for context: WKWebExtensionContext) -> CGSize {
    MainActor.assumeIsolated { webView.frame.size }
  }
  nonisolated func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    MainActor.assumeIsolated {
      if fromOrigin { _ = webView.reloadFromOrigin() } else { _ = webView.reload() }
    }
    completionHandler(nil)
  }
}

@MainActor
final class HostWindow: NSObject, WKWebExtensionWindow {
  var tabs: [HostTab] = []
  var activeTab: HostTab?

  nonisolated func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
    MainActor.assumeIsolated { tabs }
  }
  nonisolated func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
    MainActor.assumeIsolated { activeTab }
  }
  nonisolated func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
  nonisolated func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
  nonisolated func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
  nonisolated func frame(for context: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 1280, height: 800) }
  nonisolated func screenFrame(for context: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 1280, height: 800) }
}

// MARK: - Host

enum HostError: Error, CustomStringConvertible {
  case setup(String)
  var description: String {
    switch self { case .setup(let s): return s }
  }
}

@MainActor
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate, WKNavigationDelegate {
  let extensionDir: URL
  let native: NativeStub
  private(set) var webExtension: WKWebExtension!
  private(set) var controller: WKWebExtensionController!
  private(set) var context: WKWebExtensionContext!
  let window = HostWindow()
  /// Off-screen window that hosts the tab web views, so WebKit treats them as
  /// on screen (layout, timers, media and snapshots behave as in a tab).
  /// It is never ordered front.
  private var hostWindow: NSWindow?
  private var navigationWaiters: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
  /// Errors WebKit reported through the delegate (navigation failures).
  private(set) var notes: [String] = []

  init(extensionDir: URL, native: NativeStub) {
    self.extensionDir = extensionDir
    self.native = native
  }

  /// Loads the extension and grants everything it asks for, as a user who
  /// enabled it in Safari and allowed it on netflix.com would have.
  func load() async throws {
    let ext = try await WKWebExtension(resourceBaseURL: extensionDir)
    webExtension = ext
    controller = WKWebExtensionController(configuration: .nonPersistent())
    controller.delegate = self
    let ctx = WKWebExtensionContext(for: ext)
    ctx.isInspectable = true
    for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
    for m in ext.allRequestedMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
    context = ctx
    try controller.load(ctx)
    controller.didOpenWindow(window)
    controller.didFocusWindow(window)
  }

  var extensionErrors: [String] { webExtension?.errors.map { describe($0) } ?? [] }
  var contextErrors: [String] { context?.errors.map { describe($0) } ?? [] }

  func describe(_ e: Error) -> String {
    let ns = e as NSError
    var s = ns.localizedDescription
    if let reason = ns.localizedFailureReason, !s.contains(reason) { s += " (" + reason + ")" }
    return s
  }

  func loadBackground() async -> Error? {
    await withCheckedContinuation { c in context.loadBackgroundContent { c.resume(returning: $0) } }
  }

  /// A web view for one of the extension's own pages (the popup).
  func openExtensionPage(_ path: String, size: CGSize = CGSize(width: 360, height: 600)) async throws -> WKWebView {
    guard let cfg = context.webViewConfiguration else { throw HostError.setup("context has no webViewConfiguration") }
    let wv = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
    wv.navigationDelegate = self
    try await navigate(wv) { wv.load(URLRequest(url: self.context.baseURL.appendingPathComponent(path))) }
    return wv
  }

  /// A tab whose web view the extension's content scripts are injected into.
  func openTab(size: CGSize = CGSize(width: 1280, height: 720)) -> HostTab {
    let cfg = WKWebViewConfiguration()
    cfg.webExtensionController = controller
    cfg.preferences.inactiveSchedulingPolicy = .none
    cfg.mediaTypesRequiringUserActionForPlayback = []
    // Content scripts are only injected into web views that use the
    // controller's own data store; a different one (even another
    // non-persistent store) silently gets none.
    cfg.websiteDataStore = controller.configuration.defaultWebsiteDataStore
    let wv = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
    wv.navigationDelegate = self
    wv.isInspectable = true
    attachOffscreen(wv)
    let tab = HostTab(webView: wv)
    tab.window = window
    let previous = window.activeTab
    window.tabs.append(tab)
    window.activeTab = tab
    controller.didOpenTab(tab)
    controller.didActivateTab(tab, previousActiveTab: previous)
    controller.didSelectTabs([tab])
    return tab
  }

  private func attachOffscreen(_ wv: WKWebView) {
    if hostWindow == nil {
      let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: wv.frame.width, height: wv.frame.height),
                       styleMask: [.borderless], backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.contentView = NSView(frame: CGRect(origin: .zero, size: wv.frame.size))
      hostWindow = w
    }
    hostWindow?.contentView?.addSubview(wv)
  }

  func tabDidNavigate(_ tab: HostTab) {
    controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
  }

  /// Starts a navigation and waits for it to finish (or fail).
  func navigate(_ wv: WKWebView, _ start: () -> Void) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      navigationWaiters[ObjectIdentifier(wv)] = c
      start()
    }
  }

  private func settle(_ wv: WKWebView, _ error: Error?) {
    guard let c = navigationWaiters.removeValue(forKey: ObjectIdentifier(wv)) else { return }
    if let error { c.resume(throwing: error) } else { c.resume() }
  }

  // MARK: WKNavigationDelegate

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      if let tab = window.tabs.first(where: { $0.webView === webView }) { tabDidNavigate(tab) }
      settle(webView, nil)
    }
  }
  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated {
      notes.append("navigation failed: \(describe(error))")
      settle(webView, error)
    }
  }
  nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated {
      notes.append("navigation failed: \(describe(error))")
      settle(webView, error)
    }
  }
  nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    MainActor.assumeIsolated { notes.append("web content process terminated") }
  }

  // MARK: WKWebExtensionControllerDelegate

  nonisolated func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
    MainActor.assumeIsolated { [window] }
  }

  nonisolated func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
    MainActor.assumeIsolated { window }
  }

  nonisolated func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
    // tabs.create (the popup's key links): record it, open nothing.
    MainActor.assumeIsolated {
      notes.append("tabs.create \(configuration.url?.absoluteString ?? "")")
    }
    completionHandler(nil, nil)
  }

  nonisolated func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
    completionHandler(matchPatterns, nil)
  }

  nonisolated func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, Error?) -> Void) {
    MainActor.assumeIsolated {
      replyHandler(native.handle(message), nil)
    }
  }
}

// MARK: - JavaScript helpers

extension WKWebView {
  /// Runs an async function body in the page's main world and returns its
  /// result decoded from JSON (the body must `return JSON.stringify(...)`).
  @MainActor
  func evalJSON(_ body: String, world: WKContentWorld? = nil) async throws -> Any? {
    let raw = try await callAsyncJavaScript(body, contentWorld: world ?? .page)
    guard let s = raw as? String, let data = s.data(using: .utf8) else { return raw }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }
}
