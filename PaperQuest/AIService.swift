import Foundation
import PaperCore
import Security
import UIKit

/// The owner's own Claude and ChatGPT API keys, in the Keychain (synchronizable with iCloud Keychain), so they
/// survive every update and a reinstall. Never stored in files, never built into the app (the IPA is public).
enum KeyStore {
    private static let service = "com.avradip.paperquest.keys"

    private static func base(_ p: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue]
    }

    static func key(_ p: AIProvider) -> String? {
        var q = base(p)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasKey(_ p: AIProvider) -> Bool { !(key(p) ?? "").isEmpty }

    static func save(_ value: String, for p: AIProvider) {
        var del = base(p)
        del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(del as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base(p)
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

enum AIService {
    static let providerKey = "ai.provider"
    static let backupKey = "ai.backup"
    static let openAIModelKey = "ai.openai.model"
    private static let autoModelKey = "ai.openai.autoModel"
    private static let autoModelDateKey = "ai.openai.autoModelDate"

    static var chosen: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .claude
    }

    static var useBackup: Bool { UserDefaults.standard.object(forKey: backupKey) as? Bool ?? true }

    /// Asks the chosen service (and, if it fails for a passing reason, the other one). Returns who answered.
    static func ask(system: String, cached: String, context: String, provider: AIProvider? = nil) async throws -> (AssistantResult, AIProvider) {
        let first = provider ?? chosen
        var order = [first]
        let other: AIProvider = first == .claude ? .chatgpt : .claude
        if useBackup && KeyStore.hasKey(other) { order.append(other) }
        var last: Error = AIFailure.noKey(first)
        for (n, p) in order.enumerated() {
            do {
                let text = try await rawAsk(p, system: system, cached: cached, context: context)
                guard let result = AssistantResult.parse(text) else { throw AIFailure.unreadable }
                return (result, p)
            } catch {
                last = error
                let passing = (error as? AIFailure)?.worthTryingOther ?? (error is URLError)
                if n == order.count - 1 || !passing { break }
            }
        }
        throw last
    }

    static func rawAsk(_ p: AIProvider, system: String, cached: String, context: String) async throws -> String {
        guard let key = KeyStore.key(p), !key.isEmpty else { throw AIFailure.noKey(p) }
        let bg = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "ai-call", expirationHandler: nil) }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
        switch p {
        case .claude: return try await claude(key: key, system: system, cached: cached, context: context)
        case .chatgpt: return try await chatGPT(key: key, system: system, cached: cached, context: context)
        }
    }

    private static func claude(key: String, system: String, cached: String, context: String) async throws -> String {
        var req = URLRequest(url: ClaudeWire.endpoint)
        req.httpMethod = "POST"
        for (k, v) in ClaudeWire.headers(apiKey: key) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ClaudeWire.body(system: system, cached: cached, context: context,
                                                                                 schema: AssistantPrompt.schemaObject))
        req.timeoutInterval = 900
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await b in bytes { body.append(b) }
            throw ClaudeWire.failure(status: status, body: body)
        }
        var stream = ClaudeStream()
        for try await line in bytes.lines { stream.feed(line: line) }
        return try ClaudeWire.finish(stream)
    }

    private static func chatGPT(key: String, system: String, cached: String, context: String) async throws -> String {
        let model = await openAIModel(key: key)
        func send(effort: String?) async throws -> (Int, Data) {
            var req = URLRequest(url: OpenAIWire.endpoint)
            req.httpMethod = "POST"
            for (k, v) in OpenAIWire.headers(apiKey: key) { req.setValue(v, forHTTPHeaderField: k) }
            req.httpBody = try JSONSerialization.data(withJSONObject: OpenAIWire.body(model: model, system: system, cached: cached, context: context,
                                                                                     effort: effort, schema: AssistantPrompt.schemaObject))
            req.timeoutInterval = 900
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        var (status, data) = try await send(effort: "high")
        // A model without reasoning settings rejects the effort field: ask again without it.
        if status == 400, String(decoding: data, as: UTF8.self).lowercased().contains("reasoning") {
            (status, data) = try await send(effort: nil)
        }
        return try OpenAIWire.text(status: status, data: data)
    }

    /// The model typed in Settings, else "astra" (or the newest GPT) from the account's model list, checked daily.
    static func openAIModel(key: String) async -> String {
        let ud = UserDefaults.standard
        if let typed = ud.string(forKey: openAIModelKey)?.trimmingCharacters(in: .whitespaces), !typed.isEmpty { return typed }
        if let cached = ud.string(forKey: autoModelKey), let when = ud.object(forKey: autoModelDateKey) as? Date,
           Date().timeIntervalSince(when) < 86_400 { return cached }
        var req = URLRequest(url: OpenAIWire.modelsEndpoint)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
           let picked = OpenAIWire.pickModel(fromModelsList: data) {
            ud.set(picked, forKey: autoModelKey)
            ud.set(Date(), forKey: autoModelDateKey)
            return picked
        }
        return ud.string(forKey: autoModelKey) ?? OpenAIWire.fallbackModel
    }

    static var autoPickedModel: String? { UserDefaults.standard.string(forKey: autoModelKey) }

    /// A small real call to check a key.
    static func test(_ p: AIProvider) async throws -> String {
        let text = try await rawAsk(p, system: AssistantPrompt.system, cached: "MANUSCRIPT: (empty test)",
                                    context: "This is a connection test from Paper Quest Settings. Reply with one friendly line in \"reply\" and leave every list empty.")
        return AssistantResult.parse(text)?.reply ?? "Connected."
    }
}
