import Foundation
import Combine

@MainActor
final class SideloadSigningAccountService: ObservableObject {
    @Published private(set) var accounts: [SideloadSigningAccount] = []
    @Published private(set) var statuses: [String: SideloadSigningAccountStatus] = [:]
    
    private let keychain = KeychainHelper.shared
    private let defaults = UserDefaults.standard
    private let developerPortal = SideloadDeveloperPortalClient()
    private let accountsKey = "sideload.signing.accounts"
    private let summariesKey = "sideload.signing.account.teamSummaries"
    private let keychainPrefix = "sideload.signing.password."
    
    init() {
        loadAccounts()
        loadCachedStatuses()
    }
    
    func save(email: String, password: String, summary: SideloadSigningTeamSummary? = nil) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            return
        }
        
        keychain.save(password, for: passwordKey(for: normalizedEmail))
        
        var emails = storedEmails()
        emails.removeAll { $0.caseInsensitiveCompare(normalizedEmail) == .orderedSame }
        emails.insert(normalizedEmail, at: 0)
        defaults.set(emails, forKey: accountsKey)
        
        loadAccounts()
        
        if let summary {
            cache(summary, forKey: normalizedEmail.lowercased())
            statuses[normalizedEmail.lowercased()] = .ready(summary)
        }
    }
    
    func password(for account: SideloadSigningAccount) -> String? {
        password(forEmail: account.email)
    }
    
    func delete(_ account: SideloadSigningAccount) {
        guard account.source == .saved else {
            return
        }
        
        keychain.delete(for: passwordKey(for: account.email))
        
        let emails = storedEmails().filter {
            $0.caseInsensitiveCompare(account.email) != .orderedSame
        }
        defaults.set(emails, forKey: accountsKey)
        
        loadAccounts()
    }
    
    func status(for account: SideloadSigningAccount) -> SideloadSigningAccountStatus {
        statuses[account.statusKey] ?? .idle
    }
    
    func refreshStatus(for account: SideloadSigningAccount, passwordOverride: String? = nil) async {
        let key = account.statusKey
        let cached = cachedSummary(forKey: key)
        let resolvedPassword = passwordOverride ?? password(forEmail: account.email)
        
        guard let password = resolvedPassword, !password.isEmpty else {
            if let cached {
                statuses[key] = .ready(cached)
            } else if account.source == .currentAppAccount {
                statuses[key] = .unavailable("Sign in again or add this Apple ID as a signing account to check App IDs.")
            } else {
                statuses[key] = .unavailable("Enter this account's password to check App IDs.")
            }
            return
        }
        
        statuses[key] = .checking(cached: cached)
        
        do {
            let summary = try await developerPortal.fetchSigningTeamSummary(email: account.email, password: password)
            cache(summary, forKey: key)
            statuses[key] = .ready(summary)
        } catch SideloadDeveloperPortalError.requiresTwoFactorAuthentication {
            statuses[key] = .failed("Two-factor verification is required before App IDs can be checked.", cached: cached)
        } catch {
            statuses[key] = .failed(error.localizedDescription, cached: cached)
        }
    }
    
    private func loadAccounts() {
        accounts = storedEmails().map { email in
            SideloadSigningAccount(
                id: Self.savedID(for: email),
                email: email,
                source: .saved
            )
        }
    }
    
    private func storedEmails() -> [String] {
        defaults.stringArray(forKey: accountsKey) ?? []
    }
    
    private func password(forEmail email: String) -> String? {
        keychain.load(for: passwordKey(for: email))
    }
    
    private func loadCachedStatuses() {
        for (key, summary) in cachedSummaries() {
            statuses[key] = .ready(summary)
        }
    }
    
    private func cachedSummary(forKey key: String) -> SideloadSigningTeamSummary? {
        cachedSummaries()[key]
    }
    
    private func cache(_ summary: SideloadSigningTeamSummary, forKey key: String) {
        var summaries = cachedSummaries()
        summaries[key] = summary
        
        guard let data = try? JSONEncoder().encode(summaries) else {
            return
        }
        
        defaults.set(data, forKey: summariesKey)
    }
    
    private func cachedSummaries() -> [String: SideloadSigningTeamSummary] {
        guard let data = defaults.data(forKey: summariesKey),
              let summaries = try? JSONDecoder().decode([String: SideloadSigningTeamSummary].self, from: data) else {
            return [:]
        }
        
        return summaries
    }
    
    private func passwordKey(for email: String) -> String {
        keychainPrefix + email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    static func savedID(for email: String) -> String {
        "saved-\(email.lowercased())"
    }
    
    static func currentAppAccountID(for email: String) -> String {
        "current-\(email.lowercased())"
    }
}
