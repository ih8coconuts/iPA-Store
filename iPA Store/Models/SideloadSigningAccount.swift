import Foundation

enum SideloadSigningAccountSource: Equatable, Hashable {
    case currentAppAccount
    case saved
}

struct SideloadSigningAccount: Identifiable, Equatable, Hashable {
    let id: String
    let email: String
    let source: SideloadSigningAccountSource
    
    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    var statusKey: String {
        normalizedEmail
    }
    
    var subtitle: String {
        switch source {
        case .currentAppAccount:
            return "Current App Account"
        case .saved:
            return "Saved Signing Account"
        }
    }
}
