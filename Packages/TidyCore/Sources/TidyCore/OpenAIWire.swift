import Foundation

/// Provider-neutral message content.
public enum AIContent: Sendable {
    case text(String)
    case jpeg(Data)
}

public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case claude, chatgpt

    public var label: String { self == .claude ? "Claude" : "ChatGPT" }
}

/// Which service answers, chosen in Settings.
public enum AIPreference: String, CaseIterable, Codable, Sendable {
    case claudeFirst, chatgptFirst, claudeOnly, chatgptOnly

    public var label: String {
        switch self {
        case .claudeFirst: return "Claude, ChatGPT as backup"
        case .chatgptFirst: return "ChatGPT, Claude as backup"
        case .claudeOnly: return "Claude only"
        case .chatgptOnly: return "ChatGPT only"
        }
    }

    /// Services to try, in order, among those that have a key.
    public func order(hasClaude: Bool, hasChatGPT: Bool) -> [AIProvider] {
        let wanted: [AIProvider]
        switch self {
        case .claudeFirst: wanted = [.claude, .chatgpt]
        case .chatgptFirst: wanted = [.chatgpt, .claude]
        case .claudeOnly: wanted = [.claude]
        case .chatgptOnly: wanted = [.chatgpt]
        }
        return wanted.filter { $0 == .claude ? hasClaude : hasChatGPT }
    }
}

extension ClaudeWire {
    public static func blocks(_ content: [AIContent]) -> [[String: Any]] {
        content.map {
            switch $0 {
            case let .text(t): return textBlock(t)
            case let .jpeg(d): return jpegBlock(d)
            }
        }
    }

    /// Whether another service should be tried after this failure.
    public static func worthTryingAnother(_ error: Error) -> Bool {
        guard let f = error as? Failure else { return error is URLError }
        switch f {
        case .noKey, .tooLong: return false
        default: return true
        }
    }
}

/// The OpenAI Responses API request and response, as plain data (the app does the HTTP call).
public enum OpenAIWire {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    public static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
    /// Used when the account's model list can't be read.
    public static let fallbackModel = "gpt-5"

    public static func headers(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "content-type": "application/json"]
    }

    public static func blocks(_ content: [AIContent]) -> [[String: Any]] {
        content.map {
            switch $0 {
            case let .text(t): return ["type": "input_text", "text": t]
            case let .jpeg(d): return ["type": "input_image", "image_url": "data:image/jpeg;base64,\(d.base64EncodedString())"]
            }
        }
    }

    /// Reasoning models (gpt-5 and later, o-series) take an effort setting; others reject it.
    public static func supportsReasoning(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.hasPrefix("o") { return true }
        guard m.hasPrefix("gpt-"), let major = Int(m.dropFirst(4).prefix { $0.isNumber }) else { return false }
        return major >= 5
    }

    public static func body(model: String, system: String, content: [AIContent], schema: [String: Any], schemaName: String,
                            effort: ClaudeWire.Effort, maxTokens: Int = 16000) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": [["role": "user", "content": blocks(content)]],
            "max_output_tokens": maxTokens,
            "text": ["format": ["type": "json_schema", "name": schemaName, "schema": schema, "strict": true]],
            "store": false,
        ]
        if supportsReasoning(model) { body["reasoning"] = ["effort": effort.rawValue] }
        return try JSONSerialization.data(withJSONObject: body)
    }

    public static func extractJSONText(status: Int, data: Data) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            switch status {
            case 401, 403: throw ClaudeWire.Failure.badKey
            case 429: throw ClaudeWire.Failure.rateLimited
            case 503: throw ClaudeWire.Failure.overloaded
            default: throw ClaudeWire.Failure.server(status, message)
            }
        }
        guard let object else { throw ClaudeWire.Failure.unreadable }
        if object["status"] as? String == "incomplete" {
            let reason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
            throw reason == "content_filter" ? ClaudeWire.Failure.refused : ClaudeWire.Failure.tooLong
        }
        var text = ""
        for item in object["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "refusal": throw ClaudeWire.Failure.refused
                case "output_text": text += part["text"] as? String ?? ""
                default: break
                }
            }
        }
        guard !text.isEmpty else { throw ClaudeWire.Failure.unreadable }
        return text
    }

    public static func decode<T: Decodable>(_ type: T.Type, status: Int, data: Data) throws -> T {
        let text = try extractJSONText(status: status, data: data)
        do {
            return try AIResults.decoder.decode(T.self, from: Data(text.utf8))
        } catch {
            throw ClaudeWire.Failure.unreadable
        }
    }

    /// Newest full-size GPT model the account can use, from GET /v1/models.
    public static func pickModel(fromModelsList data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        let skip = ["mini", "nano", "audio", "realtime", "image", "search", "transcribe", "tts", "embedding",
                    "codex", "instruct", "oss", "chat-latest", "preview", "vision", "turbo", "16k", "moderation"]
        let candidates = list.compactMap { m -> (String, Double)? in
            guard let id = m["id"] as? String else { return nil }
            let lower = id.lowercased()
            guard lower.hasPrefix("gpt-"), !skip.contains(where: { lower.contains($0) }) else { return nil }
            // Prefer the moving alias over dated snapshots such as gpt-5-2025-08-07.
            if lower.range(of: #"-20\d\d-\d\d-\d\d$"#, options: .regularExpression) != nil { return nil }
            let created = (m["created"] as? Double) ?? Double((m["created"] as? Int) ?? 0)
            return (id, created)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }
}

/// OpenAI image editing ("how will it look"): the room photo plus a description, returned as a new picture.
public enum OpenAIImageWire {
    public static let endpoint = URL(string: "https://api.openai.com/v1/images/edits")!
    public static let defaultModel = "gpt-image-1"

    /// multipart/form-data body; returns (content type header, body).
    public static func request(model: String, prompt: String, jpeg: Data, size: String = "1024x1024",
                               boundary: String = "TidyAtlas-\(UUID().uuidString)") -> (contentType: String, body: Data) {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("prompt", prompt)
        field("size", size)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"room.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return ("multipart/form-data; boundary=\(boundary)", body)
    }

    /// The picture bytes from the response.
    public static func image(status: Int, data: Data) throws -> Data {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            switch status {
            case 401, 403: throw ClaudeWire.Failure.badKey
            case 429: throw ClaudeWire.Failure.rateLimited
            case 400 where message.lowercased().contains("safety"): throw ClaudeWire.Failure.refused
            default: throw ClaudeWire.Failure.server(status, message)
            }
        }
        guard let first = (object?["data"] as? [[String: Any]])?.first,
              let b64 = first["b64_json"] as? String, let bytes = Data(base64Encoded: b64) else {
            throw ClaudeWire.Failure.unreadable
        }
        return bytes
    }
}
