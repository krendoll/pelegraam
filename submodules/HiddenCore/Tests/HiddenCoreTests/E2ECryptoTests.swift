import XCTest
@testable import HiddenCore

final class E2ECryptoTests: XCTestCase {

    func testRoundTrip() {
        let plaintext = Data("привет hidden world".utf8)
        guard let blob = E2ECrypto.encrypt(plaintext) else { return XCTFail("encrypt") }
        // Layout: [iv 12][tag 16][ct N], ct length == plaintext length for GCM.
        XCTAssertEqual(blob.count, E2ECrypto.ivSize + E2ECrypto.tagSize + plaintext.count)
        guard let back = E2ECrypto.decrypt(blob) else { return XCTFail("decrypt") }
        XCTAssertEqual(back, plaintext)
    }

    func testTamperFails() {
        guard var blob = E2ECrypto.encrypt(Data("secret".utf8)) else { return XCTFail() }
        blob[blob.count - 1] ^= 0x01 // flip a ciphertext bit
        XCTAssertNil(E2ECrypto.decrypt(blob))
    }

    func testWrongKeyFails() {
        guard let blob = E2ECrypto.encrypt(Data("secret".utf8)) else { return XCTFail() }
        var otherKey = E2ECrypto.devPSK
        otherKey[0] ^= 0xff
        XCTAssertNil(E2ECrypto.decrypt(blob, key: otherKey))
    }

    func testTooShortBlob() {
        XCTAssertNil(E2ECrypto.decrypt(Data([0, 1, 2])))
    }

    /// Guards against silent drift from the desktop PSK (e2e_crypto.h kDevPsk).
    func testDevPSKConstant() {
        XCTAssertEqual(E2ECrypto.devPSK.count, 32)
        XCTAssertEqual(E2ECrypto.devPSK.first, 0x6b)
        XCTAssertEqual(E2ECrypto.devPSK.last, 0x4b)
    }
}
