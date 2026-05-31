import Foundation
import Security

struct SideloadCertificateRequest: Sendable {
    let csrPEM: String
    let privateKey: SecKey
    
    static func make(machineName: String) throws -> SideloadCertificateRequest {
        let tag = Data("iPAStore.Signing.\(UUID().uuidString)".utf8)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: "iPA Store Apple Development",
            kSecAttrApplicationTag as String: tag,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SideloadSigningError.codeSigningFailed(
                "certificate request",
                error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "Could not create private key."
            )
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SideloadSigningError.codeSigningFailed(
                "certificate request",
                error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "Could not export public key."
            )
        }
        
        let requestInfo = ASN1.sequence([
            ASN1.integer(0),
            ASN1.name([
                ("2.5.4.6", "US"),
                ("2.5.4.8", "CA"),
                ("2.5.4.7", "Los Angeles"),
                ("2.5.4.10", "iPA Store"),
                ("2.5.4.3", machineName)
            ]),
            ASN1.subjectPublicKeyInfo(rsaPublicKey: publicKeyData),
            ASN1.tagged(0, Data())
        ])
        
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA1,
            requestInfo as CFData,
            &error
        ) as Data? else {
            throw SideloadSigningError.codeSigningFailed(
                "certificate request",
                error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "Could not sign certificate request."
            )
        }
        
        let csr = ASN1.sequence([
            requestInfo,
            ASN1.algorithmIdentifier("1.2.840.113549.1.1.5"),
            ASN1.bitString(signature)
        ])
        
        return SideloadCertificateRequest(
            csrPEM: pemArmor(csr, label: "CERTIFICATE REQUEST"),
            privateKey: privateKey
        )
    }
    
    private static func pemArmor(_ data: Data, label: String) -> String {
        let base64 = data.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start..<end])
        }
        
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }
}

private enum ASN1 {
    static func sequence(_ values: [Data]) -> Data {
        encode(tag: 0x30, contents: values.reduce(Data(), +))
    }
    
    static func set(_ values: [Data]) -> Data {
        encode(tag: 0x31, contents: values.reduce(Data(), +))
    }
    
    static func integer(_ value: UInt8) -> Data {
        encode(tag: 0x02, contents: Data([value]))
    }
    
    static func null() -> Data {
        encode(tag: 0x05, contents: Data())
    }
    
    static func objectIdentifier(_ string: String) -> Data {
        let parts = string.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else {
            return encode(tag: 0x06, contents: Data())
        }
        
        var bytes = Data([UInt8(parts[0] * 40 + parts[1])])
        for part in parts.dropFirst(2) {
            bytes.append(contentsOf: base128(part))
        }
        
        return encode(tag: 0x06, contents: bytes)
    }
    
    static func utf8String(_ string: String) -> Data {
        encode(tag: 0x0C, contents: Data(string.utf8))
    }
    
    static func printableString(_ string: String) -> Data {
        encode(tag: 0x13, contents: Data(string.utf8))
    }
    
    static func bitString(_ data: Data) -> Data {
        var contents = Data([0x00])
        contents.append(data)
        return encode(tag: 0x03, contents: contents)
    }
    
    static func tagged(_ index: UInt8, _ contents: Data) -> Data {
        encode(tag: 0xA0 + index, contents: contents)
    }
    
    static func algorithmIdentifier(_ oid: String) -> Data {
        sequence([objectIdentifier(oid), null()])
    }
    
    static func subjectPublicKeyInfo(rsaPublicKey: Data) -> Data {
        sequence([
            algorithmIdentifier("1.2.840.113549.1.1.1"),
            bitString(rsaPublicKey)
        ])
    }
    
    static func name(_ attributes: [(String, String)]) -> Data {
        sequence(attributes.map { oid, value in
            let valueData = oid == "2.5.4.6" ? printableString(value) : utf8String(value)
            return set([
                sequence([
                    objectIdentifier(oid),
                    valueData
                ])
            ])
        })
    }
    
    private static func encode(tag: UInt8, contents: Data) -> Data {
        var data = Data([tag])
        data.append(length(contents.count))
        data.append(contents)
        return data
    }
    
    private static func length(_ value: Int) -> Data {
        if value < 128 {
            return Data([UInt8(value)])
        }
        
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    
    private static func base128(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        
        return bytes
    }
}
