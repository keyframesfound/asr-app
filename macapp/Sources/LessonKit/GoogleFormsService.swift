import AppKit
import Foundation
import Network

/// Google Forms API client — builds quiz forms directly in the teacher's Drive.
///
/// Port of src/GForms.php with a desktop-native OAuth flow: the default browser
/// opens Google's consent page and Google redirects to a loopback HTTP listener
/// inside the app (`http://127.0.0.1:8317/`). Unlike the web app (which signs in
/// fresh for every quiz), the Mac app keeps the refresh token in the keychain so
/// the teacher stays signed in until they log out.
public struct GoogleFormsService: Sendable {
    /// forms.body plus OpenID email — the email names the signed-in account in Settings.
    public static let scope = "https://www.googleapis.com/auth/forms.body openid email"
    public static let redirectPort: UInt16 = 8317
    public static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/" }

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let formsAPI = "https://forms.googleapis.com/v1"

    public struct Credentials: Sendable {
        public var clientID: String
        public var clientSecret: String
        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID.trimmingCharacters(in: .whitespaces)
            self.clientSecret = clientSecret.trimmingCharacters(in: .whitespaces)
        }
    }

    /// OAuth token bundle kept across sign-ins (refresh token in the keychain).
    public struct Token: Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String?
    }

    public let credentials: Credentials

    public init(credentials: Credentials) {
        self.credentials = credentials
    }

    public var isConfigured: Bool {
        !credentials.clientID.isEmpty && !credentials.clientSecret.isEmpty
    }

    // MARK: - Sign-in (browser + loopback listener)

    struct CallbackResult: Sendable {
        var code: String
        var state: String
        var error: String
    }

    /// One full sign-in round-trip. Opens Google's consent page in the default
    /// browser and awaits the loopback redirect. Returns the exchanged token.
    public func signIn() async throws -> Token {
        let state = UUID().uuidString
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            // We need a refresh token, not just the 1-hour access token.
            .init(name: "access_type", value: "offline"),
            // Re-ask for the account + consent so a fresh refresh token is minted.
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "state", value: state),
        ]

        let listener = OAuthLoopbackListener(port: Self.redirectPort)
        let callback: CallbackResult
        do {
            callback = try await withCheckedThrowingContinuation { continuation in
                listener.start { result in
                    continuation.resume(with: result)
                }
                // Open the browser while the listener is already binding.
                // Opening it after the await would deadlock: the continuation
                // only resumes once Google redirects back through this very
                // browser, which would never have been opened.
                DispatchQueue.main.async {
                    if !NSWorkspace.shared.open(components.url!) {
                        listener.fail(FormsError(
                            "Could not open the browser for Google sign-in."))
                    }
                }
            }
        } catch {
            listener.stop()
            throw error
        }

        do {
            if !callback.error.isEmpty {
                throw FormsError("Google sign-in failed: \(callback.error)")
            }
            if callback.code.isEmpty {
                throw FormsError("Google sign-in failed: no authorisation code was returned.")
            }
            if callback.state != state {
                throw FormsError("Sign-in session expired — please try again.")
            }
            return try await exchangeCode(callback.code)
        } catch {
            listener.stop()
            throw error
        }
    }

    /// Exchange a fresh access token for a stored refresh token.
    public static func refresh(credentials: Credentials, refreshToken: String) async throws -> (accessToken: String, expiresIn: Int) {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = formEncode([
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FormsError("Could not reach Google's token endpoint.")
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0 }?["error_description"] as? String ?? ""
            throw FormsError("Google sign-in has expired (\(http.statusCode)) \(detail) — log in again.")
        }
        let expiresIn = json["expires_in"] as? Int ?? 3600
        return (accessToken, expiresIn)
    }

    private func exchangeCode(_ code: String) async throws -> Token {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let form = [
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
        ]
        request.httpBody = Self.formEncode(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FormsError("Could not reach Google's token endpoint.")
        }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0 }?["error_description"] as? String
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw FormsError("Google sign-in failed (token exchange \(http.statusCode)): \(detail)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw FormsError("Google sign-in returned no access token.")
        }
        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw FormsError("Google sign-in returned no refresh token — revoke the app's access at "
                             + "myaccount.google.com/permissions and try again.")
        }
        return Token(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600)),
            email: Self.emailFromIDToken(json["id_token"] as? String))
    }

    /// The id_token is a JWT; decode its payload for the account email so
    /// Settings can show who is signed in.
    static func emailFromIDToken(_ idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    // MARK: - Form creation (port of GForms::createQuizForm)

    /// Create a quiz-mode form; returns (form_id, student URL, edit URL).
    public func createQuizForm(title: String, description: String,
                               questions: [QuizQuestion], accessToken: String) async throws -> Quiz {
        var headers: [String: String] { ["Authorization": "Bearer \(accessToken)"] }

        // 1. Create the form shell.
        var request = URLRequest(url: URL(string: "\(Self.formsAPI)/forms")!)
        request.httpMethod = "POST"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["info": ["title": title.isEmpty ? "Session Quiz" : title]])
        let (data, response) = try await Self.perform(request)
        let form = try Self.check(data, response)
        guard let formID = form["formId"] as? String, !formID.isEmpty else {
            throw FormsError("Google Forms API returned no form id.")
        }

        // 2. Quiz mode must be on before graded items exist.
        let settingsURL = URL(string: "\(Self.formsAPI)/forms/\(formID):batchUpdate")!
        var request2 = URLRequest(url: settingsURL)
        request2.httpMethod = "POST"
        for (k, v) in headers { request2.setValue(v, forHTTPHeaderField: k) }
        request2.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request2.timeoutInterval = 60
        request2.httpBody = try JSONSerialization.data(withJSONObject: [
            "requests": [
                ["updateFormInfo": [
                    "info": ["description": description],
                    "updateMask": "description",
                ]],
                ["updateSettings": [
                    "settings": [
                        "quizSettings": ["isQuiz": true],
                        "emailCollectionType": "DO_NOT_COLLECT",
                    ],
                    "updateMask": "quizSettings,emailCollectionType",
                ]],
            ]
        ])
        let (settingsData, settingsResponse) = try await Self.perform(request2)
        _ = try Self.check(settingsData, settingsResponse)

        // 3. The questions themselves.
        let itemsURL = URL(string: "\(Self.formsAPI)/forms/\(formID):batchUpdate")!
        var request3 = URLRequest(url: itemsURL)
        request3.httpMethod = "POST"
        for (k, v) in headers { request3.setValue(v, forHTTPHeaderField: k) }
        request3.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request3.timeoutInterval = 120
        request3.httpBody = try JSONSerialization.data(withJSONObject: [
            "requests": questions.enumerated().map { index, question in
                ["createItem": ["item": try Self.questionItem(question),
                                "location": ["index": index]]]
            }
        ])
        let (itemsData, itemsResponse) = try await Self.perform(request3)
        _ = try Self.check(itemsData, itemsResponse)

        return Quiz(
            title: title,
            description: description,
            questions: questions,
            formURL: form["responderUri"] as? String ?? "",
            formEditURL: "https://docs.google.com/forms/d/\(formID)/edit")
    }

    /// Port of GForms::questionItem — radio question, 1 point, correct answer
    /// marked, explanation shown on wrong answers.
    static func questionItem(_ q: QuizQuestion) throws -> [String: Any] {
        guard q.options.indices.contains(q.answer) else {
            throw FormsError("A quiz question was malformed (missing options or answer).")
        }
        var grading: [String: Any] = [
            "pointValue": 1,
            "correctAnswers": ["answers": [["value": q.options[q.answer]]]],
        ]
        let explanation = q.explanation.trimmingCharacters(in: .whitespaces)
        if !explanation.isEmpty {
            grading["whenWrong"] = ["text": explanation]
        }
        return [
            "title": q.question,
            "questionItem": [
                "question": [
                    "required": true,
                    "choiceQuestion": [
                        "type": "RADIO",
                        "options": q.options.map { ["value": $0] },
                    ],
                    "grading": grading,
                ],
            ],
        ]
    }

    // MARK: - Plumbing

    public struct FormsError: LocalizedError, Sendable {
        let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FormsError("Could not reach the Google Forms API: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw FormsError("Could not reach the Google Forms API.")
        }
        return (data, http)
    }

    private static func check(_ data: Data, _ http: HTTPURLResponse) throws -> [String: Any] {
        if http.statusCode >= 400 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw FormsError("Google Forms API error (\(http.statusCode)): \(message)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return json
    }

    static func formEncode(_ form: [String: String]) -> String {
        form.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved)!)=\(value.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved)!)"
        }.joined(separator: "&")
    }
}

extension CharacterSet {
    /// application/x-www-form-urlencoded uses a slightly narrower safe set than URLComponents.
    static let rfc3986Unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Minimal one-shot HTTP listener that catches Google's loopback redirect.
final class OAuthLoopbackListener: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "oauth.loopback")
    /// The start()-local single-resume closure, so fail(_:) reuses the same
    /// guard and the continuation can never be resumed twice.
    private var finishHandler: ((Result<GoogleFormsService.CallbackResult, Error>) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start(completion: @escaping @Sendable (Result<GoogleFormsService.CallbackResult, Error>) -> Void) {
        let port = self.port
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener

            var finished = false
            let lock = NSLock()
            func finish(_ result: Result<GoogleFormsService.CallbackResult, Error>) {
                lock.lock()
                let alreadyDone = finished
                finished = true
                lock.unlock()
                guard !alreadyDone else { return }
                stop()
                completion(result)
            }
            finishHandler = finish

            listener.newConnectionHandler = { [weak self] connection in
                self?.connections.append(connection)
                connection.start(queue: self?.queue ?? .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                    if let data, let request = String(data: data, encoding: .utf8),
                       let target = request.split(separator: "\r\n").first,
                       let rawTarget = target.split(separator: " ").dropFirst().first {
                        let result = Self.parse(target: String(rawTarget))
                        let succeeded = result.error.isEmpty && !result.code.isEmpty
                        Self.respond(connection: connection, success: succeeded) {
                            finish(.success(result))
                        }
                    } else if let error {
                        finish(.failure(GoogleFormsService.FormsError("Sign-in listener failed: \(error.localizedDescription)")))
                    }
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    finish(.failure(GoogleFormsService.FormsError(
                        "Could not listen on 127.0.0.1:\(port) for the Google sign-in redirect (\(error.localizedDescription)).")))
                }
            }
            listener.start(queue: queue)

            // If the browser tab is closed without consenting, no redirect ever
            // arrives — time the round-trip out instead of waiting forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                finish(.failure(GoogleFormsService.FormsError(
                    "Google sign-in timed out — try again and complete the sign-in in the browser.")))
            }
        } catch {
            completion(.failure(GoogleFormsService.FormsError(
                "Could not listen on 127.0.0.1:\(port) for the Google sign-in redirect (\(error.localizedDescription)).")))
        }
    }

    static func parse(target: String) -> GoogleFormsService.CallbackResult {
        var code = "", state = "", error = ""
        if let query = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems {
            code = query.first(where: { $0.name == "code" })?.value ?? ""
            state = query.first(where: { $0.name == "state" })?.value ?? ""
            error = query.first(where: { $0.name == "error" })?.value ?? ""
        }
        return .init(code: code, state: state, error: error)
    }

    /// Serve a tiny completion page so the tab doesn't hang on a dead port.
    static func respond(connection: NWConnection, success: Bool, then: @escaping @Sendable () -> Void) {
        let message = success
            ? "Google sign-in complete — you can close this window."
            : "Google sign-in failed or was cancelled — you can close this window and retry in the app."
        let body = "<!doctype html><html><body><p>\(message)</p><script>setTimeout(function(){window.close()},400)</script></body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.send(content: nil, completion: .contentProcessed { _ in
                connection.cancel()
                then()
            })
        })
    }

    /// Fail a pending sign-in from outside the network path (the browser could
    /// not be opened). No-op once the listener already finished.
    func fail(_ error: Error) {
        finishHandler?(.failure(error))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }
}
