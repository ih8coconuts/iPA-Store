import Darwin
import Combine
import Foundation

enum SideloadInstallError: LocalizedError {
    case unsupportedTarget
    case missingDeviceIdentifier
    case missingIPAFile
    case missingBundleIdentifier
    case mobileDeviceUnavailable
    case deviceNotFound(String)
    case deviceNotTrusted(String)
    case mobileDeviceOperationFailed(operation: String, status: Int32)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            return "Apple Silicon local installs are not wired yet. Choose an iPhone or iPad for this first sideload path."
        case .missingDeviceIdentifier:
            return "The selected device is missing its UDID."
        case .missingIPAFile:
            return "The selected IPA file could not be found."
        case .missingBundleIdentifier:
            return "The bundle identifier is missing."
        case .mobileDeviceUnavailable:
            return "Apple's MobileDevice framework could not be loaded."
        case .deviceNotFound(let udid):
            return "Could not find the selected device (\(udid)). Unlock it and trust this Mac."
        case .deviceNotTrusted(let udid):
            return "The selected device (\(udid)) is not trusted or pairing validation failed."
        case .mobileDeviceOperationFailed(let operation, let status):
            return "\(operation) failed with MobileDevice status \(Self.hexStatus(status)). \(Self.hint(for: status))"
        }
    }
    
    private static func hexStatus(_ status: Int32) -> String {
        let value = UInt32(bitPattern: status)
        return "0x" + String(value, radix: 16, uppercase: false)
    }
    
    private static func hint(for status: Int32) -> String {
        switch UInt32(bitPattern: status) {
        case 0xe8008015:
            return "The app usually needs a matching provisioning profile."
        case 0xe8008017:
            return "The app's code signature does not match its contents."
        case 0xe8008018:
            return "The signing certificate is invalid, expired, or not trusted."
        case 0xe8008020:
            return "The app appears to be encrypted or not signed for developer installation."
        default:
            return "The IPA may need to be re-signed before it can be installed."
        }
    }
}

@MainActor
final class SideloadInstallerService: ObservableObject {
    @Published private(set) var isInstalling = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "Ready"
    
    func install(
        ipaURL: URL,
        appTitle: String,
        bundleIdentifier: String,
        signingEmail: String?,
        signingPassword: String?,
        preferredTeamID: String?,
        to device: SideloadDevice
    ) async throws {
        guard !isInstalling else {
            return
        }
        
        guard device.connectionKind != .appleSilicon else {
            throw SideloadInstallError.unsupportedTarget
        }
        
        guard let udid = device.uniqueIdentifier, !udid.isEmpty else {
            throw SideloadInstallError.missingDeviceIdentifier
        }
        
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw SideloadInstallError.missingIPAFile
        }
        
        let normalizedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBundleIdentifier.isEmpty else {
            throw SideloadInstallError.missingBundleIdentifier
        }
        
        isInstalling = true
        progress = 0.06
        statusText = "Reading app bundles..."
        
        do {
            guard let signingEmail,
                  let signingPassword,
                  !signingEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !signingPassword.isEmpty else {
                throw SideloadDeveloperPortalError.missingSigningCredentials
            }
            
            let developerPortal = SideloadDeveloperPortalClient()
            let signingTargets = try await Task.detached(priority: .userInitiated) {
                try SideloadAppSigner.signingTargets(
                    ipaURL: ipaURL,
                    mainBundleIdentifier: normalizedBundleIdentifier
                )
            }.value
            
            progress = 0.12
            statusText = signingTargets.count == 1 ? "Fetching signing profile..." : "Fetching signing profiles..."
            
            var remoteProfiles = try await developerPortal
                .fetchDevelopmentProvisioningProfiles(
                    email: signingEmail,
                    password: signingPassword,
                    targets: signingTargets,
                    device: device,
                    preferredTeamID: preferredTeamID
                )
            
            progress = 0.28
            statusText = "Signing \(appTitle)..."
            
            let signedApp: SideloadSignedApp
            do {
                signedApp = try await sign(
                    ipaURL: ipaURL,
                    bundleIdentifier: normalizedBundleIdentifier,
                    deviceIdentifier: udid,
                    signingTargets: signingTargets,
                    profiles: remoteProfiles
                )
            } catch SideloadSigningError.missingSigningIdentity {
                progress = 0.34
                statusText = "Creating signing certificate..."
                
                try await developerPortal.createDevelopmentCertificate(
                    email: signingEmail,
                    password: signingPassword,
                    preferredTeamID: remoteProfiles.values.first?.teamID ?? preferredTeamID,
                    machineName: "iPA Store \(ProcessInfo.processInfo.hostName)"
                )
                
                progress = 0.44
                statusText = signingTargets.count == 1 ? "Refreshing signing profile..." : "Refreshing signing profiles..."
                
                remoteProfiles = try await developerPortal.fetchDevelopmentProvisioningProfiles(
                    email: signingEmail,
                    password: signingPassword,
                    targets: signingTargets,
                    device: device,
                    preferredTeamID: remoteProfiles.values.first?.teamID ?? preferredTeamID
                )
                
                progress = 0.50
                statusText = "Signing \(appTitle)..."
                
                signedApp = try await sign(
                    ipaURL: ipaURL,
                    bundleIdentifier: normalizedBundleIdentifier,
                    deviceIdentifier: udid,
                    signingTargets: signingTargets,
                    profiles: remoteProfiles
                )
            }
            
            defer {
                signedApp.extractedApp.cleanUp()
            }
            
            progress = 0.56
            statusText = "Sending signed \(appTitle) to \(device.name)..."
            
            let progressReporter = SideloadInstallProgressReporter(
                service: self,
                appTitle: appTitle,
                deviceName: device.name,
                startProgress: 0.56,
                progressSpan: 0.42
            )
            let updateInstallProgress: @Sendable (Double) -> Void = { fraction in
                progressReporter.update(fraction)
            }
            
            try await Task.detached(priority: .userInitiated) {
                try MobileDeviceAppInstaller().installAppBundle(
                    at: signedApp.extractedApp.appBundleURL,
                    toUDID: udid,
                    connectionKind: device.connectionKind,
                    progressHandler: updateInstallProgress
                )
            }.value
            
            progress = 1
            statusText = "Sideloaded \(appTitle)"
            isInstalling = false
        } catch {
            progress = 0
            statusText = "Sideload failed"
            isInstalling = false
            throw error
        }
    }
    
    private func sign(
        ipaURL: URL,
        bundleIdentifier: String,
        deviceIdentifier: String,
        signingTargets: [SideloadSigningTarget],
        profiles: [String: SideloadRemoteProvisioningProfile]
    ) async throws -> SideloadSignedApp {
        let profileDataByBundleIdentifier = profiles.mapValues { $0.data }
        let teamID = profiles.values.first?.teamID
        
        return try await Task.detached(priority: .userInitiated) {
            try SideloadAppSigner.prepareSignedApp(
                ipaURL: ipaURL,
                bundleIdentifier: bundleIdentifier,
                deviceIdentifier: deviceIdentifier,
                preferredTeamID: teamID,
                signingTargets: signingTargets,
                remoteProvisioningProfiles: profileDataByBundleIdentifier
            )
        }.value
    }
    
    fileprivate func updateInstallProgress(
        appTitle: String,
        deviceName: String,
        startProgress: Double,
        progressSpan: Double,
        fraction: Double
    ) {
        guard isInstalling else {
            return
        }
        
        let clampedFraction = max(0, min(1, fraction))
        progress = max(progress, startProgress + clampedFraction * progressSpan)
        statusText = "Installing \(appTitle) on \(deviceName)..."
    }
}

nonisolated private final class SideloadInstallProgressReporter: @unchecked Sendable {
    weak var service: SideloadInstallerService?
    let appTitle: String
    let deviceName: String
    let startProgress: Double
    let progressSpan: Double
    
    init(
        service: SideloadInstallerService,
        appTitle: String,
        deviceName: String,
        startProgress: Double,
        progressSpan: Double
    ) {
        self.service = service
        self.appTitle = appTitle
        self.deviceName = deviceName
        self.startProgress = startProgress
        self.progressSpan = progressSpan
    }
    
    func update(_ fraction: Double) {
        Task { @MainActor in
            guard let service, service.isInstalling else {
                return
            }
            
            service.updateInstallProgress(
                appTitle: appTitle,
                deviceName: deviceName,
                startProgress: startProgress,
                progressSpan: progressSpan,
                fraction: fraction
            )
        }
    }
}

nonisolated private final class MobileDeviceAppInstaller {
    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias ProgressCallback = @convention(c) (CFDictionary?, UnsafeMutableRawPointer?) -> Void
    private typealias AMDeviceConnect = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceDisconnect = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceIsPaired = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceValidatePairing = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceStartSession = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceStopSession = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceCopyDeviceIdentifier = @convention(c) (DeviceRef?) -> Unmanaged<CFString>?
    private typealias USBMuxCopyDeviceArray = @convention(c) () -> Unmanaged<CFArray>?
    private typealias AMDeviceCreateFromProperties = @convention(c) (CFDictionary?) -> DeviceRef?
    private typealias AMDeviceSecureTransferPath = @convention(c) (Int32, DeviceRef?, CFURL, CFDictionary, ProgressCallback?, UnsafeMutableRawPointer?) -> Int32
    private typealias AMDeviceSecureInstallApplication = @convention(c) (Int32, DeviceRef?, CFURL, CFDictionary, ProgressCallback?, UnsafeMutableRawPointer?) -> Int32
    
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var connect: AMDeviceConnect?
    private var disconnect: AMDeviceDisconnect?
    private var isPaired: AMDeviceIsPaired?
    private var validatePairing: AMDeviceValidatePairing?
    private var startSession: AMDeviceStartSession?
    private var stopSession: AMDeviceStopSession?
    private var copyDeviceIdentifier: AMDeviceCopyDeviceIdentifier?
    private var copyMuxDeviceArray: USBMuxCopyDeviceArray?
    private var createDeviceFromProperties: AMDeviceCreateFromProperties?
    private var secureTransferPath: AMDeviceSecureTransferPath?
    private var secureInstallApplication: AMDeviceSecureInstallApplication?
    
    func installAppBundle(
        at appBundleURL: URL,
        toUDID udid: String,
        connectionKind: SideloadConnectionKind,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) throws {
        guard loadFrameworkIfNeeded() else {
            throw SideloadInstallError.mobileDeviceUnavailable
        }
        
        guard let device = findDevice(udid: udid, connectionKind: connectionKind) ?? findDevice(udid: udid, connectionKind: nil) else {
            throw SideloadInstallError.deviceNotFound(udid)
        }
        
        try connectTrustedSession(device: device, udid: udid)
        defer {
            _ = stopSession?(device)
            _ = disconnect?(device)
        }
        
        let options = ["PackageType": "Developer"] as NSDictionary
        progressHandler(0)
        
        let transferContext = MobileDeviceProgressContext { fraction in
            progressHandler(fraction * 0.45)
        }
        let transferStatus = withExtendedLifetime(transferContext) {
            secureTransferPath?(
                0,
                device,
                appBundleURL as CFURL,
                options,
                Self.progressCallback,
                Unmanaged.passUnretained(transferContext).toOpaque()
            ) ?? -1
        }
        
        guard transferStatus == 0 else {
            throw SideloadInstallError.mobileDeviceOperationFailed(
                operation: "Transfer",
                status: transferStatus
            )
        }
        
        progressHandler(0.45)
        
        let installContext = MobileDeviceProgressContext { fraction in
            progressHandler(0.45 + fraction * 0.55)
        }
        let installStatus = withExtendedLifetime(installContext) {
            secureInstallApplication?(
                0,
                device,
                appBundleURL as CFURL,
                options,
                Self.progressCallback,
                Unmanaged.passUnretained(installContext).toOpaque()
            ) ?? -1
        }
        
        guard installStatus == 0 else {
            throw SideloadInstallError.mobileDeviceOperationFailed(
                operation: "Install",
                status: installStatus
            )
        }
        
        progressHandler(1)
    }
    
    private func loadFrameworkIfNeeded() -> Bool {
        if frameworkHandle != nil {
            return true
        }
        
        let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        guard let handle = dlopen(path, RTLD_NOW) else {
            return false
        }
        
        frameworkHandle = handle
        connect = loadSymbol("AMDeviceConnect", from: handle, as: AMDeviceConnect.self)
        disconnect = loadSymbol("AMDeviceDisconnect", from: handle, as: AMDeviceDisconnect.self)
        isPaired = loadSymbol("AMDeviceIsPaired", from: handle, as: AMDeviceIsPaired.self)
        validatePairing = loadSymbol("AMDeviceValidatePairing", from: handle, as: AMDeviceValidatePairing.self)
        startSession = loadSymbol("AMDeviceStartSession", from: handle, as: AMDeviceStartSession.self)
        stopSession = loadSymbol("AMDeviceStopSession", from: handle, as: AMDeviceStopSession.self)
        copyDeviceIdentifier = loadSymbol("AMDeviceCopyDeviceIdentifier", from: handle, as: AMDeviceCopyDeviceIdentifier.self)
        copyMuxDeviceArray = loadSymbol("USBMuxCopyDeviceArray", from: handle, as: USBMuxCopyDeviceArray.self)
        createDeviceFromProperties = loadSymbol("AMDeviceCreateFromProperties", from: handle, as: AMDeviceCreateFromProperties.self)
        secureTransferPath = loadSymbol("AMDeviceSecureTransferPath", from: handle, as: AMDeviceSecureTransferPath.self)
        secureInstallApplication = loadSymbol("AMDeviceSecureInstallApplication", from: handle, as: AMDeviceSecureInstallApplication.self)
        
        return connect != nil
        && disconnect != nil
        && isPaired != nil
        && validatePairing != nil
        && startSession != nil
        && stopSession != nil
        && copyDeviceIdentifier != nil
        && copyMuxDeviceArray != nil
        && createDeviceFromProperties != nil
        && secureTransferPath != nil
        && secureInstallApplication != nil
    }
    
    private func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }
        
        return unsafeBitCast(symbol, to: type)
    }
    
    private func findDevice(udid: String, connectionKind: SideloadConnectionKind?) -> DeviceRef? {
        guard let muxDevices = copyMuxDeviceArray?()?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        
        for muxDevice in muxDevices {
            guard let properties = muxDevice["Properties"] as? NSDictionary,
                  let device = createDeviceFromProperties?(properties) else {
                continue
            }
            
            let identifier = copyIdentifier(from: device)
            ?? properties["SerialNumber"] as? String
            ?? properties["USBSerialNumber"] as? String
            
            let matchesConnection: Bool
            if let connectionKind {
                matchesConnection = self.connectionKind(from: properties) == connectionKind
            } else {
                matchesConnection = true
            }
            
            if identifier == udid, matchesConnection {
                return device
            }
        }
        
        return nil
    }
    
    private func connectionKind(from properties: NSDictionary) -> SideloadConnectionKind {
        guard let connectionType = properties["ConnectionType"] as? String else {
            return .usb
        }
        
        return connectionType.localizedCaseInsensitiveContains("network") ? .wifi : .usb
    }
    
    private func copyIdentifier(from device: DeviceRef) -> String? {
        copyDeviceIdentifier?(device)?.takeRetainedValue() as String?
    }
    
    private func connectTrustedSession(device: DeviceRef, udid: String) throws {
        guard connect?(device) == 0,
              isPaired?(device) == 1,
              validatePairing?(device) == 0,
              startSession?(device) == 0 else {
            throw SideloadInstallError.deviceNotTrusted(udid)
        }
    }
    
    private static let progressCallback: ProgressCallback = { status, context in
        guard let context,
              let fraction = MobileDeviceAppInstaller.progressFraction(from: status) else {
            return
        }
        
        let progressContext = Unmanaged<MobileDeviceProgressContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        progressContext.update(fraction)
    }
    
    private static func progressFraction(from status: CFDictionary?) -> Double? {
        guard let dictionary = status as NSDictionary? else {
            return nil
        }
        
        for key in ["PercentComplete", "OverallProgress", "Progress", "Percent"] {
            if let fraction = normalizedProgressValue(dictionary[key]) {
                return fraction
            }
        }
        
        return nil
    }
    
    private static func normalizedProgressValue(_ value: Any?) -> Double? {
        let rawValue: Double?
        
        if let number = value as? NSNumber {
            rawValue = number.doubleValue
        } else if let string = value as? String {
            rawValue = Double(string)
        } else {
            rawValue = nil
        }
        
        guard let rawValue else {
            return nil
        }
        
        let fraction = rawValue > 1 ? rawValue / 100 : rawValue
        return max(0, min(1, fraction))
    }
}

nonisolated private final class MobileDeviceProgressContext {
    private let handler: @Sendable (Double) -> Void
    
    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }
    
    func update(_ fraction: Double) {
        handler(fraction)
    }
}
