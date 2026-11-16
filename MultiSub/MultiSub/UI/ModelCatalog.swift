//
//  ModelCatalog.swift
//  MultiSub
//
//  Curated list of Gemma 4 4-bit quantized models shown in
//  GeneralSettingsView's model picker, plus the device-memory tiering used
//  to warn about / block models too large for this machine. IDs were given
//  directly by the user, not independently verified against Hugging Face
//  from this environment — a wrong ID simply surfaces through the existing
//  "下載失敗" error path, same as a mistyped ID in the old free-text field.
//

import Foundation

struct ModelCatalogEntry: Identifiable, Hashable {
    let id: String
    let displayName: String
}

enum ModelCatalog {
    static let entries: [ModelCatalogEntry] = [
        ModelCatalogEntry(id: "mlx-community/gemma-4-e2b-it-4bit", displayName: "Gemma 4 E2B"),
        ModelCatalogEntry(id: "mlx-community/gemma-4-e4b-it-4bit", displayName: "Gemma 4 E4B"),
        ModelCatalogEntry(id: "mlx-community/gemma-4-12B-it-4bit", displayName: "Gemma 4 12B"),
        ModelCatalogEntry(id: "mlx-community/gemma-4-26b-a4b-it-4bit", displayName: "Gemma 4 26B A4B"),
        ModelCatalogEntry(id: "mlx-community/gemma-4-31b-it-4bit", displayName: "Gemma 4 31B")
    ]
}

enum ModelMemoryTier {
    case ok, warning, blocked
}

extension ModelCatalog {
    /// Models present under the shared `models/` directory (whether
    /// downloaded through the picker or dropped in manually by the user via
    /// "在 Finder 中打開模型資料夾") that aren't already one of the curated
    /// `entries` — so a manually-installed model still shows up somewhere.
    /// Best-effort reverse of `"models--" + id.replacingOccurrences(of: "/",
    /// with: "--")`: splits the dir name on the *first* "--" only, which is
    /// lossy if an org or model name itself contains "--", but matches every
    /// real repo id this project deals with.
    static func discoverExtraModels() -> [ModelCatalogEntry] {
        let knownIDs = Set(entries.map(\.id))
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: MultiSubPaths.modelsRoot, includingPropertiesForKeys: nil
        ) else { return [] }
        var extras: [ModelCatalogEntry] = []
        for dir in dirs {
            let name = dir.lastPathComponent
            guard name.hasPrefix("models--") else { continue }
            let rest = String(name.dropFirst("models--".count))
            guard let separatorRange = rest.range(of: "--") else { continue }
            let id = rest[..<separatorRange.lowerBound] + "/" + rest[separatorRange.upperBound...]
            let id2 = String(id)
            guard !knownIDs.contains(id2), Translator.isModelDownloaded(id2) else { continue }
            extras.append(ModelCatalogEntry(id: id2, displayName: id2))
        }
        return extras
    }
}

extension ModelCatalog {
    static func displayName(for modelID: String) -> String {
        entries.first { $0.id == modelID }?.displayName ?? modelID
    }

    /// Bytes on disk for a downloaded model. Mirrors
    /// `Translator.isModelDownloaded`'s repo-dir naming so the size shown
    /// always matches what that check just confirmed exists.
    static func directorySize(modelID: String) -> Int64 {
        let repoDir = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let root = MultiSubPaths.modelsRoot.appendingPathComponent(repoDir, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}

/// Disk size ÷ physical memory above 40% warns, above 60% blocks (a blocked
/// model can still be forced after a confirmation alert).
enum ModelMemoryAdvisor {
    static let warningRatio = 0.4
    static let blockedRatio = 0.6

    static func tier(diskBytes: Int64, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelMemoryTier {
        guard physicalMemory > 0, diskBytes > 0 else { return .ok }
        let ratio = Double(diskBytes) / Double(physicalMemory)
        if ratio > blockedRatio { return .blocked }
        if ratio > warningRatio { return .warning }
        return .ok
    }

    /// Whether to ask before downloading or selecting a model of this size.
    /// An unknown size asks too: it could be the one that doesn't fit.
    static func needsConfirmation(diskBytes: Int64?) -> Bool {
        guard let diskBytes else { return true }
        return tier(diskBytes: diskBytes) == .blocked
    }

    /// Title and message of that confirmation, shared by 一般設定 and the
    /// engine setup so both ask the same way.
    static func confirmationTitle(sizeKnown: Bool) -> String {
        sizeKnown ? "這個模型可能超出記憶體" : "查不到這個模型的大小"
    }

    static func confirmationMessage(sizeKnown: Bool) -> String {
        if sizeKnown {
            return "模型大小超過這台 Mac 記憶體的 \(Int(blockedRatio * 100))%，載入時可能讓系統變慢或當機。"
        }
        let memory = ModelCatalog.formatBytes(Int64(ProcessInfo.processInfo.physicalMemory))
        return "不確定它會不會超出這台 Mac 的記憶體（\(memory)）。太大的話，載入時可能讓系統變慢或當機。"
    }
}
