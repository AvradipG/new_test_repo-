import Foundation
import Security
import UIKit
import TidyCore

/// The owner's own API keys (Claude, ChatGPT), kept in the Keychain, never in a file or the database.
///
/// Kept through every update: app updates (TestFlight or App Store) never touch the Keychain. The items are also
/// synchronizable, so iCloud Keychain (when on) restores them after deleting and reinstalling the app or on a new
/// iPhone. Keys are never built into the app: the IPA is published on a public repository.
enum KeyStore {
    private static let service = "com.avradip.tidyatlas.keys"

    private static func base(_ p: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue]
    }

    static func key(_ p: AIProvider) -> String? {
        if let v = read(base(p)) { return v }
        // 1.0 stored the Claude key under another name, on this device only: move it over once.
        if p == .claude, let old = read([kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: "com.avradip.tidyatlas.claude",
                                         kSecAttrAccount as String: "anthropic-api-key"]) {
            save(old, for: .claude)
            return old
        }
        return nil
    }

    static func hasKey(_ p: AIProvider) -> Bool { !(key(p) ?? "").isEmpty }
    /// Any AI key at all.
    static var hasKey: Bool { hasKey(.claude) || hasKey(.chatgpt) }

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
            // iCloud Keychain unavailable: keep it on this iPhone (still kept through updates).
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func read(_ q: [String: Any]) -> String? {
        var query = q
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One structured-output call to Claude or ChatGPT, following the preference in Settings, with the other
/// service as automatic backup when the first one fails.
enum AIService {
    static let preferenceKey = "ai.preference"
    static let openAIModelKey = "ai.openai.model"
    private static let autoModelKey = "ai.openai.autoModel"
    private static let autoModelDateKey = "ai.openai.autoModelDate"

    static var preference: AIPreference {
        AIPreference(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .claudeFirst
    }

    /// Which service answered the last call, for the problem report.
    @MainActor static var lastProvider: AIProvider?

    static func call<T: Decodable>(_ type: T.Type, system: String, content: [AIContent], schema: String,
                                   effort: ClaudeWire.Effort, maxTokens: Int = 16000) async throws -> T {
        let order = preference.order(hasClaude: KeyStore.hasKey(.claude), hasChatGPT: KeyStore.hasKey(.chatgpt))
        guard !order.isEmpty else { throw ClaudeWire.Failure.noKey }
        var lastError: Error = ClaudeWire.Failure.noKey
        for (n, provider) in order.enumerated() {
            do {
                let r = try await call(provider, type, system: system, content: content, schema: schema, effort: effort, maxTokens: maxTokens)
                await MainActor.run { lastProvider = provider }
                return r
            } catch {
                lastError = error
                guard n < order.count - 1, ClaudeWire.worthTryingAnother(error) else { break }
            }
        }
        throw lastError
    }

    static func call<T: Decodable>(_ provider: AIProvider, _ type: T.Type, system: String, content: [AIContent], schema: String,
                                   effort: ClaudeWire.Effort, maxTokens: Int = 16000) async throws -> T {
        guard let key = KeyStore.key(provider), !key.isEmpty else { throw ClaudeWire.Failure.noKey }
        let schemaObject = Prompts.schemaObject(schema)
        var request: URLRequest
        switch provider {
        case .claude:
            request = URLRequest(url: ClaudeWire.endpoint)
            for (name, value) in ClaudeWire.headers(apiKey: key) { request.setValue(value, forHTTPHeaderField: name) }
            request.httpBody = try ClaudeWire.body(system: system, content: ClaudeWire.blocks(content), schema: schemaObject,
                                                   effort: effort, maxTokens: maxTokens)
        case .chatgpt:
            request = URLRequest(url: OpenAIWire.endpoint)
            for (name, value) in OpenAIWire.headers(apiKey: key) { request.setValue(value, forHTTPHeaderField: name) }
            let model = await openAIModel(key: key)
            request.httpBody = try OpenAIWire.body(model: model, system: system, content: content,
                                                   schema: schemaObject, schemaName: "tidy_result", effort: effort, maxTokens: maxTokens)
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 600

        // Ask iOS for a little extra time if the app is sent to the background mid-request.
        let task = await UIApplication.shared.beginBackgroundTask(withName: "ai-call", expirationHandler: nil)
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch provider {
        case .claude: return try ClaudeWire.decode(T.self, status: status, data: data)
        case .chatgpt: return try OpenAIWire.decode(T.self, status: status, data: data)
        }
    }

    /// The model typed in Settings, or the newest GPT model the account has (checked once a day), or gpt-5.
    static func openAIModel(key: String) async -> String {
        let ud = UserDefaults.standard
        if let chosen = ud.string(forKey: openAIModelKey)?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty { return chosen }
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

    /// Cheap call to check that a key works.
    static func test(_ provider: AIProvider) async throws -> String {
        let r = try await call(provider, AskResult.self, system: "Reply with a one-line friendly hello for a tidying app.",
                               content: [.text("Say hello.")], schema: Prompts.askSchema, effort: .low, maxTokens: 2000)
        return r.answer
    }
}
