import CryptoKit
import Foundation

/// A canonical SHA-256 digest.
///
/// The public representation is a normalized, lowercase hexadecimal string.
/// SQLite adapters in this module use `rawBytes` so the database stores the
/// digest as exactly 32 bytes instead of duplicating its textual encoding.
public struct ContentDigest: Codable, Comparable, CustomStringConvertible,
    Hashable, Sendable {
    private static let rawByteCount = 32

    public let hex: String

    public init(validating hex: String) throws {
        guard hex.utf8.count == 64,
              hex.unicodeScalars.allSatisfy(Self.isASCIIHexDigit) else {
            throw PersistenceError.invalidDigest
        }
        self.hex = hex.lowercased()
    }

    public init(hashing data: Data) {
        hex = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    internal init(rawBytes: Data) throws {
        guard rawBytes.count == Self.rawByteCount else {
            throw PersistenceError.invalidDigest
        }
        hex = rawBytes.map { String(format: "%02x", $0) }.joined()
    }

    internal var rawBytes: Data {
        let characters = Array(hex.utf8)
        var result = Data()
        result.reserveCapacity(Self.rawByteCount)
        for index in stride(from: 0, to: characters.count, by: 2) {
            let high = Self.hexValue(characters[index])
            let low = Self.hexValue(characters[index + 1])
            result.append((high << 4) | low)
        }
        return result
    }

    public var description: String { hex }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.hex < rhs.hex
    }

    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30 ... 0x39).contains(scalar.value)
            || (0x41 ... 0x46).contains(scalar.value)
            || (0x61 ... 0x66).contains(scalar.value)
    }

    private static func hexValue(_ character: UInt8) -> UInt8 {
        switch character {
        case 0x30 ... 0x39:
            character - 0x30
        case 0x61 ... 0x66:
            character - 0x61 + 10
        default:
            preconditionFailure("ContentDigest always stores normalized hexadecimal.")
        }
    }
}
