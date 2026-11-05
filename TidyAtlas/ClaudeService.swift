import Foundation
import Security
import UIKit
import TidyCore

/// The owner's own Claude API key, kept in the iPhone Keychain (never in the database or a file).
enum KeyStore {
    private static let service = "com.avradip.tidyatlas.claude"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var hasKey: Bool { !(apiKey ?? "").isEmpty }

    static func save(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// One structured-output call to Claude over HTTPS.
enum ClaudeService {
    static func call<T: Decodable>(_ type: T.Type, system: String, content: [[String: Any]], schema: String,
                                   effort: ClaudeWire.Effort, maxTokens: Int = 16000) async throws -> T {
        guard let key = KeyStore.apiKey, !key.isEmpty else { throw ClaudeWire.Failure.noKey }
        var request = URLRequest(url: ClaudeWire.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        for (name, value) in ClaudeWire.headers(apiKey: key) { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try ClaudeWire.body(system: system, content: content, schema: Prompts.schemaObject(schema),
                                               effort: effort, maxTokens: maxTokens)

        // Ask iOS for a little extra time if the app is sent to the background mid-request.
        let task = await UIApplication.shared.beginBackgroundTask(withName: "claude", expirationHandler: nil)
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try ClaudeWire.decode(T.self, status: status, data: data)
    }

    /// Cheap call to check that the key works.
    static func testKey() async throws -> String {
        let r = try await call(AskResult.self, system: "Reply with a one-line friendly hello for a tidying app.",
                               content: [ClaudeWire.textBlock("Say hello.")], schema: Prompts.askSchema,
                               effort: .low, maxTokens: 2000)
        return r.answer
    }
}
