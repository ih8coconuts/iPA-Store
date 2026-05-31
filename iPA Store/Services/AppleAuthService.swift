// Services/AppleAuthService.swift
import Foundation
import CommonCrypto
import Combine

@MainActor
class AppleAuthService: ObservableObject {
    @Published var isSignedIn = false
    @Published var appleID: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var requires2FA = false
    @Published var canRequestSMSCode = false

    private let keychain = KeychainHelper.shared
    private var pendingEmail: String?
    private var pendingPassword: String?
    private var sessionId: String?
    private var scnt: String?
    private var twoFAVerification = TwoFAVerification.trustedDevice
    private var preferredPhoneNumber: TwoFactorOptions.TrustedPhoneNumber?
    private var lastTwoFACode: String?
    private let appStoreClient = AppStoreClient()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: config)
    }()

    private let widgetKey = "e0b80c3bf78523bfe80974d320935bfa30add02e1bff88ec2166c6bd5a706c42"

    init() {
        if let email = keychain.load(for: "appleID") {
            appleID = email
            isSignedIn = true
        }
    }

    // MARK: - Public

    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        pendingEmail = email
        pendingPassword = password
        resetAuthSessionState(clearCookies: true)

        do {
            try await srpSignIn(email: email, password: password)
            requires2FA = true
        } catch AuthError.signedInDirectly {
            saveSession(email: email)
            try? await appStoreAccount(forceRefresh: true)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func requestSMSCode() async {
        guard let sid = sessionId,
              let s = scnt,
              let phone = preferredPhoneNumber else {
            errorMessage = "No trusted phone number is available for this sign-in."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await requestPhoneCode(phone: phone, sessionId: sid, scnt: s)
            twoFAVerification = .phone(id: phone.id, mode: phone.pushMode ?? "sms")
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func submitTwoFACode(_ code: String) async {
        guard let email = pendingEmail else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await verifyCode(code)
            try await trustSession()
            lastTwoFACode = code
            saveSession(email: email)
            requires2FA = false
            try? await appStoreAccount(forceRefresh: true)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func signOut() {
        keychain.delete(for: "appleID")
        keychain.delete(for: "dsPersonId")
        keychain.delete(for: "passwordToken")
        keychain.delete(for: "storeFront")
        keychain.delete(for: "pod")
        appleID = ""
        isSignedIn = false
        requires2FA = false
        errorMessage = nil
        pendingEmail = nil
        pendingPassword = nil
        lastTwoFACode = nil
        resetAuthSessionState(clearCookies: true)
    }

    func appStoreAccount(forceRefresh: Bool) async throws -> AppStoreAccount {
        let email = pendingEmail ?? appleID

        if !forceRefresh, let saved = loadAppStoreAccount(email: email) {
            return saved
        }

        guard let password = pendingPassword, !password.isEmpty, !email.isEmpty else {
            throw AppStoreClientError.appStoreAccountUnavailable
        }

        let account = try await appStoreClient.login(email: email, password: password, authCode: lastTwoFACode)
        saveAppStoreAccount(account)
        lastTwoFACode = nil
        return account
    }

    func clearAppStoreAccount() {
        keychain.delete(for: "dsPersonId")
        keychain.delete(for: "passwordToken")
        keychain.delete(for: "storeFront")
        keychain.delete(for: "pod")
    }
    
    func signingPassword(for email: String) -> String? {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        if appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedEmail,
           let pendingPassword,
           !pendingPassword.isEmpty {
            return pendingPassword
        }
        
        return keychain.load(for: signingPasswordKey(for: normalizedEmail))
    }

    // MARK: - Step 1: SRP signin/init + signin/complete

    private func srpSignIn(email: String, password: String) async throws {
        let (srpClient, clientPublicKey) = await Task.detached(priority: .userInitiated) {
            let client = AppleSRPClient(accountName: email)
            return (client, client.clientPublicKey)
        }.value

        let initURL = URL(string: "https://idmsa.apple.com/appleauth/auth/signin/init")!
        var initReq = URLRequest(url: initURL)
        initReq.httpMethod = "POST"
        setSRPHeaders(&initReq)

        struct InitBody: Encodable {
            let a: String
            let accountName: String
            let protocols: [String]
        }
        initReq.httpBody = try JSONEncoder().encode(
            InitBody(a: clientPublicKey, accountName: email, protocols: ["s2k", "s2k_fo"])
        )

        let (initData, initResp) = try await session.data(for: initReq)
        let initHTTP = initResp as! HTTPURLResponse
        updateSessionHeaders(from: initHTTP)

        guard initHTTP.statusCode == 200 else {
            throw AuthError.failed(parseAppleError(from: initData) ?? "SRP init failed (HTTP \(initHTTP.statusCode))")
        }

        struct InitResponse: Decodable {
            let b: String
            let c: String
            let salt: String
            let iteration: Int
            let `protocol`: String
        }
        let initJson = try JSONDecoder().decode(InitResponse.self, from: initData)

        let (m1, m2) = try await Task.detached(priority: .userInitiated) {
            var client = srpClient
            return try client.processChallenge(
                password: password,
                salt: initJson.salt,
                serverPublicKey: initJson.b,
                protocol: initJson.protocol,
                iterations: initJson.iteration
            )
        }.value

        let hashcash = await fetchHashcash()

        let completeURL = URL(string: "https://idmsa.apple.com/appleauth/auth/signin/complete?isRememberMeEnabled=false")!
        var completeReq = URLRequest(url: completeURL)
        completeReq.httpMethod = "POST"
        setSRPHeaders(&completeReq)
        if let hashcash {
            completeReq.setValue(hashcash, forHTTPHeaderField: "X-Apple-HC")
        }

        struct CompleteBody: Encodable {
            let accountName: String
            let c: String
            let m1: String
            let m2: String
            let rememberMe: Bool
        }
        completeReq.httpBody = try JSONEncoder().encode(
            CompleteBody(accountName: email, c: initJson.c, m1: m1, m2: m2, rememberMe: false)
        )

        let (completeData, completeResp) = try await session.data(for: completeReq)
        let completeHTTP = completeResp as! HTTPURLResponse
        updateSessionHeaders(from: completeHTTP)

        switch completeHTTP.statusCode {
        case 200:
            throw AuthError.signedInDirectly
        case 409:
            await fetchTwoFactorOptionsIfAvailable()
            return
        case 401:
            throw AuthError.failed(parseAppleError(from: completeData) ?? "Incorrect Apple ID or password.")
        default:
            throw AuthError.failed(parseAppleError(from: completeData) ?? "Sign in failed (HTTP \(completeHTTP.statusCode))")
        }
    }

    // MARK: - Step 2: Verify 2FA code

    private func fetchTwoFactorOptionsIfAvailable() async {
        guard let sid = sessionId, let s = scnt else { return }

        let url = URL(string: "https://idmsa.apple.com/appleauth/auth")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        setTwoFactorHeaders(&req)
        req.setValue(sid, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        req.setValue(s, forHTTPHeaderField: "scnt")

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return
        }

        guard http.statusCode == 200 || http.statusCode == 409 else {
            return
        }

        // Keep using the session/scnt from signin/complete for verification.
        // This call is only to discover trusted phone fallback options.
        updateTwoFAVerification(from: data)
    }

    private func verifyCode(_ code: String) async throws {
        guard let sid = sessionId, let s = scnt else {
            throw AuthError.failed("Session expired. Please start over.")
        }

        try await verifyCode(code, using: twoFAVerification, sessionId: sid, scnt: s)
    }

    private func verifyCode(
        _ code: String,
        using verification: TwoFAVerification,
        sessionId: String,
        scnt: String
    ) async throws {
        let req: URLRequest

        switch verification {
        case .trustedDevice:
            let url = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode")!
            struct CodeBody: Encodable {
                struct SecurityCode: Encodable { let code: String }
                let securityCode: SecurityCode
            }
            req = try verificationRequest(
                url: url,
                sessionId: sessionId,
                scnt: scnt,
                body: CodeBody(securityCode: .init(code: code))
            )
        case .phone(let phoneId, let mode):
            let url = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone/securitycode")!
            struct PhoneCodeBody: Encodable {
                struct SecurityCode: Encodable { let code: String }
                struct PhoneNumber: Encodable { let id: Int }
                let securityCode: SecurityCode
                let phoneNumber: PhoneNumber
                let mode: String
            }
            req = try verificationRequest(
                url: url,
                sessionId: sessionId,
                scnt: scnt,
                body:
                PhoneCodeBody(
                    securityCode: .init(code: code),
                    phoneNumber: .init(id: phoneId),
                    mode: mode
                )
            )
        }

        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse

        guard http.statusCode == 200 || http.statusCode == 204 else {
            throw AuthError.failed(
                appleFailureMessage(
                    prefix: "Verification failed via \(verification.label)",
                    statusCode: http.statusCode,
                    data: data
                )
            )
        }

        updateSessionHeaders(from: http)
    }

    // MARK: - Step 3: Trust the session

    private func trustSession() async throws {
        guard let sid = sessionId, let s = scnt else { return }

        let url = URL(string: "https://idmsa.apple.com/appleauth/auth/2sv/trust")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        setTwoFactorHeaders(&req)
        req.setValue(sid, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        req.setValue(s, forHTTPHeaderField: "scnt")

        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse
        updateSessionHeaders(from: http)

        guard http.statusCode == 200 || http.statusCode == 204 else {
            throw AuthError.failed(parseAppleError(from: data) ?? "Session trust failed (HTTP \(http.statusCode))")
        }
    }

    // MARK: - Helpers

    private func requestPhoneCode(
        phone: TwoFactorOptions.TrustedPhoneNumber,
        sessionId: String,
        scnt: String
    ) async throws {
        let url = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone")!

        struct PhoneCodeRequest: Encodable {
            struct PhoneNumber: Encodable { let id: Int }
            let phoneNumber: PhoneNumber
            let mode: String
        }

        var req = try verificationRequest(
            url: url,
            sessionId: sessionId,
            scnt: scnt,
            body: PhoneCodeRequest(
                phoneNumber: .init(id: phone.id),
                mode: phone.pushMode ?? "sms"
            )
        )
        req.httpMethod = "PUT"

        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse

        guard http.statusCode == 200 || http.statusCode == 204 else {
            throw AuthError.failed(
                appleFailureMessage(
                    prefix: "Could not request SMS code",
                    statusCode: http.statusCode,
                    data: data
                )
            )
        }

        updateSessionHeaders(from: http)
    }

    private func fetchHashcash() async -> String? {
        guard var components = URLComponents(string: "https://idmsa.apple.com/appleauth/auth/signin") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "widgetKey", value: widgetKey)]
        guard let url = components.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              let bits = http.value(forHTTPHeaderField: "X-Apple-HC-Bits"),
              let challenge = http.value(forHTTPHeaderField: "X-Apple-HC-Challenge"),
              let bitCount = Int(bits) else {
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            AppleAuthService.makeHashcash(bits: bitCount, challenge: challenge)
        }.value
    }

    nonisolated private static func sha1(_ text: String) -> Data {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    nonisolated private static func makeHashcash(bits: Int, challenge: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMddHHmmss"
        let date = formatter.string(from: Date())

        var counter = 0
        while true {
            let candidate = "1:\(bits):\(date):\(challenge)::\(counter)"
            if hasLeadingZeroBits(Self.sha1(candidate), count: bits) {
                return candidate
            }
            counter += 1
        }
    }

    nonisolated private static func hasLeadingZeroBits(_ data: Data, count: Int) -> Bool {
        var remaining = count
        for byte in data {
            if remaining <= 0 {
                return true
            }

            if remaining >= 8 {
                guard byte == 0 else { return false }
                remaining -= 8
            } else {
                let mask = UInt8((0xFF00 >> remaining) & 0xFF)
                return (byte & mask) == 0
            }
        }

        return remaining <= 0
    }

    private func setAppleJSONHeaders(_ req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")
        req.setValue("https://idmsa.apple.com/appleauth/auth", forHTTPHeaderField: "Referer")
        req.setValue("https://idmsa.apple.com", forHTTPHeaderField: "Origin")
    }

    private func setTwoFactorHeaders(_ req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")
    }

    private func setSRPHeaders(_ req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")
    }

    private func verificationRequest<Body: Encodable>(
        url: URL,
        sessionId: String,
        scnt: String,
        body: Body
    ) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        setTwoFactorHeaders(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sessionId, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        req.setValue(scnt, forHTTPHeaderField: "scnt")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func updateSessionHeaders(from response: HTTPURLResponse) {
        if let value = response.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") {
            sessionId = value
        }
        if let value = response.value(forHTTPHeaderField: "scnt") {
            scnt = value
        }
    }

    private func resetAuthSessionState(clearCookies: Bool) {
        sessionId = nil
        scnt = nil
        twoFAVerification = .trustedDevice
        preferredPhoneNumber = nil
        canRequestSMSCode = false

        guard clearCookies else { return }

        let storage = HTTPCookieStorage.shared
        storage.cookies?
            .filter { $0.domain.contains("idmsa.apple.com") || $0.domain == ".apple.com" }
            .forEach { storage.deleteCookie($0) }
    }

    private func updateTwoFAVerification(from data: Data) {
        guard let options = try? JSONDecoder().decode(TwoFactorOptions.self, from: data) else {
            twoFAVerification = .trustedDevice
            preferredPhoneNumber = nil
            canRequestSMSCode = false
            return
        }

        if let phone = options.preferredPhoneNumber {
            let phoneVerification = TwoFAVerification.phone(id: phone.id, mode: phone.pushMode ?? "sms")
            preferredPhoneNumber = phone
            canRequestSMSCode = true

            if options.noTrustedDevices == true {
                twoFAVerification = phoneVerification
                return
            }
        } else {
            preferredPhoneNumber = nil
            canRequestSMSCode = false
        }

        twoFAVerification = .trustedDevice
    }

    private func parseAppleError(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
            return text.isEmpty ? nil : text
        }

        let possibleLists = [
            object["service_errors"],
            object["serviceErrors"],
            object["validationErrors"],
            object["errors"]
        ]

        for list in possibleLists {
            if let errors = list as? [[String: Any]],
               let message = errors.compactMap({ $0["message"] as? String }).first {
                return message
            }
        }

        if let message = (object["message"] as? String) ?? (object["errorMessage"] as? String) ?? (object["reason"] as? String) {
            if let code = object["errorCode"] ?? object["serverErrorCode"] ?? object["error"] {
                return "\(message) [\(code)]"
            }
            return message
        }

        if let code = object["errorCode"] ?? object["serverErrorCode"] ?? object["error"] {
            return "\(code)"
        }

        return nil
    }

    private func appleFailureMessage(prefix: String, statusCode: Int, data: Data) -> String {
        if let parsed = parseAppleError(from: data) {
            return "\(prefix) (HTTP \(statusCode)): \(parsed)"
        }

        let body = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(240)

        if body.isEmpty {
            return "\(prefix) (HTTP \(statusCode))"
        }

        return "\(prefix) (HTTP \(statusCode)): \(body)"
    }

    private func saveSession(email: String) {
        keychain.save(email, for: "appleID")
        
        if let pendingPassword, !pendingPassword.isEmpty {
            keychain.save(pendingPassword, for: signingPasswordKey(for: email))
        }
        
        appleID = email
        isSignedIn = true
    }
    
    private func signingPasswordKey(for email: String) -> String {
        "sideload.signing.password." + email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func saveAppStoreAccount(_ account: AppStoreAccount) {
        keychain.save(account.directoryServicesID, for: "dsPersonId")
        keychain.save(account.passwordToken, for: "passwordToken")
        keychain.save(account.storeFront, for: "storeFront")

        if let pod = account.pod, !pod.isEmpty {
            keychain.save(pod, for: "pod")
        } else {
            keychain.delete(for: "pod")
        }
    }

    private func loadAppStoreAccount(email: String) -> AppStoreAccount? {
        guard !email.isEmpty,
              let dsid = keychain.load(for: "dsPersonId"),
              let passwordToken = keychain.load(for: "passwordToken"),
              let storeFront = keychain.load(for: "storeFront") else {
            return nil
        }

        return AppStoreAccount(
            email: email,
            passwordToken: passwordToken,
            directoryServicesID: dsid,
            storeFront: storeFront,
            pod: keychain.load(for: "pod")
        )
    }
}

enum AuthError: LocalizedError {
    case requires2FA
    case signedInDirectly
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .requires2FA:
            return "Two-factor authentication required."
        case .signedInDirectly:
            return nil
        case .failed(let msg):
            return msg
        }
    }
}

private enum TwoFAVerification {
    case trustedDevice
    case phone(id: Int, mode: String)

    var label: String {
        switch self {
        case .trustedDevice:
            return "trusteddevice"
        case .phone(_, let mode):
            return "phone/\(mode)"
        }
    }
}

private struct TwoFactorOptions: Decodable {
    struct TrustedPhoneNumber: Decodable {
        let id: Int
        let pushMode: String?
        let numberWithDialCode: String?
    }

    struct PhoneNumberVerification: Decodable {
        let trustedPhoneNumbers: [TrustedPhoneNumber]?
        let trustedPhoneNumber: TrustedPhoneNumber?
    }

    let noTrustedDevices: Bool?
    let trustedPhoneNumbers: [TrustedPhoneNumber]?
    let phoneNumberVerification: PhoneNumberVerification?

    var preferredPhoneNumber: TrustedPhoneNumber? {
        trustedPhoneNumbers?.first ??
        phoneNumberVerification?.trustedPhoneNumber ??
        phoneNumberVerification?.trustedPhoneNumbers?.first
    }
}
