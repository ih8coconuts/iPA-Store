import Foundation
import Security

struct SideloadSignedApp: Sendable {
    let extractedApp: SideloadExtractedApp
    let profileName: String
    let teamID: String
}

nonisolated enum SideloadSigningTargetKind: Hashable, Sendable {
    case app
    case appExtension
}

nonisolated struct SideloadSigningTarget: Identifiable, Hashable, Sendable {
    let kind: SideloadSigningTargetKind
    let displayName: String
    let originalBundleIdentifier: String
    let targetBundleIdentifier: String
    let relativePath: String?
    
    var id: String {
        targetBundleIdentifier
    }
}

enum SideloadSigningError: LocalizedError {
    case invalidBundleIdentifier(String)
    case encryptedExecutable(String)
    case missingExecutable(String)
    case missingProvisioningProfilesDirectory
    case missingProvisioningProfile(bundleIdentifier: String, deviceIdentifier: String, preferredTeamID: String?)
    case missingSigningIdentity(teamID: String, profileName: String)
    case provisioningProfileDecodeFailed(String)
    case missingRemoteProvisioningProfile(String)
    case plistWriteFailed(String)
    case codeSigningAPIMissing
    case codeSigningFailed(String, String)
    
    var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier(let bundleIdentifier):
            return "\"\(bundleIdentifier)\" is not a valid bundle identifier."
        case .encryptedExecutable(let appName):
            return "\(appName) still appears to be FairPlay-encrypted. Re-signing needs a decrypted IPA."
        case .missingExecutable(let appName):
            return "\(appName) does not have a readable executable."
        case .missingProvisioningProfilesDirectory:
            return "No local provisioning profiles were found. Open Xcode once with this Apple ID or let the app create profiles when developer portal signing is wired in."
        case .missingProvisioningProfile(let bundleIdentifier, let deviceIdentifier, let preferredTeamID):
            if let preferredTeamID {
                return "No provisioning profile for \(bundleIdentifier) includes device \(deviceIdentifier) on team \(preferredTeamID)."
            }
            
            return "No provisioning profile for \(bundleIdentifier) includes device \(deviceIdentifier)."
        case .missingSigningIdentity(let teamID, let profileName):
            return "No Apple Development signing identity in Keychain matches \(profileName) on team \(teamID)."
        case .provisioningProfileDecodeFailed(let filename):
            return "Could not read provisioning profile \(filename)."
        case .missingRemoteProvisioningProfile(let bundleIdentifier):
            return "Apple did not return a provisioning profile for \(bundleIdentifier)."
        case .plistWriteFailed(let filename):
            return "Could not update \(filename)."
        case .codeSigningAPIMissing:
            return "macOS code signing APIs could not be loaded."
        case .codeSigningFailed(let item, let message):
            return "Could not sign \(item): \(message)"
        }
    }
}

enum SideloadAppSigner {
    nonisolated static func signingTargets(
        ipaURL: URL,
        mainBundleIdentifier: String
    ) throws -> [SideloadSigningTarget] {
        let normalizedMainBundleIdentifier = try normalizeBundleIdentifier(mainBundleIdentifier)
        let extractedApp = try SideloadIPAExtractor.extractAppBundle(from: ipaURL)
        defer {
            extractedApp.cleanUp()
        }
        
        let mainInfo = try bundleInfo(at: extractedApp.appBundleURL)
        let originalMainBundleIdentifier = try bundleIdentifier(from: mainInfo)
        let mainDisplayName = displayName(
            from: mainInfo,
            fallback: extractedApp.appBundleURL.deletingPathExtension().lastPathComponent
        )
        
        var targets: [SideloadSigningTarget] = [
            SideloadSigningTarget(
                kind: .app,
                displayName: mainDisplayName,
                originalBundleIdentifier: originalMainBundleIdentifier,
                targetBundleIdentifier: normalizedMainBundleIdentifier,
                relativePath: nil
            )
        ]
        
        for extensionURL in try appExtensionBundleURLs(in: extractedApp.appBundleURL) {
            let info = try bundleInfo(at: extensionURL)
            let originalBundleIdentifier = try bundleIdentifier(from: info)
            let targetBundleIdentifier = try targetBundleIdentifier(
                forNestedBundleIdentifier: originalBundleIdentifier,
                originalMainBundleIdentifier: originalMainBundleIdentifier,
                targetMainBundleIdentifier: normalizedMainBundleIdentifier
            )
            let fallbackName = extensionURL.deletingPathExtension().lastPathComponent
            let relativePath = extensionURL.path.replacingOccurrences(
                of: extractedApp.appBundleURL.path + "/",
                with: ""
            )
            
            targets.append(
                SideloadSigningTarget(
                    kind: .appExtension,
                    displayName: "\(mainDisplayName) \(displayName(from: info, fallback: fallbackName))",
                    originalBundleIdentifier: originalBundleIdentifier,
                    targetBundleIdentifier: targetBundleIdentifier,
                    relativePath: relativePath
                )
            )
        }
        
        return targets
    }
    
    nonisolated static func prepareSignedApp(
        ipaURL: URL,
        bundleIdentifier: String,
        deviceIdentifier: String,
        preferredTeamID: String?,
        signingTargets: [SideloadSigningTarget],
        remoteProvisioningProfiles: [String: Data]
    ) throws -> SideloadSignedApp {
        let normalizedBundleIdentifier = try normalizeBundleIdentifier(bundleIdentifier)
        let extractedApp = try SideloadIPAExtractor.extractAppBundle(from: ipaURL)
        
        do {
            try ensureAppIsSignable(extractedApp.appBundleURL)
            
            let mainTarget = signingTargets.first { $0.kind == .app }
            let mainProfile = try provisioningProfile(
                for: mainTarget?.targetBundleIdentifier ?? normalizedBundleIdentifier,
                normalizedBundleIdentifier: normalizedBundleIdentifier,
                deviceIdentifier: deviceIdentifier,
                preferredTeamID: preferredTeamID,
                remoteProvisioningProfiles: remoteProvisioningProfiles
            )
            
            let identity = try SideloadSigningIdentityStore.identity(matching: mainProfile)
            
            try rewriteBundleIdentifier(normalizedBundleIdentifier, in: extractedApp.appBundleURL)
            try embed(profile: mainProfile, in: extractedApp.appBundleURL)
            try removeExistingSignatureArtifacts(in: extractedApp.appBundleURL)
            
            let mainSigner = try AppleCodeSigner(
                identity: identity.identity,
                teamID: mainProfile.teamID,
                bundleIdentifier: normalizedBundleIdentifier,
                entitlements: mainProfile.entitlements(for: normalizedBundleIdentifier)
            )
            
            try signAppExtensions(
                in: extractedApp.appBundleURL,
                signingTargets: signingTargets,
                remoteProvisioningProfiles: remoteProvisioningProfiles,
                identity: identity.identity
            )
            
            try mainSigner.signSupportingCode(in: extractedApp.appBundleURL)
            try mainSigner.signBundle(extractedApp.appBundleURL)
            
            return SideloadSignedApp(
                extractedApp: extractedApp,
                profileName: mainProfile.name,
                teamID: mainProfile.teamID
            )
        } catch {
            extractedApp.cleanUp()
            throw error
        }
    }
    
    nonisolated private static func provisioningProfile(
        for targetBundleIdentifier: String,
        normalizedBundleIdentifier: String,
        deviceIdentifier: String,
        preferredTeamID: String?,
        remoteProvisioningProfiles: [String: Data]
    ) throws -> SideloadProvisioningProfile {
        if let profileData = remoteProvisioningProfiles[targetBundleIdentifier] {
            return try SideloadProvisioningProfile(data: profileData, sourceURL: nil)
        }
        
        if targetBundleIdentifier == normalizedBundleIdentifier {
            return try SideloadProvisioningProfileStore()
                .bestProfile(
                    bundleIdentifier: normalizedBundleIdentifier,
                    deviceIdentifier: deviceIdentifier,
                    preferredTeamID: preferredTeamID
                )
        }
        
        throw SideloadSigningError.missingRemoteProvisioningProfile(targetBundleIdentifier)
    }
    
    nonisolated private static func signAppExtensions(
        in appBundleURL: URL,
        signingTargets: [SideloadSigningTarget],
        remoteProvisioningProfiles: [String: Data],
        identity: SecIdentity
    ) throws {
        let targetsByOriginalBundleIdentifier = Dictionary(
            uniqueKeysWithValues: signingTargets
                .filter { $0.kind == .appExtension }
                .map { ($0.originalBundleIdentifier, $0) }
        )
        
        for extensionURL in try appExtensionBundleURLs(in: appBundleURL) {
            let info = try bundleInfo(at: extensionURL)
            let originalBundleIdentifier = try bundleIdentifier(from: info)
            guard let target = targetsByOriginalBundleIdentifier[originalBundleIdentifier] else {
                continue
            }
            
            guard let profileData = remoteProvisioningProfiles[target.targetBundleIdentifier] else {
                throw SideloadSigningError.missingRemoteProvisioningProfile(target.targetBundleIdentifier)
            }
            
            let profile = try SideloadProvisioningProfile(data: profileData, sourceURL: nil)
            try rewriteBundleIdentifier(target.targetBundleIdentifier, in: extensionURL)
            try embed(profile: profile, in: extensionURL)
            
            let signer = try AppleCodeSigner(
                identity: identity,
                teamID: profile.teamID,
                bundleIdentifier: target.targetBundleIdentifier,
                entitlements: profile.entitlements(for: target.targetBundleIdentifier)
            )
            try signer.signSupportingCode(in: extensionURL)
            try signer.signBundle(extensionURL)
        }
    }
    
    nonisolated private static func normalizeBundleIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$"#
        
        guard !trimmed.isEmpty,
              trimmed.contains("."),
              trimmed.range(of: pattern, options: .regularExpression) != nil,
              !trimmed.contains("..") else {
            throw SideloadSigningError.invalidBundleIdentifier(value)
        }
        
        return trimmed
    }
    
    nonisolated private static func ensureAppIsSignable(_ appBundleURL: URL) throws {
        let info = try bundleInfo(at: appBundleURL)
        let appName = (info["CFBundleDisplayName"] as? String)
        ?? (info["CFBundleName"] as? String)
        ?? appBundleURL.deletingPathExtension().lastPathComponent
        
        guard let executableName = info["CFBundleExecutable"] as? String else {
            throw SideloadSigningError.missingExecutable(appName)
        }
        
        let executableURL = appBundleURL.appendingPathComponent(executableName)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw SideloadSigningError.missingExecutable(appName)
        }
        
        if try MachOEncryptionDetector.isEncryptedExecutable(at: executableURL) {
            throw SideloadSigningError.encryptedExecutable(appName)
        }
    }
    
    nonisolated private static func rewriteBundleIdentifier(_ bundleIdentifier: String, in appBundleURL: URL) throws {
        let infoURL = appBundleURL.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.binary
        let data = try Data(contentsOf: infoURL)
        
        guard var info = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? [String: Any] else {
            throw SideloadIPAExtractionError.missingInfoPlist
        }
        
        info["CFBundleIdentifier"] = bundleIdentifier
        
        guard PropertyListSerialization.propertyList(info, isValidFor: format) else {
            throw SideloadSigningError.plistWriteFailed(infoURL.lastPathComponent)
        }
        
        let outputData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: format,
            options: 0
        )
        try outputData.write(to: infoURL, options: [.atomic])
    }
    
    nonisolated private static func embed(profile: SideloadProvisioningProfile, in appBundleURL: URL) throws {
        let destinationURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        try profile.data.write(to: destinationURL, options: [.atomic])
    }
    
    nonisolated private static func removeExistingSignatureArtifacts(in appBundleURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        var urlsToRemove: [URL] = []
        
        for case let url as URL in enumerator {
            let filename = url.lastPathComponent
            
            if filename == "_CodeSignature" || filename == "CodeResources" || filename == "SC_Info" {
                urlsToRemove.append(url)
                enumerator.skipDescendants()
            }
        }
        
        for url in urlsToRemove.sorted(by: { $0.path.count > $1.path.count }) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
    
    nonisolated private static func bundleInfo(at bundleURL: URL) throws -> [String: Any] {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        
        guard let info = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw SideloadIPAExtractionError.missingInfoPlist
        }
        
        return info
    }
    
    nonisolated private static func bundleIdentifier(from info: [String: Any]) throws -> String {
        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw SideloadIPAExtractionError.missingInfoPlist
        }
        
        return bundleIdentifier
    }
    
    nonisolated private static func displayName(from info: [String: Any], fallback: String) -> String {
        (info["CFBundleDisplayName"] as? String)
        ?? (info["CFBundleName"] as? String)
        ?? fallback
    }
    
    nonisolated private static func appExtensionBundleURLs(in appBundleURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.localizedCaseInsensitiveCompare("appex") == .orderedSame {
            urls.append(url)
            enumerator.skipDescendants()
        }
        
        return urls.sorted { lhs, rhs in
            lhs.path < rhs.path
        }
    }
    
    nonisolated private static func targetBundleIdentifier(
        forNestedBundleIdentifier nestedBundleIdentifier: String,
        originalMainBundleIdentifier: String,
        targetMainBundleIdentifier: String
    ) throws -> String {
        let target: String
        if nestedBundleIdentifier == originalMainBundleIdentifier {
            target = targetMainBundleIdentifier
        } else if nestedBundleIdentifier.hasPrefix(originalMainBundleIdentifier + ".") {
            let suffix = nestedBundleIdentifier.dropFirst(originalMainBundleIdentifier.count)
            target = targetMainBundleIdentifier + suffix
        } else {
            target = targetMainBundleIdentifier + "." + sanitizedBundleComponent(nestedBundleIdentifier)
        }
        
        return try normalizeBundleIdentifier(target)
    }
    
    nonisolated private static func sanitizedBundleComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let component = value
            .split(separator: ".")
            .last
            .map(String.init) ?? "Extension"
        let sanitized = component.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        
        return sanitized.isEmpty ? "Extension" : sanitized
    }
}

nonisolated struct SideloadProvisioningProfile {
    let data: Data
    let sourceURL: URL?
    let name: String
    let uuid: String
    let teamID: String
    let teamName: String
    let appIdentifier: String
    let expirationDate: Date
    let provisionedDevices: Set<String>
    let entitlements: [String: Any]
    let developerCertificates: [Data]
    
    var isExpired: Bool {
        expirationDate <= Date()
    }
    
    var isWildcard: Bool {
        appIdentifier.hasSuffix(".*")
    }
    
    func matches(bundleIdentifier: String, deviceIdentifier: String, preferredTeamID: String?) -> Bool {
        guard !isExpired else {
            return false
        }
        
        if let preferredTeamID, teamID != preferredTeamID {
            return false
        }
        
        guard provisionedDevices.contains(deviceIdentifier) else {
            return false
        }
        
        let expectedIdentifier = "\(teamID).\(bundleIdentifier)"
        return appIdentifier == expectedIdentifier || appIdentifier == "\(teamID).*"
    }
    
    func entitlements(for bundleIdentifier: String) -> [String: Any] {
        var result = entitlements
        let applicationIdentifier = "\(teamID).\(bundleIdentifier)"
        
        result["application-identifier"] = applicationIdentifier
        result["com.apple.developer.team-identifier"] = teamID
        
        if let accessGroups = result["keychain-access-groups"] as? [String] {
            result["keychain-access-groups"] = accessGroups.map { accessGroup in
                if accessGroup == "\(teamID).*" || accessGroup.hasPrefix(teamID + ".") {
                    return applicationIdentifier
                }
                
                return accessGroup
            }
        } else {
            result["keychain-access-groups"] = [applicationIdentifier]
        }
        
        return result
    }
    
    init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        try self.init(data: data, sourceURL: fileURL)
    }
    
    init(data: Data, sourceURL: URL?) throws {
        let plistData = try ProvisioningProfileDecoder.decode(data)
        
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let name = plist["Name"] as? String,
              let uuid = plist["UUID"] as? String,
              let teamIDs = plist["TeamIdentifier"] as? [String],
              let teamID = teamIDs.first,
              let teamName = plist["TeamName"] as? String,
              let expirationDate = plist["ExpirationDate"] as? Date,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appIdentifier = entitlements["application-identifier"] as? String,
              let certificates = plist["DeveloperCertificates"] as? [Data] else {
            throw SideloadSigningError.provisioningProfileDecodeFailed(sourceURL?.lastPathComponent ?? "downloaded profile")
        }
        
        self.data = data
        self.sourceURL = sourceURL
        self.name = name
        self.uuid = uuid
        self.teamID = teamID
        self.teamName = teamName
        self.appIdentifier = appIdentifier
        self.expirationDate = expirationDate
        self.entitlements = entitlements
        self.developerCertificates = certificates
        
        let devices = plist["ProvisionedDevices"] as? [String] ?? []
        provisionedDevices = Set(devices)
    }
}

nonisolated private struct SideloadProvisioningProfileStore {
    private let fileManager = FileManager.default
    
    func bestProfile(
        bundleIdentifier: String,
        deviceIdentifier: String,
        preferredTeamID: String?
    ) throws -> SideloadProvisioningProfile {
        let directory = try provisioningProfilesDirectory()
        let profileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.localizedCaseInsensitiveCompare("mobileprovision") == .orderedSame }
        
        let profiles = profileURLs.compactMap { try? SideloadProvisioningProfile(fileURL: $0) }
        let matchingProfiles = profiles
            .filter {
                $0.matches(
                    bundleIdentifier: bundleIdentifier,
                    deviceIdentifier: deviceIdentifier,
                    preferredTeamID: preferredTeamID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isWildcard != rhs.isWildcard {
                    return !lhs.isWildcard
                }
                
                return lhs.expirationDate > rhs.expirationDate
            }
        
        if let profile = matchingProfiles.first {
            return profile
        }
        
        throw SideloadSigningError.missingProvisioningProfile(
            bundleIdentifier: bundleIdentifier,
            deviceIdentifier: deviceIdentifier,
            preferredTeamID: preferredTeamID
        )
    }
    
    private func provisioningProfilesDirectory() throws -> URL {
        let directory = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("MobileDevice", isDirectory: true)
            .appendingPathComponent("Provisioning Profiles", isDirectory: true)
        
        guard fileManager.fileExists(atPath: directory.path) else {
            throw SideloadSigningError.missingProvisioningProfilesDirectory
        }
        
        return directory
    }
}

nonisolated private struct SideloadSigningIdentity {
    let identity: SecIdentity
    let certificateData: Data
    let summary: String
}

nonisolated private enum SideloadSigningIdentityStore {
    static func identity(matching profile: SideloadProvisioningProfile) throws -> SideloadSigningIdentity {
        let identities = try allCodeSigningIdentities()
        
        for identity in identities where profile.developerCertificates.contains(identity.certificateData) {
            return identity
        }
        
        throw SideloadSigningError.missingSigningIdentity(
            teamID: profile.teamID,
            profileName: profile.name
        )
    }
    
    private static func allCodeSigningIdentities() throws -> [SideloadSigningIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            return []
        }
        
        let rawIdentities: [SecIdentity]
        if let identities = item as? [SecIdentity] {
            rawIdentities = identities
        } else if let item {
            rawIdentities = [item as! SecIdentity]
        } else {
            rawIdentities = []
        }
        
        return rawIdentities.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else {
                return nil
            }
            
            let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "Apple Development"
            let retainedIdentity = Unmanaged.passRetained(identity).takeRetainedValue()
            return SideloadSigningIdentity(
                identity: retainedIdentity,
                certificateData: SecCertificateCopyData(certificate) as Data,
                summary: summary
            )
        }
    }
}

nonisolated private enum ProvisioningProfileDecoder {
    static func decode(_ data: Data) throws -> Data {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw SideloadSigningError.codeSigningAPIMissing
        }
        
        let updateStatus = data.withUnsafeBytes { buffer in
            CMSDecoderUpdateMessage(decoder, buffer.baseAddress!, data.count)
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw SideloadSigningError.provisioningProfileDecodeFailed("mobileprovision")
        }
        
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content else {
            throw SideloadSigningError.provisioningProfileDecodeFailed("mobileprovision")
        }
        
        return content as Data
    }
}

private typealias SecCodeSigner = CFTypeRef

@_silgen_name("SecCodeSignerCreate")
nonisolated private func SecCodeSignerCreate(
    _ parameters: CFDictionary,
    _ flags: SecCSFlags,
    _ signer: UnsafeMutablePointer<SecCodeSigner?>
) -> OSStatus

@_silgen_name("SecCodeSignerAddSignatureWithErrors")
nonisolated private func SecCodeSignerAddSignatureWithErrors(
    _ signer: SecCodeSigner,
    _ code: SecStaticCode,
    _ flags: SecCSFlags,
    _ errors: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> OSStatus

nonisolated private struct AppleCodeSigner {
    // SecCodeSigner expects CSMAGIC_EMBEDDED_ENTITLEMENTS bytes, not the raw plist.
    private static let embeddedEntitlementsMagic: UInt32 = 0xFADE_7171
    
    let identity: SecIdentity
    let teamID: String
    let bundleIdentifier: String
    let entitlementData: Data
    
    init(identity: SecIdentity, teamID: String, bundleIdentifier: String, entitlements: [String: Any]) throws {
        self.identity = identity
        self.teamID = teamID
        self.bundleIdentifier = bundleIdentifier
        entitlementData = try Self.entitlementBlob(from: entitlements)
    }
    
    private static func entitlementBlob(from entitlements: [String: Any]) throws -> Data {
        let xmlData = try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )
        
        var data = Data(capacity: xmlData.count + 8)
        var magic = embeddedEntitlementsMagic.bigEndian
        var length = UInt32(xmlData.count + 8).bigEndian
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(xmlData)
        return data
    }
    
    func signSupportingCode(in appBundleURL: URL) throws {
        for url in try nestedSignableURLs(in: appBundleURL) {
            try sign(url: url, identifier: nil, entitlements: nil)
        }
    }
    
    func signBundle(_ appBundleURL: URL) throws {
        try sign(url: appBundleURL, identifier: bundleIdentifier, entitlements: entitlementData)
    }
    
    private func nestedSignableURLs(in appBundleURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var urls: [URL] = []
        
        for case let url as URL in enumerator {
            guard url != appBundleURL else {
                continue
            }
            
            if url.pathExtension.localizedCaseInsensitiveCompare("appex") == .orderedSame {
                enumerator.skipDescendants()
                continue
            }
            
            if isSignableBundle(url) {
                urls.append(url)
                enumerator.skipDescendants()
                continue
            }
            
            if isSignableMachOFile(url) {
                urls.append(url)
            }
        }
        
        return urls.sorted { lhs, rhs in
            lhs.path.split(separator: "/").count > rhs.path.split(separator: "/").count
        }
    }
    
    private func isSignableBundle(_ url: URL) -> Bool {
        let signableExtensions = ["app", "appex", "framework", "xpc", "bundle"]
        return signableExtensions.contains { url.pathExtension.localizedCaseInsensitiveCompare($0) == .orderedSame }
    }
    
    private func isSignableMachOFile(_ url: URL) -> Bool {
        guard url.pathExtension.localizedCaseInsensitiveCompare("dylib") == .orderedSame else {
            return false
        }
        
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
    
    private func sign(url: URL, identifier: String?, entitlements: Data?) throws {
        var staticCode: SecStaticCode?
        let codeStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCode)
        
        guard codeStatus == errSecSuccess, let staticCode else {
            throw SideloadSigningError.codeSigningFailed(url.lastPathComponent, securityMessage(for: codeStatus))
        }
        
        var parameters: [String: Any] = [
            "signer": identity,
            "teamidentifier": teamID
        ]
        
        if let identifier {
            parameters["identifier"] = identifier
        }
        
        if let entitlements {
            parameters["entitlements"] = entitlements
        }
        
        var signer: SecCodeSigner?
        let parameterDictionary = parameters as CFDictionary
        let signerStatus = SecCodeSignerCreate(parameterDictionary, SecCSFlags(rawValue: 0), &signer)
        
        guard signerStatus == errSecSuccess, let signer else {
            throw SideloadSigningError.codeSigningFailed(url.lastPathComponent, securityMessage(for: signerStatus))
        }
        
        var error: Unmanaged<CFError>?
        let signStatus = withExtendedLifetime(parameterDictionary) {
            withExtendedLifetime(entitlements) {
                withExtendedLifetime(staticCode) {
                    withExtendedLifetime(signer) {
                        SecCodeSignerAddSignatureWithErrors(
                            signer,
                            staticCode,
                            SecCSFlags(rawValue: 0),
                            &error
                        )
                    }
                }
            }
        }
        
        guard signStatus == errSecSuccess else {
            if let error = error?.takeRetainedValue() {
                throw SideloadSigningError.codeSigningFailed(
                    url.lastPathComponent,
                    CFErrorCopyDescription(error) as String
                )
            }
            
            throw SideloadSigningError.codeSigningFailed(url.lastPathComponent, securityMessage(for: signStatus))
        }
    }
    
    private func securityMessage(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        
        return "Security status \(status)"
    }
}

nonisolated private enum MachOEncryptionDetector {
    static func isEncryptedExecutable(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try data.containsEncryptedMachOSlice(at: 0)
    }
}

nonisolated private extension Data {
    func containsEncryptedMachOSlice(at offset: Int) throws -> Bool {
        guard count >= offset + 4 else {
            return false
        }
        
        let magicBE = try uint32BE(at: offset)
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
            return try containsEncryptedFatMachO(at: offset)
        }
        
        return try encryptedMachOSlice(at: offset)
    }
    
    private func containsEncryptedFatMachO(at offset: Int) throws -> Bool {
        let architectureCount = Int(try uint32BE(at: offset + 4))
        let fatHeaderSize = 8
        let architectureSize = 20
        
        for index in 0..<architectureCount {
            let architectureOffset = offset + fatHeaderSize + index * architectureSize
            guard architectureOffset + architectureSize <= count else {
                return false
            }
            
            let sliceOffset = Int(try uint32BE(at: architectureOffset + 8))
            if try encryptedMachOSlice(at: sliceOffset) {
                return true
            }
        }
        
        return false
    }
    
    private func encryptedMachOSlice(at offset: Int) throws -> Bool {
        let magic = try uint32LE(at: offset)
        let headerSize: Int
        let commandCountOffset: Int
        
        switch magic {
        case 0xFEED_FACE:
            headerSize = 28
            commandCountOffset = offset + 16
        case 0xFEED_FACF:
            headerSize = 32
            commandCountOffset = offset + 16
        default:
            return false
        }
        
        let commandCount = Int(try uint32LE(at: commandCountOffset))
        var commandOffset = offset + headerSize
        
        for _ in 0..<commandCount {
            guard commandOffset + 8 <= count else {
                return false
            }
            
            let command = try uint32LE(at: commandOffset)
            let commandSize = Int(try uint32LE(at: commandOffset + 4))
            
            guard commandSize >= 8, commandOffset + commandSize <= count else {
                return false
            }
            
            if command == 0x21 || command == 0x2C {
                let cryptID = try uint32LE(at: commandOffset + 16)
                return cryptID != 0
            }
            
            commandOffset += commandSize
        }
        
        return false
    }
    
    private func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw SideloadIPAExtractionError.invalidIPA
        }
        
        return withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        }
    }
    
    private func uint32BE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw SideloadIPAExtractionError.invalidIPA
        }
        
        return withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        }
    }
}
