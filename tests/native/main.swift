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
              dangling: Set<String> = [], refMain: Bool = false) throws {
    let repo = MultiSubPaths.modelRepoDirectory(for: id, in: modelsRoot)
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

func unwrap<T>(_ value: T?, line: Int = #line) throws -> T {
    guard let value else { throw CheckFailed(description: "line \(line): unexpected nil") }
    return value
}

try? fm.removeItem(at: modelsRoot)
print("\n\(passed) tests passed" + (failed > 0 ? ", \(failed) FAILED" : ""))
exit(failed == 0 ? 0 : 1)
