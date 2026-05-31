import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SideloadView: View {
    @EnvironmentObject private var auth: AppleAuthService
    @EnvironmentObject private var downloads: AppDownloadService
    @EnvironmentObject private var signingAccounts: SideloadSigningAccountService
    @StateObject private var deviceDiscovery = SideloadDeviceDiscoveryService()
    @StateObject private var sideloadInstaller = SideloadInstallerService()
    
    @State private var selectedDeviceID: SideloadDevice.ID?
    @State private var selectedSigningAccountID: SideloadSigningAccount.ID?
    @State private var selectedIPA: SideloadIPAChoice?
    @State private var showingAccountChooser = false
    @State private var showingAddSigningAccount = false
    @State private var accountSearchText = ""
    @State private var showingIPAChooser = false
    @State private var ipaSearchText = ""
    @State private var notice: DownloadNotice?
    @State private var showingAdvancedOptions = false
    @State private var sideloadBundleIdentifier = ""
    @State private var isLoadingIPAMetadata = false
    
    private var selectedDevice: SideloadDevice? {
        deviceDiscovery.devices.first { $0.id == selectedDeviceID }
    }
    
    private var signingAccountChoices: [SideloadSigningAccount] {
        var choices: [SideloadSigningAccount] = []
        
        if auth.isSignedIn, !auth.appleID.isEmpty {
            choices.append(
                SideloadSigningAccount(
                    id: SideloadSigningAccountService.currentAppAccountID(for: auth.appleID),
                    email: auth.appleID,
                    source: .currentAppAccount
                )
            )
        }
        
        choices.append(contentsOf: signingAccounts.accounts)
        return choices
    }
    
    private var selectedSigningAccount: SideloadSigningAccount? {
        signingAccountChoices.first { $0.id == selectedSigningAccountID }
    }
    
    private var selectedSigningAccountStatus: SideloadSigningAccountStatus {
        guard let selectedSigningAccount else {
            return .idle
        }
        
        return signingAccounts.status(for: selectedSigningAccount)
    }
    
    private var canSideload: Bool {
        selectedDevice != nil
        && selectedSigningAccount != nil
        && selectedIPA?.fileURL != nil
        && !sideloadBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isLoadingIPAMetadata
        && !sideloadInstaller.isInstalling
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerView
                        
                        Divider()
                            .padding(.top, 22)
                        
                        VStack(alignment: .leading, spacing: 28) {
                            deviceSection
                            signingAccountSection
                            ipaSection
                            selectedAppSection
                            advancedOptionsSection
                        }
                        .padding(.top, 28)
                    }
                    .frame(maxWidth: 860, alignment: .topLeading)
                    .padding(.horizontal, 36)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                
                SideloadStatusBar(
                    statusText: sideloadInstaller.statusText,
                    progress: sideloadInstaller.progress,
                    canSideload: canSideload,
                    isInstalling: sideloadInstaller.isInstalling
                ) {
                    startSideload()
                }
            }
            .navigationTitle("Sideload")
            .toolbar {
                ToolbarItem {
                    Button {
                        deviceDiscovery.refresh()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(deviceDiscovery.isScanning)
                    .help("Refresh Devices")
                }
            }
        }
        .task {
            deviceDiscovery.start()
        }
        .onChange(of: deviceDiscovery.devices) { _, devices in
            reconcileSelectedDevice(with: devices)
        }
        .onChange(of: signingAccountChoices) { _, accounts in
            reconcileSelectedSigningAccount(with: accounts)
        }
        .onChange(of: auth.isSignedIn) { _, _ in
            reconcileSelectedSigningAccount(with: signingAccountChoices)
        }
        .onAppear {
            reconcileSelectedSigningAccount(with: signingAccountChoices)
        }
        .task(id: selectedSigningAccountID) {
            guard let selectedSigningAccount else {
                return
            }
            
            await signingAccounts.refreshStatus(
                for: selectedSigningAccount,
                passwordOverride: auth.signingPassword(for: selectedSigningAccount.email)
            )
        }
        .sheet(isPresented: $showingAddSigningAccount) {
            SigningAccountLoginSheet { email, password, summary in
                signingAccounts.save(email: email, password: password, summary: summary)
                selectedSigningAccountID = SideloadSigningAccountService.savedID(for: email)
                showingAddSigningAccount = false
            }
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 16) {
            Image(systemName: headerIconName)
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .frame(width: 56)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedDevice?.name ?? "Select a Device")
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                
                Text(selectedDevice?.detailText ?? headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
    
    private var headerSubtitle: String {
        if deviceDiscovery.isScanning {
            return "Looking for USB and Wi-Fi devices..."
        }
        
        return "Connect a device with USB, enable Wi-Fi sync, or choose Apple Silicon."
    }
    
    private var headerIconName: String {
        guard let selectedDevice else {
            return "iphone"
        }
        
        return selectedDevice.connectionKind == .appleSilicon ? "macbook" : "iphone.gen3"
    }
    
    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("Device:")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 92, alignment: .trailing)
                
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Device", selection: deviceSelection) {
                        if deviceDiscovery.devices.isEmpty {
                            Text(deviceDiscovery.isScanning ? "Scanning..." : "No Devices Found")
                                .tag(Optional<SideloadDevice.ID>.none)
                        }
                        
                        ForEach(deviceDiscovery.devices) { device in
                            Text("\(device.name) - \(device.detailText)")
                                .tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 360, alignment: .leading)
                    
                    Text(deviceHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
        }
    }
    
    private var ipaSection: some View {
        HStack(alignment: .top, spacing: 18) {
            Text("IPA:")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 92, alignment: .trailing)
                .padding(.top, 7)
            
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showingIPAChooser.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedIPA?.title ?? "Choose IPA")
                            .foregroundStyle(selectedIPA == nil ? .secondary : .primary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 360, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingIPAChooser, arrowEdge: .bottom) {
                    IPAChooserPopover(
                        searchText: $ipaSearchText,
                        downloadedApps: downloads.downloads,
                        onChooseDownloaded: { download in
                            setSelectedIPA(
                                SideloadIPAChoice(download: download, fileURL: downloads.ipaFileURL(for: download))
                            )
                            showingIPAChooser = false
                        },
                        onChooseCustom: {
                            showingIPAChooser = false
                            chooseCustomIPA()
                        }
                    )
                }
                
                Text("Choose from Downloads or select an IPA from your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
    
    private var signingAccountSection: some View {
        HStack(alignment: .top, spacing: 18) {
            Text("Account:")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 92, alignment: .trailing)
                .padding(.top, 7)
            
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showingAccountChooser.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedSigningAccount?.email ?? "Choose Apple Account")
                            .foregroundStyle(selectedSigningAccount == nil ? .secondary : .primary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 360, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingAccountChooser, arrowEdge: .bottom) {
                    SigningAccountChooserPopover(
                        searchText: $accountSearchText,
                        accounts: signingAccountChoices,
                        onChoose: { account in
                            selectedSigningAccountID = account.id
                            showingAccountChooser = false
                        },
                        onAdd: {
                            showingAccountChooser = false
                            showingAddSigningAccount = true
                        },
                        onDelete: { account in
                            signingAccounts.delete(account)
                            reconcileSelectedSigningAccount(with: signingAccountChoices)
                        }
                    )
                }
                
                Text(signingAccountHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                SigningAccountStatusLine(status: selectedSigningAccountStatus) {
                    guard let selectedSigningAccount else {
                        return
                    }
                    
                    Task {
                        await signingAccounts.refreshStatus(
                            for: selectedSigningAccount,
                            passwordOverride: auth.signingPassword(for: selectedSigningAccount.email)
                        )
                    }
                }
            }
            
            Spacer()
        }
    }
    
    private var selectedAppSection: some View {
        HStack(alignment: .top, spacing: 18) {
            Text("App:")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 92, alignment: .trailing)
                .padding(.top, 18)
            
            Group {
                if let selectedIPA {
                    SelectedIPAView(choice: selectedIPA, isLoadingMetadata: isLoadingIPAMetadata)
                } else {
                    EmptySelectedIPAView()
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            
            Spacer()
        }
    }
    
    private var advancedOptionsSection: some View {
        HStack(alignment: .top, spacing: 18) {
            Text("")
                .frame(width: 92)
            
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Advanced Options", isOn: $showingAdvancedOptions)
                    .toggleStyle(.checkbox)
                
                if showingAdvancedOptions {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bundle ID:")
                            .font(.system(size: 13, weight: .semibold))
                        
                        TextField("Bundle Identifier", text: $sideloadBundleIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 360)
                        
                        Text("Used for App ID registration and signing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
        }
    }
    
    private var deviceSelection: Binding<SideloadDevice.ID?> {
        Binding(
            get: { selectedDeviceID },
            set: { selectedDeviceID = $0 }
        )
    }
    
    private var deviceHelpText: String {
        if let errorMessage = deviceDiscovery.errorMessage {
            return errorMessage
        }
        
        if deviceDiscovery.isScanning {
            return "Scanning for devices available over USB and Wi-Fi."
        }
        
        if deviceDiscovery.devices.isEmpty {
            return "No iPhone, iPad, or Apple Silicon target is available yet. Unlock the device and trust this Mac if prompted."
        }
        
        if selectedDevice?.connectionKind == .appleSilicon {
            return "Apple Silicon is listed as a target, but local install is not wired yet."
        }
        
        return "The selected device will receive the signed app."
    }
    
    private func reconcileSelectedDevice(with devices: [SideloadDevice]) {
        if let selectedDeviceID, devices.contains(where: { $0.id == selectedDeviceID }) {
            return
        }
        
        selectedDeviceID = devices.first?.id
    }
    
    private func reconcileSelectedSigningAccount(with accounts: [SideloadSigningAccount]) {
        if let selectedSigningAccountID, accounts.contains(where: { $0.id == selectedSigningAccountID }) {
            return
        }
        
        selectedSigningAccountID = accounts.first?.id
    }
    
    private var signingAccountHelpText: String {
        if let selectedSigningAccount {
            switch selectedSigningAccount.source {
            case .currentAppAccount:
                if auth.signingPassword(for: selectedSigningAccount.email) != nil {
                    return "Uses the Apple account currently signed in to this app for signing."
                }
                
                return "Sign in again or add this Apple ID as a signing account so iPA Store can request signing assets."
            case .saved:
                return "Uses a saved signing account without changing the app sign-in."
            }
        }
        
        return "Select or add the Apple account used for signing."
    }
    
    private func chooseCustomIPA() {
        let panel = NSOpenPanel()
        panel.title = "Choose IPA"
        panel.message = "Choose an IPA to sideload."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        if let ipaType = UTType(filenameExtension: "ipa") {
            panel.allowedContentTypes = [ipaType]
        }
        
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        
        setSelectedIPA(SideloadIPAChoice(fileURL: url))
    }
    
    private func startSideload() {
        guard let selectedDevice,
              let selectedIPA,
              let selectedSigningAccount,
              let fileURL = selectedIPA.fileURL else {
            return
        }
        
        Task {
            do {
                let signingPassword = auth.signingPassword(for: selectedSigningAccount.email)
                ?? signingAccounts.password(for: selectedSigningAccount)
                
                try await sideloadInstaller.install(
                    ipaURL: fileURL,
                    appTitle: selectedIPA.title,
                    bundleIdentifier: sideloadBundleIdentifier,
                    signingEmail: selectedSigningAccount.email,
                    signingPassword: signingPassword,
                    preferredTeamID: selectedSigningAccountStatus.cachedSummary?.teamID,
                    to: selectedDevice
                )
            } catch {
                notice = DownloadNotice(title: "Sideload Failed", message: error.localizedDescription)
            }
        }
    }
    
    private func setSelectedIPA(_ choice: SideloadIPAChoice) {
        selectedIPA = choice
        sideloadBundleIdentifier = choice.bundleIdentifier ?? ""
        loadMetadata(for: choice)
    }
    
    private func loadMetadata(for choice: SideloadIPAChoice) {
        guard let fileURL = choice.fileURL else {
            return
        }
        
        isLoadingIPAMetadata = true
        
        Task {
            do {
                let metadata = try await Task.detached(priority: .userInitiated) {
                    try SideloadIPAExtractor.metadata(from: fileURL)
                }.value
                
                guard selectedIPA?.id == choice.id else {
                    return
                }
                
                selectedIPA = selectedIPA?.applying(metadata)
                sideloadBundleIdentifier = metadata.bundleIdentifier
                isLoadingIPAMetadata = false
            } catch {
                guard selectedIPA?.id == choice.id else {
                    return
                }
                
                if sideloadBundleIdentifier.isEmpty {
                    sideloadBundleIdentifier = choice.bundleIdentifier ?? ""
                }
                isLoadingIPAMetadata = false
            }
        }
    }
}

private struct SideloadIPAChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let sourceLabel: String
    let artworkURL: String?
    let localIconURL: URL?
    let fileURL: URL?
    let bundleIdentifier: String?
    
    init(download: DownloadedApp, fileURL: URL?) {
        id = "download-\(download.id)"
        title = download.app.trackName
        subtitle = download.app.version.map { "Version \($0)" } ?? download.ipaFilename
        sourceLabel = "Downloads"
        artworkURL = download.app.artworkUrl512
        localIconURL = nil
        self.fileURL = fileURL
        bundleIdentifier = download.app.bundleId
    }
    
    init(fileURL: URL) {
        id = "file-\(fileURL.path)"
        title = fileURL.deletingPathExtension().lastPathComponent
        subtitle = fileURL.lastPathComponent
        sourceLabel = "File"
        artworkURL = nil
        localIconURL = nil
        self.fileURL = fileURL
        bundleIdentifier = nil
    }
    
    private init(
        id: String,
        title: String,
        subtitle: String,
        sourceLabel: String,
        artworkURL: String?,
        localIconURL: URL?,
        fileURL: URL?,
        bundleIdentifier: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceLabel = sourceLabel
        self.artworkURL = artworkURL
        self.localIconURL = localIconURL
        self.fileURL = fileURL
        self.bundleIdentifier = bundleIdentifier
    }
    
    func applying(_ metadata: SideloadIPAMetadata) -> SideloadIPAChoice {
        let versionText: String
        if let version = metadata.version, !version.isEmpty {
            versionText = "Version \(version)"
        } else if let buildVersion = metadata.buildVersion, !buildVersion.isEmpty {
            versionText = "Build \(buildVersion)"
        } else {
            versionText = subtitle
        }
        
        return SideloadIPAChoice(
            id: id,
            title: metadata.displayName,
            subtitle: versionText,
            sourceLabel: sourceLabel,
            artworkURL: artworkURL,
            localIconURL: metadata.iconFileURL ?? localIconURL,
            fileURL: fileURL,
            bundleIdentifier: metadata.bundleIdentifier
        )
    }
}

private struct SigningAccountChooserPopover: View {
    @Binding var searchText: String
    
    let accounts: [SideloadSigningAccount]
    let onChoose: (SideloadSigningAccount) -> Void
    let onAdd: () -> Void
    let onDelete: (SideloadSigningAccount) -> Void
    
    private var filteredAccounts: [SideloadSigningAccount] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !query.isEmpty else {
            return accounts
        }
        
        return accounts.filter { account in
            account.email.localizedCaseInsensitiveContains(query)
            || account.subtitle.localizedCaseInsensitiveContains(query)
        }
    }
    
    var body: some View {
        accountList
        .frame(width: 380, height: 390)
    }
    
    private var accountList: some View {
        VStack(spacing: 10) {
            TextField("Search Apple accounts", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 2) {
                    Button {
                        onAdd()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 20))
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add Apple Account...")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                
                                Text("Save a separate account for signing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if filteredAccounts.isEmpty {
                        Text(accounts.isEmpty ? "No signing accounts yet." : "No matching accounts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 86)
                    } else {
                        Divider()
                            .padding(.vertical, 4)
                        
                        ForEach(filteredAccounts) { account in
                            SigningAccountRow(
                                account: account,
                                onChoose: { onChoose(account) },
                                onDelete: account.source == .saved ? { onDelete(account) } : nil
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct SigningAccountLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let onSave: (String, String, SideloadSigningTeamSummary) -> Void
    
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSigningIn = false
    
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !password.isEmpty
        && !isSigningIn
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                    .frame(width: 38)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Apple Account")
                        .font(.title3.weight(.semibold))
                    
                    Text("This account is only used for signing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 10) {
                TextField("Apple ID", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSigningIn)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSigningIn)
                    .onSubmit {
                        signIn()
                    }
            }
            
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isSigningIn)
                
                Button {
                    signIn()
                } label: {
                    HStack(spacing: 6) {
                        if isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                        }
                        
                        Text(isSigningIn ? "Signing In..." : "Sign In")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 420, height: 270)
    }
    
    private func signIn() {
        guard canSubmit else {
            return
        }
        
        isSigningIn = true
        errorMessage = nil
        
        let submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedPassword = password
        
        Task {
            do {
                let summary = try await SideloadDeveloperPortalClient()
                    .fetchSigningTeamSummary(email: submittedEmail, password: submittedPassword)
                onSave(submittedEmail, submittedPassword, summary)
                dismiss()
            } catch SideloadDeveloperPortalError.requiresTwoFactorAuthentication {
                errorMessage = "Two-factor verification is required before this account can be used for signing."
            } catch {
                errorMessage = error.localizedDescription
            }
            
            isSigningIn = false
        }
    }
}

private struct SigningAccountRow: View {
    let account: SideloadSigningAccount
    let onChoose: () -> Void
    let onDelete: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 8) {
            Button {
                onChoose()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: account.source == .currentAppAccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.system(size: 21))
                        .foregroundStyle(.blue)
                        .frame(width: 34, height: 34)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        
                        Text(account.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove Signing Account")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct SigningAccountStatusLine: View {
    let status: SideloadSigningAccountStatus
    let onRefresh: () -> Void
    
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
    
    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .idle:
                EmptyView()
            case .checking(let cached):
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                
                Text(cached.map { "Refreshing App IDs... \($0.availabilityText)" } ?? "Checking App IDs...")
                    .foregroundStyle(.secondary)
            case .ready(let summary):
                Image(systemName: summary.teamType == .free ? "person.crop.circle.badge.clock" : "checkmark.seal")
                    .foregroundStyle(summary.teamType == .free ? .orange : .green)
                
                Text(statusText(for: summary))
                    .foregroundStyle(.secondary)
                
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh App IDs")
            case .unavailable(let message):
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                
                Text(message)
                    .foregroundStyle(.secondary)
            case .failed(let message, let cached):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                
                Text(failedText(message: message, cached: cached))
                    .foregroundStyle(.secondary)
                
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Retry App ID Check")
            }
        }
        .font(.caption)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private func statusText(for summary: SideloadSigningTeamSummary) -> String {
        let teamText = "\(summary.teamName) - \(summary.teamType.displayName)"
        
        if summary.teamType == .free,
           let expirationDate = summary.nextExpirationDate {
            let expirationText = Self.relativeFormatter.localizedString(for: expirationDate, relativeTo: Date())
            return "\(teamText): \(summary.availabilityText). Next frees \(expirationText)."
        }
        
        return "\(teamText): \(summary.availabilityText)."
    }
    
    private func failedText(message: String, cached: SideloadSigningTeamSummary?) -> String {
        if let cached {
            return "\(message) Last known: \(cached.availabilityText)."
        }
        
        return "Could not check App IDs: \(message)"
    }
}

private struct IPAChooserPopover: View {
    @Binding var searchText: String
    let downloadedApps: [DownloadedApp]
    let onChooseDownloaded: (DownloadedApp) -> Void
    let onChooseCustom: () -> Void
    
    private var filteredDownloads: [DownloadedApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !query.isEmpty else {
            return downloadedApps
        }
        
        return downloadedApps.filter { download in
            download.app.trackName.localizedCaseInsensitiveContains(query)
            || download.app.artistName.localizedCaseInsensitiveContains(query)
        }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            TextField("Search downloaded apps", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 2) {
                    Button {
                        onChooseCustom()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 20))
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Choose IPA File...")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                
                                Text("Pick an IPA from your Mac")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if downloadedApps.isEmpty {
                        Text("Downloaded apps will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 76)
                    } else if filteredDownloads.isEmpty {
                        Text("No matching apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 76)
                    } else {
                        Divider()
                            .padding(.vertical, 4)
                        
                        ForEach(filteredDownloads) { download in
                            Button {
                                onChooseDownloaded(download)
                            } label: {
                                IPAChoiceRow(download: download)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 390)
    }
}

private struct IPAChoiceRow: View {
    let download: DownloadedApp
    
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: download.app.artworkUrl512)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.18))
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(download.app.trackName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                Text(download.app.version.map { "Version \($0)" } ?? download.ipaFilename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct SelectedIPAView: View {
    let choice: SideloadIPAChoice
    let isLoadingMetadata: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            SideloadIPAIcon(choice: choice)
                .frame(width: 64, height: 64)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.title)
                    .font(.headline)
                    .lineLimit(2)
                
                Text(choice.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                Text(choice.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if let bundleIdentifier = choice.bundleIdentifier {
                    Text(bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if isLoadingMetadata {
                    Text("Reading IPA...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct EmptySelectedIPAView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.dashed")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("No IPA Selected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Text("Choose a downloaded app or pick an IPA file.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct SideloadIPAIcon: View {
    let choice: SideloadIPAChoice
    
    var body: some View {
        Group {
            if let localIconURL = choice.localIconURL,
               let image = NSImage(contentsOf: localIconURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let artworkURL = choice.artworkURL, let url = URL(string: artworkURL) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    iconPlaceholder
                }
            } else {
                iconPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    private var iconPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.secondary.opacity(0.18))
            .overlay {
                Image(systemName: "app")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
    }
}

private struct SideloadStatusBar: View {
    let statusText: String
    let progress: Double
    let canSideload: Bool
    let isInstalling: Bool
    let onSideload: () -> Void
    
    private var clampedProgress: Double {
        max(0, min(1, progress))
    }
    
    private var progressText: String {
        "\(Int((clampedProgress * 100).rounded()))%"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        if isInstalling {
                            Text(progressText)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    ProgressView(value: clampedProgress, total: 1)
                        .progressViewStyle(.linear)
                }
                
                Button(isInstalling ? "Sideloading..." : "Sideload") {
                    onSideload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSideload)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
