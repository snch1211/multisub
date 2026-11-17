// WebKit test harness for the MultiSub Safari Web Extension.
//
// Runs the extension in the engine Safari uses, through WebKit's public
// WKWebExtensionController API (macOS 15.4+), in web views this process
// owns. Nothing here drives Safari, and native messaging is always answered
// by a stub (WebKit only routes runtime.sendNativeMessage to a real app
// extension inside Safari).
//
// Subcommands:
//   smoke <extDir>
//       Loads the extension, its background content and popup.html, and
//       round-trips a ping popup -> background -> stub native.
//   page <file.html>
//       Loads a local page in a plain WKWebView (no extension), waits for the
//       page to write @@OUT@@<result>@@END@@ into its DOM, prints <result>.
//   watch <extDir> <scenario.json> [--snapshot out.png]
//       Runs the content scripts on a mock Netflix watch page and checks the
//       overlay at the media times the scenario lists.
//
// Common options:
//   --lang <code>     Run as if the Mac's language were <code> (zh-Hant, ja,
//                     en, zh-Hans, ko): relaunches with -AppleLanguages
//                     (<code>) and the matching __CF_USER_TEXT_ENCODING, which
//                     is what sets WebKit's legacy default text encoding
//                     (Big5, Shift_JIS, windows-1252, GBK, EUC-KR). Passing
//                     -AppleLanguages "(<code>)" directly works the same.
//   --timeout <sec>   Give up after this long (exit 3).
//   --verbose         Log more to stderr.
//
// Output: progress on stderr; for smoke and watch, one line on stdout
// starting with "RESULT " followed by a JSON object. Exit status: 0 pass,
// 1 checks failed, 2 usage or setup error, 3 timeout.
import AppKit
import Foundation
import WebKit

struct Options {
  var command = ""
  var positional: [String] = []
  var values: [String: String] = [:]
  var switches: Set<String> = []

  static let valueOptions: Set<String> = ["--lang", "--timeout", "--snapshot", "--video", "--scheme"]

  static func parse(_ argv: [String]) -> Options {
    var o = Options()
    var i = 1
    while i < argv.count {
      let a = argv[i]
      if a.hasPrefix("--") {
        if valueOptions.contains(a), i + 1 < argv.count {
          o.values[String(a.dropFirst(2))] = argv[i + 1]
          i += 2
        } else {
          o.switches.insert(String(a.dropFirst(2)))
          i += 1
        }
      } else if a.hasPrefix("-"), a.count > 1, i + 1 < argv.count {
        // A user-defaults argument such as -AppleLanguages "(ja)": Foundation
        // already read it into the argument domain.
        i += 2
      } else {
        if o.command.isEmpty { o.command = a } else { o.positional.append(a) }
        i += 1
      }
    }
    return o
  }

  var verbose: Bool { switches.contains("verbose") }
}

// MARK: - Output

enum Out {
  static var verbose = false

  static func log(_ s: String) {
    FileHandle.standardError.write(("[harness] " + s + "\n").data(using: .utf8)!)
  }

  static func debug(_ s: String) {
    if verbose { log(s) }
  }

  static func stdout(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
  }

  static func json(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: data, encoding: .utf8)
    else { return "{\"error\":\"unserializable result\"}" }
    return s
  }

  /// Prints the RESULT line and exits: 0 when `ok`, 1 otherwise.
  static func finish(_ result: [String: Any], ok: Bool) -> Never {
    var r = result
    r["ok"] = ok
    stdout("RESULT " + json(r))
    exit(ok ? 0 : 1)
  }

  static func fail(_ message: String, code: Int32 = 2) -> Never {
    log("error: " + message)
    stdout("RESULT " + json(["ok": false, "error": message]))
    exit(code)
  }
}

// MARK: - Helpers

/// A file URL with "." and ".." resolved and symlinks followed. WebKit kills
/// the process (SIGKILL, no message) when an extension's resource base URL
/// still contains "..", so every path from the command line goes through
/// here.
func fileURL(_ path: String) -> URL {
  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
}

@MainActor
func sleep(ms: Int) async {
  try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

/// The legacy Mac script and region codes loginwindow writes into
/// __CF_USER_TEXT_ENCODING (as "uid:script:region") for a primary language.
/// WebKit derives its legacy default text encoding from this variable, not
/// from AppleLanguages, so switching only AppleLanguages leaves it at the
/// login language's encoding.
func textEncodingCodes(for language: String) -> (script: Int, region: Int)? {
  let l = language.lowercased()
  if l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") { return (0x2, 53) } // Big5
  if l.hasPrefix("zh") { return (0x19, 52) } // GBK
  if l.hasPrefix("ja") { return (0x1, 14) } // Shift_JIS
  if l.hasPrefix("ko") { return (0x3, 51) } // EUC-KR
  if l.hasPrefix("en") { return (0x0, 0) } // windows-1252
  return nil
}

/// Makes the system language of this process the one asked for, as if the
/// Mac had been set up in it: -AppleLanguages "(<lang>)" for Foundation and
/// a matching __CF_USER_TEXT_ENCODING for WebKit's legacy default encoding.
/// The language comes from --lang or from an -AppleLanguages argument.
/// Relaunches once when the command line or environment has to change.
func relaunchForLanguageIfNeeded(_ argv: [String]) {
  var args = argv
  var lang: String?
  if let idx = args.firstIndex(of: "--lang"), idx + 1 < args.count {
    lang = args[idx + 1]
    args.removeSubrange(idx...(idx + 1))
    if let a = args.firstIndex(of: "-AppleLanguages"), a + 1 < args.count { args.removeSubrange(a...(a + 1)) }
    args += ["-AppleLanguages", "(\(lang!))"]
  } else if let a = args.firstIndex(of: "-AppleLanguages"), a + 1 < args.count {
    lang = args[a + 1].trimmingCharacters(in: CharacterSet(charactersIn: "() \"'")).components(separatedBy: ",").first
  }
  guard let lang, let codes = textEncodingCodes(for: lang) else {
    if args != argv { Out.fail("unsupported language for --lang: \(argv)") }
    return
  }
  let wanted = String(format: "0x%X:0x%X:0x%X", getuid(), codes.script, codes.region)
  let current = ProcessInfo.processInfo.environment["__CF_USER_TEXT_ENCODING"] ?? ""
  if args == argv && current.uppercased() == wanted.uppercased() { return }
  setenv("__CF_USER_TEXT_ENCODING", wanted, 1)
  let exe = Bundle.main.executablePath ?? argv[0]
  args[0] = exe
  var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
  cargs.append(nil)
  execv(exe, &cargs)
  Out.fail("could not relaunch with -AppleLanguages: errno \(errno)")
}

let usage = """
  usage: harness smoke <extDir> [--lang <code>]
         harness page <file.html> [--timeout <sec>]
         harness watch <extDir> <scenario.json> [--snapshot out.png] [--video auto|none|<file>] [--scheme http|https] [--lang <code>]
  """

// MARK: - Entry point

relaunchForLanguageIfNeeded(CommandLine.arguments)
let options = Options.parse(CommandLine.arguments)
Out.verbose = options.verbose

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let defaultTimeout: Double
switch options.command {
case "smoke": defaultTimeout = 40
case "page": defaultTimeout = 30
case "watch": defaultTimeout = 90
default:
  FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
  exit(2)
}
let timeout = Double(options.values["timeout"] ?? "") ?? defaultTimeout
DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
  Out.log("timed out after \(Int(timeout)) s")
  Out.stdout("RESULT " + Out.json(["ok": false, "error": "timeout"]))
  exit(3)
}

Task { @MainActor in
  switch options.command {
  case "smoke": await Smoke(options: options).run()
  case "page": await PageRunner(options: options).run()
  case "watch": await WatchRunner(options: options).run()
  default: exit(2)
  }
}
app.run()
