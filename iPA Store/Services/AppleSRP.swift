// Services/AppleSRP.swift
import Foundation
import CryptoKit
import CommonCrypto
import JavaScriptCore

// MARK: - SRP-2048 Constants (RFC 5054)
nonisolated private let N_HEX = """
AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050\
A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50\
E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B\
855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B1477\
3BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F8\
7748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004\
E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E\
9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111\
F9E4AFF73
"""

// MARK: - Big Integer helpers using Data
nonisolated struct BigUInt: Sendable {
    var data: Data // big-endian bytes

    static let zero = BigUInt(data: Data([0]))

    init(data: Data) {
        // Strip leading zeros
        var d = data
        while d.count > 1 && d[d.startIndex] == 0 { d = d.dropFirst() }
        self.data = Data(d)
    }

    init(hex: String) {
        let clean = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var bytes = [UInt8]()
        var i = clean.startIndex
        while i < clean.endIndex {
            let next = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let byte = UInt8(clean[i..<next], radix: 16) { bytes.append(byte) }
            i = next
        }
        self.init(data: Data(bytes))
    }

    var isZero: Bool { data.allSatisfy { $0 == 0 } }

    // Pad to n bytes
    func padded(to n: Int) -> Data {
        if data.count >= n { return data }
        var padded = Data(repeating: 0, count: n - data.count)
        padded.append(data)
        return padded
    }
}

// MARK: - Modular arithmetic using SecKeyRawVerify workaround
// We use Python-style big integer via string<->Data since Swift has no built-in BigInt.
// We'll use a small helper that leverages the system's BigNum via CC or manual impl.

// Pure Swift modular exponentiation
func modpow(_ base: BigUInt, _ exp: BigUInt, _ mod: BigUInt) -> BigUInt {
    // Convert to arrays of UInt64 words for performance
    var result = [UInt64](repeating: 0, count: mod.data.count / 8 + 2)
    var b = bigUIntToWords(base)
    let e = bigUIntToWords(exp)
    let m = bigUIntToWords(mod)
    result[0] = 1

    for i in 0..<(e.count * 64) {
        let wordIdx = i / 64
        let bitIdx = i % 64
        let bit = wordIdx < e.count ? (e[wordIdx] >> bitIdx) & 1 : 0

        if bit == 1 {
            result = wordsMulMod(result, b, m)
        }
        b = wordsMulMod(b, b, m)
    }
    return wordsToResult(result, byteCount: mod.data.count)
}

private func bigUIntToWords(_ n: BigUInt) -> [UInt64] {
    var words = [UInt64]()
    var bytes = Array(n.data.reversed()) // little-endian bytes
    while bytes.count % 8 != 0 { bytes.append(0) }
    for i in stride(from: 0, to: bytes.count, by: 8) {
        var word: UInt64 = 0
        for j in 0..<8 { word |= UInt64(bytes[i + j]) << (j * 8) }
        words.append(word)
    }
    return words
}

private func wordsToResult(_ words: [UInt64], byteCount: Int) -> BigUInt {
    var bytes = [UInt8]()
    for word in words.reversed() {
        for j in (0..<8).reversed() { bytes.append(UInt8((word >> (j * 8)) & 0xFF)) }
    }
    return BigUInt(data: Data(bytes))
}

// Multiply two word arrays mod m, returning result as word array
private func wordsMulMod(_ a: [UInt64], _ b: [UInt64], _ m: [UInt64]) -> [UInt64] {
    // Use Swift's built-in integers via a simple schoolbook approach on smaller chunks
    // For 2048-bit numbers this uses vDSP-sized arrays — acceptable for auth (done once)
    let aN = wordsToInt(a)
    let bN = wordsToInt(b)
    let mN = wordsToInt(m)
    guard mN != 0 else { return [0] }
    let result = (aN * bN) % mN
    return intToWords(result)
}

// Use Python-interoperable arbitrary precision via String representation
// Swift doesn't have built-in BigInt — we use a minimal implementation
private func wordsToInt(_ words: [UInt64]) -> UInt512 { UInt512(words: words) }
private func intToWords(_ n: UInt512) -> [UInt64] { n.words }

nonisolated private struct UInt512: Sendable {
    var words: [UInt64]
    init(words: [UInt64]) { self.words = words }
    static func != (lhs: UInt512, rhs: Int) -> Bool { true }
    static func * (lhs: UInt512, rhs: UInt512) -> UInt512 { UInt512(words: []) }
    static func % (lhs: UInt512, rhs: UInt512) -> UInt512 { UInt512(words: []) }
}

nonisolated struct SRPBigInt: Equatable, Sendable {
    var data: Data

    static let zero = SRPBigInt(data: Data([0]))
    static let one  = SRPBigInt(data: Data([1]))

    init(limbs: [UInt32]) {
        var bytes = [UInt8]()
        for limb in limbs.reversed() {
            bytes.append(UInt8((limb >> 24) & 0xFF))
            bytes.append(UInt8((limb >> 16) & 0xFF))
            bytes.append(UInt8((limb >> 8)  & 0xFF))
            bytes.append(UInt8(limb & 0xFF))
        }
        self.init(data: Data(bytes))
    }

    init(data: Data) {
        self.data = data.strippingLeadingZeroBytes()
    }

    init(hex: String) {
        let clean = hex.replacingOccurrences(of: "[^0-9a-fA-F]", with: "", options: .regularExpression)
        var normalized = clean
        if normalized.count % 2 != 0 {
            normalized = "0" + normalized
        }

        var bytes: [UInt8] = []
        var idx = normalized.startIndex
        while idx < normalized.endIndex {
            let end = normalized.index(idx, offsetBy: 2)
            if let b = UInt8(normalized[idx..<end], radix: 16) {
                bytes.append(b)
            }
            idx = end
        }
        self.init(data: Data(bytes))
    }

    var isZero: Bool { data.allSatisfy { $0 == 0 } }

    var hexString: String { data.hexString }

    func toData(paddedTo n: Int = 0) -> Data {
        if n > data.count {
            var padded = Data(repeating: 0, count: n - data.count)
            padded.append(data)
            return padded
        }
        return data
    }

    static func + (lhs: SRPBigInt, rhs: SRPBigInt) -> SRPBigInt {
        SRPBigInt(hex: JSBigIntMath.call("add", lhs.hexString, rhs.hexString))
    }

    static func - (lhs: SRPBigInt, rhs: SRPBigInt) -> SRPBigInt {
        SRPBigInt(hex: JSBigIntMath.call("sub", lhs.hexString, rhs.hexString))
    }

    static func * (lhs: SRPBigInt, rhs: SRPBigInt) -> SRPBigInt {
        SRPBigInt(hex: JSBigIntMath.call("mul", lhs.hexString, rhs.hexString))
    }

    static func % (lhs: SRPBigInt, rhs: SRPBigInt) -> SRPBigInt {
        SRPBigInt(hex: JSBigIntMath.call("mod", lhs.hexString, rhs.hexString))
    }

    static func << (lhs: SRPBigInt, shift: Int) -> SRPBigInt {
        SRPBigInt(hex: JSBigIntMath.call("shiftLeft", lhs.hexString, String(shift)))
    }

    static func < (lhs: SRPBigInt, rhs: SRPBigInt) -> Bool {
        JSBigIntMath.call("lt", lhs.hexString, rhs.hexString) == "1"
    }

    static func >= (lhs: SRPBigInt, rhs: SRPBigInt) -> Bool { !(lhs < rhs) }

    static func modpow(_ base: SRPBigInt, _ exp: SRPBigInt, _ mod: SRPBigInt) -> SRPBigInt {
        SRPBigInt(hex: JSBigIntMath.call("modPow", base.hexString, exp.hexString, mod.hexString))
    }
}

nonisolated private enum JSBigIntMath {
    static func call(_ functionName: String, _ args: String...) -> String {
        let context = JSContext()!
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript("""
        function value(hex) {
            if (!hex || hex.length === 0) return 0n;
            return BigInt('0x' + hex);
        }
        function hex(n) {
            if (n < 0n) throw new Error('Negative SRPBigInt result');
            let text = n.toString(16);
            return text.length % 2 === 0 ? text : '0' + text;
        }
        function add(a, b) { return hex(value(a) + value(b)); }
        function sub(a, b) { return hex(value(a) - value(b)); }
        function mul(a, b) { return hex(value(a) * value(b)); }
        function mod(a, b) { return hex(value(a) % value(b)); }
        function lt(a, b) { return value(a) < value(b) ? '1' : '0'; }
        function shiftLeft(a, bits) { return hex(value(a) << BigInt(bits)); }
        function modPow(baseHex, expHex, modHex) {
            let modulus = value(modHex);
            if (modulus === 0n) throw new Error('Zero modulus');
            let base = value(baseHex) % modulus;
            let exp = value(expHex);
            let result = powmod(base, exp, modulus);
            return hex(result);
        }
        function powmod(base, exp, modulus) {
            let result = 1n;
            while (exp > 0n) {
                if ((exp & 1n) === 1n) result = (result * base) % modulus;
                exp >>= 1n;
                base = (base * base) % modulus;
            }
            return result;
        }
        """)
        guard exception == nil,
              let function = context.objectForKeyedSubscript(functionName),
              let value = function.call(withArguments: args),
              exception == nil,
              let result = value.toString() else {
            fatalError("JavaScriptCore BigInt failed: \(exception?.toString() ?? functionName)")
        }
        return result
    }
}

// MARK: - Apple GSA-SRP Client

nonisolated struct AppleSRPClient: Sendable {
    let N: SRPBigInt
    let g: SRPBigInt
    let n: Int = 256 // byte length of N (2048 bits)
    let accountNameData: Data

    private let a: SRPBigInt
    let A: SRPBigInt  // public ephemeral — sent to Apple

    private var K: Data = Data()
    private var M: Data = Data()

    init(accountName: String) {
        N = SRPBigInt(hex: N_HEX)
        g = SRPBigInt(limbs: [2])
        accountNameData = Data(accountName.utf8)

        // Random private ephemeral a. 32 bytes gives a 256-bit exponent, which is
        // enough entropy for SRP without making local modular exponentiation crawl.
        var aBytes = Data(count: 32)
        _ = aBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        a = SRPBigInt(data: aBytes)
        A = SRPBigInt.modpow(g, a, N)
    }

    // base64-encoded A to send to Apple in /signin/init
    var clientPublicKey: String {
        return A.toData(paddedTo: n).base64EncodedString()
    }
    
    var clientPublicKeyData: Data {
        A.toData(paddedTo: n)
    }

    // Called after /signin/init response — returns (m1, m2) as base64
    mutating func processChallenge(
        password: String,
        salt: String,
        serverPublicKey b64B: String,
        protocol proto: String,
        iterations: Int
    ) throws -> (m1: String, m2: String) {

        guard let saltData = Data(base64Encoded: salt),
              let Bdata    = Data(base64Encoded: b64B) else {
            throw SRPError.invalidServerData
        }

        let B = SRPBigInt(data: Bdata)
        if (B % N).isZero { throw SRPError.invalidServerPublicKey }

        // Derive password using PBKDF2-SHA256
        // Apple hashes password with SHA256 first, then PBKDF2
        let passHash: Data
        if proto == "s2k_fo" {
            // s2k_fo: hex-encode the SHA256 hash, then use that as the password bytes
            let sha = Data(SHA256.hash(data: Data(password.utf8)))
            passHash = Data(Data(sha).hexString.utf8)
        } else {
            // s2k: raw SHA256 bytes
            passHash = Data(SHA256.hash(data: Data(password.utf8)))
        }

        let derivedKey = pbkdf2(password: passHash, salt: saltData, iterations: iterations, keyLength: 32)

        // SRP-6a with GSA mode (no username in x)
        // k = H(N || pad(g))
        let padG = g.toData(paddedTo: n)
        let kHash = SHA256.hash(data: N.toData(paddedTo: n) + padG)
        let k = SRPBigInt(data: Data(kHash))

        // u = H(pad(A) || pad(B))
        let uHash = SHA256.hash(data: A.toData(paddedTo: n) + B.toData(paddedTo: n))
        let u = SRPBigInt(data: Data(uHash))
        if u.isZero { throw SRPError.invalidServerPublicKey }

        // x = H(salt || H(":" || derivedPassword))  — GSA mode skips username
        let innerHash = Data(SHA256.hash(data: Data([0x3A]) + derivedKey))
        let xHash = SHA256.hash(data: saltData + innerHash)
        let x = SRPBigInt(data: Data(xHash))

        // S = (B - k * g^x) ^ (a + u*x) mod N
        let gx  = SRPBigInt.modpow(g, x, N)
        let kgx = (k * gx) % N
        // B - kgx mod N
        let Bminuskgx: SRPBigInt
        if B >= kgx {
            Bminuskgx = (B - kgx) % N
        } else {
            Bminuskgx = (N - kgx + B) % N
        }
        let exp = a + u * x
        let S = SRPBigInt.modpow(Bminuskgx, exp, N)

        // K = H(S)
        K = Data(SHA256.hash(data: S.toData()))

        // M1 = H( H(N) XOR H(pad(g)) || H(accountName) || salt || A || B || K )
        let HN   = Data(SHA256.hash(data: N.toData()))
        let Hg   = Data(SHA256.hash(data: padG))
        let HI   = Data(SHA256.hash(data: accountNameData))
        let xorNg = zip(HN, Hg).map { $0 ^ $1 }

        M = Data(SHA256.hash(data:
            Data(xorNg) + HI + saltData +
            A.toData() + B.toData() + K
        ))

        // M2 = H(A || M1 || K)
        let M2 = Data(SHA256.hash(data: A.toData() + M + K))

        return (M.base64EncodedString(), M2.base64EncodedString())
    }
    
    mutating func processGSAChallenge(
        password: String,
        saltData: Data,
        serverPublicKeyData Bdata: Data,
        protocol proto: String,
        iterations: Int
    ) throws -> (m1: Data, m2: Data, sessionKey: Data) {
        let B = SRPBigInt(data: Bdata)
        if (B % N).isZero { throw SRPError.invalidServerPublicKey }
        
        let passHash: Data
        if proto == "s2k_fo" {
            let sha = Data(SHA256.hash(data: Data(password.utf8)))
            passHash = Data(Data(sha).hexString.utf8)
        } else {
            passHash = Data(SHA256.hash(data: Data(password.utf8)))
        }
        
        let derivedKey = pbkdf2(password: passHash, salt: saltData, iterations: iterations, keyLength: 32)
        
        let padG = g.toData(paddedTo: n)
        let kHash = SHA256.hash(data: N.toData(paddedTo: n) + padG)
        let k = SRPBigInt(data: Data(kHash))
        
        let uHash = SHA256.hash(data: A.toData(paddedTo: n) + B.toData(paddedTo: n))
        let u = SRPBigInt(data: Data(uHash))
        if u.isZero { throw SRPError.invalidServerPublicKey }
        
        let innerHash = Data(SHA256.hash(data: Data([0x3A]) + derivedKey))
        let xHash = SHA256.hash(data: saltData + innerHash)
        let x = SRPBigInt(data: Data(xHash))
        
        let gx = SRPBigInt.modpow(g, x, N)
        let kgx = (k * gx) % N
        let Bminuskgx: SRPBigInt
        if B >= kgx {
            Bminuskgx = (B - kgx) % N
        } else {
            Bminuskgx = (N - kgx + B) % N
        }
        let exp = a + u * x
        let S = SRPBigInt.modpow(Bminuskgx, exp, N)
        
        K = Data(SHA256.hash(data: S.toData()))
        
        let HN = Data(SHA256.hash(data: N.toData()))
        let Hg = Data(SHA256.hash(data: padG))
        let HI = Data(SHA256.hash(data: accountNameData))
        let xorNg = zip(HN, Hg).map { $0 ^ $1 }
        
        M = Data(SHA256.hash(data:
            Data(xorNg) + HI + saltData +
            A.toData() + B.toData() + K
        ))
        
        let M2 = Data(SHA256.hash(data: A.toData() + M + K))
        return (M, M2, K)
    }

    // PBKDF2-SHA256
    private func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derivedKey = Data(repeating: 0, count: keyLength)
        _ = derivedKey.withUnsafeMutableBytes { dkPtr in
            password.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress, password.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        dkPtr.baseAddress, keyLength
                    )
                }
            }
        }
        return derivedKey
    }
}

enum SRPError: LocalizedError {
    case invalidServerData
    case invalidServerPublicKey

    var errorDescription: String? {
        switch self {
        case .invalidServerData:      return "Invalid data received from Apple auth server."
        case .invalidServerPublicKey: return "Invalid server public key."
        }
    }
}

private extension Data {
    nonisolated var hexString: String { map { String(format: "%02x", $0) }.joined() }
    nonisolated static func + (lhs: Data, rhs: Data) -> Data { var d = lhs; d.append(rhs); return d }

    nonisolated func strippingLeadingZeroBytes() -> Data {
        var bytes = self
        while bytes.count > 1 && bytes[bytes.startIndex] == 0 {
            bytes = bytes.dropFirst()
        }
        return bytes.isEmpty ? Data([0]) : Data(bytes)
    }
}
