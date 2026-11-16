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

    /// Every model with files on disk, downloaded or not (`hasModelFiles`):
    /// a download cut short leaves gigabytes that only deleting gives back.
    /// Found from the repo folders (`models--<org>--<name>`) and from the
    /// partial folders (`.download-tmp/<org>--<name>`), so a model whose
    /// repo folder was deleted in Finder while its partial folder stayed is
    /// still listed. Best-effort reverse of those names: splits on the
    /// *first* "--" only, which is lossy if an org or model name itself
    /// contains "--", but matches every real repo id this project deals with.
    static func modelIDsOnDisk(in root: URL = MultiSubPaths.modelsRoot) -> [String] {
        let fm = FileManager.default
        func modelID(fromFolderName name: Substring) -> String? {
            guard let separator = name.range(of: "--") else { return nil }
            return String(name[..<separator.lowerBound]) + "/" + name[separator.upperBound...]
        }
        var ids = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix("models--") {
            if let id = modelID(fromFolderName: name.dropFirst("models--".count)) { ids.insert(id) }
        }
        // The UUID-named folders older builds left have no "--".
        for name in (try? fm.contentsOfDirectory(atPath: modelPartialRoot(in: root).path)) ?? [] {
            if let id = modelID(fromFolderName: Substring(name)) { ids.insert(id) }
        }
        return ids.filter { hasModelFiles(for: $0, in: root) }.sorted()
    }

    /// Whether `modelID` has data on disk, complete or not: a file with
    /// bytes in it under its repo folder or its partial folder. The
    /// expected-files list alone doesn't count (see `unfinishedDownloadBytes`).
    /// Stops at the first such file, so it's cheap enough for a row's body.
    static func hasModelFiles(for modelID: String, in root: URL = MultiSubPaths.modelsRoot) -> Bool {
        dataBytes(in: modelRepoDirectory(for: modelID, in: root), stopAtFirst: true) > 0
            || dataBytes(in: modelPartialDirectory(for: modelID, in: root), stopAtFirst: true) > 0
    }

    /// What a download of `modelID` that didn't finish left on disk, in
    /// bytes: the stored files under its repo folder (blobs and refs; the
    /// snapshot's links into `blobs/` aren't counted twice) plus the
    /// unfinished files in its partial folder. Hidden files are left out:
    /// the expected-files list alone, from a download that stopped before
    /// any data arrived, is 0, as there is nothing to resume from or to get
    /// back (a Finder `.DS_Store` is 0 too). Meant for a model that isn't
    /// downloaded; for a downloaded one this is its whole size.
    static func unfinishedDownloadBytes(for modelID: String, in root: URL = MultiSubPaths.modelsRoot) -> Int64 {
        dataBytes(in: modelRepoDirectory(for: modelID, in: root))
            + dataBytes(in: modelPartialDirectory(for: modelID, in: root))
    }

    /// Bytes in the regular, non-empty, non-hidden files under `directory`
    /// (hidden folders such as `.multisub-expected-files` are skipped whole,
    /// links aren't followed). 0 when it doesn't exist.
    private static func dataBytes(in directory: URL, stopAtFirst: Bool = false) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: nil)
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize, size > 0
            else { continue }
            total += Int64(size)
            if stopAtFirst { break }
        }
        return total
    }

    // MARK: Partial downloads

    /// `<root>/.download-tmp`: the files `ModelDownloader` hasn't finished,
    /// one folder per model.
    static func modelPartialRoot(in root: URL = MultiSubPaths.modelsRoot) -> URL {
        root.appendingPathComponent(".download-tmp", isDirectory: true)
    }

    /// `<root>/.download-tmp/<org>--<name>`: where `modelID`'s unfinished
    /// files (`<etag>.partial`) wait, from one attempt and one app run to
    /// the next, until every file is stored. Named like the repo folder,
    /// with anything but letters, digits, "-", "_" and "." replaced by "_"
    /// (a leading "." too, so the name never reaches outside the folder).
    static func modelPartialDirectory(for modelID: String, in root: URL = MultiSubPaths.modelsRoot) -> URL {
        var name = modelID.replacingOccurrences(of: "/", with: "--")
            .map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? String($0) : "_" }
            .joined()
        if name.isEmpty || name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return modelPartialRoot(in: root).appendingPathComponent(name, isDirectory: true)
    }

    /// Deletes what an unfinished download of `modelID` kept for resuming,
    /// if anything. Deleting a model must do this too, or its gigabytes stay
    /// behind and the row keeps offering 繼續下載. Never while that model
    /// downloads.
    static func removePartialDownload(for modelID: String, in root: URL = MultiSubPaths.modelsRoot) {
        try? FileManager.default.removeItem(at: modelPartialDirectory(for: modelID, in: root))
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
