import Foundation

enum SideloadSigningTeamType: String, Codable, Equatable, Hashable {
    case free
    case individual
    case organization
    case unknown
    
    var displayName: String {
        switch self {
        case .free:
            return "Personal Team"
        case .individual:
            return "Individual Team"
        case .organization:
            return "Organization Team"
        case .unknown:
            return "Developer Team"
        }
    }
}

struct SideloadSigningTeamSummary: Codable, Equatable, Hashable {
    static let personalAccountAppIDLimit = 10
    
    let teamID: String
    let teamName: String
    let teamType: SideloadSigningTeamType
    let registeredAppIDCount: Int
    let nextExpirationDate: Date?
    let checkedAt: Date
    
    var appIDLimit: Int? {
        switch teamType {
        case .free, .individual:
            return Self.personalAccountAppIDLimit
        case .organization, .unknown:
            return nil
        }
    }
    
    var remainingAppIDCount: Int? {
        guard let appIDLimit else {
            return nil
        }
        
        return max(appIDLimit - registeredAppIDCount, 0)
    }
    
    var availabilityText: String {
        if let appIDLimit, let remainingAppIDCount {
            let noun = remainingAppIDCount == 1 ? "App ID" : "App IDs"
            return "\(remainingAppIDCount) of \(appIDLimit) \(noun) left"
        }
        
        let noun = registeredAppIDCount == 1 ? "App ID" : "App IDs"
        return "\(registeredAppIDCount) registered \(noun)"
    }
}

enum SideloadSigningAccountStatus: Equatable {
    case idle
    case checking(cached: SideloadSigningTeamSummary?)
    case ready(SideloadSigningTeamSummary)
    case unavailable(String)
    case failed(String, cached: SideloadSigningTeamSummary?)
    
    var cachedSummary: SideloadSigningTeamSummary? {
        switch self {
        case .checking(let cached), .failed(_, let cached):
            return cached
        case .ready(let summary):
            return summary
        case .idle, .unavailable:
            return nil
        }
    }
}
