import Foundation

/// The Claude Messages API request and response, as plain data (the app does the HTTP call).
public enum ClaudeWire {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let model = "claude-opus-5-5"
    public static let apiVersion = "2026-10-21"
    /// Server-side refusal fallback ("default" routing by refusal category).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public enum Effort: String, Sendable { case low, medium, high }

    public static func headers(apiKey: String) -> [String: String] {
        [
            "x-api-key": apiKey,
            "anthropic-version": apiVersion,
            "anthropic-beta": fallbackBeta,
            "content-type": "application/json",
        ]
    }

    public static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    public static func jpegBlock(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    /// Body for one structured-output call.
    public static func body(system: String, content: [[String: Any]], schema: [String: Any],
                            effort: Effort, maxTokens: Int = 16000) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "fallbacks": "default",
            "output_config": [
                "effort": effort.rawValue,
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": content]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    public enum Failure: LocalizedError, Equatable {
        case noKey
        case badKey
        case rateLimited
        case overloaded
        case refused
        case tooLong
        case server(Int, String)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .noKey: return "Add a Claude or ChatGPT API key in Settings first."
            case .badKey: return "The API key was rejected. Check it in Settings."
            case .rateLimited: return "The AI service is busy right now (rate limit). Give it a minute and try again."
            case .overloaded: return "The AI service is overloaded at the moment. Try again in a minute."
            case .refused: return "The AI couldn't help with this one. Try a different photo or wording."
            case .tooLong: return "That was too much for one go. Try a photo with fewer things in it."
            case let .server(code, message): return "AI request failed (\(code)): \(message)"
            case .unreadable: return "The AI sent back an answer the app couldn't read. Please try again."
            }
        }
    }

    /// Turns an HTTP status and body into the JSON text Claude wrote, or a friendly failure.
    public static func extractJSONText(status: Int, data: Data) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            switch status {
            case 401, 403: throw Failure.badKey
            case 429: throw Failure.rateLimited
            case 529: throw Failure.overloaded
            default: throw Failure.server(status, message)
            }
        }
        guard let object else { throw Failure.unreadable }
        let stop = object["stop_reason"] as? String
        if stop == "refusal" { throw Failure.refused }
        if stop == "max_tokens" { throw Failure.tooLong }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw Failure.unreadable }
        return text
    }

    public static func decode<T: Decodable>(_ type: T.Type, status: Int, data: Data) throws -> T {
        let text = try extractJSONText(status: status, data: data)
        do {
            return try AIResults.decoder.decode(T.self, from: Data(text.utf8))
        } catch {
            throw Failure.unreadable
        }
    }
}
