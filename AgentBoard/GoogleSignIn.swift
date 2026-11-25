// Google sign-in in the system browser sheet (authorization code with PKCE, RFC 8252).
// Returns the Google ID token; the board exchanges it for its own sign-in.
import AuthenticationServices
import CryptoKit
import Foundation

final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private weak var window: UIWindow?

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private var clientID: String { Bundle.main.object(forInfoDictionaryKey: "ABGoogleClientID") as? String ?? "" }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window ?? ASPresentationAnchor() }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("no random numbers") }
        return base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func start(from window: UIWindow?, done: @escaping (Result<String, Error>) -> Void) {
        self.window = window
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            done(.failure(Failure(text: "This build has no Google client id.")))
            return
        }
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.random()
        let state = Self.random()
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: scheme) { [weak self] back, error in
            guard let self else { return }
            self.session = nil
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                done(.failure(Failure(text: "The sign-in window was closed before you finished.")))
                return
            }
            let items = back.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard value("state") == state, let code = value("code") else {
                done(.failure(error ?? Failure(text: "Google did not finish the sign-in (\(value("error") ?? "no answer")).")))
                return
            }
            self.exchange(code: code, verifier: verifier, redirect: redirect, done: done)
        }
        session.presentationContextProvider = self
        self.session = session
        if !session.start() { done(.failure(Failure(text: "The sign-in window could not be opened."))) }
    }

    private func exchange(code: String, verifier: String, redirect: String, done: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if let token = json?["id_token"] as? String {
                    done(.success(token))
                } else {
                    done(.failure(error ?? Failure(text: "Google did not accept the sign-in (\(json?["error"] as? String ?? "no answer")).")))
                }
            }
        }.resume()
    }
}
