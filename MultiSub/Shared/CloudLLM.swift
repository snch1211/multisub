//
//  CloudLLM.swift
//  MultiSub
//
//  Bring-your-own-key cloud engines: Anthropic's Messages API and any
//  OpenAI-compatible chat-completions endpoint (OpenAI, OpenRouter, Gemini's
//  OpenAI-compatible endpoint, or a user-supplied base URL such as a local
//  LM Studio / Ollama server).
//
//  Imports Foundation only, on purpose: this file is also compiled on its own
//  with a scratch `main` to exercise the real APIs outside Xcode.
//
//  The API key lives only inside `CloudLLMClient` for the duration of a
//  request. It never appears in an error message, a description or a log
//  line: provider error text is scrubbed before it is surfaced, and the
//  client's description/mirror leave the key out.
//

import Foundation

/// One entry in the model picker's short list.
struct CloudModelOption: Hashable, Sendable, Identifiable {
    let id: String
    let label: String
}

enum CloudProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic, openai, openrouter, gemini, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .custom: return "自訂（OpenAI 相容）"
        }
    }

    /// Base URL the request paths (`/messages`, `/chat/completions`,
    /// `/models`) are appended to. Custom servers have none; the user types it.
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: return ""
        }
    }

    /// The fastest model that still annotates and translates well. An empty
    /// `CloudSettings.model` means "use this".
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-6-luna"
        case .openrouter: return "anthropic/claude-haiku-5.5"
        case .gemini: return "gemini-3.1-flash-lite"
        case .custom: return ""
        }
    }

    var recommended: [CloudModelOption] {
        switch self {
        case .anthropic:
            return [CloudModelOption(id: "claude-haiku-5-5", label: "最快（推薦）"),
                    CloudModelOption(id: "claude-sonnet-5-5", label: "平衡"),
                    CloudModelOption(id: "claude-opus-5-5", label: "最高品質")]
        case .openai:
            return [CloudModelOption(id: "gpt-6-luna", label: "最快（推薦）"),
                    CloudModelOption(id: "gpt-6.1-terra", label: "平衡"),
                    CloudModelOption(id: "gpt-6.1-sol", label: "高品質")]
        case .openrouter:
            return [CloudModelOption(id: "anthropic/claude-haiku-5.5", label: "最快（推薦）"),
                    CloudModelOption(id: "openai/gpt-6-luna", label: "便宜快速"),
                    CloudModelOption(id: "deepseek/deepseek-v4.1-flash-1017", label: "最便宜")]
        case .gemini:
            return [CloudModelOption(id: "gemini-3.1-flash-lite", label: "最快（推薦）"),
                    CloudModelOption(id: "gemini-3.5-flash-lite", label: "較新")]
        case .custom:
            return []
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .openrouter: return "sk-or-…"
        case .gemini: return "AIza…"
        case .custom: return "選填，本機伺服器通常不需要"
        }
    }

    /// Where the user creates a key.
    var keyURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .custom: return nil
        }
    }

    var needsBaseURL: Bool { self == .custom }
    /// Local OpenAI-compatible servers usually run without auth.
    var keyRequired: Bool { self != .custom }

    /// Who receives the subtitle text, as the consent prompt names it
    /// (`MultiSubConfig.cloudConsent`). A custom server has no name of its
    /// own, so the prompt points at the address the user typed.
    var consentRecipient: String { self == .custom ? "你填的 API 網址" : displayName }
}

enum CloudLLMError: Error, LocalizedError, Sendable, Equatable {
    /// Associated strings are the short, user-facing message (Traditional
    /// Chinese), already scrubbed of anything key-like.
    case authFailed(String)
    case rateLimited(String)
    case network(String)
    case badResponse(String)
    case provider(Int, String)
    /// A 2xx reply with no usable answer: the provider declined (Anthropic
    /// `stop_reason: "refusal"`, OpenAI `finish_reason: "content_filter"` or
    /// `message.refusal`), or the output budget ran out before any answer
    /// (empty text with `max_tokens`/`length`, or reasoning that never
    /// closed). Kept apart from `badResponse` so callers can treat it as
    /// "nothing for this input" instead of a failed request: a whole batch
    /// is usually refused because of one line, and retrying it unchanged
    /// would only be refused again.
    case refused(String)

    /// Stable code shared with the extension (`error` in native replies).
    var code: String {
        switch self {
        case .authFailed: return "auth-failed"
        case .rateLimited: return "rate-limited"
        case .network: return "network"
        case .badResponse, .provider, .refused: return "provider-error"
        }
    }

    var message: String {
        switch self {
        case .authFailed(let m), .rateLimited(let m), .network(let m), .badResponse(let m), .provider(_, let m),
             .refused(let m):
            return m
        }
    }

    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }

    var errorDescription: String? { message }
}

struct CloudLLMClient: Sendable {
    let provider: CloudProvider
    /// Resolved model id (an empty setting falls back to the provider default).
    let model: String
    /// Resolved base URL without a trailing slash.
    let baseURL: String
    private let apiKey: String?

    static let anthropicVersion = "2026-10-21"
    static let requestTimeout: TimeInterval = 60
    /// Retries for 429/5xx/529 on top of the first attempt.
    private static let maxTransientRetries = 2
    private static let maxRetryDelay: Double = 8

    init(provider: CloudProvider, model: String, baseURL: String, apiKey: String?) {
        self.provider = provider
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedModel.isEmpty ? provider.defaultModel : trimmedModel
        // Only a custom server takes a user-supplied base URL. For the named
        // providers a leftover value (typed while "custom" was selected) must
        // not redirect requests, and with them the key, somewhere else.
        var base = provider.needsBaseURL
            ? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : provider.defaultBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        // People often paste the full endpoint they saw in their server's docs.
        for suffix in ["/chat/completions", "/models"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        self.baseURL = base
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
    }

    // MARK: - Public API

    /// One non-streaming completion. Returns the model's answer with any
    /// leading reasoning block removed. The text may be empty when the model
    /// chose to say nothing; a refusal, a content filter, or an output budget
    /// that ran out before the answer throws `CloudLLMError.refused`, and
    /// every other failure throws another `CloudLLMError`.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let data = try await perform(hasOptionalParams: provider != .custom) { includeOptional in
            try self.completionRequest(system: system, user: user, maxTokens: maxTokens,
                                       includeOptional: includeOptional)
        }
        return try parseCompletion(data)
    }

    /// Model ids the key can use, in the provider's own order (Anthropic and
    /// OpenRouter list newest/most popular first). Obvious non-chat models
    /// (embeddings, speech, images) are left out for the named providers.
    func listModels() async throws -> [String] {
        let path = provider == .anthropic ? "models?limit=1000" : "models"
        let data = try await perform(hasOptionalParams: false) { _ in
            var request = URLRequest(url: try self.endpoint(path))
            request.httpMethod = "GET"
            self.applyHeaders(&request)
            return request
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]]
        else { throw CloudLLMError.badResponse("AI 服務回傳的模型清單格式不正確。") }
        var seen = Set<String>()
        var ids: [String] = []
        for entry in entries {
            guard var id = entry["id"] as? String, !id.isEmpty else { continue }
            // Gemini's OpenAI-compatible list uses "models/<id>"; chat
            // completions want the bare id.
            if provider == .gemini, id.hasPrefix("models/") { id.removeFirst("models/".count) }
            if provider != .custom, Self.isNonChatModel(id) { continue }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    // MARK: - Requests

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL + "/" + path),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil
        else { throw CloudLLMError.network("API 網址格式不正確，請檢查設定。") }
        return url
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        switch provider {
        case .anthropic:
            if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openai, .openrouter, .gemini, .custom:
            if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
            if provider == .openrouter {
                // Optional attribution header; shows the app name in the
                // user's OpenRouter activity log.
                request.setValue("MultiSub", forHTTPHeaderField: "X-OpenRouter-Title")
            }
        }
    }

    /// `includeOptional` toggles the per-provider latency settings. They are
    /// dropped on a 400 retry so a user-picked model with different rules
    /// still works; `max_tokens` is never optional.
    private func completionRequest(system: String, user: String, maxTokens: Int,
                                   includeOptional: Bool) throws -> URLRequest {
        var body: [String: Any]
        let url: URL
        switch provider {
        case .anthropic:
            url = try endpoint("messages")
            body = [
                "model": model,
                "max_tokens": maxTokens,
                "messages": [["role": "user", "content": user]],
            ]
            if !system.isEmpty { body["system"] = system }
            // Never send temperature/top_p/top_k: current Claude models reject them.
            if includeOptional { body["output_config"] = ["effort": "low"] }
        case .openai, .openrouter, .gemini, .custom:
            url = try endpoint("chat/completions")
            var messages: [[String: Any]] = []
            if !system.isEmpty { messages.append(["role": "system", "content": system]) }
            messages.append(["role": "user", "content": user])
            body = ["model": model, "messages": messages]
            if provider == .openai {
                body["max_completion_tokens"] = maxTokens
            } else {
                body["max_tokens"] = maxTokens
            }
            if includeOptional {
                switch provider {
                case .openai: body["reasoning_effort"] = "none"
                case .openrouter: body["reasoning"] = ["effort": "low"]
                case .gemini: body["reasoning_effort"] = "minimal"
                case .anthropic, .custom: break
                }
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends the request built by `build`, handling the two retry policies:
    /// one retry without optional parameters on a plain 400, and up to two
    /// backed-off retries on 429/500/502/503/529. Returns the body of a 2xx.
    private func perform(hasOptionalParams: Bool,
                         _ build: (_ includeOptional: Bool) throws -> URLRequest) async throws -> Data {
        var includeOptional = hasOptionalParams
        var transientRetries = 0
        while true {
            let request = try build(includeOptional)
            let (data, response) = try await send(request)
            let status = response.statusCode
            if (200..<300).contains(status) { return data }

            let detail = errorDetail(from: data, status: status)
            let lower = detail.lowercased()
            if status == 400, includeOptional, !Self.looksLikeAuthProblem(lower), !Self.looksLikeCreditProblem(lower) {
                includeOptional = false
                continue
            }
            if [429, 500, 502, 503, 529].contains(status),
               transientRetries < Self.maxTransientRetries,
               !Self.looksLikeCreditProblem(lower) {
                let delay = Self.retryDelay(response, attempt: transientRetries)
                transientRetries += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            throw Self.classify(status: status, detail: detail)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudLLMError.badResponse("AI 服務的回應格式不正確。")
            }
            return (data, http)
        } catch let error as CloudLLMError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw CloudLLMError.network(Self.networkMessage(error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudLLMError.network("網路錯誤：\(scrub(error.localizedDescription))")
        }
    }

    /// Ephemeral: nothing about these requests (cookies, cache, credentials)
    /// is written to disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Responses

    static let refusalMessage = "AI 服務拒絕處理這段字幕。"
    static let noAnswerMessage = "AI 服務沒有回傳結果（輸出長度用完了），可以換一個模型再試。"

    /// finish_reason values that mean the provider blocked the output.
    /// OpenAI and OpenRouter send "content_filter"; the others are what
    /// Gemini-style safety blocks look like when a gateway passes them on.
    private static let blockedFinishReasons: Set<String> = [
        "content_filter", "refusal", "safety", "prohibited_content", "blocklist", "spii", "recitation",
    ]

    /// Not private so the Foundation-only scratch build can feed it canned
    /// provider replies.
    func parseCompletion(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudLLMError.badResponse("AI 服務的回應格式不正確。")
        }
        let raw: String
        // The reply stopped because it hit `max_tokens`, not because the
        // model was done.
        let hitOutputLimit: Bool
        switch provider {
        case .anthropic:
            let stopReason = object["stop_reason"] as? String
            // A safety classifier declined (HTTP 200). Any partial text is
            // not an answer to show as a subtitle.
            if stopReason == "refusal" { throw CloudLLMError.refused(Self.refusalMessage) }
            // Only `text` blocks carry the answer; thinking/tool blocks are skipped.
            guard let content = object["content"] as? [[String: Any]] else {
                throw CloudLLMError.badResponse("AI 服務的回應格式不正確。")
            }
            raw = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            hitOutputLimit = stopReason == "max_tokens"
        case .openai, .openrouter, .gemini, .custom:
            guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
                // OpenRouter can report upstream failures inside a 200 body.
                if object["error"] != nil {
                    throw Self.classify(status: (object["error"] as? [String: Any])?["code"] as? Int ?? 502,
                                        detail: errorDetail(from: data, status: 502))
                }
                throw CloudLLMError.badResponse("AI 服務的回應格式不正確。")
            }
            let finishReason = (first["finish_reason"] as? String)?.lowercased()
            let message = first["message"] as? [String: Any]
            if let finishReason, Self.blockedFinishReasons.contains(finishReason) {
                throw CloudLLMError.refused(Self.refusalMessage)
            }
            if let refusal = message?["refusal"] as? String,
               !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CloudLLMError.refused(Self.refusalMessage)
            }
            switch message?["content"] {
            case let text as String:
                raw = text
            case let parts as [[String: Any]]:
                if parts.contains(where: { ($0["type"] as? String) == "refusal" }) {
                    throw CloudLLMError.refused(Self.refusalMessage)
                }
                raw = parts.compactMap { $0["text"] as? String }.joined()
            default:
                // null content with no refusal: usually the budget went to reasoning.
                raw = ""
            }
            hitOutputLimit = finishReason == "length"
        }
        let (text, reasoningUnclosed) = Self.stripReasoning(raw)
        // Empty because the budget ran out (or the reasoning never ended) is
        // a failure to answer, not an empty translation; an empty reply the
        // model finished on purpose is left for the caller's parser.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hitOutputLimit || reasoningUnclosed {
            throw CloudLLMError.refused(Self.noAnswerMessage)
        }
        return text
    }

    /// Removes reasoning that OpenAI-compatible servers sometimes leave in
    /// `content` (vLLM without a reasoning parser, LM Studio with reasoning
    /// separation off, DeepSeek-R1 / Qwen3-style models). Left in, its
    /// numbered notes and draft JSON are what the parsers find first, and the
    /// single-line path would show the whole block as the subtitle.
    ///
    /// Handles leading `<think>…</think>` / `<thinking>…</thinking>` blocks
    /// (case-insensitive, after optional whitespace, possibly several), and a
    /// lone closing tag whose opening tag was part of the chat template.
    /// `unclosed` is true when a block opened and never closed, i.e. the
    /// output was cut off inside the reasoning; `text` is then empty, since
    /// what's there is reasoning, not an answer.
    static func stripReasoning(_ raw: String) -> (text: String, unclosed: Bool) {
        var rest = raw
        var stripped = false
        while let open = reasoningOpenTag.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let openRange = Range(open.range, in: rest),
              let nameRange = Range(open.range(at: 1), in: rest) {
            let closing = "</" + rest[nameRange] + ">"
            guard let close = rest.range(of: closing, options: .caseInsensitive,
                                         range: openRange.upperBound..<rest.endIndex)
            else { return ("", true) }
            rest = String(rest[close.upperBound...])
            stripped = true
        }
        if !stripped,
           let close = orphanClosingTag.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let closeRange = Range(close.range, in: rest) {
            rest = String(rest[closeRange.upperBound...])
            stripped = true
        }
        guard stripped else { return (raw, false) }
        return (String(rest.drop(while: { $0.isWhitespace })), false)
    }

    private static let reasoningOpenTag = try! NSRegularExpression(
        pattern: #"^\s*<(think|thinking)(?:\s[^>]*)?>"#, options: [.caseInsensitive])
    /// A closing tag with no opening tag anywhere before it.
    private static let orphanClosingTag = try! NSRegularExpression(
        pattern: #"^(?:(?!<think)[\s\S])*?</(?:think|thinking)>"#, options: [.caseInsensitive])

    /// The provider's own error text (scrubbed, truncated), or the HTTP
    /// status phrase when the body has none.
    private func errorDetail(from data: Data, status: Int) -> String {
        var text: String?
        if let json = try? JSONSerialization.jsonObject(with: data) {
            text = Self.errorText(in: json)
        } else if let raw = String(data: data, encoding: .utf8),
                  !raw.isEmpty, !raw.lowercased().contains("<html") {
            text = raw
        }
        var detail = scrub(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        if detail.isEmpty { detail = HTTPURLResponse.localizedString(forStatusCode: status) }
        if detail.count > 200 { detail = String(detail.prefix(200)) + "…" }
        return detail
    }

    /// Handles `{"error":{"message"}}` (Anthropic/OpenAI/OpenRouter),
    /// `[{"error":{…}}]` (Google), `{"error":"…"}` and `{"message":"…"}`.
    private static func errorText(in json: Any) -> String? {
        if let array = json as? [Any], let first = array.first { return errorText(in: first) }
        guard let object = json as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let type = error["type"] as? String { return type }
        }
        if let error = object["error"] as? String { return error }
        if let message = object["message"] as? String { return message }
        if let detail = object["detail"] as? String { return detail }
        return nil
    }

    private static func classify(status: Int, detail: String) -> CloudLLMError {
        let lower = detail.lowercased()
        if status == 402 || looksLikeCreditProblem(lower) {
            return .rateLimited("額度不足：請到 AI 服務的網站儲值，或調高用量上限。（\(detail)）")
        }
        if status == 401 || status == 403 || looksLikeAuthProblem(lower) {
            return .authFailed("API Key 無效或沒有權限。（\(detail)）")
        }
        switch status {
        case 429:
            return .rateLimited("請求太頻繁或超過用量限制，請稍後再試。（\(detail)）")
        case 404:
            return .provider(status, "找不到這個模型或網址，請檢查設定。（\(detail)）")
        case 529:
            return .provider(status, "服務暫時過載，請稍後再試。")
        default:
            return .provider(status, "AI 服務回傳錯誤（HTTP \(status)）：\(detail)")
        }
    }

    private static func looksLikeCreditProblem(_ lower: String) -> Bool {
        ["credit balance", "insufficient credit", "insufficient_quota", "exceeded your current quota",
         "spend limit", "spending limit", "billing", "payment required", "requires more credits"]
            .contains { lower.contains($0) }
    }

    /// Some providers (Gemini) answer a bad key with 400, not 401.
    private static func looksLikeAuthProblem(_ lower: String) -> Bool {
        ["api key not valid", "invalid api key", "invalid x-api-key", "incorrect api key",
         "invalid authentication", "api_key_invalid", "unauthorized"]
            .contains { lower.contains($0) }
    }

    private static func networkMessage(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "連線逾時，請檢查網路後再試。"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "沒有網路連線。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "連不上伺服器，請確認網址與網路。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "無法建立安全連線。"
        default:
            return "網路錯誤（\(error.code.rawValue)）。"
        }
    }

    /// `retry-after` (seconds or HTTP date) when the provider sends one,
    /// otherwise 1 s then 2 s; never more than `maxRetryDelay`.
    private static func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> Double {
        if let raw = response.value(forHTTPHeaderField: "retry-after-ms"), let ms = Double(raw) {
            return min(max(ms / 1000, 0), maxRetryDelay)
        }
        if let raw = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces) {
            if let seconds = Double(raw) { return min(max(seconds, 0), maxRetryDelay) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) {
                return min(max(date.timeIntervalSinceNow, 0), maxRetryDelay)
            }
        }
        let base = pow(2.0, Double(attempt))
        return min(base + Double.random(in: 0...0.25), maxRetryDelay)
    }

    private static func isNonChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return ["embedding", "embed-", "tts", "whisper", "transcribe", "dall-e", "image", "imagen",
                "moderation", "realtime", "audio", "veo", "aqa", "search"]
            .contains { lower.contains($0) }
    }

    /// Removes the key itself and anything shaped like a key from provider
    /// text before it reaches the UI or a log.
    private func scrub(_ text: String) -> String {
        var result = text
        if let apiKey, !apiKey.isEmpty { result = result.replacingOccurrences(of: apiKey, with: "••••") }
        return Self.keyPattern.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "••••")
    }

    private static let keyPattern = try! NSRegularExpression(
        pattern: #"(sk-[A-Za-z0-9_\-*]{6,}|AIza[0-9A-Za-z_\-]{10,}|Bearer\s+\S+)"#)
}

extension CloudLLMClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Keeps the key out of `print`, `dump`, string interpolation and os_log.
    var description: String { "CloudLLMClient(\(provider.rawValue), \(model))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["provider": provider, "model": model, "baseURL": baseURL])
    }
}
