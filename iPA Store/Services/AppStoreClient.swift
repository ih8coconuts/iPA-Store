import Foundation

struct AppStoreAccount {
    let email: String
    let passwordToken: String
    let directoryServicesID: String
    let storeFront: String
    let pod: String?
}

enum AppStoreClientError: LocalizedError {
    case authCodeRequired
    case appStoreAccountUnavailable
    case appStoreSessionExpired
    case licenseRequired
    case paidAppsNotSupported
    case invalidResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .authCodeRequired:
            return "Apple needs a verification code before downloads can be prepared. Sign in again and enter the code Apple sends you."
        case .appStoreAccountUnavailable:
            return "Download credentials are not ready. Open Profile, sign in again, then try the download."
        case .appStoreSessionExpired:
            return "The App Store download session expired. Open Profile, sign in again, then try the download."
        case .licenseRequired:
            return "This app needs an App Store license before it can be downloaded."
        case .paidAppsNotSupported:
            return "Paid app purchases are not supported here yet."
        case .invalidResponse(let message), .requestFailed(let message):
            return message
        }
    }
}

final class AppStoreClient {
    private let redirectDelegate = RedirectBlockingDelegate()
    private lazy var apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = .shared
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()

    private let keychain = KeychainHelper.shared
    private let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    func login(email: String, password: String, authCode: String?) async throws -> AppStoreAccount {
        let guid = deviceGUID()
        let endpoint = try await authenticationEndpoint(guid: guid)
        return try await login(email: email, password: password, authCode: authCode, guid: guid, endpoint: endpoint)
    }

    func download(
        app: AppResult,
        account: AppStoreAccount,
        to folder: URL,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        let guid = deviceGUID()

        do {
            return try await downloadPackage(app: app, account: account, guid: guid, to: folder, progress: progress)
        } catch AppStoreClientError.licenseRequired {
            try await purchaseFreeApp(app: app, account: account, guid: guid)
            return try await downloadPackage(app: app, account: account, guid: guid, to: folder, progress: progress)
        }
    }

    private func authenticationEndpoint(guid: String) async throws -> String {
        let url = URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(guid)")!
        let response = try await sendRequest(url: url, method: "GET", headers: ["Accept": "application/xml"], plist: nil)

        guard response.statusCode == 200 else {
            throw AppStoreClientError.requestFailed("Could not prepare App Store downloads (HTTP \(response.statusCode)).")
        }

        guard let urlBag = response.dictionary?["urlBag"] as? [String: Any],
              let endpoint = stringValue(urlBag["authenticateAccount"]),
              !endpoint.isEmpty else {
            throw AppStoreClientError.invalidResponse("Apple did not return a download authentication endpoint.")
        }

        return endpoint
    }

    private func login(
        email: String,
        password: String,
        authCode: String?,
        guid: String,
        endpoint: String
    ) async throws -> AppStoreAccount {
        var requestURL = endpoint
        let cleanCode = authCode?.replacingOccurrences(of: " ", with: "") ?? ""
        var lastResponse: PlistResponse?

        for attempt in 1...4 {
            let payload: [String: Any] = [
                "appleId": email,
                "attempt": String(attempt),
                "guid": guid,
                "password": password + cleanCode,
                "rmp": "0",
                "why": "signIn"
            ]

            let response = try await sendRequest(
                url: URL(string: requestURL)!,
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                plist: payload
            )
            lastResponse = response

            if response.statusCode == 302,
               let location = response.header("Location"),
               !location.isEmpty {
                requestURL = location
                continue
            }

            let dictionary = response.dictionary ?? [:]
            let failureType = stringValue(dictionary["failureType"]) ?? ""
            let customerMessage = stringValue(dictionary["customerMessage"]) ?? ""

            if attempt == 1 && failureType == "-5000" {
                continue
            }

            if failureType.isEmpty && cleanCode.isEmpty && customerMessage == "MZFinance.BadLogin.Configurator_message" {
                throw AppStoreClientError.authCodeRequired
            }

            if !failureType.isEmpty {
                throw AppStoreClientError.requestFailed(customerMessage.isEmpty ? "App Store sign-in failed (\(failureType))." : customerMessage)
            }

            guard response.statusCode == 200 else {
                throw AppStoreClientError.requestFailed("App Store sign-in failed (HTTP \(response.statusCode)).")
            }

            guard let passwordToken = stringValue(dictionary["passwordToken"]),
                  let dsid = stringValue(dictionary["dsPersonId"]),
                  !passwordToken.isEmpty,
                  !dsid.isEmpty else {
                throw AppStoreClientError.invalidResponse("Apple did not return download credentials.")
            }

            guard let storeFront = response.header("X-Set-Apple-Store-Front"), !storeFront.isEmpty else {
                throw AppStoreClientError.invalidResponse("Apple did not return an App Store storefront.")
            }

            let accountInfo = dictionary["accountInfo"] as? [String: Any]
            let resolvedEmail = stringValue(accountInfo?["appleId"]) ?? email

            return AppStoreAccount(
                email: resolvedEmail,
                passwordToken: passwordToken,
                directoryServicesID: dsid,
                storeFront: storeFront,
                pod: response.header("pod")
            )
        }

        if let lastResponse {
            throw AppStoreClientError.requestFailed("App Store sign-in redirected too many times (last HTTP \(lastResponse.statusCode)).")
        }

        throw AppStoreClientError.requestFailed("App Store sign-in failed.")
    }

    private func purchaseFreeApp(app: AppResult, account: AppStoreAccount, guid: String) async throws {
        if let price = app.price, price > 0 {
            throw AppStoreClientError.paidAppsNotSupported
        }

        do {
            try await purchaseFreeApp(app: app, account: account, guid: guid, pricingParameters: "STDQ")
        } catch AppStoreClientError.requestFailed(let message) where message == "2059" {
            try await purchaseFreeApp(app: app, account: account, guid: guid, pricingParameters: "GAME")
        } catch AppStoreClientError.requestFailed(let message) where message == "5002" {
            return
        }
    }

    private func purchaseFreeApp(
        app: AppResult,
        account: AppStoreAccount,
        guid: String,
        pricingParameters: String
    ) async throws {
        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": guid,
            "needDiv": "0",
            "origPage": "Software-\(app.trackId)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricingParameters,
            "productType": "C",
            "salableAdamId": app.trackId
        ]

        let response = try await sendRequest(
            url: appStoreURL(path: "/WebObjects/MZFinance.woa/wa/buyProduct", account: account),
            method: "POST",
            headers: [
                "Content-Type": "application/x-apple-plist",
                "iCloud-DSID": account.directoryServicesID,
                "X-Dsid": account.directoryServicesID,
                "X-Apple-Store-Front": account.storeFront,
                "X-Token": account.passwordToken
            ],
            plist: payload
        )

        let dictionary = response.dictionary ?? [:]
        let failureType = stringValue(dictionary["failureType"]) ?? ""
        let customerMessage = stringValue(dictionary["customerMessage"]) ?? ""

        if failureType == "2034" || failureType == "2042" || failureType == "1008" {
            throw AppStoreClientError.appStoreSessionExpired
        }

        if failureType == "5002" {
            return
        }

        if failureType == "2059" {
            throw AppStoreClientError.requestFailed("2059")
        }

        if !failureType.isEmpty {
            throw AppStoreClientError.requestFailed(customerMessage.isEmpty ? failureType : customerMessage)
        }

        let documentType = stringValue(dictionary["jingleDocType"]) ?? ""
        let status = intValue(dictionary["status"]) ?? -1

        guard response.statusCode == 200, documentType == "purchaseSuccess", status == 0 else {
            throw AppStoreClientError.requestFailed("Could not acquire the App Store license for \(app.trackName).")
        }
    }

    private func downloadPackage(
        app: AppResult,
        account: AppStoreAccount,
        guid: String,
        to folder: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.trackId
        ]

        var components = URLComponents(url: appStoreURL(path: "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct", account: account), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]

        let response = try await sendRequest(
            url: components.url!,
            method: "POST",
            headers: [
                "Content-Type": "application/x-apple-plist",
                "iCloud-DSID": account.directoryServicesID,
                "X-Dsid": account.directoryServicesID
            ],
            plist: payload
        )

        let dictionary = response.dictionary ?? [:]
        let failureType = stringValue(dictionary["failureType"]) ?? ""
        let customerMessage = stringValue(dictionary["customerMessage"]) ?? ""

        switch failureType {
        case "":
            break
        case "9610":
            throw AppStoreClientError.licenseRequired
        case "2034", "2042", "1008", "5002":
            throw AppStoreClientError.appStoreSessionExpired
        default:
            throw AppStoreClientError.requestFailed(customerMessage.isEmpty ? "Download failed (\(failureType))." : customerMessage)
        }

        guard let items = dictionary["songList"] as? [[String: Any]],
              let item = items.first,
              let source = stringValue(item["URL"]),
              let sourceURL = URL(string: source) else {
            throw AppStoreClientError.invalidResponse("Apple did not return an IPA download URL.")
        }

        let metadata = item["metadata"] as? [String: Any]
        let version = stringValue(metadata?["bundleShortVersionString"]) ?? app.version ?? "unknown"
        let destination = availableDestinationURL(in: folder, app: app, version: version)

        var request = URLRequest(url: sourceURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let downloader = PackageDownloader(destination: destination, progress: progress)
        return try await downloader.download(request: request)
    }

    private func sendRequest(
        url: URL,
        method: String,
        headers: [String: String],
        plist: [String: Any]?
    ) async throws -> PlistResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let plist {
            request.httpBody = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        }

        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppStoreClientError.requestFailed("Apple returned an invalid response.")
        }

        let dictionary: [String: Any]?
        if data.isEmpty {
            dictionary = nil
        } else {
            dictionary = try? decodePlistDictionary(from: data)
        }

        return PlistResponse(statusCode: http.statusCode, headers: http.allHeaderFields, dictionary: dictionary, body: data)
    }

    private func decodePlistDictionary(from data: Data) throws -> [String: Any] {
        let normalized = normalizePlistData(data)
        let object = try PropertyListSerialization.propertyList(from: normalized, options: [], format: nil)

        guard let dictionary = object as? [String: Any] else {
            throw AppStoreClientError.invalidResponse("Apple returned a response that was not a dictionary.")
        }

        return dictionary
    }

    private func normalizePlistData(_ data: Data) -> Data {
        if data.prefix(6) == Data("bplist".utf8) {
            return data
        }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if let plistStart = text.range(of: "<plist", options: [.caseInsensitive]),
           let plistEnd = text.range(of: "</plist>", options: [.caseInsensitive, .backwards]) {
            return Data(text[plistStart.lowerBound..<plistEnd.upperBound].utf8)
        }

        if let dictStart = text.range(of: "<dict", options: [.caseInsensitive]),
           let dictEnd = text.range(of: "</dict>", options: [.caseInsensitive, .backwards]) {
            let body = text[dictStart.lowerBound..<dictEnd.upperBound]
            return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">\(body)</plist>
            """.utf8)
        }

        if text.contains("<key>") {
            return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\(text)</dict></plist>
            """.utf8)
        }

        return data
    }

    private func appStoreURL(path: String, account: AppStoreAccount) -> URL {
        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        return URL(string: "https://\(podPrefix)buy.itunes.apple.com\(path)")!
    }

    private func availableDestinationURL(in folder: URL, app: AppResult, version: String) -> URL {
        let identity = app.bundleId?.isEmpty == false ? app.bundleId! : app.trackName
        let baseName = sanitizedPathComponent("\(identity)_\(app.trackId)_\(version)")
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension("ipa")

        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension("ipa")
            suffix += 1
        }

        return candidate
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "app" : cleaned
    }

    private func deviceGUID() -> String {
        if let existing = keychain.load(for: "appStoreGUID"), !existing.isEmpty {
            return existing
        }

        let digits = Array("0123456789ABCDEF")
        let guid = String((0..<12).map { _ in digits.randomElement()! })
        keychain.save(guid, for: "appStoreGUID")
        return guid
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

private struct PlistResponse {
    let statusCode: Int
    let headers: [AnyHashable: Any]
    let dictionary: [String: Any]?
    let body: Data

    func header(_ name: String) -> String? {
        for (key, value) in headers {
            guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }

            if let string = value as? String {
                return string
            }

            if let values = value as? [String] {
                return values.joined(separator: "; ")
            }
        }

        return nil
    }
}

private final class PackageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(destination: URL, progress: @escaping @MainActor (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(request: URLRequest) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                let config = URLSessionConfiguration.default
                config.httpCookieAcceptPolicy = .always
                config.httpShouldSetCookies = true
                config.httpCookieStorage = .shared

                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                self.session = session
                self.task = task
                task.resume()
            }
        } onCancel: {
            task?.cancel()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let progress = progress
        Task { @MainActor in
            progress(value)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(.failure(AppStoreClientError.requestFailed("IPA download failed (HTTP \(http.statusCode)).")))
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.moveItem(at: location, to: destination)
            let progress = progress
            Task { @MainActor in
                progress(1)
            }
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
