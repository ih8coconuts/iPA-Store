import AppKit
import Combine
import Foundation

struct DownloadNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct DownloadedApp: Codable, Identifiable {
    let app: AppResult
    let ipaFilename: String
    let downloadedAt: Date
    
    var id: Int { app.trackId }
}

struct ActiveDownload: Identifiable {
    let app: AppResult
    var progress: Double
    
    var id: Int { app.trackId }
}

@MainActor
final class AppDownloadService: ObservableObject {
    @Published private(set) var downloads: [DownloadedApp] = []
    @Published private(set) var activeDownloads: [ActiveDownload] = []
    @Published var notice: DownloadNotice?

    private let client = AppStoreClient()
    private let fileManager = FileManager.default
    
    init() {
        loadDownloads()
    }

    var activeDownloadCount: Int {
        activeDownloads.count
    }

    func isDownloading(_ app: AppResult) -> Bool {
        activeDownload(for: app) != nil
    }

    func activeDownload(for app: AppResult) -> ActiveDownload? {
        activeDownloads.first { $0.app.trackId == app.trackId }
    }

    func downloadedApp(for app: AppResult) -> DownloadedApp? {
        downloads.first { $0.app.trackId == app.trackId }
    }
    
    func ipaFileURL(for download: DownloadedApp) -> URL? {
        try? fileURL(for: download)
    }
    
    func downloadToLibrary(app: AppResult, auth: AppleAuthService) async {
        guard auth.isSignedIn else {
            notice = DownloadNotice(title: "Sign In Required", message: "Sign in with your Apple ID before downloading \(app.trackName).")
            return
        }

        if downloadedApp(for: app) != nil {
            notice = DownloadNotice(title: "Already Downloaded", message: "\(app.trackName) is already in Downloads.")
            return
        }

        if activeDownload(for: app) != nil {
            notice = DownloadNotice(title: "Already Downloading", message: "\(app.trackName) is already downloading.")
            return
        }

        addActiveDownload(app)
        defer { removeActiveDownload(appID: app.trackId) }
        
        do {
            let folder = try downloadsDirectory()
            let account = try await auth.appStoreAccount(forceRefresh: false)
            let destination = try await download(
                app: app,
                account: account,
                auth: auth,
                folder: folder
            ) { [weak self] progress in
                self?.updateActiveDownload(appID: app.trackId, progress: progress)
            }
            let item = DownloadedApp(app: app, ipaFilename: destination.lastPathComponent, downloadedAt: Date())
            
            downloads.removeAll { $0.app.trackId == app.trackId }
            downloads.insert(item, at: 0)
            try saveDownloads()
        } catch {
            notice = DownloadNotice(title: "Download Failed", message: error.localizedDescription)
        }
    }
    
    func export(app: AppResult) {
        guard let download = downloadedApp(for: app) else {
            notice = DownloadNotice(title: "Not Downloaded", message: "\(app.trackName) is not in Downloads yet.")
            return
        }
        
        export(download)
    }
    
    func export(_ download: DownloadedApp) {
        guard let folder = chooseExportFolder(for: download) else {
            return
        }
        
        let didAccessFolder = folder.startAccessingSecurityScopedResource()
        defer {
            if didAccessFolder {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let source = try fileURL(for: download)
            guard fileManager.fileExists(atPath: source.path) else {
                removeMissingDownload(download)
                notice = DownloadNotice(title: "File Missing", message: "\(download.app.trackName) was removed from Downloads because its IPA file is missing.")
                return
            }
            
            let destination = availableDestinationURL(in: folder, suggestedFilename: source.lastPathComponent)
            try fileManager.copyItem(at: source, to: destination)
            notice = DownloadNotice(title: "Export Complete", message: "\(download.app.trackName) was copied to \(destination.path).")
        } catch {
            notice = DownloadNotice(title: "Export Failed", message: error.localizedDescription)
        }
    }
    
    func delete(_ download: DownloadedApp) {
        do {
            let source = try fileURL(for: download)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.removeItem(at: source)
            }
            
            downloads.removeAll { $0.id == download.id }
            try saveDownloads()
            notice = DownloadNotice(title: "Deleted", message: "\(download.app.trackName) was removed from Downloads.")
        } catch {
            notice = DownloadNotice(title: "Delete Failed", message: error.localizedDescription)
        }
    }
    
    func showDownloadsFolderInFinder() {
        do {
            let folder = try downloadsDirectory()
            NSWorkspace.shared.open(folder)
        } catch {
            notice = DownloadNotice(title: "Could Not Open Finder", message: error.localizedDescription)
        }
    }

    private func download(
        app: AppResult,
        account: AppStoreAccount,
        auth: AppleAuthService,
        folder: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        do {
            return try await client.download(app: app, account: account, to: folder, progress: progress)
        } catch AppStoreClientError.appStoreSessionExpired {
            auth.clearAppStoreAccount()
            let refreshedAccount = try await auth.appStoreAccount(forceRefresh: true)
            return try await client.download(app: app, account: refreshedAccount, to: folder, progress: progress)
        }
    }

    private func chooseExportFolder(for download: DownloadedApp) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.message = "Choose where to export \(download.app.trackName)."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        return panel.runModal() == .OK ? panel.url : nil
    }
    
    private func loadDownloads() {
        do {
            let url = try metadataURL()
            guard fileManager.fileExists(atPath: url.path) else {
                downloads = []
                return
            }
            
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([DownloadedApp].self, from: data)
            downloads = decoded.filter { download in
                guard let fileURL = try? fileURL(for: download) else { return false }
                return fileManager.fileExists(atPath: fileURL.path)
            }
            
            if decoded.count != downloads.count {
                try saveDownloads()
            }
        } catch {
            downloads = []
        }
    }
    
    private func saveDownloads() throws {
        let url = try metadataURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(downloads)
        try data.write(to: url, options: [.atomic])
    }
    
    private func removeMissingDownload(_ download: DownloadedApp) {
        downloads.removeAll { $0.id == download.id }
        try? saveDownloads()
    }
    
    private func addActiveDownload(_ app: AppResult) {
        activeDownloads.removeAll { $0.app.trackId == app.trackId }
        activeDownloads.insert(ActiveDownload(app: app, progress: 0), at: 0)
    }
    
    private func updateActiveDownload(appID: Int, progress: Double) {
        guard let index = activeDownloads.firstIndex(where: { $0.app.trackId == appID }) else {
            return
        }
        
        activeDownloads[index].progress = min(max(progress, 0), 1)
    }
    
    private func removeActiveDownload(appID: Int) {
        activeDownloads.removeAll { $0.app.trackId == appID }
    }
    
    private func fileURL(for download: DownloadedApp) throws -> URL {
        try downloadsDirectory().appendingPathComponent(download.ipaFilename)
    }
    
    private func metadataURL() throws -> URL {
        try libraryDirectory().appendingPathComponent("downloads.json")
    }
    
    private func downloadsDirectory() throws -> URL {
        let directory = try libraryDirectory().appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private func libraryDirectory() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("iPA Store", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private func availableDestinationURL(in folder: URL, suggestedFilename: String) -> URL {
        let baseURL = folder.appendingPathComponent(suggestedFilename)
        let pathExtension = baseURL.pathExtension
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        var candidate = baseURL
        
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let filename = pathExtension.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(pathExtension)"
            candidate = folder.appendingPathComponent(filename)
            suffix += 1
        }
        
        return candidate
    }
}
