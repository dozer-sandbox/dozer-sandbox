import CryptoKit
import SwiftASN1
import Foundation
import X509

// Feature 580 Phase 2 — one certificate authority PER SANDBOX, trusted inside that sandbox only.
//
// The proxy decrypts TLS only for hosts it injects a credential into (and hosts whose rules need a
// method or path), presenting a leaf certificate this CA signs on the fly. The CA's private key
// stays on the Mac, in the sandbox's own directory of the store (0600); the guest receives only
// the certificate, which is installed into its trust store at every fresh boot. Deleting the
// sandbox deletes its CA. ECDSA P-256 throughout.

/// One certificate authority per sandbox (580): signs the leaf certificates the proxy presents
/// for hosts it decrypts. The private key never leaves the Mac; the guest gets only the certificate.
public final class SandboxCA: @unchecked Sendable {
    public let certificatePEM: String
    let certificate: Certificate
    private let key: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var leaves: [String: (certificatePEM: String, keyPEM: String, created: Date)] = [:]

    /// The certificate's SHA-256 over its DER bytes, hex (for display and tests).
    public let fingerprint: String

    init(certificate: Certificate, key: P256.Signing.PrivateKey) throws {
        self.certificate = certificate
        self.key = key
        certificatePEM = try certificate.serializeAsPEM().pemString
        fingerprint = SHA256.hash(data: Data(try Self.der(certificate))).map { String(format: "%02x", $0) }.joined()
    }

    /// A new CA for `sandbox`, valid for ten years.
    public static func generate(sandbox: String, now: Date = Date()) throws -> SandboxCA {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            OrganizationName("DozerKit sandbox proxy")
            CommonName("Sandbox \(sandbox) egress CA")
        }
        let ca = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(10 * 365 * 86400),
            issuer: name, subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
            },
            issuerPrivateKey: Certificate.PrivateKey(key))
        return try SandboxCA(certificate: ca, key: key)
    }

    /// The CA stored in `directory` (`egress-ca.pem` + `egress-ca-key.pem`), or a new one written there.
    public static func loadOrCreate(in directory: URL, sandbox: String) throws -> SandboxCA {
        let fm = FileManager.default
        let certURL = directory.appendingPathComponent("egress-ca.pem")
        let keyURL = directory.appendingPathComponent("egress-ca-key.pem")
        if let c = try? String(contentsOf: certURL, encoding: .utf8), let k = try? String(contentsOf: keyURL, encoding: .utf8),
           let cert = try? Certificate(pemEncoded: c), let key = try? P256.Signing.PrivateKey(pemRepresentation: k),
           cert.notValidAfter > Date().addingTimeInterval(86400) {
            return try SandboxCA(certificate: cert, key: key)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ca = try generate(sandbox: sandbox)
        try? fm.removeItem(at: keyURL)
        guard fm.createFile(atPath: keyURL.path, contents: Data(ca.key.pemRepresentation.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw SandboxError.invalidSpec("cannot write the sandbox CA key in \(directory.path)")
        }
        try ca.certificatePEM.write(to: certURL, atomically: true, encoding: .utf8)
        return ca
    }

    /// A leaf certificate for `host` (cached for the life of this object), valid 1 hour back to
    /// 7 days ahead of `now`, with the host as its only subject alternative name.
    public func leaf(for host: String, now: Date = Date()) throws -> (certificatePEM: String, keyPEM: String) {
        let h = host.lowercased()
        lock.lock()
        if let l = leaves[h], now.timeIntervalSince(l.created) < 3 * 86400 { lock.unlock(); return (l.certificatePEM, l.keyPEM) }
        lock.unlock()
        let leafKey = P256.Signing.PrivateKey()
        let san: GeneralName = IPv4CIDR.parseAddress(h) != nil
            ? .ipAddress(ASN1OctetStringShim.bytes(h)) : .dnsName(h)
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(7 * 86400),
            issuer: certificate.subject,
            subject: try DistinguishedName { CommonName(h) },
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
            },
            issuerPrivateKey: Certificate.PrivateKey(key))
        let pem = try cert.serializeAsPEM().pemString
        lock.lock()
        leaves[h] = (pem, leafKey.pemRepresentation, now)
        lock.unlock()
        return (pem, leafKey.pemRepresentation)
    }

    static func der(_ c: Certificate) throws -> [UInt8] {
        let pem = try c.serializeAsPEM().pemString
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Array(Data(base64Encoded: b64) ?? Data())
    }
}

/// `GeneralName.ipAddress` wants the address as raw octets.
enum ASN1OctetStringShim {
    static func bytes(_ ip: String) -> ASN1OctetString {
        let v = IPv4CIDR.parseAddress(ip) ?? 0
        return ASN1OctetString(contentBytes: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
}
