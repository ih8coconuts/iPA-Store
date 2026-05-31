import Foundation

enum SideloadConnectionKind: String, Equatable, Hashable, Sendable {
    case usb = "USB"
    case wifi = "Wi-Fi"
    case appleSilicon = "This Mac"
}

struct SideloadDevice: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let uniqueIdentifier: String?
    let name: String
    let systemVersion: String
    let connectionKind: SideloadConnectionKind
    
    var detailText: String {
        switch connectionKind {
        case .appleSilicon:
            return "macOS \(systemVersion) - \(connectionKind.rawValue)"
        case .usb, .wifi:
            return "iOS \(systemVersion) - \(connectionKind.rawValue)"
        }
    }
}
