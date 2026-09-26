import XCTest
@testable import MilktoastCore

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(
            SHA256Digest.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256Digest.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256Digest.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testMultiBlockInputCrossesThePaddingBoundary() {
        // 64 bytes exactly: forces a second padding block.
        XCTAssertEqual(
            SHA256Digest.hex(String(repeating: "a", count: 64)),
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        )
        XCTAssertEqual(
            SHA256Digest.hex(String(repeating: "a", count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testDigestLength() {
        XCTAssertEqual(SHA256Digest.digest(Array("hello".utf8)).count, 32)
    }
}
