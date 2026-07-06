//
//  ModelCatalog.swift
//  MultiSub
//
//  C3: curated list of Gemma 4 4-bit quantized models shown in
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
    /// C3: models present under the shared `models/` directory (whether
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

/// PLAN.md C3（2026-07-05 使用者拍板）：磁碟大小 ÷ 實體記憶體 > 40% 警告、> 60% 阻擋
/// （阻擋門檻可強制選用，需經確認 alert）。
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
}
