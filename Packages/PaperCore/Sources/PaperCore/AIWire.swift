import Foundation

public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case claude, chatgpt
    public var label: String { self == .claude ? "Claude" : "ChatGPT" }
}

public enum AIFailure: LocalizedError, Equatable {
    case noKey(AIProvider)
    case badKey(AIProvider)
    case rateLimited
    case overloaded
    case refused
    case tooLong
    case server(Int, String)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .noKey(let p): return "Add your \(p.label) API key in Settings first."
        case .badKey(let p): return "\(p.label) rejected the API key. Check it in Settings."
        case .rateLimited: return "The AI service is busy (rate limit). Try again in a minute."
        case .overloaded: return "The AI service is overloaded right now. Try again in a minute."
        case .refused: return "The AI declined this request. Try rewording it."
        case .tooLong: return "The answer ran out of room. Ask for a smaller piece at a time."
        case let .server(code, message): return "AI request failed (\(code)): \(message)"
        case .unreadable: return "The AI's answer couldn't be read. Please try again."
        }
    }

    /// Whether the other service is worth trying after this failure.
    public var worthTryingOther: Bool {
        switch self {
        case .noKey, .tooLong: return false
        default: return true
        }
    }
}

/// Claude Messages API (raw HTTPS: there is no official Swift SDK). Opus 5.5 at effort high, structured output,
/// streamed, with the manuscript as a cached block and server-side refusal fallback.
public enum ClaudeWire {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let model = "claude-opus-5-5"
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public static func headers(apiKey: String) -> [String: String] {
        ["x-api-key": apiKey, "anthropic-version": apiVersion, "anthropic-beta": fallbackBeta,
         "content-type": "application/json", "accept": "text/event-stream"]
    }

    public static func body(system: String, cached: String, context: String, effort: String = "high",
                            schema: [String: Any], maxTokens: Int = 32000) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": [["type": "text", "text": system]],
            "fallbacks": "default",
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": cached, "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": context],
            ]]],
        ]
    }

    public static func failure(status: Int, body: Data) -> AIFailure {
        let message = (((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401, 403: return .badKey(.claude)
        case 429: return .rateLimited
        case 529, 503: return .overloaded
        default: return .server(status, message ?? "unknown error")
        }
    }

    /// The final text of a finished stream, or why there is none.
    public static func finish(_ s: ClaudeStream) throws -> String {
        if let e = s.errorMessage { throw e.lowercased().contains("overload") ? AIFailure.overloaded : AIFailure.server(200, e) }
        if s.stopReason == "refusal" { throw AIFailure.refused }
        if s.stopReason == "max_tokens" { throw AIFailure.tooLong }
        guard !s.text.isEmpty else { throw AIFailure.unreadable }
        return s.text
    }
}

/// OpenAI Responses API (ChatGPT). The model is the one typed in Settings, else one named "astra" on the account,
/// else the newest full GPT model; reasoning effort high.
public enum OpenAIWire {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    public static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
    public static let fallbackModel = "gpt-5"

    public static func headers(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "content-type": "application/json"]
    }

    public static func body(model: String, system: String, cached: String, context: String, effort: String? = "high",
                            schema: [String: Any], maxTokens: Int = 32000) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": [["role": "user", "content": [["type": "input_text", "text": cached], ["type": "input_text", "text": context]]]],
            "max_output_tokens": maxTokens,
            "text": ["format": ["type": "json_schema", "name": "paper_quest_answer", "schema": schema, "strict": true]],
            "store": false,
        ]
        if let effort { b["reasoning"] = ["effort": effort] }
        return b
    }

    public static func text(status: Int, data: Data) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            switch status {
            case 401, 403: throw AIFailure.badKey(.chatgpt)
            case 429: throw AIFailure.rateLimited
            case 503: throw AIFailure.overloaded
            default: throw AIFailure.server(status, message)
            }
        }
        guard let object else { throw AIFailure.unreadable }
        if object["status"] as? String == "incomplete" {
            let reason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
            throw reason == "content_filter" ? AIFailure.refused : AIFailure.tooLong
        }
        var text = ""
        for item in object["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "refusal" { throw AIFailure.refused }
                if part["type"] as? String == "output_text" { text += part["text"] as? String ?? "" }
            }
        }
        guard !text.isEmpty else { throw AIFailure.unreadable }
        return text
    }

    /// From GET /v1/models: a model whose id contains `prefer` ("astra"), newest first; else the newest full GPT.
    public static func pickModel(fromModelsList data: Data, prefer: String = "astra") -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        let entries = list.compactMap { m -> (id: String, created: Double)? in
            guard let id = m["id"] as? String else { return nil }
            return (id, (m["created"] as? Double) ?? Double((m["created"] as? Int) ?? 0))
        }
        let dated = #"-20\d\d-\d\d-\d\d$"#
        let preferred = entries.filter { e in
            let l = e.id.lowercased()
            return l.contains(prefer) && !l.contains("mini") && !l.contains("nano")
        }
        if let exact = preferred.first(where: { $0.id.lowercased() == prefer }) { return exact.id }
        if let best = preferred.filter({ $0.id.range(of: dated, options: .regularExpression) == nil }).max(by: { $0.created < $1.created }) {
            return best.id
        }
        let skip = ["mini", "nano", "audio", "realtime", "image", "search", "transcribe", "tts", "embedding",
                    "codex", "instruct", "oss", "chat-latest", "preview", "vision", "turbo", "16k", "moderation"]
        let gpt = entries.filter { e in
            let l = e.id.lowercased()
            return l.hasPrefix("gpt-") && !skip.contains(where: { l.contains($0) }) && l.range(of: dated, options: .regularExpression) == nil
        }
        return gpt.max { $0.created < $1.created }?.id
    }
}
