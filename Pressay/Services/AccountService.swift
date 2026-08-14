import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

struct PressayCloudConfiguration: Equatable, Sendable {
    let apiBaseURL: URL
    let issuerURL: URL
    let clientID: String
    let audience: String
    let redirectURI: URL
    let entitlementPublicKey: Data?
    let commercialEnabled: Bool

    static var current: PressayCloudConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard
            let apiString = nonPlaceholder(info["PressayAPIBaseURL"] as? String),
            let issuerString = nonPlaceholder(info["PressayOAuthIssuerURL"] as? String),
            let clientID = nonPlaceholder(info["PressayOAuthClientID"] as? String),
            let apiURL = URL(string: apiString),
            let issuerURL = URL(string: issuerString)
        else { return nil }

        let audience = nonPlaceholder(info["PressayOAuthAudience"] as? String)
            ?? clientID
        let key = nonPlaceholder(info["PressayEntitlementPublicKey"] as? String)
            .flatMap { Data(base64Encoded: $0) }
        let enabled: Bool
        if let boolean = info["PressayCommercialEnabled"] as? Bool {
            enabled = boolean
        } else {
            enabled = ["yes", "true", "1"].contains(
                (info["PressayCommercialEnabled"] as? String)?.lowercased() ?? ""
            )
        }
        return PressayCloudConfiguration(
            apiBaseURL: apiURL,
            issuerURL: issuerURL,
            clientID: clientID,
            audience: audience,
            redirectURI: Constants.cloudRedirectURI,
            entitlementPublicKey: key,
            commercialEnabled: enabled
        )
    }

    private static func nonPlaceholder(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("$(") else { return nil }
        return clean
    }
}

struct PressayAccount: Codable, Equatable, Sendable {
    let id: UUID
    let email: String?
    let displayName: String?
    let createdAt: Date
}

struct PressayDevice: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let deviceIdentifier: String
    let platform: String
    let appVersion: String
    let distributionChannel: String?
    let architecture: String?
    let osMajor: Int?
    let transcriptionEngine: String?
    let telemetryConsent: Bool?
    let createdAt: Date?
    let lastSeenAt: Date
}

/// Wire payload for `POST /v1/devices/register`.
///
/// The Pressay API deliberately uses camelCase for request bodies. Keep this
/// separate from `PressayJSON.encoder`, which uses snake_case for local cached
/// values, so a storage-format change can never break the account handshake.
struct PressayDeviceRegistration: Encodable, Equatable, Sendable {
    let deviceIdentifier: String
    let platform: String
    let appVersion: String
    let distributionChannel: String
    let architecture: String
    let osMajor: Int
    let transcriptionEngine: String
    let localModelID: String?
    let telemetryConsent: Bool

    func encodedForAPI() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

struct PressayEntitlement: Codable, Equatable, Sendable {
    struct TimelineItem: Codable, Equatable, Sendable {
        let source: String
        let plan: String
        let endsAt: Date?
    }

    let plan: String
    let status: String
    let source: String
    let effectivePlan: String
    let effectiveSource: String
    let grantEnd: Date?
    let subscriptionEnd: Date?
    let features: [String]
    let trialEnd: Date?
    let currentPeriodEnd: Date?
    let offlineValidUntil: Date
    let isFoundingUser: Bool
    let deviceLimit: Int
    let timeline: [TimelineItem]
    let issuedAt: Date

    var isPaid: Bool { effectivePlan != "free" }
    var isUsableOffline: Bool { offlineValidUntil > Date() }
}

struct SignedEntitlementSnapshot: Codable, Equatable, Sendable {
    let algorithm: String
    let payload: String
    let value: String
}

enum EntitlementSnapshotError: LocalizedError, Equatable {
    case missingSignature
    case invalidPublicKey
    case invalidSignature
    case malformedPayload
    case expired

    var errorDescription: String? {
        switch self {
        case .missingSignature: "Le serveur n’a pas signé les droits reçus."
        case .invalidPublicKey: "La clé de vérification Pressay est invalide."
        case .invalidSignature: "La signature des droits Pressay est invalide."
        case .malformedPayload: "Les droits Pressay reçus sont illisibles."
        case .expired: "La période hors ligne de ces droits est expirée."
        }
    }
}

enum EntitlementSnapshotVerifier {
    static func verify(
        _ snapshot: SignedEntitlementSnapshot?,
        publicKeyData: Data,
        now: Date = Date()
    ) throws -> PressayEntitlement {
        guard let snapshot, snapshot.algorithm == "Ed25519" else {
            throw EntitlementSnapshotError.missingSignature
        }
        guard let payload = Data(base64Encoded: snapshot.payload),
              let signature = Data(base64Encoded: snapshot.value) else {
            throw EntitlementSnapshotError.malformedPayload
        }
        let rawKey = rawEd25519PublicKey(from: publicKeyData)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            throw EntitlementSnapshotError.invalidPublicKey
        }
        guard key.isValidSignature(signature, for: payload) else {
            throw EntitlementSnapshotError.invalidSignature
        }
        guard let entitlement = try? PressayJSON.decoder.decode(
            PressayEntitlement.self,
            from: payload
        ) else {
            throw EntitlementSnapshotError.malformedPayload
        }
        guard entitlement.offlineValidUntil > now else {
            throw EntitlementSnapshotError.expired
        }
        return entitlement
    }

    private static func rawEd25519PublicKey(from data: Data) -> Data {
        // Node exports Ed25519 public keys as a 44-byte SPKI DER value. CryptoKit
        // expects the 32-byte raw key. Accept both formats to keep deployment safe.
        if data.count == 44 {
            return data.suffix(32)
        }
        return data
    }
}

enum PressayAccountError: LocalizedError, Equatable {
    case notConfigured
    case authenticationCancelled
    case invalidCallback
    case invalidOAuthState
    case tokenExchangeFailed
    case sessionExpired
    case deviceLimitReached
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Le compte Pressay n’est pas encore configuré pour cette version."
        case .authenticationCancelled: "Connexion annulée."
        case .invalidCallback: "La réponse de connexion est invalide."
        case .invalidOAuthState: "La réponse de connexion ne correspond pas à cette demande."
        case .tokenExchangeFailed: "Le service d’identité n’a pas pu créer la session Pressay."
        case .sessionExpired: "Ta session a expiré. Reconnecte-toi pour continuer."
        case .deviceLimitReached: "La limite de Mac actifs pour ce plan est atteinte."
        case .server(let code): "Le service Pressay a refusé la demande (\(code))."
        }
    }
}

@MainActor
final class AccountService: NSObject, ObservableObject {
    static let shared: AccountService = {
        // Hosted macOS tests construct the complete SwiftUI Settings scene
        // before XCTest starts. Never let that implicit view construction read
        // production OAuth tokens: a code-signing ACL prompt can otherwise
        // block the test host (and SecurityAgent) indefinitely.
        if Constants.isRunningTests {
            return AccountService(
                configuration: nil,
                keychain: EmptyAccountKeychainStore()
            )
        }
        return AccountService()
    }()

    enum State: Equatable {
        case unavailable
        case signedOut
        case signingIn
        case loading
        case signedIn
        case failed(String)
    }

    @Published private(set) var state: State
    @Published private(set) var account: PressayAccount?
    @Published private(set) var entitlement: PressayEntitlement?
    @Published private(set) var devices: [PressayDevice] = []
    @Published private(set) var requestID: String?

    private struct OAuthMetadata: Codable {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let userinfoEndpoint: URL?
    }

    private struct TokenSet: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    private struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    private struct AccountEnvelope: Codable { let account: PressayAccount }
    private struct DeviceEnvelope: Codable { let device: PressayDevice }
    private struct DevicesEnvelope: Codable { let devices: [PressayDevice] }
    private struct EntitlementEnvelope: Codable {
        let snapshot: SignedEntitlementSnapshot?
    }
    private struct APIErrorEnvelope: Codable { let error: String }

    private let configuration: PressayCloudConfiguration?
    private let keychain: KeychainStoring
    private let defaults: UserDefaults
    private let session: URLSession
    private var authenticationSession: ASWebAuthenticationSession?
    private var tokens: TokenSet?
    private lazy var currentDeviceIdentifier = stableDeviceIdentifier()

    init(
        configuration: PressayCloudConfiguration? = .current,
        keychain: KeychainStoring = KeychainHelper.shared,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.defaults = defaults
        self.session = session
        if !Constants.isRunningTests,
           let data = keychain.data(
               account: Constants.keychainAccountTokensAccount
           ) {
            self.tokens = try? PressayJSON.decoder.decode(TokenSet.self, from: data)
        }
        self.state = configuration == nil ? .unavailable : (tokens == nil ? .signedOut : .loading)
        super.init()
        guard configuration != nil, tokens != nil, !Constants.isRunningTests else { return }
        Task { await refresh() }
    }

    var isConfigured: Bool { configuration != nil }
    var commercialEnabled: Bool {
        configuration?.commercialEnabled == true && !Constants.isRunningTests
    }
    var canUsePaidFeatures: Bool {
        guard commercialEnabled else { return true }
        return entitlement?.isPaid == true && entitlement?.isUsableOffline == true
    }

    func allows(_ feature: String) -> Bool {
        guard commercialEnabled else { return true }
        if let entitlement, entitlement.isUsableOffline {
            return entitlement.features.contains(feature)
        }
        return Self.freeFeatures.contains(feature)
    }

    func signIn() async {
        guard let configuration else {
            state = .unavailable
            return
        }
        state = .signingIn
        do {
            let metadata = try await metadata(for: configuration)
            let verifier = Self.randomURLSafeString(byteCount: 48)
            let stateToken = Self.randomURLSafeString(byteCount: 32)
            let authorizationURL = try Self.authorizationURL(
                configuration: configuration,
                endpoint: metadata.authorizationEndpoint,
                verifier: verifier,
                state: stateToken
            )
            let callback = try await startAuthentication(
                url: authorizationURL,
                callbackScheme: configuration.redirectURI.scheme
            )
            let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
            let values = Dictionary(
                uniqueKeysWithValues: (components?.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            guard values["state"] == stateToken else {
                throw PressayAccountError.invalidOAuthState
            }
            guard let code = values["code"], !code.isEmpty else {
                throw PressayAccountError.invalidCallback
            }
            tokens = try await exchangeCode(
                code,
                verifier: verifier,
                metadata: metadata,
                configuration: configuration
            )
            try persistTokens()
            try await provisionAndRefresh()
        } catch let error as ASWebAuthenticationSessionError
            where error.code == .canceledLogin {
            state = .signedOut
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard configuration != nil, tokens != nil else {
            state = configuration == nil ? .unavailable : .signedOut
            return
        }
        state = .loading
        do {
            try await provisionAndRefresh()
        } catch {
            if case PressayAccountError.sessionExpired = error {
                clearLocalSession()
            } else {
                loadCachedEntitlement()
                state = entitlement?.isUsableOffline == true
                    ? .signedIn
                    : .failed(error.localizedDescription)
            }
        }
    }

    func signOut() {
        clearLocalSession()
    }

    func revokeDevice(_ id: UUID) async {
        do {
            _ = try await apiRequest(path: "devices/\(id.uuidString)", method: "DELETE")
            devices.removeAll { $0.id == id }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func isCurrentDevice(_ device: PressayDevice) -> Bool {
        device.deviceIdentifier == currentDeviceIdentifier
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func authorizationURL(
        configuration: PressayCloudConfiguration,
        endpoint: URL,
        verifier: String,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw PressayAccountError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: configuration.audience)
        ]
        guard let url = components.url else { throw PressayAccountError.notConfigured }
        return url
    }

    private func provisionAndRefresh() async throws {
        _ = try await apiRequest(path: "accounts/bootstrap", method: "POST", body: Data("{}".utf8))
        let accountData = try await apiRequest(path: "me")
        account = try PressayJSON.decoder.decode(AccountEnvelope.self, from: accountData).account
        try await registerThisMac()
        let entitlementData = try await apiRequest(path: "entitlements")
        let envelope = try PressayJSON.decoder.decode(EntitlementEnvelope.self, from: entitlementData)
        guard let publicKey = configuration?.entitlementPublicKey else {
            throw EntitlementSnapshotError.invalidPublicKey
        }
        entitlement = try EntitlementSnapshotVerifier.verify(envelope.snapshot, publicKeyData: publicKey)
        ModeStore.shared.objectWillChange.send()
        if let snapshot = envelope.snapshot,
           let encoded = try? PressayJSON.encoder.encode(snapshot) {
            defaults.set(encoded, forKey: Constants.cachedEntitlementSnapshotKey)
        }
        let devicesData = try await apiRequest(path: "devices")
        devices = try PressayJSON.decoder.decode(DevicesEnvelope.self, from: devicesData).devices
        state = .signedIn
    }

    private func registerThisMac() async throws {
        let consent = defaults.bool(forKey: Constants.remoteTelemetryEnabledKey)
        let registration = PressayDeviceRegistration(
            deviceIdentifier: currentDeviceIdentifier,
            platform: "macos",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            distributionChannel: "direct",
            architecture: Self.architecture,
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            transcriptionEngine: defaults.string(forKey: Constants.transcriptionEngineKey) ?? "unknown",
            localModelID: consent ? defaults.string(forKey: Constants.whisperKitModelPathKey) : nil,
            telemetryConsent: consent
        )
        let body = try registration.encodedForAPI()
        _ = try await apiRequest(path: "devices/register", method: "POST", body: body)
    }

    private func stableDeviceIdentifier() -> String {
        if let data = keychain.data(account: Constants.keychainDeviceIdentifierAccount),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        let value = UUID().uuidString.lowercased()
        _ = keychain.save(data: Data(value.utf8), account: Constants.keychainDeviceIdentifierAccount)
        return value
    }

    private func apiRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        retryAfterRefresh: Bool = true
    ) async throws -> Data {
        guard let configuration, var tokens else { throw PressayAccountError.sessionExpired }
        if tokens.expiresAt <= Date().addingTimeInterval(60), retryAfterRefresh {
            tokens = try await refreshTokens(tokens, configuration: configuration)
            self.tokens = tokens
            try persistTokens()
        }
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        requestID = http.value(forHTTPHeaderField: "X-Request-ID")
        if http.statusCode == 401, retryAfterRefresh, tokens.refreshToken != nil {
            let refreshed = try await refreshTokens(tokens, configuration: configuration)
            self.tokens = refreshed
            try persistTokens()
            return try await apiRequest(path: path, method: method, body: body, retryAfterRefresh: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? PressayJSON.decoder.decode(APIErrorEnvelope.self, from: data).error)
                ?? "http_\(http.statusCode)"
            if code == "device_limit_reached" { throw PressayAccountError.deviceLimitReached }
            if http.statusCode == 401 { throw PressayAccountError.sessionExpired }
            throw PressayAccountError.server(code)
        }
        return data
    }

    private func metadata(for configuration: PressayCloudConfiguration) async throws -> OAuthMetadata {
        let url = configuration.issuerURL
            .appendingPathComponent(".well-known")
            .appendingPathComponent("oauth-authorization-server")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PressayAccountError.notConfigured
        }
        return try PressayJSON.decoder.decode(OAuthMetadata.self, from: data)
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        metadata: OAuthMetadata,
        configuration: PressayCloudConfiguration
    ) async throws -> TokenSet {
        let body = Self.formEncoded([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "resource": configuration.audience
        ])
        return try await requestTokens(url: metadata.tokenEndpoint, body: body)
    }

    private func refreshTokens(
        _ current: TokenSet,
        configuration: PressayCloudConfiguration
    ) async throws -> TokenSet {
        guard let refreshToken = current.refreshToken else {
            throw PressayAccountError.sessionExpired
        }
        let metadata = try await metadata(for: configuration)
        let body = Self.formEncoded([
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "resource": configuration.audience
        ])
        let refreshed = try await requestTokens(url: metadata.tokenEndpoint, body: body)
        return TokenSet(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            expiresAt: refreshed.expiresAt
        )
    }

    private func requestTokens(url: URL, body: Data) async throws -> TokenSet {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? PressayJSON.decoder.decode(TokenResponse.self, from: data) else {
            throw PressayAccountError.tokenExchangeFailed
        }
        return TokenSet(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(decoded.expiresIn)
        )
    }

    private func startAuthentication(url: URL, callbackScheme: String?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) {
                callback, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: PressayAccountError.invalidCallback)
                }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = false
            authenticationSession = auth
            guard auth.start() else {
                continuation.resume(throwing: PressayAccountError.authenticationCancelled)
                return
            }
        }
    }

    private func persistTokens() throws {
        guard let tokens else { return }
        let data = try PressayJSON.encoder.encode(tokens)
        guard keychain.save(data: data, account: Constants.keychainAccountTokensAccount) else {
            throw PressayAccountError.tokenExchangeFailed
        }
    }

    private func loadCachedEntitlement() {
        guard let publicKey = configuration?.entitlementPublicKey,
              let data = defaults.data(forKey: Constants.cachedEntitlementSnapshotKey),
              let snapshot = try? PressayJSON.decoder.decode(SignedEntitlementSnapshot.self, from: data),
              let cached = try? EntitlementSnapshotVerifier.verify(snapshot, publicKeyData: publicKey)
        else { return }
        entitlement = cached
    }

    private func clearLocalSession() {
        _ = keychain.delete(account: Constants.keychainAccountTokensAccount)
        defaults.removeObject(forKey: Constants.cachedEntitlementSnapshotKey)
        tokens = nil
        account = nil
        entitlement = nil
        devices = []
        ModeStore.shared.objectWillChange.send()
        state = configuration == nil ? .unavailable : .signedOut
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func formEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = fields.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static let freeFeatures: Set<String> = [
        "dictation.local",
        "dictation.byok",
        "modes.faithful",
        "modes.clean",
        "modes.message",
        "history.24h",
        "data.export",
        "data.delete"
    ]
}

private final class EmptyAccountKeychainStore: KeychainStoring {
    func save(data: Data, account: String) -> Bool { false }
    func data(account: String) -> Data? { nil }
    func delete(account: String) -> Bool { true }
}

extension AccountService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }
}

private enum PressayJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.pressayFractional.date(from: value)
                ?? ISO8601DateFormatter.pressayStandard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension ISO8601DateFormatter {
    static let pressayFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let pressayStandard = ISO8601DateFormatter()
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
