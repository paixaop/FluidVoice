import AppKit
import Combine
import CryptoKit
import Network
import Security

@MainActor
final class CaptureChatGPT: ObservableObject {
    static let shared = CaptureChatGPT()

    @Published private(set) var email: String?
    @Published private(set) var isBusy = false

    private static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private static let planScope = "chatgpt.tokens.use.direct"
    private static let hostKey = "CaptureChatGPTHost"
    private static let network = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    private var credentials: Credentials?
    private var registration: Registration?
    private var refresh: Task<Credentials, Error>?
    private var didLoad = false

    private nonisolated struct Registration: Codable {
        let clientID: String
        let subject: String
        let email: String
    }

    private nonisolated struct Credentials: Codable {
        let registration: Registration
        let idToken: String
        let accessToken: String
        let refreshToken: String
        let expiry: Date
    }

    private nonisolated struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String
        let id_token: String?
        let expires_in: Double
        let scope: String?
    }

    private nonisolated struct Saved: Codable {
        let registration: Registration
        let credentials: Credentials?
    }

    private nonisolated enum SignInError: LocalizedError {
        case authentication, denied, expired, storage, timeout, revoke, noPlan

        var errorDescription: String? {
            switch self {
            case .authentication: "OpenAI couldn’t verify the ChatGPT sign-in. Try connecting again."
            case .denied: "ChatGPT sign-in was declined."
            case .expired: "Connect your ChatGPT account in Settings → Capture."
            case .storage: "FluidVoice couldn’t read or save the ChatGPT connection in Keychain."
            case .timeout: "ChatGPT sign-in timed out. Start again in Settings."
            case .revoke: "Signed out locally. Open ChatGPT’s connection settings to confirm disconnection."
            case .noPlan: "Allow FluidVoice to use your ChatGPT plan when signing in."
            }
        }
    }

    private init() {}

    func load() throws {
        guard !self.didLoad else { return }
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
                throw SignInError.storage
            }
            self.credentials = saved.credentials
            self.registration = saved.registration
            self.email = saved.credentials?.registration.email
        } else if status != errSecItemNotFound {
            throw SignInError.storage
        }
        self.didLoad = true
    }

    func signIn(useSavedAccount: Bool = true) async throws {
        try self.load()
        guard !self.isBusy, self.refresh == nil else { return }
        self.isBusy = true
        defer { self.isBusy = false }

        let registration = useSavedAccount ? self.registration : nil
        let host = UserDefaults.standard.string(forKey: Self.hostKey) ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        let state = try Self.randomString()
        let nonce = try Self.randomString()
        let verifier = try Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let (client, code, callback) = try await self.authorize(
            registration: registration,
            host: host,
            state: state,
            nonce: nonce,
            challenge: challenge
        )
        let tokens: Tokens = try await Self.post("/api/accounts/oauth/token", fields: [
            "grant_type": "authorization_code", "client_id": client, "code": code,
            "code_verifier": verifier, "redirect_uri": callback, "resource": Self.resource,
        ])
        guard Self.hasPlan(tokens.scope) else { throw SignInError.noPlan }
        guard let idToken = tokens.id_token else { throw SignInError.authentication }
        let identity = try await Self.identity(idToken, client: client, nonce: nonce)
        guard registration == nil || registration?.subject == identity.subject else { throw SignInError.authentication }
        try self.save(Credentials(
            registration: identity,
            idToken: idToken,
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token,
            expiry: .now.addingTimeInterval(tokens.expires_in)
        ), registration: identity)
    }

    func accessToken() async throws -> String {
        try self.load()
        guard !self.isBusy, let credentials = self.credentials else { throw SignInError.expired }
        if credentials.expiry.timeIntervalSinceNow > 60 { return credentials.accessToken }
        if let refresh = self.refresh { return try await refresh.value.accessToken }
        let task = Task {
            let tokens: Tokens = try await Self.post("/api/accounts/oauth/token", fields: [
                "grant_type": "refresh_token", "client_id": credentials.registration.clientID,
                "refresh_token": credentials.refreshToken, "resource": Self.resource,
            ])
            if let scope = tokens.scope, !Self.hasPlan(scope) { throw SignInError.noPlan }
            let renewed = Credentials(
                registration: credentials.registration,
                idToken: credentials.idToken,
                accessToken: tokens.access_token,
                refreshToken: tokens.refresh_token,
                expiry: .now.addingTimeInterval(tokens.expires_in)
            )
            try self.save(renewed, registration: renewed.registration)
            return renewed
        }
        self.refresh = task
        defer { self.refresh = nil }
        return try await task.value.accessToken
    }

    func signOut() async throws {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        if let refresh = self.refresh { _ = await refresh.result }
        guard let credentials = self.credentials else { return }
        let request = try Self.request("/api/accounts/oauth/revoke", fields: [
            "token": credentials.refreshToken, "token_type_hint": "refresh_token", "client_id": credentials.registration.clientID,
        ])
        let status = try? await Self.network.data(for: request).1 as? HTTPURLResponse
        try self.save(nil, registration: credentials.registration)
        guard status?.statusCode == 200 else { throw SignInError.revoke }
    }

    nonisolated struct Model: Decodable, Identifiable {
        let slug: String
        let display_name: String
        let visibility: String?
        var id: String {
            self.slug
        }
    }

    private nonisolated struct ModelList: Decodable { let models: [Model] }

    func models() async throws -> [Model] {
        let token = try await self.accessToken()
        guard let url = URL(string: Self.resource + "/models") else { throw SignInError.authentication }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.network.data(for: request)
        guard response.url == url, (response as? HTTPURLResponse)?.statusCode == 200 else { throw SignInError.authentication }
        return try JSONDecoder().decode(ModelList.self, from: data).models.filter { $0.visibility == "list" }
    }

    private func save(_ credentials: Credentials?, registration: Registration) throws {
        let data = try JSONEncoder().encode(Saved(registration: registration, credentials: credentials))
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(Self.keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = Self.keychainQuery
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SignInError.storage }
        self.credentials = credentials
        self.registration = registration
        self.email = credentials?.registration.email
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "com.fluidvoice").capture-chatgpt",
            kSecAttrAccount as String: "oauth",
        ]
    }

    private func authorize(
        registration: Registration?, host: String, state: String, nonce: String, challenge: String
    ) async throws -> (client: String, code: String, callback: String) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let (events, delivery) = AsyncThrowingStream<OAuthEvent, Error>.makeStream()
        listener.stateUpdateHandler = { [weak listener] status in
            switch status {
            case .ready:
                if let port = listener?.port { delivery.yield(.ready(port.rawValue)) }
            case let .failed(error): delivery.finish(throwing: error)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            let queue = DispatchQueue.global(qos: .userInitiated)
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            Self.receiveCallback(connection, delivery: delivery)
        }
        listener.start(queue: .global(qos: .userInitiated))
        let timeout = Task {
            try await Task.sleep(for: .seconds(180))
            delivery.finish(throwing: SignInError.timeout)
        }
        defer {
            timeout.cancel()
            delivery.finish()
            listener.cancel()
        }
        var callback: String?
        for try await event in events {
            switch event {
            case let .ready(port):
                let redirect = "http://127.0.0.1:\(port)/auth/callback"
                callback = redirect
                var values = [
                    "client_id": registration?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": host,
                    "response_type": "code", "redirect_uri": redirect, "resource": Self.resource,
                    "scope": "openid profile email offline_access resource.invoke \(Self.planScope)",
                    "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": challenge,
                ]
                if let registration {
                    values["login_hint"] = registration.email
                    values["id_token_hint"] = self.credentials?.idToken
                } else {
                    values["agent_name_hint"] = "FluidVoice"
                }
                guard var endpoint = URLComponents(string: Self.issuer + "/api/accounts/authorize") else {
                    throw SignInError.authentication
                }
                endpoint.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = endpoint.url, NSWorkspace.shared.open(url) else { throw SignInError.authentication }
            case let .callback(path):
                guard let callback, let values = URLComponents(string: path)?.queryItems,
                      values.filter({ $0.name == "state" }).map(\.value) == [state]
                else { continue }
                guard !values.contains(where: { $0.name == "error" }) else { throw SignInError.denied }
                let returnedClient = values.first(where: { $0.name == "client_id" })?.value
                guard let client = returnedClient ?? registration?.clientID,
                      client.hasPrefix("oaiapp_"), registration == nil || registration?.clientID == client,
                      let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty
                else { throw SignInError.authentication }
                return (client, code, callback)
            }
        }
        throw CancellationError()
    }

    private nonisolated enum OAuthEvent { case ready(UInt16), callback(String) }

    private nonisolated static func receiveCallback(
        _ connection: NWConnection,
        delivery: AsyncThrowingStream<OAuthEvent, Error>.Continuation,
        accumulated: Data = Data()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= 8192, error == nil else { connection.cancel(); return }
            guard let lineEnd = bytes.range(of: Data([13, 10])) else {
                if complete { connection.cancel() } else { self.receiveCallback(connection, delivery: delivery, accumulated: bytes) }
                return
            }
            guard let request = String(bytes: bytes[..<lineEnd.lowerBound], encoding: .utf8) else {
                connection.cancel()
                return
            }
            let line = request.split(separator: " ")
            guard line.count == 3, line[0] == "GET", line[1].hasPrefix("/auth/callback?") else {
                connection.cancel()
                return
            }
            let body = "Return to FluidVoice to see the result of your sign-in."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            delivery.yield(.callback(String(line[1])))
        }
    }

    private static func hasPlan(_ scope: String?) -> Bool {
        let scopes = scope?.split(separator: " ") ?? []
        return scopes.contains(Substring(Self.planScope)) && scopes.contains("resource.invoke")
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SignInError.authentication }
        return Data(bytes).base64URL
    }

    private static func request(_ path: String, fields: [String: String]) throws -> URLRequest {
        guard let url = URL(string: issuer + path) else { throw SignInError.authentication }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&").utf8)
        return request
    }

    private static func post<T: Decodable>(_ path: String, fields: [String: String]) async throws -> T {
        let request = try Self.request(path, fields: fields)
        let (data, response) = try await Self.network.data(for: request)
        guard response.url == request.url, (response as? HTTPURLResponse)?.statusCode == 200 else { throw SignInError.authentication }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated struct JWTHeader: Decodable { let alg: String; let kid: String }
    private nonisolated struct JWKSet: Decodable {
        struct Key: Decodable { let kid: String; let kty: String; let n: String?; let e: String? }
        let keys: [Key]
    }

    private static func identity(_ token: String, client: String, nonce: String) async throws -> Registration {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let headerData = Data(base64URL: String(parts[0])),
              let header = try? JSONDecoder().decode(JWTHeader.self, from: headerData), header.alg == "RS256",
              let signature = Data(base64URL: String(parts[2])),
              let claimData = Data(base64URL: String(parts[1])),
              let claims = try JSONSerialization.jsonObject(with: claimData) as? [String: Any]
        else { throw SignInError.authentication }
        guard let url = URL(string: Self.issuer + "/.well-known/jwks.json") else { throw SignInError.authentication }
        let (data, response) = try await Self.network.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard response.url == url, (response as? HTTPURLResponse)?.statusCode == 200,
              let jwk = try JSONDecoder().decode(JWKSet.self, from: data).keys.first(where: { $0.kid == header.kid && $0.kty == "RSA" }),
              let n = jwk.n.flatMap(Data.init(base64URL:)), let e = jwk.e.flatMap(Data.init(base64URL:)),
              !n.isEmpty, !e.isEmpty
        else { throw SignInError.authentication }
        func integer(_ bytes: Data) -> Data {
            Self.der(0x02, (bytes.first ?? 0) >= 128 ? Data([0]) + bytes : bytes)
        }
        let keyData = Self.der(0x30, integer(n) + integer(e))
        let keyAttributes = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: n.count * 8,
        ] as CFDictionary
        guard let key = SecKeyCreateWithData(keyData as CFData, keyAttributes, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(parts.prefix(2).joined(separator: ".").utf8) as CFData, signature as CFData, nil),
              claims["iss"] as? String == Self.issuer, claims["nonce"] as? String == nonce,
              (claims["exp"] as? Double ?? 0) > Date.now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let email = claims["email"] as? String, !email.isEmpty
        else { throw SignInError.authentication }
        let audience = claims["aud"] as? [String] ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(client), audience.count == 1 || claims["azp"] as? String == client else {
            throw SignInError.authentication
        }
        return Registration(clientID: client, subject: subject, email: email)
    }

    private static func der(_ tag: UInt8, _ payload: Data) -> Data {
        if payload.count < 128 { return Data([tag, UInt8(payload.count)]) + payload }
        var value = payload.count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: value), at: 0)
            value >>= 8
        }
        return Data([tag, 0x80 | UInt8(bytes.count)] + bytes) + payload
    }

    private final nonisolated class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

private extension Data {
    nonisolated var base64URL: String {
        self.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated init?(base64URL: String) {
        let input = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: input + String(repeating: "=", count: (4 - input.count % 4) % 4))
    }
}
