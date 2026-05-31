import Foundation
import zlib

struct SideloadExtractedApp: Sendable {
    let temporaryDirectory: URL?
    let appBundleURL: URL
    
    nonisolated func cleanUp() {
        guard let temporaryDirectory else {
            return
        }
        
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

struct SideloadIPAMetadata: Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String
    let version: String?
    let buildVersion: String?
    let iconFileURL: URL?
}

enum SideloadIPAExtractionError: LocalizedError {
    case invalidIPA
    case encryptedArchive
    case unsupportedZIP64
    case unsupportedCompressionMethod(Int)
    case unsafePath(String)
    case missingPayloadApp
    case missingInfoPlist
    case decompressionFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidIPA:
            return "The selected IPA is not a valid ZIP archive."
        case .encryptedArchive:
            return "Encrypted IPA archives are not supported."
        case .unsupportedZIP64:
            return "ZIP64 IPA archives are not supported yet."
        case .unsupportedCompressionMethod(let method):
            return "This IPA uses an unsupported ZIP compression method (\(method))."
        case .unsafePath(let path):
            return "The IPA contains an unsafe path: \(path)"
        case .missingPayloadApp:
            return "The IPA does not contain a Payload app bundle."
        case .missingInfoPlist:
            return "The app bundle does not contain a readable Info.plist."
        case .decompressionFailed:
            return "The IPA could not be decompressed."
        }
    }
}

enum SideloadIPAExtractor {
    nonisolated static func extractAppBundle(from fileURL: URL) throws -> SideloadExtractedApp {
       
        if fileURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
            return SideloadExtractedApp(temporaryDirectory: nil, appBundleURL: fileURL)
        }
        
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("iPAStoreSideload-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = temporaryDirectory.appendingPathComponent("Payload", isDirectory: true)
        
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        
        do {
            let archive = try ZIPArchive(url: fileURL)
            
            try archive.extractPayload(to: temporaryDirectory)
            
            let payloadContents = try fileManager.contentsOfDirectory(
                at: payloadDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
           
            guard let appBundle = payloadContents.first(where: { url in
                url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame
            }) else {
                throw SideloadIPAExtractionError.missingPayloadApp
            }
            
            return SideloadExtractedApp(temporaryDirectory: temporaryDirectory, appBundleURL: appBundle)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }
    
    nonisolated static func metadata(from fileURL: URL) throws -> SideloadIPAMetadata {
        let extractedApp = try extractAppBundle(from: fileURL)
        defer {
            extractedApp.cleanUp()
        }
        
        return try metadata(fromAppBundle: extractedApp.appBundleURL, sourceURL: fileURL)
    }
    
    nonisolated static func metadata(fromAppBundle appBundleURL: URL, sourceURL: URL) throws -> SideloadIPAMetadata {
        let infoURL = appBundleURL.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw SideloadIPAExtractionError.missingInfoPlist
        }
        
        let displayName = (info["CFBundleDisplayName"] as? String)
        ?? (info["CFBundleName"] as? String)
        ?? sourceURL.deletingPathExtension().lastPathComponent
        let version = info["CFBundleShortVersionString"] as? String
        let buildVersion = info["CFBundleVersion"] as? String
        let iconFileURL = try? cachedIconURL(
            fromAppBundle: appBundleURL,
            info: info,
            bundleIdentifier: bundleIdentifier
        )
        
        return SideloadIPAMetadata(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            version: version,
            buildVersion: buildVersion,
            iconFileURL: iconFileURL
        )
    }
    
    nonisolated private static func cachedIconURL(
        fromAppBundle appBundleURL: URL,
        info: [String: Any],
        bundleIdentifier: String
    ) throws -> URL? {
        guard let iconURL = bestIconURL(fromAppBundle: appBundleURL, info: info) else {
            return nil
        }
        
        let fileManager = FileManager.default
        let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPA Store", isDirectory: true)
            .appendingPathComponent("Sideload Icons", isDirectory: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        let filename = "\(sanitizedPathComponent(bundleIdentifier))-\(UUID().uuidString).png"
        let destinationURL = cacheDirectory.appendingPathComponent(filename)
        try fileManager.copyItem(at: iconURL, to: destinationURL)
        return destinationURL
    }
    
    nonisolated private static func bestIconURL(fromAppBundle appBundleURL: URL, info: [String: Any]) -> URL? {
        let iconNames = Set(iconNameCandidates(from: info).map { normalizedIconName($0) })
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        
        var bestURL: URL?
        var bestScore = Int.min
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.localizedCaseInsensitiveCompare("png") == .orderedSame else {
                continue
            }
            
            let normalizedName = normalizedIconName(fileURL.deletingPathExtension().lastPathComponent)
            let nameScore: Int
            
            if iconNames.isEmpty {
                nameScore = normalizedName.localizedCaseInsensitiveContains("appicon")
                || normalizedName.localizedCaseInsensitiveContains("icon") ? 1_000 : 0
            } else if iconNames.contains(normalizedName) {
                nameScore = 2_000
            } else if iconNames.contains(where: { normalizedName.hasPrefix($0) }) {
                nameScore = 1_500
            } else {
                nameScore = 0
            }
            
            guard nameScore > 0 else {
                continue
            }
            
            let sizeScore = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let scaleScore: Int
            let name = fileURL.lastPathComponent.lowercased()
            if name.contains("@3x") {
                scaleScore = 300
            } else if name.contains("@2x") {
                scaleScore = 200
            } else {
                scaleScore = 100
            }
            
            let score = nameScore + scaleScore + min(sizeScore / 1_024, 999)
            if score > bestScore {
                bestScore = score
                bestURL = fileURL
            }
        }
        
        return bestURL
    }
    
    nonisolated private static func iconNameCandidates(from info: [String: Any]) -> [String] {
        var names: [String] = []
        
        func appendIconFiles(from dictionary: [String: Any]?) {
            guard let dictionary else {
                return
            }
            
            if let iconFile = dictionary["CFBundleIconFile"] as? String {
                names.append(iconFile)
            }
            
            if let iconFiles = dictionary["CFBundleIconFiles"] as? [String] {
                names.append(contentsOf: iconFiles)
            }
            
            if let primaryIcon = dictionary["CFBundlePrimaryIcon"] as? [String: Any] {
                appendIconFiles(from: primaryIcon)
            }
        }
        
        if let iconFile = info["CFBundleIconFile"] as? String {
            names.append(iconFile)
        }
        
        if let iconFiles = info["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: iconFiles)
        }
        
        appendIconFiles(from: info["CFBundleIcons"] as? [String: Any])
        appendIconFiles(from: info["CFBundleIcons~ipad"] as? [String: Any])
        
        return names
    }
    
    nonisolated private static func normalizedIconName(_ name: String) -> String {
        name
            .replacingOccurrences(of: ".png", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "@2x", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "@3x", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "~ipad", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "~iphone", with: "", options: [.caseInsensitive])
            .lowercased()
    }
    
    nonisolated private static func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }
}

nonisolated private struct ZIPArchive {
    private let url: URL
    private let entries: [ZIPEntry]
    
    init(url: URL) throws {
        self.url = url
        
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        
        let fileSize = try handle.seekToEnd()
        let maximumEOCDSearchLength = UInt64(65_535 + 22)
        let tailLength = min(fileSize, maximumEOCDSearchLength)
        try handle.seek(toOffset: fileSize - tailLength)
        
        guard let tail = try handle.read(upToCount: Int(tailLength)),
              let eocdIndex = tail.endOfCentralDirectoryIndex else {
            throw SideloadIPAExtractionError.invalidIPA
        }
        
        let totalEntries = try Int(tail.uint16LE(at: eocdIndex + 10))
        let centralDirectorySize = try tail.uint32LE(at: eocdIndex + 12)
        let centralDirectoryOffset = try tail.uint32LE(at: eocdIndex + 16)
        
        guard centralDirectorySize != UInt32.max,
              centralDirectoryOffset != UInt32.max else {
            throw SideloadIPAExtractionError.unsupportedZIP64
        }
        
        try handle.seek(toOffset: UInt64(centralDirectoryOffset))
        guard let centralDirectory = try handle.read(upToCount: Int(centralDirectorySize)) else {
            throw SideloadIPAExtractionError.invalidIPA
        }
        
        self.entries = try ZIPArchive.readEntries(
            from: centralDirectory,
            expectedCount: totalEntries
        )
    }
    
    func extractPayload(to destinationDirectory: URL) throws {
        let fileManager = FileManager.default
        let destinationPath = destinationDirectory.standardizedFileURL.path
        let handle = try FileHandle(forReadingFrom: url)
        
        defer {
            try? handle.close()
        }
        
        for entry in entries where entry.path.hasPrefix("Payload/") {
            
            guard let outputURL = try outputURL(
                for: entry.path,
                destinationDirectory: destinationDirectory,
                destinationPath: destinationPath
            ) else {
                continue
            }
            
            if entry.isDirectory {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }
            
            guard (entry.flags & 0x1) == 0 else {
                throw SideloadIPAExtractionError.encryptedArchive
            }
            
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            
            let compressedData = try readCompressedData(for: entry, handle: handle)
            let fileData = try decompress(compressedData, entry: entry)
            
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            
            if entry.isSymbolicLink {
                let target = String(decoding: fileData, as: UTF8.self)
                try fileManager.createSymbolicLink(atPath: outputURL.path, withDestinationPath: target)
            } else {
                guard fileManager.createFile(atPath: outputURL.path, contents: fileData) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                
                if let permissions = entry.posixPermissions {
                    try fileManager.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: outputURL.path
                    )
                }
            }
        }
    }
    
    private static func readEntries(from centralDirectory: Data, expectedCount: Int) throws -> [ZIPEntry] {
        var entries: [ZIPEntry] = []
        var offset = 0
        
        while offset < centralDirectory.count {
            guard try centralDirectory.uint32LE(at: offset) == 0x0201_4B50 else {
                throw SideloadIPAExtractionError.invalidIPA
            }
            
            let flags = try centralDirectory.uint16LE(at: offset + 8)
            let compressionMethod = try centralDirectory.uint16LE(at: offset + 10)
            let compressedSize = try centralDirectory.uint32LE(at: offset + 20)
            let uncompressedSize = try centralDirectory.uint32LE(at: offset + 24)
            let fileNameLength = try Int(centralDirectory.uint16LE(at: offset + 28))
            let extraFieldLength = try Int(centralDirectory.uint16LE(at: offset + 30))
            let fileCommentLength = try Int(centralDirectory.uint16LE(at: offset + 32))
            let externalAttributes = try centralDirectory.uint32LE(at: offset + 38)
            let localHeaderOffset = try centralDirectory.uint32LE(at: offset + 42)
            let fileNameStart = offset + 46
            let fileNameEnd = fileNameStart + fileNameLength
            
            guard fileNameEnd <= centralDirectory.count,
                  compressedSize != UInt32.max,
                  uncompressedSize != UInt32.max,
                  localHeaderOffset != UInt32.max else {
                throw SideloadIPAExtractionError.unsupportedZIP64
            }
            
            let fileNameData = centralDirectory[fileNameStart..<fileNameEnd]
            guard let path = String(data: fileNameData, encoding: .utf8) else {
                throw SideloadIPAExtractionError.invalidIPA
            }
            
            entries.append(
                ZIPEntry(
                    path: path,
                    flags: flags,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset,
                    externalAttributes: externalAttributes
                )
            )
            
            offset = fileNameEnd + extraFieldLength + fileCommentLength
        }
        
        if expectedCount > 0, entries.count != expectedCount {
            throw SideloadIPAExtractionError.invalidIPA
        }
        
        return entries
    }
    
    private func outputURL(
        for path: String,
        destinationDirectory: URL,
        destinationPath: String
    ) throws -> URL? {
        guard !path.hasPrefix("/") else {
            throw SideloadIPAExtractionError.unsafePath(path)
        }
        
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        
        guard components.first == "Payload" else {
            return nil
        }
        
        guard components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.contains("\0")
        }) else {
            throw SideloadIPAExtractionError.unsafePath(path)
        }
        
        let outputURL = components.reduce(destinationDirectory) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        let standardizedPath = outputURL.standardizedFileURL.path
        
        guard standardizedPath == destinationPath || standardizedPath.hasPrefix(destinationPath + "/") else {
            throw SideloadIPAExtractionError.unsafePath(path)
        }
        
        return outputURL
    }
    
    private func readCompressedData(for entry: ZIPEntry, handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))

        guard let localHeader = try handle.read(upToCount: 30),
              localHeader.count == 30,
              try localHeader.uint32LE(at: 0) == 0x0403_4B50 else {
            throw SideloadIPAExtractionError.invalidIPA
        }

        let fileNameLength = try UInt64(localHeader.uint16LE(at: 26))
        let extraFieldLength = try UInt64(localHeader.uint16LE(at: 28))
        let dataOffset = UInt64(entry.localHeaderOffset) + 30 + fileNameLength + extraFieldLength

        try handle.seek(toOffset: dataOffset)

        // ✅ Valid empty file
        if entry.compressedSize == 0 {
            return Data()
        }

        guard let data = try handle.read(upToCount: Int(entry.compressedSize)),
              data.count == Int(entry.compressedSize) else {
            throw SideloadIPAExtractionError.invalidIPA
        }

        return data
    }
    
    private func decompress(_ compressedData: Data, entry: ZIPEntry) throws -> Data {
        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return try compressedData.inflateRaw(expectedSize: Int(entry.uncompressedSize))
        default:
            throw SideloadIPAExtractionError.unsupportedCompressionMethod(Int(entry.compressionMethod))
        }
    }
}

nonisolated private struct ZIPEntry {
    let path: String
    let flags: UInt16
    let compressionMethod: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
    let externalAttributes: UInt32
    
    var isDirectory: Bool {
        path.hasSuffix("/") || fileType == 0o040000
    }
    
    var isSymbolicLink: Bool {
        fileType == 0o120000
    }
    
    var posixPermissions: Int? {
        let mode = Int((externalAttributes >> 16) & 0xFFFF)
        guard mode != 0 else {
            return nil
        }
        
        return mode & 0o777
    }
    
    private var fileType: Int {
        Int((externalAttributes >> 16) & 0xF000)
    }
}

private extension Data {
    nonisolated var endOfCentralDirectoryIndex: Int? {
        guard count >= 22 else {
            return nil
        }
        
        var index = count - 22
        while index >= 0 {
            if (try? uint32LE(at: index)) == 0x0605_4B50 {
                return index
            }
            
            index -= 1
        }
        
        return nil
    }
    
    nonisolated func uint16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw SideloadIPAExtractionError.invalidIPA
        }
        
        return withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
    }
    
    nonisolated func uint32LE(at offset: Int) throws -> UInt32 {
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
    
    nonisolated func inflateRaw(expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else {
            return Data()
        }
        
        var output = Data(repeating: 0, count: expectedSize)
        let outputCapacity = output.count
        var stream = z_stream()
        
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw SideloadIPAExtractionError.decompressionFailed
        }
        
        defer {
            inflateEnd(&stream)
        }
        
        let result = withUnsafeBytes { inputRawBuffer in
            output.withUnsafeMutableBytes { outputRawBuffer in
                let inputBuffer = inputRawBuffer.bindMemory(to: Bytef.self)
                let outputBuffer = outputRawBuffer.bindMemory(to: Bytef.self)
                
                stream.next_in = UnsafeMutablePointer(mutating: inputBuffer.baseAddress)
                stream.avail_in = uInt(count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputCapacity)
                
                return inflate(&stream, Z_FINISH)
            }
        }
        
        guard result == Z_STREAM_END,
              stream.total_out == uLong(expectedSize) else {
            throw SideloadIPAExtractionError.decompressionFailed
        }
        
        return output
    }
}
