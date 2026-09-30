import CryptoKit
import Foundation

enum OpenSSHKeyError: Error, Equatable, LocalizedError {
    case notOpenSSHFormat
    case encrypted
    case unsupportedAlgorithm(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notOpenSSHFormat: "Paste a private key that begins with “-----BEGIN OPENSSH PRIVATE KEY-----”."
        case .encrypted: "Passphrase-protected keys aren't supported yet. Generate a key in the app, or import an unencrypted copy."
        case .unsupportedAlgorithm(let name): "“\(name)” keys aren't supported. Use an Ed25519 or ECDSA P-256 key."
        case .malformed: "The private key couldn't be read."
        }
    }
}

enum OpenSSHKeys {
    static func generateEd25519() -> SSHPrivateKeyMaterial {
        SSHPrivateKeyMaterial(algorithm: .ed25519, rawRepresentation: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    static func publicKeyBlob(for material: SSHPrivateKeyMaterial) throws -> Data {
        var writer = SSHWireWriter()
        switch material.algorithm {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: material.rawRepresentation)
            writer.write(string: Data(SSHKeyAlgorithm.ed25519.rawValue.utf8))
            writer.write(string: key.publicKey.rawRepresentation)
        case .ecdsaP256:
            let key = try P256.Signing.PrivateKey(rawRepresentation: material.rawRepresentation)
            writer.write(string: Data(SSHKeyAlgorithm.ecdsaP256.rawValue.utf8))
            writer.write(string: Data("nistp256".utf8))
            writer.write(string: key.publicKey.x963Representation)
        }
        return writer.data
    }

    static func authorizedKeysLine(for material: SSHPrivateKeyMaterial, comment: String) throws -> String {
        "\(material.algorithm.rawValue) \(try publicKeyBlob(for: material).base64EncodedString()) \(comment)"
    }

    /// OpenSSH-style `SHA256:` fingerprint of a public key blob.
    static func fingerprint(ofBlob blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Fingerprint of a public key in `authorized_keys` form: `<type> <base64> [comment]`.
    static func fingerprint(ofOpenSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return fingerprint(ofBlob: blob)
    }

    /// Parses an unencrypted `openssh-key-v1` private key.
    static func parsePrivateKey(_ text: String) throws -> SSHPrivateKeyMaterial {
        let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let footer = "-----END OPENSSH PRIVATE KEY-----"
        guard let start = text.range(of: header), let end = text.range(of: footer), start.upperBound <= end.lowerBound else {
            throw OpenSSHKeyError.notOpenSSHFormat
        }
        let body = text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else { throw OpenSSHKeyError.malformed }

        var reader = SSHWireReader(data)
        let magic = Data("openssh-key-v1".utf8) + Data([0])
        guard try reader.read(count: magic.count) == magic else { throw OpenSSHKeyError.notOpenSSHFormat }
        let cipher = try reader.readUTF8()
        let kdf = try reader.readUTF8()
        _ = try reader.readString()
        guard cipher == "none", kdf == "none" else { throw OpenSSHKeyError.encrypted }
        guard try reader.readUInt32() == 1 else { throw OpenSSHKeyError.malformed }
        _ = try reader.readString()

        var section = SSHWireReader(try reader.readString())
        guard try section.readUInt32() == section.readUInt32() else { throw OpenSSHKeyError.malformed }
        let type = try section.readUTF8()
        switch type {
        case SSHKeyAlgorithm.ed25519.rawValue:
            _ = try section.readString()
            let secret = try section.readString()
            guard secret.count == 64 else { throw OpenSSHKeyError.malformed }
            let material = SSHPrivateKeyMaterial(algorithm: .ed25519, rawRepresentation: secret.prefix(32))
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: material.rawRepresentation)
            return material
        case SSHKeyAlgorithm.ecdsaP256.rawValue:
            guard try section.readUTF8() == "nistp256" else { throw OpenSSHKeyError.malformed }
            _ = try section.readString()
            var scalar = try section.readString()
            while scalar.count > 32, scalar.first == 0 { scalar = scalar.dropFirst() }
            guard scalar.count <= 32 else { throw OpenSSHKeyError.malformed }
            let padded = Data(repeating: 0, count: 32 - scalar.count) + scalar
            let material = SSHPrivateKeyMaterial(algorithm: .ecdsaP256, rawRepresentation: padded)
            _ = try P256.Signing.PrivateKey(rawRepresentation: material.rawRepresentation)
            return material
        default:
            throw OpenSSHKeyError.unsupportedAlgorithm(type)
        }
    }
}

struct SSHWireWriter {
    private(set) var data = Data()

    mutating func write(uint32 value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func write(string value: Data) {
        write(uint32: UInt32(value.count))
        data.append(value)
    }
}

struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw OpenSSHKeyError.malformed }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt32() throws -> UInt32 {
        try read(count: 4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func readString() throws -> Data {
        try read(count: Int(readUInt32()))
    }

    mutating func readUTF8() throws -> String {
        guard let value = String(data: try readString(), encoding: .utf8) else { throw OpenSSHKeyError.malformed }
        return value
    }
}
