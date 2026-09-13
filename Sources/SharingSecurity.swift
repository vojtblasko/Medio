import Foundation
import CryptoKit
import Security
import Network
import Darwin

/// Per-install trust anchor in this device's Keychain; per-session TLS leaf identity.
/// CryptoKit signs X.509 data and Network.framework negotiates TLS. No custom cipher.
final class SharingTLSIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificate: SecCertificate
    let rootCertificate: Data
    let fingerprint: String
    private let keyTag: Data

    private init(identity: SecIdentity, certificate: SecCertificate, root: Data, tag: Data) {
        self.identity = identity
        self.certificate = certificate
        rootCertificate = root
        keyTag = tag
        fingerprint = SHA256.hash(data: root).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    deinit {
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate, kSecValueRef: certificate] as CFDictionary)
    }

    enum Failure: Error { case keychain(OSStatus), invalidCertificate, missingIdentity, invalidHost }

    static func make(host: String, keychainAccount: String = "medio.local-audio.root.v1") throws -> SharingTLSIdentity {
        let root = try loadRoot(account: keychainAccount)
        let leafKey = P256.Signing.PrivateKey()
        let leafDER = try SharingCertificate.make(subject: "Medio Audio", publicKey: leafKey.publicKey,
            issuer: root.name, signingKey: root.key, isCA: false, host: host, validDays: 7)
        guard let certificate = SecCertificateCreateWithData(nil, leafDER as CFData) else { throw Failure.invalidCertificate }
        let tag = Data("medio.audio.tls.\(UUID().uuidString)".utf8)
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(leafKey.x963Representation as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256
        ] as CFDictionary, &keyError) else { throw Failure.invalidCertificate }
        let keyStatus = SecItemAdd([kSecClass: kSecClassKey, kSecValueRef: privateKey,
            kSecAttrApplicationTag: tag, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil)
        guard keyStatus == errSecSuccess else { throw Failure.keychain(keyStatus) }
        var keepIdentity = false
        defer {
            if !keepIdentity {
                SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
                SecItemDelete([kSecClass: kSecClassCertificate, kSecValueRef: certificate] as CFDictionary)
            }
        }
        let certStatus = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate] as CFDictionary, nil)
        guard certStatus == errSecSuccess else { throw Failure.keychain(certStatus) }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true] as CFDictionary, &result)
        guard status == errSecSuccess, let candidates = result as? [SecIdentity] else { throw Failure.keychain(status) }
        for identity in candidates {
            var candidate: SecCertificate?
            if SecIdentityCopyCertificate(identity, &candidate) == errSecSuccess,
               let candidate, SecCertificateCopyData(candidate) as Data == leafDER {
                keepIdentity = true
                return SharingTLSIdentity(identity: identity, certificate: certificate, root: root.certificate, tag: tag)
            }
        }
        throw Failure.missingIdentity
    }

    func options() throws -> NWProtocolTLS.Options {
        guard let identity = sec_identity_create(identity) else { throw Failure.missingIdentity }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }

    private struct Root: Codable {
        let privateBytes: Data
        let certificate: Data
        let name: String
        let expires: Date
        var key: P256.Signing.PrivateKey { get throws { try P256.Signing.PrivateKey(rawRepresentation: privateBytes) } }
    }

    private static func loadRoot(account: String) throws -> Root {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Medio Local Audio TLS", kSecAttrAccount: account]
        var search = query
        search[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data,
           let root = try? JSONDecoder().decode(Root.self, from: data), root.expires.timeIntervalSinceNow > 8 * 86_400 {
            return root
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
        let key = P256.Signing.PrivateKey()
        let name = "Medio Local Audio \(UUID().uuidString.prefix(8))"
        let certificate = try SharingCertificate.make(subject: name, publicKey: key.publicKey,
            issuer: name, signingKey: key, isCA: true, host: nil, validDays: 1825)
        let root = Root(privateBytes: key.rawRepresentation, certificate: certificate, name: name,
            expires: Date().addingTimeInterval(1825 * 86_400))
        let data = try JSONEncoder().encode(root)
        let update = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary
        if status == errSecSuccess {
            let updated = SecItemUpdate(query as CFDictionary, update)
            guard updated == errSecSuccess else { throw Failure.keychain(updated) }
        } else {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        }
        return root
    }
}

/// Minimal DER encoding for the fixed certificate fields below (RFC 5280).
/// Keys and ECDSA/SHA-256 signatures are supplied by CryptoKit.
private enum SharingCertificate {
    static func make(subject: String, publicKey: P256.Signing.PublicKey, issuer: String,
                     signingKey: P256.Signing.PrivateKey, isCA: Bool, host: String?, validDays: Double) throws -> Data {
        let algorithm = sequence(oid([1,2,840,10045,4,3,2]))
        let publicInfo = sequence(sequence(oid([1,2,840,10045,2,1]) + oid([1,2,840,10045,3,1,7])) + bits(publicKey.x963Representation))
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] = (serial[0] & 0x7f) | 1
        var extensions = extensionValue([2,5,29,19], critical: true,
            value: isCA ? sequence(tag(0x01, Data([0xff])) + integer(Data([0]))) : sequence(Data()))
        extensions += extensionValue([2,5,29,15], critical: true,
            value: tag(0x03, isCA ? Data([1, 0x06]) : Data([7, 0x80])))
        if !isCA {
            extensions += extensionValue([2,5,29,37], value: sequence(oid([1,3,6,1,5,5,7,3,1])))
            guard let host else { throw SharingTLSIdentity.Failure.invalidHost }
            var ipv4 = in_addr(), ipv6 = in6_addr()
            let ip: Data
            if inet_pton(AF_INET, host, &ipv4) == 1 { ip = withUnsafeBytes(of: ipv4) { Data($0) } }
            else if inet_pton(AF_INET6, host, &ipv6) == 1 { ip = withUnsafeBytes(of: ipv6) { Data($0) } }
            else { throw SharingTLSIdentity.Failure.invalidHost }
            extensions += extensionValue([2,5,29,17], value: sequence(tag(0x87, ip)))
        }
        let validity = sequence(time(Date().addingTimeInterval(-300)) + time(Date().addingTimeInterval(validDays * 86_400)))
        let fields = tag(0xa0, integer(Data([2]))) + integer(serial) + algorithm + name(issuer)
            + validity + name(subject) + publicInfo + tag(0xa3, sequence(extensions))
        let tbs = sequence(fields)
        let signature = try signingKey.signature(for: tbs).derRepresentation
        return sequence(tbs + algorithm + bits(signature))
    }

    private static func name(_ value: String) -> Data { sequence(tag(0x31, sequence(oid([2,5,4,3]) + tag(0x0c, Data(value.utf8))))) }
    private static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tag(0x17, Data(formatter.string(from: date).utf8))
    }
    private static func extensionValue(_ id: [UInt64], critical: Bool = false, value: Data) -> Data {
        sequence(oid(id) + (critical ? tag(0x01, Data([0xff])) : Data()) + tag(0x04, value))
    }
    private static func integer(_ value: Data) -> Data { tag(0x02, value) }
    private static func bits(_ value: Data) -> Data { tag(0x03, Data([0]) + value) }
    private static func sequence(_ value: Data) -> Data { tag(0x30, value) }
    private static func oid(_ components: [UInt64]) -> Data {
        var data = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var value = component, bytes = [UInt8(value & 127)]
            value >>= 7
            while value > 0 { bytes.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
            data.append(contentsOf: bytes)
        }
        return tag(0x06, data)
    }
    private static func tag(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count
        var header = Data([tag])
        if length < 128 { header.append(UInt8(length)) }
        else {
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            header.append(0x80 | UInt8(bytes.count)); header.append(contentsOf: bytes)
        }
        return header + value
    }
}
