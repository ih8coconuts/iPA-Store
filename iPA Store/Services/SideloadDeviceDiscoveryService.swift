import Foundation
import Combine
import Darwin

@MainActor
final class SideloadDeviceDiscoveryService: ObservableObject {
    @Published private(set) var devices: [SideloadDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?
    
    private let bridge = MobileDeviceBridge()
    private var didStart = false
    
    init() {
        bridge.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                self?.devices = devices
                self?.isScanning = false
            }
        }
        
        bridge.onError = { [weak self] message in
            Task { @MainActor in
                self?.errorMessage = message
                self?.isScanning = false
            }
        }
    }
    
    func start() {
        guard !didStart else {
            refresh()
            return
        }
        
        didStart = true
        refresh()
    }
    
    func refresh() {
        isScanning = true
        errorMessage = nil
        bridge.start()
        
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            isScanning = false
        }
    }
}

private final class MobileDeviceBridge {
    var onDevicesChanged: (([SideloadDevice]) -> Void)?
    var onError: ((String) -> Void)?
    
    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias DeviceNotificationCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias AMDeviceNotificationSubscribe = @convention(c) (DeviceNotificationCallback?, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias AMDeviceConnect = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceDisconnect = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceIsPaired = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceValidatePairing = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceStartSession = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceStopSession = @convention(c) (DeviceRef?) -> Int32
    private typealias AMDeviceCopyValue = @convention(c) (DeviceRef?, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias AMDeviceCopyDeviceIdentifier = @convention(c) (DeviceRef?) -> Unmanaged<CFString>?
    private typealias AMDeviceGetInterfaceType = @convention(c) (DeviceRef?) -> Int32
    private typealias USBMuxCopyDeviceArray = @convention(c) () -> Unmanaged<CFArray>?
    private typealias AMDeviceCreateFromProperties = @convention(c) (CFDictionary?) -> DeviceRef?
    
    private let queue = DispatchQueue(label: "com.ipastore.mobiledevice.discovery")
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var notificationHandle: UnsafeMutableRawPointer?
    private var devicesByID: [String: SideloadDevice] = [:]
    private var identifiersByPointer: [UInt: String] = [:]
    
    private var subscribe: AMDeviceNotificationSubscribe?
    private var connect: AMDeviceConnect?
    private var disconnect: AMDeviceDisconnect?
    private var isPaired: AMDeviceIsPaired?
    private var validatePairing: AMDeviceValidatePairing?
    private var startSession: AMDeviceStartSession?
    private var stopSession: AMDeviceStopSession?
    private var copyValue: AMDeviceCopyValue?
    private var copyDeviceIdentifier: AMDeviceCopyDeviceIdentifier?
    private var getInterfaceType: AMDeviceGetInterfaceType?
    private var copyMuxDeviceArray: USBMuxCopyDeviceArray?
    private var createDeviceFromProperties: AMDeviceCreateFromProperties?
    
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            
            guard self.loadFrameworkIfNeeded() else {
                self.devicesByID = self.localDeviceDictionary()
                self.publishDevices()
                self.onError?("Could not load Apple's device discovery framework.")
                return
            }
            
            guard self.notificationHandle == nil else {
                self.refreshSnapshot()
                return
            }
            
            var notification: UnsafeMutableRawPointer?
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = self.subscribe?(Self.deviceNotificationCallback, 0, 0, context, &notification) ?? -1
            
            guard result == 0 else {
                self.onError?("Could not start iPhone and iPad discovery. MobileDevice returned \(Self.hexStatus(result)).")
                return
            }
            
            self.notificationHandle = notification
            self.refreshSnapshot()
        }
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
        subscribe = loadSymbol("AMDeviceNotificationSubscribe", from: handle, as: AMDeviceNotificationSubscribe.self)
        connect = loadSymbol("AMDeviceConnect", from: handle, as: AMDeviceConnect.self)
        disconnect = loadSymbol("AMDeviceDisconnect", from: handle, as: AMDeviceDisconnect.self)
        isPaired = loadSymbol("AMDeviceIsPaired", from: handle, as: AMDeviceIsPaired.self)
        validatePairing = loadSymbol("AMDeviceValidatePairing", from: handle, as: AMDeviceValidatePairing.self)
        startSession = loadSymbol("AMDeviceStartSession", from: handle, as: AMDeviceStartSession.self)
        stopSession = loadSymbol("AMDeviceStopSession", from: handle, as: AMDeviceStopSession.self)
        copyValue = loadSymbol("AMDeviceCopyValue", from: handle, as: AMDeviceCopyValue.self)
        copyDeviceIdentifier = loadSymbol("AMDeviceCopyDeviceIdentifier", from: handle, as: AMDeviceCopyDeviceIdentifier.self)
        getInterfaceType = loadSymbol("AMDeviceGetInterfaceType", from: handle, as: AMDeviceGetInterfaceType.self)
        copyMuxDeviceArray = loadSymbol("USBMuxCopyDeviceArray", from: handle, as: USBMuxCopyDeviceArray.self)
        createDeviceFromProperties = loadSymbol("AMDeviceCreateFromProperties", from: handle, as: AMDeviceCreateFromProperties.self)
        
        return subscribe != nil && copyValue != nil
    }
    
    private func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }
        
        return unsafeBitCast(symbol, to: type)
    }
    
    private static func hexStatus(_ status: Int32) -> String {
        let value = UInt32(bitPattern: status)
        return "0x" + String(value, radix: 16, uppercase: false)
    }
    
    private static let deviceNotificationCallback: DeviceNotificationCallback = { info, context in
        guard let info, let context else { return }
        
        let bridge = Unmanaged<MobileDeviceBridge>.fromOpaque(context).takeUnretainedValue()
        let device = info.load(as: DeviceRef?.self)
        let message = info
            .advanced(by: MemoryLayout<DeviceRef?>.stride)
            .load(as: UInt32.self)
        
        bridge.queue.async {
            bridge.handleDeviceNotification(device: device, message: message)
        }
    }
    
    private func handleDeviceNotification(device: DeviceRef?, message: UInt32) {
        switch message {
        case 1, 2:
            refreshSnapshot()
            
            if let device {
                identifiersByPointer[UInt(bitPattern: device)] = nil
            }
        default:
            publishDevices()
        }
    }
    
    private func refreshSnapshot() {
        guard let muxDevices = copyMuxDeviceArray?()?.takeRetainedValue() as? [[String: Any]] else {
            publishDevices()
            return
        }
        
        var snapshotDevices = localDeviceDictionary()
        
        for muxDevice in muxDevices {
            guard let properties = muxDevice["Properties"] as? NSDictionary,
                  let device = createDeviceFromProperties?(properties) else {
                continue
            }
            
            let connectionKind = connectionKind(from: properties)
            let fallbackID = properties["SerialNumber"] as? String
                ?? properties["USBSerialNumber"] as? String
            let endpointID = endpointID(
                from: muxDevice,
                properties: properties,
                connectionKind: connectionKind
            )
            
            if let sideloadDevice = makeDevice(
                from: device,
                connectionKindOverride: connectionKind,
                fallbackID: fallbackID,
                endpointID: endpointID
            ) {
                snapshotDevices[sideloadDevice.id] = sideloadDevice
            }
        }
        
        devicesByID = snapshotDevices
        publishDevices()
    }
    
    private func makeDevice(
        from device: DeviceRef,
        connectionKindOverride: SideloadConnectionKind? = nil,
        fallbackID: String? = nil,
        endpointID: String? = nil
    ) -> SideloadDevice? {
        var didConnect = false
        if connect?(device) == 0 {
            didConnect = true
        }
        
        var didStartSession = false
        if isPaired?(device) == 1 {
            _ = validatePairing?(device)
            if startSession?(device) == 0 {
                didStartSession = true
            }
        }
        
        defer {
            if didStartSession {
                _ = stopSession?(device)
            }
            
            if didConnect {
                _ = disconnect?(device)
            }
        }
        
        let baseID = copyIdentifier(from: device)
            ?? copyString("UniqueDeviceID", from: device)
            ?? fallbackID
            ?? String(UInt(bitPattern: device))
        let id = [baseID, endpointID]
            .compactMap { $0 }
            .joined(separator: "-")
        let productName = copyString("ProductName", from: device)
        let deviceName = copyString("DeviceName", from: device) ?? productName ?? "iPhone"
        let systemVersion = copyString("ProductVersion", from: device) ?? "Unknown"
        let connectionKind = connectionKindOverride ?? connectionKind(for: device)
        
        return SideloadDevice(
            id: id,
            uniqueIdentifier: baseID,
            name: deviceName,
            systemVersion: systemVersion,
            connectionKind: connectionKind
        )
    }
    
    private func connectionKind(from properties: NSDictionary) -> SideloadConnectionKind {
        guard let connectionType = properties["ConnectionType"] as? String else {
            return .usb
        }
        
        return connectionType.localizedCaseInsensitiveContains("network") ? .wifi : .usb
    }
    
    private func connectionKind(for device: DeviceRef) -> SideloadConnectionKind {
        guard let interfaceType = getInterfaceType?(device) else {
            return .usb
        }
        
        return interfaceType == 2 ? .wifi : .usb
    }
    
    private func endpointID(
        from muxDevice: [String: Any],
        properties: NSDictionary,
        connectionKind: SideloadConnectionKind
    ) -> String {
        let deviceID = muxDevice["DeviceID"] ?? properties["DeviceID"] ?? properties["InterfaceIndex"]
        
        if let deviceID {
            return "\(connectionKind.rawValue)-\(deviceID)"
        }
        
        return connectionKind.rawValue
    }
    
    private func localDeviceDictionary() -> [String: SideloadDevice] {
        guard let localDevice = localAppleSiliconDevice() else {
            return [:]
        }
        
        return [localDevice.id: localDevice]
    }
    
    private func localAppleSiliconDevice() -> SideloadDevice? {
        guard Self.isAppleSiliconMac() else {
            return nil
        }
        
        return SideloadDevice(
            id: "apple-silicon-local",
            uniqueIdentifier: nil,
            name: "Apple Silicon",
            systemVersion: Self.macOSVersionString(),
            connectionKind: .appleSilicon
        )
    }
    
    private static func isAppleSiliconMac() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    
    private static func macOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private func copyIdentifier(from device: DeviceRef) -> String? {
        copyDeviceIdentifier?(device)?.takeRetainedValue() as String?
    }
    
    private func copyString(_ key: String, from device: DeviceRef) -> String? {
        guard let value = copyValue?(device, nil, key as CFString)?.takeRetainedValue() else {
            return nil
        }
        
        return value as? String
    }
    
    private func publishDevices() {
        let sortedDevices = devicesByID.values.sorted { lhs, rhs in
            if lhs.connectionKind == .appleSilicon && rhs.connectionKind != .appleSilicon {
                return false
            }
            
            if lhs.connectionKind != .appleSilicon && rhs.connectionKind == .appleSilicon {
                return true
            }
            
            let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            
            return connectionSortOrder(lhs.connectionKind) < connectionSortOrder(rhs.connectionKind)
        }
        
        onDevicesChanged?(sortedDevices)
    }
    
    private func connectionSortOrder(_ connectionKind: SideloadConnectionKind) -> Int {
        switch connectionKind {
        case .usb:
            return 0
        case .wifi:
            return 1
        case .appleSilicon:
            return 2
        }
    }
}
