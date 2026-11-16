//
//  Paths.swift
//  MultiSub
//
//  Where shared files live. Shared between the host app and the Safari
//  extension.
//

import Foundation

enum MultiSubPaths {
    /// See `AppIdentity.appGroupID` for why the group name is derived from
    /// our signature instead of written down.
    static var appGroupID: String? { AppIdentity.appGroupID }

    /// Both targets are sandboxed, so the model and config live in the shared
    /// App Group container, visible to the app and the Safari extension alike.
    static var sharedRoot: URL {
        let fm = FileManager.default
        let base: URL
        if let groupID = appGroupID,
           let group = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            base = group.appendingPathComponent("MultiSub", isDirectory: true)
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MultiSub", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var modelsRoot: URL { sharedRoot.appendingPathComponent("models", isDirectory: true) }
    static var configFile: URL { sharedRoot.appendingPathComponent("config.json") }
}

// MARK: - Downloaded models

extension MultiSubPaths {
    /// `<root>/models--<org>--<name>`, the Hugging Face cache folder that
    /// `HubCache` writes and `ModelDownloader` fills for `modelID`.
    static func modelRepoDirectory(for modelID: String,
                                   in root: URL = MultiSubPaths.modelsRoot) -> URL {
        root.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// The folder holding a complete copy of `modelID` on this Mac, or nil.
    ///
    /// Models are stored in the Hugging Face cache layout:
    /// `<modelsRoot>/models--<org>--<name>/snapshots/<commit>/…`. Only the
    /// disk is read, which is what lets a model load without asking
    /// huggingface.co anything (see `LocalModelFolder`). The snapshot
    /// `refs/main` names is tried first; any other complete snapshot (an
    /// older download, or one the user put there by hand) also counts.
    static func modelSnapshotDirectory(for modelID: String,
                                       in root: URL = MultiSubPaths.modelsRoot) -> URL? {
        let repoDir = modelRepoDirectory(for: modelID, in: root)
        let fm = FileManager.default
        guard let snapshots = try? fm.contentsOfDirectory(
            at: repoDir.appendingPathComponent("snapshots", isDirectory: true),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        let main = (try? String(contentsOf: repoDir.appendingPathComponent("refs/main"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = snapshots.sorted { a, b in
            let aMain = a.lastPathComponent == main, bMain = b.lastPathComponent == main
            if aMain != bMain { return aMain }
            return a.lastPathComponent < b.lastPathComponent
        }
        return ordered.first { snapshot in
            switch expectedFiles(repoDirectory: repoDir, commit: snapshot.lastPathComponent) {
            case .notRecorded: return isCompleteModelSnapshot(snapshot, expectedFiles: nil)
            case .files(let files): return isCompleteModelSnapshot(snapshot, expectedFiles: files)
            case .unreadable: return false
            }
        }
    }

    /// Whether `directory` has what loading a model reads: `config.json`,
    /// `tokenizer.json` and the weights, with every shard of a
    /// `model-00001-of-00004.safetensors` style set, plus every file in
    /// `expectedFiles` (what `ModelDownloader` set out to fetch, see
    /// `recordExpectedFiles`). Without such a list (a download by an older
    /// build, or files put there by hand) `tokenizer_config.json` is needed
    /// too: it carries the special tokens, so a Gemma prompt built without
    /// it has no `<bos>`. A download cut short leaves some of these out (or
    /// a link to a blob that isn't there); such a model counts as not
    /// downloaded instead of being completed from the network, or loaded
    /// with a file missing, when it's used.
    static func isCompleteModelSnapshot(_ directory: URL, expectedFiles: [String]?) -> Bool {
        let fm = FileManager.default
        // Follows the snapshot's links into `blobs/`.
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        guard exists("config.json"), exists("tokenizer.json"),
              let names = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return false }
        if let expectedFiles {
            guard expectedFiles.allSatisfy(exists) else { return false }
        } else {
            guard exists("tokenizer_config.json") else { return false }
        }
        let weights = names.filter { $0.hasSuffix(".safetensors") && exists($0) }
        guard !weights.isEmpty else { return false }
        var checkedSets: Set<String> = []
        for name in weights {
            guard let set = ShardSet(fileName: name), checkedSets.insert(set.key).inserted else { continue }
            for index in 1...set.count where !exists(set.fileName(index)) { return false }
        }
        return true
    }

    /// Records the files a download of `modelID` at `commit` is about to
    /// fetch. `ModelDownloader` writes this before it stores the first
    /// file, so until the last one is in the snapshot the model doesn't
    /// count as downloaded, whichever file a download cut short is missing.
    /// Kept beside `snapshots/` rather than in it, so the snapshot folder
    /// mlx-swift-lm reads holds only the repo's own files; deleting the
    /// model's folder deletes it too.
    static func recordExpectedFiles(_ files: [String], modelID: String, commit: String,
                                    in root: URL = MultiSubPaths.modelsRoot) throws {
        let url = try expectedFilesURL(repoDirectory: modelRepoDirectory(for: modelID, in: root), commit: commit)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(ExpectedFiles(files: files.sorted())).write(to: url, options: .atomic)
    }

    /// Every model with a folder holding at least one file, downloaded or
    /// not: a download cut short leaves gigabytes there that only deleting
    /// the folder gives back. Best-effort reverse of `modelRepoDirectory`:
    /// splits the folder name on the *first* "--" only, which is lossy if
    /// an org or model name itself contains "--", but matches every real
    /// repo id this project deals with.
    static func modelIDsOnDisk(in root: URL = MultiSubPaths.modelsRoot) -> [String] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return dirs.compactMap { dir -> String? in
            let name = dir.lastPathComponent
            guard name.hasPrefix("models--") else { return nil }
            let rest = name.dropFirst("models--".count)
            guard let separator = rest.range(of: "--") else { return nil }
            let id = String(rest[..<separator.lowerBound]) + "/" + rest[separator.upperBound...]
            return hasModelFiles(for: id, in: root) ? id : nil
        }
        .sorted()
    }

    /// Whether `modelID` has a folder with any file in it, complete or not.
    static func hasModelFiles(for modelID: String, in root: URL = MultiSubPaths.modelsRoot) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: modelRepoDirectory(for: modelID, in: root),
            includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: nil)
        else { return false }
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return true
        }
        return false
    }

    private struct ExpectedFiles: Codable {
        var files: [String]
    }

    private static let expectedFilesFolder = ".multisub-expected-files"

    private static func expectedFilesURL(repoDirectory: URL, commit: String) throws -> URL {
        // `commit` names a file; HubCache refuses the same names for snapshots.
        guard !commit.isEmpty, commit != ".", commit != "..",
              !commit.contains("/"), !commit.contains("\\")
        else { throw CocoaError(.fileWriteInvalidFileName) }
        return repoDirectory.appendingPathComponent(expectedFilesFolder, isDirectory: true)
            .appendingPathComponent(commit + ".json")
    }

    private enum ExpectedFilesRecord {
        /// Not downloaded by `ModelDownloader` (or by a build before it kept
        /// the list).
        case notRecorded
        case files([String])
        /// Says nothing about which files are needed, so the snapshot
        /// doesn't count.
        case unreadable
    }

    private static func expectedFiles(repoDirectory: URL, commit: String) -> ExpectedFilesRecord {
        guard let url = try? expectedFilesURL(repoDirectory: repoDirectory, commit: commit),
              FileManager.default.fileExists(atPath: url.path)
        else { return .notRecorded }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ExpectedFiles.self, from: data)
        else { return .unreadable }
        return .files(list.files)
    }

    /// `<prefix>-<index>-of-<count>.safetensors`, the names Hugging Face
    /// gives a model's weights when it splits them into shards.
    private struct ShardSet {
        let prefix: Substring
        let indexWidth: Int
        let countText: Substring
        let count: Int

        init?(fileName: String) {
            let stem = fileName.dropLast(".safetensors".count)
            guard let of = stem.range(of: "-of-", options: .backwards) else { return nil }
            let head = stem[..<of.lowerBound]
            guard let dash = head.range(of: "-", options: .backwards) else { return nil }
            let indexText = head[dash.upperBound...]
            countText = stem[of.upperBound...]
            guard !indexText.isEmpty, indexText.allSatisfy(\.isASCIIDigit),
                  !countText.isEmpty, countText.allSatisfy(\.isASCIIDigit),
                  let count = Int(countText), (1...1000).contains(count)
            else { return nil }
            prefix = head[..<dash.lowerBound]
            indexWidth = indexText.count
            self.count = count
        }

        var key: String { "\(prefix)|\(indexWidth)|\(countText)" }

        func fileName(_ index: Int) -> String {
            let digits = String(index)
            let padded = String(repeating: "0", count: max(0, indexWidth - digits.count)) + digits
            return "\(prefix)-\(padded)-of-\(countText).safetensors"
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
