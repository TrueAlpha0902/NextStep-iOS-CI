import Foundation
@testable import NextStepPersistence
import XCTest

final class ContentDigestTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(
            ContentDigest(hashing: Data()).hex,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ContentDigest(hashing: Data("abc".utf8)).hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testValidatingDigestNormalizesUppercaseAndPreservesRawBytes() throws {
        let lowercase =
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let digest = try ContentDigest(validating: lowercase.uppercased())

        XCTAssertEqual(digest.hex, lowercase)
        XCTAssertEqual(digest.rawBytes.count, 32)
        XCTAssertEqual(try ContentDigest(rawBytes: digest.rawBytes), digest)
    }

    func testRawDigestRequiresExactly32Bytes() {
        XCTAssertThrowsError(try ContentDigest(rawBytes: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try ContentDigest(rawBytes: Data(repeating: 0, count: 33)))
    }

    func testValidatingDigestRejects63Characters() {
        assertInvalid(String(repeating: "a", count: 63))
    }

    func testValidatingDigestRejects65Characters() {
        assertInvalid(String(repeating: "a", count: 65))
    }

    func testValidatingDigestRejectsNonHexASCII() {
        assertInvalid(String(repeating: "a", count: 63) + "g")
    }

    func testValidatingDigestRejectsWhitespace() {
        assertInvalid(String(repeating: "a", count: 63) + " ")
        assertInvalid(" " + String(repeating: "a", count: 64))
    }

    func testValidatingDigestRejectsUnicode() {
        assertInvalid(String(repeating: "a", count: 63) + "\u{00E9}")
        assertInvalid(String(repeating: "\u{FF21}", count: 64))
    }

    func testSingleValueDecodingValidatesAndNormalizes() throws {
        let uppercase = String(repeating: "A", count: 64)
        let decoded = try JSONDecoder().decode(
            ContentDigest.self,
            from: try JSONEncoder().encode(uppercase)
        )

        XCTAssertEqual(decoded.hex, String(repeating: "a", count: 64))
        XCTAssertThrowsError(try JSONDecoder().decode(
            ContentDigest.self,
            from: try JSONEncoder().encode(String(repeating: "z", count: 64))
        )) { error in
            XCTAssertEqual(error as? PersistenceError, .invalidDigest)
        }
    }

    private func assertInvalid(
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ContentDigest(validating: value),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .invalidDigest,
                file: file,
                line: line
            )
        }
    }
}
