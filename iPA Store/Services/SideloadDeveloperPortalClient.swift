import Foundation
import CryptoKit
import CommonCrypto
import Darwin
import Security

enum SideloadDeveloperPortalError: LocalizedError {
    case anisetteUnavailable(String)
    case badServerResponse
    case incorrectCredentials
    case invalidAnisetteData
    case requiresTwoFactorAuthentication
    case incorrectVerificationCode
    case noTeams
    case missingSigningCredentials
    case appleError(String)
    
    var errorDescription: String? {
        switch self {
        case .anisetteUnavailable(let message):
            return "Could not prepare Apple developer authentication: \(message)"
        case .badServerResponse:
            return "Apple returned an unexpected developer portal response."
        case .incorrectCredentials:
            return "Incorrect Apple ID or password."
        case .invalidAnisetteData:
            return "Apple rejected this Mac's authentication data."
        case .requiresTwoFactorAuthentication:
            return "Two-factor verification is required."
        case .incorrectVerificationCode:
            return "Incorrect verification code."
        case .noTeams:
            return "No Apple developer teams were found for this account."
        case .missingSigningCredentials:
            return "Save this Apple ID as a signing account first so iPA Store can request signing assets from Apple."
        case .appleError(let message):
            return message
        }
    }
}

struct SideloadRemoteProvisioningProfile: Sendable {
    let data: Data
    let identifier: String
    let name: String
    let teamID: String
    let bundleIdentifier: String
}

final class SideloadDeveloperPortalClient {
    private let authenticationProtocolVersion = "A1234"
    private let portalProtocolVersion = "QH65B2"
    private let clientID = "XABBG36SBA"
    private let appTokenIdentifier = "com.apple.gs.xcode.auth"
    private var cachedAuthenticationContext: DeveloperPortalAuthenticationContext?
    
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }()
    
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    func fetchSigningTeamSummary(email: String, password: String) async throws -> SideloadSigningTeamSummary {
        let context = try await authenticationContext(
            email: email,
            password: password,
            preferredTeamID: nil
        )
        let team = context.team
        let developerSession = context.session
        
        let appIDs = try await fetchAppIDs(team: team, session: developerSession)
        return SideloadSigningTeamSummary(
            teamID: team.id,
            teamName: team.name,
            teamType: team.type,
            registeredAppIDCount: appIDs.count,
            nextExpirationDate: appIDs.compactMap(\.expirationDate).sorted().first,
            checkedAt: Date()
        )
    }
    
    func fetchDevelopmentProvisioningProfile(
        email: String,
        password: String,
        appName: String,
        bundleIdentifier: String,
        device: SideloadDevice,
        preferredTeamID: String?
    ) async throws -> SideloadRemoteProvisioningProfile {
        let target = SideloadSigningTarget(
            kind: .app,
            displayName: appName,
            originalBundleIdentifier: bundleIdentifier,
            targetBundleIdentifier: bundleIdentifier,
            relativePath: nil
        )
        let profiles = try await fetchDevelopmentProvisioningProfiles(
            email: email,
            password: password,
            targets: [target],
            device: device,
            preferredTeamID: preferredTeamID
        )
        
        guard let profile = profiles[bundleIdentifier] else {
            throw SideloadSigningError.missingRemoteProvisioningProfile(bundleIdentifier)
        }
        
        return profile
    }
    
    func fetchDevelopmentProvisioningProfiles(
        email: String,
        password: String,
        targets: [SideloadSigningTarget],
        device: SideloadDevice,
        preferredTeamID: String?
    ) async throws -> [String: SideloadRemoteProvisioningProfile] {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            throw SideloadDeveloperPortalError.missingSigningCredentials
        }
        
        guard let deviceIdentifier = device.uniqueIdentifier, !deviceIdentifier.isEmpty else {
            throw SideloadInstallError.missingDeviceIdentifier
        }
        
        let context = try await authenticationContext(
            email: email,
            password: password,
            preferredTeamID: preferredTeamID
        )
        let team = context.team
        let developerSession = context.session
        
        try await registerDeviceIfNeeded(
            name: device.name,
            identifier: deviceIdentifier,
            team: team,
            session: developerSession
        )
        
        var profiles: [String: SideloadRemoteProvisioningProfile] = [:]
        for target in targets {
            let appID = try await registerAppIDIfNeeded(
                name: target.displayName,
                bundleIdentifier: target.targetBundleIdentifier,
                team: team,
                session: developerSession
            )
            
            profiles[target.targetBundleIdentifier] = try await fetchProvisioningProfile(
                appID: appID,
                bundleIdentifier: target.targetBundleIdentifier,
                team: team,
                session: developerSession
            )
        }
        
        return profiles
    }
    
    func createDevelopmentCertificate(
        email: String,
        password: String,
        preferredTeamID: String?,
        machineName: String
    ) async throws {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            throw SideloadDeveloperPortalError.missingSigningCredentials
        }
        
        let context = try await authenticationContext(
            email: email,
            password: password,
            preferredTeamID: preferredTeamID
        )
        let team = context.team
        let developerSession = context.session
        
        let request = try SideloadCertificateRequest.make(machineName: machineName)
        let certificateData = try await submitDevelopmentCertificateRequest(
            request,
            machineName: machineName,
            team: team,
            session: developerSession
        )
        try importCertificateToKeychain(certificateData)
    }
    
    private func authenticationContext(
        email unsanitizedEmail: String,
        password: String,
        preferredTeamID: String?
    ) async throws -> DeveloperPortalAuthenticationContext {
        let email = unsanitizedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        if let cachedAuthenticationContext,
           cachedAuthenticationContext.email == email,
           cachedAuthenticationContext.matches(preferredTeamID: preferredTeamID) {
            return cachedAuthenticationContext
        }
        
        let anisette = try SideloadAnisetteData.current()
        let developerSession = try await authenticate(email: email, password: password, anisette: anisette)
        let teams = try await fetchTeams(session: developerSession)
        
        guard let team = preferredTeam(from: teams, preferredTeamID: preferredTeamID) else {
            throw SideloadDeveloperPortalError.noTeams
        }
        
        let context = DeveloperPortalAuthenticationContext(
            email: email,
            preferredTeamID: preferredTeamID,
            session: developerSession,
            team: team
        )
        cachedAuthenticationContext = context
        return context
    }
    
    private func preferredTeam(from teams: [DeveloperPortalTeam]) -> DeveloperPortalTeam? {
        preferredTeam(from: teams, preferredTeamID: nil)
    }
    
    private func preferredTeam(from teams: [DeveloperPortalTeam], preferredTeamID: String?) -> DeveloperPortalTeam? {
        if let preferredTeamID,
           let team = teams.first(where: { $0.id == preferredTeamID }) {
            return team
        }
        
        return teams.first { $0.type == .individual || $0.type == .organization }
        ?? teams.first { $0.type == .free }
        ?? teams.first
    }
}

private extension SideloadDeveloperPortalClient {
    func authenticate(email unsanitizedEmail: String, password: String, anisette: SideloadAnisetteData) async throws -> DeveloperPortalSession {
        let email = unsanitizedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var srpClient = AppleSRPClient(accountName: email)
        let clientDictionary = anisette.clientDictionary(locale: Locale.current)
        
        let initRequest: [String: Any] = [
            "A2k": srpClient.clientPublicKeyData,
            "cpd": clientDictionary,
            "ps": ["s2k", "s2k_fo"],
            "o": "init",
            "u": email
        ]
        
        let initResponse = try await sendGrandSlamRequest(parameters: initRequest, anisette: anisette)
        
        guard let c = initResponse["c"] as? String,
              let salt = initResponse["s"] as? Data,
              let iterations = initResponse["i"] as? Int,
              let serverPublicKey = initResponse["B"] as? Data else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        let protocolName = initResponse["sp"] as? String ?? "s2k"
        let challenge = try srpClient.processGSAChallenge(
            password: password,
            saltData: salt,
            serverPublicKeyData: serverPublicKey,
            protocol: protocolName,
            iterations: iterations
        )
        
        let completeRequest: [String: Any] = [
            "c": c,
            "cpd": clientDictionary,
            "M1": challenge.m1,
            "o": "complete",
            "u": email
        ]
        
        let completeResponse = try await sendGrandSlamRequest(parameters: completeRequest, anisette: anisette)
        
        guard let serverM2 = completeResponse["M2"] as? Data,
              let encryptedServerDictionary = completeResponse["spd"] as? Data,
              let status = completeResponse["Status"] as? [String: Any] else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        guard serverM2 == challenge.m2 else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        switch status["au"] as? String {
        case "trustedDeviceSecondaryAuth", "secondaryAuth":
            throw SideloadDeveloperPortalError.requiresTwoFactorAuthentication
        default:
            break
        }
        
        let decryptedServerDictionaryData = try encryptedServerDictionary.decryptAESCBC(
            key: challenge.sessionKey.gsaHMAC(message: "extra data key:"),
            iv: challenge.sessionKey.gsaHMAC(message: "extra data iv:")
        )
        
        guard let decryptedServerDictionary = try PropertyListSerialization.propertyList(
            from: decryptedServerDictionaryData,
            format: nil
        ) as? [String: Any],
              let dsid = decryptedServerDictionary["adsid"] as? String,
              let idmsToken = decryptedServerDictionary["GsIdmsToken"] as? String,
              let gsaSessionKey = decryptedServerDictionary["sk"] as? Data,
              let tokenChallenge = decryptedServerDictionary["c"] as? Data else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        let checksum = gsaSessionKey.gsaHMAC(messageData: Data("apptokens\(dsid)\(appTokenIdentifier)".utf8))
        let tokenRequest: [String: Any] = [
            "app": [appTokenIdentifier],
            "c": tokenChallenge,
            "checksum": checksum,
            "cpd": clientDictionary,
            "o": "apptokens",
            "t": idmsToken,
            "u": dsid
        ]
        
        let tokenResponse = try await sendGrandSlamRequest(parameters: tokenRequest, anisette: anisette)
        guard let encryptedToken = tokenResponse["et"] as? Data else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        let tokenData = try encryptedToken.decryptAESGCM(key: gsaSessionKey)
        guard let tokenDictionary = try PropertyListSerialization.propertyList(from: tokenData, format: nil) as? [String: Any],
              let appTokens = tokenDictionary["t"] as? [String: Any],
              let xcodeToken = appTokens[appTokenIdentifier] as? [String: Any],
              let authToken = xcodeToken["token"] as? String else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        return DeveloperPortalSession(dsid: dsid, authToken: authToken, anisette: anisette)
    }
    
    func sendGrandSlamRequest(parameters requestParameters: [String: Any], anisette: SideloadAnisetteData) async throws -> [String: Any] {
        let requestURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
        let body: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": requestParameters
        ]
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(anisette.deviceDescription, forHTTPHeaderField: "X-MMe-Client-Info")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        guard let responseDictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let dictionary = responseDictionary["Response"] as? [String: Any],
              let status = dictionary["Status"] as? [String: Any] else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        let errorCode = status["ec"] as? Int ?? 0
        guard errorCode == 0 else {
            switch errorCode {
            case -20101, -22406:
                throw SideloadDeveloperPortalError.incorrectCredentials
            case -22421:
                throw SideloadDeveloperPortalError.invalidAnisetteData
            case -21669:
                throw SideloadDeveloperPortalError.incorrectVerificationCode
            default:
                let message = status["em"] as? String ?? "Apple authentication failed"
                throw SideloadDeveloperPortalError.appleError("\(message) (\(errorCode))")
            }
        }
        
        return dictionary
    }
}

private extension SideloadDeveloperPortalClient {
    func fetchTeams(session developerSession: DeveloperPortalSession) async throws -> [DeveloperPortalTeam] {
        let response = try await sendPortalRequest(
            path: "listTeams.action",
            parameters: [:],
            team: nil,
            session: developerSession
        )
        
        guard let teams = response["teams"] as? [[String: Any]] else {
            try throwPortalErrorIfPresent(response)
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        return teams.compactMap(DeveloperPortalTeam.init(response:))
    }
    
    func fetchAppIDs(team: DeveloperPortalTeam, session developerSession: DeveloperPortalSession) async throws -> [DeveloperPortalAppID] {
        let response = try await sendPortalRequest(
            path: "ios/listAppIds.action",
            parameters: [:],
            team: team,
            session: developerSession
        )
        
        guard let appIDs = response["appIds"] as? [[String: Any]] else {
            try throwPortalErrorIfPresent(response)
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        return appIDs.compactMap(DeveloperPortalAppID.init(response:))
    }
    
    func fetchDevices(team: DeveloperPortalTeam, session developerSession: DeveloperPortalSession) async throws -> [DeveloperPortalDevice] {
        let response = try await sendPortalRequest(
            path: "ios/listDevices.action",
            parameters: [:],
            team: team,
            session: developerSession
        )
        
        guard let devices = response["devices"] as? [[String: Any]] else {
            try throwPortalErrorIfPresent(response)
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        return devices.compactMap(DeveloperPortalDevice.init(response:))
    }
    
    func registerDeviceIfNeeded(
        name: String,
        identifier: String,
        team: DeveloperPortalTeam,
        session developerSession: DeveloperPortalSession
    ) async throws {
        let devices = try await fetchDevices(team: team, session: developerSession)
        
        if devices.contains(where: { $0.identifier == identifier }) {
            return
        }
        
        let response = try await sendPortalRequest(
            path: "ios/addDevice.action",
            parameters: [
                "deviceNumber": identifier,
                "name": name,
                "DTDK_Platform": "ios"
            ],
            team: team,
            session: developerSession
        )
        
        if response["device"] as? [String: Any] != nil {
            return
        }
        
        try throwPortalErrorIfPresent(response)
        throw SideloadDeveloperPortalError.badServerResponse
    }
    
    func registerAppIDIfNeeded(
        name: String,
        bundleIdentifier: String,
        team: DeveloperPortalTeam,
        session developerSession: DeveloperPortalSession
    ) async throws -> DeveloperPortalAppID {
        let appIDs = try await fetchAppIDs(team: team, session: developerSession)
        
        if let appID = appIDs.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return appID
        }
        
        let response = try await sendPortalRequest(
            path: "ios/addAppId.action",
            parameters: [
                "identifier": bundleIdentifier,
                "name": sanitizedAppIDName(name)
            ],
            team: team,
            session: developerSession
        )
        
        guard let appIDDictionary = response["appId"] as? [String: Any],
              let appID = DeveloperPortalAppID(response: appIDDictionary) else {
            try throwPortalErrorIfPresent(response)
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        return appID
    }
    
    func fetchProvisioningProfile(
        appID: DeveloperPortalAppID,
        bundleIdentifier: String,
        team: DeveloperPortalTeam,
        session developerSession: DeveloperPortalSession
    ) async throws -> SideloadRemoteProvisioningProfile {
        let response = try await sendPortalRequest(
            path: "ios/downloadTeamProvisioningProfile.action",
            parameters: [
                "appIdId": appID.id,
                "DTDK_Platform": "ios"
            ],
            team: team,
            session: developerSession
        )
        
        guard let profileDictionary = response["provisioningProfile"] as? [String: Any],
              let encodedProfile = profileDictionary["encodedProfile"] as? Data else {
            try throwPortalErrorIfPresent(response)
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        let identifier = profileDictionary["provisioningProfileId"] as? String ?? UUID().uuidString
        let decodedProfile = try SideloadProvisioningProfile(data: encodedProfile, sourceURL: nil)
        
        return SideloadRemoteProvisioningProfile(
            data: encodedProfile,
            identifier: identifier,
            name: decodedProfile.name,
            teamID: decodedProfile.teamID,
            bundleIdentifier: bundleIdentifier
        )
    }
    
    func submitDevelopmentCertificateRequest(
        _ certificateRequest: SideloadCertificateRequest,
        machineName: String,
        team: DeveloperPortalTeam,
        session developerSession: DeveloperPortalSession
    ) async throws -> Data {
        let response = try await sendPortalRequest(
            path: "ios/submitDevelopmentCSR.action",
            parameters: [
                "csrContent": certificateRequest.csrPEM,
                "machineId": UUID().uuidString,
                "machineName": machineName
            ],
            team: team,
            session: developerSession
        )
        
        guard let certificateDictionary = response["certRequest"] as? [String: Any] else {
            try throwPortalErrorIfPresent(response)
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        if let data = certificateDictionary["certContent"] as? Data {
            return data
        }
        
        if let encodedData = certificateDictionary["certificateContent"] as? String,
           let data = Data(base64Encoded: encodedData) {
            return data
        }
        
        throw SideloadDeveloperPortalError.badServerResponse
    }
    
    func sendPortalRequest(
        path: String,
        parameters additionalParameters: [String: Any],
        team: DeveloperPortalTeam?,
        session developerSession: DeveloperPortalSession
    ) async throws -> [String: Any] {
        let url = URL(string: "https://developerservices2.apple.com/services/\(portalProtocolVersion)/\(path)?clientId=\(clientID)")!
        var parameters: [String: Any] = [
            "clientId": clientID,
            "protocolVersion": portalProtocolVersion,
            "requestId": UUID().uuidString.uppercased()
        ]
        
        if let team {
            parameters["teamId"] = team.id
        }
        
        for (key, value) in additionalParameters {
            parameters[key] = value
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)
        portalHeaders(for: developerSession).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        guard let responseDictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        return responseDictionary
    }
    
    func portalHeaders(for developerSession: DeveloperPortalSession) -> [String: String] {
        [
            "Content-Type": "text/x-xml-plist",
            "User-Agent": "Xcode",
            "Accept": "text/x-xml-plist",
            "Accept-Language": "en-us",
            "X-Apple-App-Info": appTokenIdentifier,
            "X-Xcode-Version": "16.2 (16C5032a)",
            "X-Apple-I-Identity-Id": developerSession.dsid,
            "X-Apple-GS-Token": developerSession.authToken,
            "X-Apple-I-MD-M": developerSession.anisette.machineID,
            "X-Apple-I-MD": developerSession.anisette.oneTimePassword,
            "X-Apple-I-MD-LU": developerSession.anisette.localUserID,
            "X-Apple-I-MD-RINFO": "\(developerSession.anisette.routingInfo)",
            "X-Mme-Device-Id": developerSession.anisette.deviceUniqueIdentifier,
            "X-MMe-Client-Info": developerSession.anisette.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from: developerSession.anisette.date),
            "X-Apple-Locale": Locale.current.identifier,
            "X-Apple-I-Locale": Locale.current.identifier,
            "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "PST"
        ]
    }
    
    func throwPortalErrorIfPresent(_ response: [String: Any]) throws {
        guard let result = response["resultCode"] else {
            return
        }
        
        let resultCode = Int("\(result)") ?? 0
        guard resultCode != 0 else {
            return
        }
        
        let message = (response["userString"] as? String)
        ?? (response["resultString"] as? String)
        ?? "Apple developer portal request failed"
        throw SideloadDeveloperPortalError.appleError("\(message) (\(resultCode))")
    }
    
    func sanitizedAppIDName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive], locale: nil)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let sanitized = folded.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : ""
        }.joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return sanitized.isEmpty ? "App" : sanitized
    }
    
    func importCertificateToKeychain(_ certificateData: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain status \(status)"
            throw SideloadSigningError.codeSigningFailed("development certificate", message)
        }
    }
}

private struct DeveloperPortalSession {
    let dsid: String
    let authToken: String
    let anisette: SideloadAnisetteData
}

private struct DeveloperPortalAuthenticationContext {
    let email: String
    let preferredTeamID: String?
    let session: DeveloperPortalSession
    let team: DeveloperPortalTeam
    
    func matches(preferredTeamID requestedTeamID: String?) -> Bool {
        if let requestedTeamID {
            return team.id == requestedTeamID
        }
        
        return preferredTeamID == nil || preferredTeamID == team.id
    }
}

private struct DeveloperPortalTeam {
    let id: String
    let name: String
    let type: SideloadSigningTeamType
    
    init?(response: [String: Any]) {
        guard let id = response["teamId"] as? String,
              let name = response["name"] as? String,
              let rawType = response["type"] as? String else {
            return nil
        }
        
        self.id = id
        self.name = name
        
        switch rawType {
        case "Company/Organization":
            type = .organization
        case "Individual":
            let memberships = response["memberships"] as? [[String: Any]] ?? []
            let membershipName = memberships.first?["name"] as? String ?? ""
            type = memberships.count == 1 && membershipName.localizedCaseInsensitiveContains("free") ? .free : .individual
        default:
            type = .unknown
        }
    }
}

private struct DeveloperPortalAppID {
    let id: String
    let bundleIdentifier: String
    let expirationDate: Date?
    
    init?(response: [String: Any]) {
        guard let id = response["appIdId"] as? String,
              let bundleIdentifier = response["identifier"] as? String else {
            return nil
        }
        
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.expirationDate = response["expirationDate"] as? Date
    }
}

private struct DeveloperPortalDevice {
    let name: String
    let identifier: String
    
    init?(response: [String: Any]) {
        guard let name = response["name"] as? String,
              let identifier = response["deviceNumber"] as? String else {
            return nil
        }
        
        self.name = name
        self.identifier = identifier
    }
}

private struct SideloadAnisetteData {
    let machineID: String
    let oneTimePassword: String
    let localUserID: String
    let routingInfo: UInt64
    let deviceUniqueIdentifier: String
    let deviceSerialNumber: String
    let deviceDescription: String
    let date: Date
    
    func clientDictionary(locale: Locale) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        return [
            "bootstrap": true,
            "icscrec": true,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud",
            "loc": locale.identifier,
            "X-Apple-Locale": locale.identifier,
            "X-Apple-I-MD": oneTimePassword,
            "X-Apple-I-MD-M": machineID,
            "X-Mme-Device-Id": deviceUniqueIdentifier,
            "X-Apple-I-MD-LU": localUserID,
            "X-Apple-I-MD-RINFO": routingInfo,
            "X-Apple-I-SRL-NO": deviceSerialNumber,
            "X-Apple-I-Client-Time": formatter.string(from: date),
            "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "PST"
        ]
    }
    
    static func current() throws -> SideloadAnisetteData {
        let aosKitURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/AOSKit.framework")
        guard let aosKit = Bundle(url: aosKitURL) else {
            throw SideloadDeveloperPortalError.anisetteUnavailable("AOSKit.framework was not found.")
        }
        
        do {
            try aosKit.loadAndReturnError()
        } catch {
            throw SideloadDeveloperPortalError.anisetteUnavailable(error.localizedDescription)
        }
        
        let otpSelector = NSSelectorFromString("retrieveOTPHeadersForDSID:")
        let serialSelector = NSSelectorFromString("machineSerialNumber")
        let udidSelector = NSSelectorFromString("machineUDID")
        
        guard let utilitiesClass = NSClassFromString("AOSUtilities"),
              utilitiesClass.responds(to: otpSelector),
              utilitiesClass.responds(to: serialSelector),
              utilitiesClass.responds(to: udidSelector) else {
            throw SideloadDeveloperPortalError.anisetteUnavailable("AOSUtilities is unavailable.")
        }
        
        let utilities = utilitiesClass as AnyObject
        guard let requestHeaders = utilities.perform(otpSelector, with: "-2")?.takeUnretainedValue() as? [String: Any] else {
            throw SideloadDeveloperPortalError.anisetteUnavailable("Missing one-time password headers.")
        }
        
        guard let machineID = requestHeaders["X-Apple-MD-M"] as? String,
              let oneTimePassword = requestHeaders["X-Apple-MD"] as? String else {
            throw SideloadDeveloperPortalError.anisetteUnavailable("Incomplete one-time password headers.")
        }
        
        guard let deviceID = utilities.perform(udidSelector)?.takeUnretainedValue() as? String,
              let localUserID = deviceID.data(using: .utf8)?.base64EncodedString() else {
            throw SideloadDeveloperPortalError.anisetteUnavailable("Missing machine identifier.")
        }
        
        let serialNumber = utilities.perform(serialSelector)?.takeUnretainedValue() as? String ?? "C02LKHBBFD57"
        let routingInfo: UInt64 = 84215040
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let buildVersion = ProcessInfo.processInfo.kernelBuildVersion ?? "22F66"
        let osName = osVersion.majorVersion < 11 ? "Mac OS X" : "macOS"
        let deviceModel = ProcessInfo.processInfo.hardwareModel ?? "Mac"
        let version = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let deviceDescription = "<\(deviceModel)> <\(osName);\(version);\(buildVersion)> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        
        return SideloadAnisetteData(
            machineID: machineID,
            oneTimePassword: oneTimePassword,
            localUserID: localUserID,
            routingInfo: routingInfo,
            deviceUniqueIdentifier: deviceID,
            deviceSerialNumber: serialNumber,
            deviceDescription: deviceDescription,
            date: Date()
        )
    }
}

private extension Data {
    func gsaHMAC(message: String) -> Data {
        gsaHMAC(messageData: Data(message.utf8))
    }
    
    func gsaHMAC(messageData: Data) -> Data {
        let key = SymmetricKey(data: self)
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
        return Data(authenticationCode)
    }
    
    func decryptAESCBC(key: Data, iv: Data) throws -> Data {
        var output = Data(repeating: 0, count: count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            Swift.min(key.count, kCCKeySizeAES256),
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        
        guard status == kCCSuccess else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        output.removeSubrange(outputLength..<output.count)
        return output
    }
    
    func decryptAESGCM(key: Data) throws -> Data {
        let versionSize = 3
        let ivSize = 16
        let tagSize = 16
        guard count > versionSize + ivSize + tagSize else {
            throw SideloadDeveloperPortalError.badServerResponse
        }
        
        let version = self[startIndex..<index(startIndex, offsetBy: versionSize)]
        let ivStart = index(startIndex, offsetBy: versionSize)
        let ivEnd = index(ivStart, offsetBy: ivSize)
        let tagStart = index(endIndex, offsetBy: -tagSize)
        let iv = self[ivStart..<ivEnd]
        let ciphertext = self[ivEnd..<tagStart]
        let tag = self[tagStart..<endIndex]
        
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(iv)),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: key), authenticating: Data(version))
    }
}

private extension ProcessInfo {
    var kernelBuildVersion: String? {
        sysctlString("kern.osversion")
    }
    
    var hardwareModel: String? {
        sysctlString("hw.model")
    }
    
    func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        
        return String(cString: buffer)
    }
}
