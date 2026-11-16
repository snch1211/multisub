// Checks for MultiSub/Shared, the Swift code the app and the extension both
// run. native.test.js builds this file together with those sources.

import Foundation

var passed = 0
var failed = 0

struct CheckFailed: Error, CustomStringConvertible {
    let description: String
}

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("ok   \(name)")
    } catch {
        failed += 1
        print("FAIL \(name)\n     \(error)")
    }
}

func expect<T: Equatable>(_ got: T, _ want: T, _ what: String = "", line: Int = #line) throws {
    guard got != want else { return }
    throw CheckFailed(description: "line \(line): \(what.isEmpty ? "" : what + ": ")got \(got), want \(want)")
}

// MARK: - Downloaded models

let fm = FileManager.default
let modelsRoot = fm.temporaryDirectory.appendingPathComponent("multisub-native-\(UUID().uuidString)", isDirectory: true)

/// Lays a snapshot out the way `HubCache.storeFile` does: the content in
/// `blobs/`, a relative link to it in `snapshots/<commit>/`. A `dangling`
/// file's blob is never written.
func snapshot(_ id: String, _ commit: String, _ files: [String],
              dangling: Set<String> = [], refMain: Bool = false, in root: URL = modelsRoot) throws {
    let repo = MultiSubPaths.modelRepoDirectory(for: id, in: root)
    let snap = repo.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
    try fm.createDirectory(at: snap, withIntermediateDirectories: true)
    try fm.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
    for file in files {
        let blob = "\(commit)-\(file)"
        if !dangling.contains(file) {
            try Data("x".utf8).write(to: repo.appendingPathComponent("blobs/\(blob)"))
        }
        try fm.createSymbolicLink(atPath: snap.appendingPathComponent(file).path,
                                  withDestinationPath: "../../blobs/\(blob)")
    }
    if refMain {
        try fm.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try commit.write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
    }
}

func downloaded(_ id: String) -> String? {
    MultiSubPaths.modelSnapshotDirectory(for: id, in: modelsRoot)?.lastPathComponent
}

/// What the Hugging Face tree lists for a catalog Gemma repo, in the order
/// `ModelDownloader` stores the files.
let gemmaFiles = ["chat_template.jinja", "config.json", "generation_config.json",
                  "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                  "model.safetensors.index.json", "processor_config.json",
                  "tokenizer.json", "tokenizer_config.json"]
let basics = ["config.json", "tokenizer.json", "tokenizer_config.json"]

test("a download cut short before its last file (tokenizer_config.json) isn't downloaded") {
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "t/cut-last", commit: "c1", in: modelsRoot)
    try snapshot("t/cut-last", "c1", Array(gemmaFiles.dropLast()), refMain: true)
    try expect(downloaded("t/cut-last"), nil)
}

test("every listed file stored: downloaded") {
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "t/whole", commit: "c1", in: modelsRoot)
    try snapshot("t/whole", "c1", gemmaFiles, refMain: true)
    try expect(downloaded("t/whole"), "c1")
}

test("cut short on any listed file, not only the ones loading reads first") {
    for missing in ["chat_template.jinja", "generation_config.json", "processor_config.json",
                    "model.safetensors.index.json"] {
        let id = "t/cut-\(missing)"
        try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: id, commit: "c1", in: modelsRoot)
        try snapshot(id, "c1", gemmaFiles.filter { $0 != missing }, refMain: true)
        try expect(downloaded(id), nil, missing)
    }
}

test("a listed file whose blob isn't there counts as missing") {
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "t/dangling-listed", commit: "c1", in: modelsRoot)
    try snapshot("t/dangling-listed", "c1", gemmaFiles, dangling: ["generation_config.json"], refMain: true)
    try expect(downloaded("t/dangling-listed"), nil)
}

test("the list sits beside snapshots/, so the snapshot folder holds only the repo's files") {
    let snap = try unwrap(MultiSubPaths.modelSnapshotDirectory(for: "t/whole", in: modelsRoot))
    try expect(try fm.contentsOfDirectory(atPath: snap.path).sorted(), gemmaFiles.sorted())
}

test("a list that can't be read doesn't count as complete") {
    try snapshot("t/garbled", "c1", gemmaFiles, refMain: true)
    let list = MultiSubPaths.modelRepoDirectory(for: "t/garbled", in: modelsRoot)
        .appendingPathComponent(".multisub-expected-files/c1.json")
    try fm.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"files\":".utf8).write(to: list)
    try expect(downloaded("t/garbled"), nil)
}

test("a list only speaks for its own commit") {
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "t/two-commits", commit: "new", in: modelsRoot)
    try snapshot("t/two-commits", "new", Array(gemmaFiles.prefix(4)), refMain: true)
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "t/two-commits", commit: "old", in: modelsRoot)
    try snapshot("t/two-commits", "old", gemmaFiles)
    try expect(downloaded("t/two-commits"), "old", "refs/main's download is unfinished, the older one is whole")
}

test("recordExpectedFiles takes a commit only as one file name") {
    for commit in ["", ".", "..", "../x", "a/b"] {
        do {
            try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "t/bad-commit", commit: commit, in: modelsRoot)
            throw CheckFailed(description: "accepted \(commit.debugDescription)")
        } catch is CocoaError {}
    }
}

test("no list (an older build's download, or files put there by hand) needs tokenizer_config.json") {
    try snapshot("t/old-cut-last", "c1", Array(gemmaFiles.dropLast()), refMain: true)
    try expect(downloaded("t/old-cut-last"), nil)
    try snapshot("t/old-whole", "c1", gemmaFiles, refMain: true)
    try expect(downloaded("t/old-whole"), "c1")
}

test("no list: config.json, tokenizer.json and every shard are needed") {
    try snapshot("t/single", "c1", basics + ["model.safetensors"])
    try expect(downloaded("t/single"), "c1", "one weights file")
    try snapshot("t/missing-shard", "c1", basics + ["model-00001-of-00003.safetensors",
                                                    "model-00003-of-00003.safetensors"])
    try expect(downloaded("t/missing-shard"), nil, "a missing shard")
    try snapshot("t/no-tokenizer", "c1", ["config.json", "tokenizer_config.json", "model.safetensors"])
    try expect(downloaded("t/no-tokenizer"), nil, "no tokenizer.json")
    try snapshot("t/no-weights", "c1", basics)
    try expect(downloaded("t/no-weights"), nil, "no weights")
    try snapshot("t/dangling-weights", "c1", basics + ["model.safetensors"], dangling: ["model.safetensors"])
    try expect(downloaded("t/dangling-weights"), nil, "weights linking to a missing blob")
    try expect(downloaded("t/nothing-here"), nil, "no folder at all")
}

test("the snapshot refs/main names is tried first") {
    try snapshot("t/prefers-main", "aaa", basics + ["model.safetensors"])
    try snapshot("t/prefers-main", "zzz", basics + ["model.safetensors"], refMain: true)
    try expect(downloaded("t/prefers-main"), "zzz")
}

test("models on disk: downloaded ones and ones a download cut short, not empty folders") {
    let root = modelsRoot.appendingPathComponent("listing", isDirectory: true)
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "org/whole", commit: "c1", in: root)
    try snapshot("org/whole", "c1", gemmaFiles, refMain: true, in: root)
    // One shard of two stored, then the app quit.
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "org/cut-short", commit: "c1", in: root)
    try snapshot("org/cut-short", "c1", Array(gemmaFiles.prefix(4)), refMain: true, in: root)
    // Cut short before the first file was stored: only the list is there.
    try MultiSubPaths.recordExpectedFiles(gemmaFiles, modelID: "org/list-only", commit: "c1", in: root)
    try fm.createDirectory(at: MultiSubPaths.modelRepoDirectory(for: "org/empty", in: root)
        .appendingPathComponent("snapshots/c1"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent(".download-tmp/x"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("not-a-model"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("not-a-model/file"))

    try expect(MultiSubPaths.modelIDsOnDisk(in: root), ["org/cut-short", "org/list-only", "org/whole"])
    try expect(MultiSubPaths.modelSnapshotDirectory(for: "org/cut-short", in: root), nil, "cut short")
    try expect(MultiSubPaths.hasModelFiles(for: "org/cut-short", in: root), true, "cut short")
    try expect(MultiSubPaths.hasModelFiles(for: "org/empty", in: root), false, "empty folders")
    try expect(MultiSubPaths.hasModelFiles(for: "org/never", in: root), false, "no folder")
    try expect(MultiSubPaths.modelIDsOnDisk(in: root.appendingPathComponent("missing")), [], "no models folder")
}

func unwrap<T>(_ value: T?, line: Int = #line) throws -> T {
    guard let value else { throw CheckFailed(description: "line \(line): unexpected nil") }
    return value
}

try? fm.removeItem(at: modelsRoot)

// MARK: - Custom server addresses

let notHTTP = "API 網址格式不正確，請以 http:// 或 https:// 開頭。"
let notPlain = "API 網址格式不正確。主機名稱請用英文字母、數字、點或連字號，網址裡不要有帳號密碼（@）、反斜線或空白。"

let acceptedBaseURLs = [
    "http://localhost:1234/v1", "https://api.example.com/v1", "http://127.0.0.1:8080",
    "http://192.168.1.20:11434/v1/", "http://10.0.0.255/v1", "http://[::1]:1234/v1",
    "http://[2001:db8::1]/v1", "HTTP://Host.Example:80/v1/", "http://a_b.example/v1",
    "http://my-server.local:1234/v1", "http://host.example:1234/v1?x=1#f",
    "http://host.example/v1/路徑", "  http://localhost:1234/v1  ", "http://host.example:/v1",
    "http://xn--bcher-kva.example/v1", "https://openrouter.example:443/api/v1",
]

/// The address and the message it gets.
let refusedBaseURLs: [(String, String)] = [
    ("", notHTTP), ("ftp://host.example/v1", notHTTP), ("localhost:1234/v1", notHTTP),
    ("http:evil.example/v1", notHTTP), ("http:/evil.example/v1", notHTTP),
    ("javascript://evil.example/v1", notHTTP),
    ("http:///evil.example/v1", notPlain),
    // The review's case: localhost:1234 to WHATWG, evil.example to Foundation.
    ("http://localhost:1234\\@evil.example/v1", notPlain),
    ("http://evil.example\\.good.example/v1", notPlain),
    ("http://localhost:1234\\evil.example/v1", notPlain),
    ("http://user:pass@host.example/v1", notPlain), ("http://a@b@c.example/v1", notPlain),
    ("http://@host.example/v1", notPlain),
    ("http://evil%2Eexample/v1", notPlain), ("http://good.example%40evil.example/v1", notPlain),
    ("http://ｅｖｉｌ.example/v1", notPlain), ("http://evil。example/v1", notPlain),
    ("http://bücher.example/v1", notPlain), ("http://faß.de/v1", notPlain),
    ("http://0x7f.0.0.1:1234/v1", notPlain), ("http://2130706433/v1", notPlain),
    ("http://127.1/v1", notPlain), ("http://0177.0.0.1/v1", notPlain),
    ("http://127.0.0.1./v1", notPlain), ("http://256.0.0.1/v1", notPlain),
    ("http://example.123/v1", notPlain), ("http://example.0x10/v1", notPlain),
    ("http://[evil.example]/v1", notPlain), ("http://[::1]evil.example/v1", notPlain),
    ("http://[fe80::1%25en0]:1234/v1", notPlain),
    ("http://host.example:99999/v1", notPlain), ("http://host.example:12a/v1", notPlain),
    ("http://host.example:1234:80/v1", notPlain),
    ("http://evil.exa\tmple/v1", notPlain), ("http://localhost:1234\n@evil.example/v1", notPlain),
    ("http://local host/v1", notPlain), ("http://host.example/v 1", notPlain),
    ("http://host.example/v\u{200B}1", notPlain), ("http://evil\u{200B}.example/v1", notPlain),
    ("http://evil|.example/v1", notPlain), ("http://evil.example;good/v1", notPlain),
]

test("custom server addresses both URL parsers read the same way are accepted") {
    for url in acceptedBaseURLs {
        try expect(CloudSettings.baseURLProblem(url), nil, url.debugDescription)
    }
}

test("addresses the popup could name as another server are refused, with what to fix") {
    for (url, message) in refusedBaseURLs {
        try expect(CloudSettings.baseURLProblem(url), message, url.debugDescription)
    }
}

/// A custom address an older build saved: nothing is sent there.
let savedBefore = CloudLLMClient(provider: .custom, model: "m",
                                 baseURL: "http://localhost:1234\\@evil.example/v1", apiKey: nil)
var savedBeforeError: String?
do {
    _ = try await savedBefore.listModels()
} catch let error as CloudLLMError {
    savedBeforeError = error.message
} catch {
    savedBeforeError = "\(error)"
}
test("a saved custom address that's refused now gets no request") {
    try expect(savedBeforeError, "API 網址格式不正確，請檢查設定。")
}

// What Foundation, which sends the requests, connects to for each accepted
// address; native.test.js checks that the WHATWG URL parser (the popup's)
// finds the same host and port.
for url in acceptedBaseURLs {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsed = URL(string: trimmed)
    let probe: [String: Any] = [
        "url": url,
        "host": parsed?.host?.lowercased() ?? NSNull(),
        "port": parsed?.port ?? NSNull(),
    ]
    let data = try JSONSerialization.data(withJSONObject: probe)
    print("PROBE " + String(decoding: data, as: UTF8.self))
}

print("RESULT {\"passed\":\(passed),\"failed\":\(failed)}")
exit(failed == 0 ? 0 : 1)
