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
    /// The folder holding a complete copy of `modelID` on this Mac, or nil.
    ///
    /// Models are stored in the Hugging Face cache layout that `HubCache`
    /// writes and `ModelDownloader` fills:
    /// `<modelsRoot>/models--<org>--<name>/snapshots/<commit>/…`. Only the
    /// disk is read, which is what lets a model load without asking
    /// huggingface.co anything (see `LocalModelFolder`). The snapshot
    /// `refs/main` names is tried first; any other complete snapshot (an
    /// older download, or one the user put there by hand) also counts.
    static func modelSnapshotDirectory(for modelID: String,
                                       in root: URL = MultiSubPaths.modelsRoot) -> URL? {
        let repoDir = root.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
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
        return ordered.first(where: isCompleteModelSnapshot)
    }

    /// Whether `directory` has what loading a model reads: `config.json`,
    /// `tokenizer.json` and the weights, with every shard of a
    /// `model-00001-of-00004.safetensors` style set. A download cut short
    /// leaves some of these out (or a link to a blob that isn't there); such
    /// a model counts as not downloaded instead of being completed from the
    /// network when it's loaded.
    static func isCompleteModelSnapshot(_ directory: URL) -> Bool {
        let fm = FileManager.default
        // Follows the snapshot's links into `blobs/`.
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        guard exists("config.json"), exists("tokenizer.json"),
              let names = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return false }
        let weights = names.filter { $0.hasSuffix(".safetensors") && exists($0) }
        guard !weights.isEmpty else { return false }
        var checkedSets: Set<String> = []
        for name in weights {
            guard let set = ShardSet(fileName: name), checkedSets.insert(set.key).inserted else { continue }
            for index in 1...set.count where !exists(set.fileName(index)) { return false }
        }
        return true
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
