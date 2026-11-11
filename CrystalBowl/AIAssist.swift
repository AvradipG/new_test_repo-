import SwiftUI
import Security
import UIKit

/// Optional AI second opinions (3.15), with the user's own Claude (Anthropic) or ChatGPT (OpenAI) API key.
/// Off until switched on in Settings. Keys are typed into the app and kept in the iPhone's Keychain only: never in
/// the code, the repository or the build (the repository and the IPA are public). What is sent: renders of the
/// 3D model (for the stand, the unrolled side strip), never the user's photos, and only when a check runs.
/// The app's own measurements stay in charge: an AI answer is a suggestion the user sees and can undo.
enum AIProvider: String, CaseIterable, Identifiable {
    case claude, openai
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude (Anthropic)" : "ChatGPT (OpenAI)" }
}

enum AIKeys {
    private static let service = "com.avradip.crystalbowl.ai"

    static func get(_ p: AIProvider) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: p.rawValue, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func set(_ p: AIProvider, _ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: p.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(k.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum AIAssist {
    static let enabledKey = "ai.enabled"
    static let providerKey = "ai.provider"
    static let openAIModelKey = "ai.openai.model"
    /// Claude model used for the checks.
    static let claudeModel = "claude-opus-5-5"

    static var provider: AIProvider { AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .claude }
    static var openAIModel: String {
        let m = UserDefaults.standard.string(forKey: openAIModelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? "gpt-5" : m
    }
    /// On, and a key for the chosen service is there.
    static var isReady: Bool { UserDefaults.standard.bool(forKey: enabledKey) && AIKeys.get(provider) != nil }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: The stand under the rock

    struct StandAnswer: Codable {
        var hasStand: Bool
        /// Where the stand begins, as a share of the image height from the top (1 when there is none).
        var boundaryFromTop: Double
        var confidence: Double
        var reason: String
    }

    static let standSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "has_stand": ["type": "boolean"],
            "boundary_from_top": ["type": "number"],
            "confidence": ["type": "number"],
            "reason": ["type": "string"],
        ],
        "required": ["has_stand", "boundary_from_top", "confidence", "reason"],
        "additionalProperties": false,
    ]

    /// Asks where the rock ends and a stand under it begins, on the unrolled side strip.
    static func askStand(strip: UIImage, heightMM: Double) async throws -> StandAnswer {
        let prompt = """
        The image is the side surface of a small rock sample from a 3D scan, unrolled all the way round: left to right \
        goes round the sample, the top row is the top of the sample and the bottom row its bottom. It is about \
        \(Int(heightMM.rounded())) mm tall. White areas are background. To be scanned, the rock may have been stood on a \
        support (a wooden block, cork, putty, a plastic cap or similar), which then shows as a band along the bottom \
        that differs from the rock in colour, texture or grain (wood shows parallel grain lines). Rock can change \
        colour on its own (bedding, veins, weathering), so only call it a support when it looks like a different \
        material, and the boundary runs across the whole width.
        Say whether there is a support, and where it begins as a fraction of the image height measured from the top \
        (0 = top, 1 = bottom; use 1 when there is no support), how sure you are (0 to 1), and in one sentence why.
        """
        let json = try await ask(prompt: prompt, image: strip, schema: standSchema)
        guard let d = json.data(using: .utf8),
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Failure(message: "The answer wasn't readable") }
        let a = StandAnswer(hasStand: o["has_stand"] as? Bool ?? false,
                            boundaryFromTop: Swift.min(1, Swift.max(0, (o["boundary_from_top"] as? NSNumber)?.doubleValue ?? 1)),
                            confidence: Swift.min(1, Swift.max(0, (o["confidence"] as? NSNumber)?.doubleValue ?? 0)),
                            reason: o["reason"] as? String ?? "")
        AppLog.info("ai", String(format: "Stand check (%@): %@ at %.3f of the height, confidence %.2f: %@", provider.rawValue,
                                 a.hasStand ? "stand" : "no stand", a.boundaryFromTop, a.confidence, a.reason))
        return a
    }

    // MARK: Requests

    /// One question with one picture; the answer is JSON text matching `schema`.
    static func ask(prompt: String, image: UIImage, schema: [String: Any]) async throws -> String {
        guard let key = AIKeys.get(provider) else { throw Failure(message: "No API key for \(provider.title): add it in Settings") }
        guard let png = scaled(image, maxSide: 1568).pngData() else { throw Failure(message: "The picture couldn't be prepared") }
        let b64 = png.base64EncodedString()
        switch provider {
        case .claude: return try await claude(key: key, prompt: prompt, png: b64, schema: schema)
        case .openai: return try await openAI(key: key, prompt: prompt, png: b64, schema: schema)
        }
    }

    static func scaled(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let s = img.size
        let k = Swift.min(1, maxSide / Swift.max(1, Swift.max(s.width, s.height)))
        guard k < 1 else { return img }
        let size = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Claude Messages API over HTTPS (Anthropic has no Swift SDK), with structured output and the server-side
    /// fallback for a classifier refusal.
    static func claude(key: String, prompt: String, png: String, schema: [String: Any]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let source: [String: Any] = ["type": "base64", "media_type": "image/png", "data": png]
        let image: [String: Any] = ["type": "image", "source": source]
        let text: [String: Any] = ["type": "text", "text": prompt]
        let format: [String: Any] = ["type": "json_schema", "schema": schema]
        let outputConfig: [String: Any] = ["format": format]
        let content: [[String: Any]] = [image, text]
        let message: [String: Any] = ["role": "user", "content": content]
        let body: [String: Any] = [
            "model": claudeModel,
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": outputConfig,
            "messages": [message],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Claude answered with HTTP \(status) and nothing readable")
        }
        guard status == 200 else {
            let msg = ((o["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw Failure(message: "Claude: \(msg)")
        }
        if (o["stop_reason"] as? String) == "refusal" { throw Failure(message: "Claude declined this request") }
        let blocks = o["content"] as? [[String: Any]] ?? []
        guard let t = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw Failure(message: "Claude's answer had no text")
        }
        if let u = o["usage"] as? [String: Any] {
            let model: String = o["model"] as? String ?? claudeModel
            let inTok: Int = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
            let outTok: Int = (u["output_tokens"] as? NSNumber)?.intValue ?? 0
            AppLog.info("ai", "Claude \(model): \(inTok) tokens in, \(outTok) out")
        }
        return t
    }

    /// OpenAI Chat Completions with a JSON-only answer. The model name is set in Settings.
    static func openAI(key: String, prompt: String, png: String, schema: [String: Any]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let schemaText = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let system: [String: Any] = ["role": "system", "content": "Answer with one JSON object only, matching this JSON Schema: " + schemaText]
        let textPart: [String: Any] = ["type": "text", "text": prompt]
        let imageURL: [String: Any] = ["url": "data:image/png;base64," + png]
        let imagePart: [String: Any] = ["type": "image_url", "image_url": imageURL]
        let parts: [[String: Any]] = [textPart, imagePart]
        let user: [String: Any] = ["role": "user", "content": parts]
        let responseFormat: [String: Any] = ["type": "json_object"]
        let body: [String: Any] = [
            "model": openAIModel,
            "response_format": responseFormat,
            "messages": [system, user],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "OpenAI answered with HTTP \(status) and nothing readable")
        }
        guard status == 200 else {
            let msg = ((o["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw Failure(message: "OpenAI: \(msg)")
        }
        let choices = o["choices"] as? [[String: Any]] ?? []
        guard let t = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            throw Failure(message: "OpenAI's answer had no text")
        }
        return t
    }
}

/// Settings: switch the AI second opinions on, pick the service and enter its key.
struct AISettingsSection: View {
    @AppStorage(AIAssist.enabledKey) private var enabled = false
    @AppStorage(AIAssist.providerKey) private var providerRaw = AIProvider.claude.rawValue
    @AppStorage(AIAssist.openAIModelKey) private var openAIModel = "gpt-5"
    @State private var keyText = ""
    @State private var saved: [String: Bool] = [:]

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .claude }

    var body: some View {
        Section {
            Toggle("AI second opinion", isOn: $enabled)
            if enabled {
                Picker("Service", selection: $providerRaw) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if provider == .openai {
                    LabeledContent("Model") {
                        TextField("gpt-5", text: $openAIModel).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if saved[provider.rawValue] == true {
                    Label("Key saved on this iPhone", systemImage: "key.fill").foregroundStyle(.green)
                    Button("Remove the key", role: .destructive) {
                        AIKeys.set(provider, nil)
                        refresh()
                    }
                } else {
                    SecureField(provider == .claude ? "Anthropic API key (sk-ant-…)" : "OpenAI API key (sk-…)", text: $keyText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save the key") {
                        AIKeys.set(provider, keyText)
                        keyText = ""
                        refresh()
                        AppLog.info("ai", "API key saved for \(provider.rawValue)")
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).count < 20)
                }
            }
        } header: {
            Text("AI second opinion")
        } footer: {
            Text("Uses your own Claude or ChatGPT API key, billed to your account. The key stays in this iPhone's Keychain and is never uploaded. When on, the app sends a render of the 3D model (for now: the unrolled side, to find a stand under the rock) and shows the answer as a suggestion you can change. Your photos are not sent.")
        }
        .onAppear { refresh() }
        .onChange(of: providerRaw) { _, _ in refresh() }
    }

    private func refresh() {
        var s: [String: Bool] = [:]
        for p in AIProvider.allCases { s[p.rawValue] = AIKeys.get(p) != nil }
        saved = s
    }
}
