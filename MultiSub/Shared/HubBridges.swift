//
//  HubBridges.swift
//  MultiSub
//
//  Plain-Swift glue between MLXLMCommon and the Hugging Face packages.
//
//  mlx-swift-lm ships this glue as the `#hubDownloader` /
//  `#huggingFaceTokenizerLoader` macros in its MLXHuggingFace product. Macros
//  pull swift-syntax into the build and, in the Xcode GUI, refuse to compile
//  until the developer clicks "Trust & Enable" — a common "it doesn't build"
//  trap for a fresh clone. These are the same bridges written out by hand
//  (mirroring the macro expansions in mlx-swift-lm 3.32), so the project
//  depends on no macro targets at all.
//

import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

enum HubBridgeError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id): return "Invalid Hugging Face repository id: \(id)"
        }
    }
}

/// Downloads model snapshots through `HuggingFace.HubClient`.
struct HubDownloader: MLXLMCommon.Downloader {
    private let client: HuggingFace.HubClient

    init(_ client: HuggingFace.HubClient) {
        self.client = client
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw HubBridgeError.invalidRepositoryID(id)
        }
        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

/// Loads a swift-transformers tokenizer from a model folder and adapts it to
/// MLXLMCommon's `Tokenizer` protocol.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names this `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
