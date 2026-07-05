import XCTest
@testable import HiddenCore

final class BridgeEnvelopeTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testParseImageEnvelope() {
        let raw = Data([0x01, 0x02, 0x03, 0xff, 0x00, 0xa5])
        let b64 = raw.base64EncodedString()
        let pt = json("{\"t\":\"img\",\"mime\":\"image/jpeg\",\"b64\":\"\(b64)\",\"cap\":\"hello\"}")
        guard case let .image(mime, data, caption)? = BridgeEnvelope.parse(pt) else {
            return XCTFail("expected image")
        }
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertEqual(data, raw)
        XCTAssertEqual(caption, "hello")
    }

    func testImageDefaultsMimeAndCaption() {
        let b64 = Data([0x10, 0x20]).base64EncodedString()
        let pt = json("{\"t\":\"img\",\"b64\":\"\(b64)\"}")
        guard case let .image(mime, _, caption)? = BridgeEnvelope.parse(pt) else {
            return XCTFail("expected image")
        }
        XCTAssertEqual(mime, "image/png")   // bridge default
        XCTAssertEqual(caption, "")
    }

    func testPlainTextIsNotAnEnvelope() {
        XCTAssertNil(BridgeEnvelope.parse(Data("just some text".utf8)))
        // Even valid JSON that isn't our envelope -> nil (caller shows as text).
        XCTAssertNil(BridgeEnvelope.parse(json("{\"hello\":\"world\"}")))
    }

    func testUnknownTypeDegradesToNil() {
        XCTAssertNil(BridgeEnvelope.parse(json("{\"t\":\"video\",\"b64\":\"AAAA\"}")))
    }

    func testImageWithoutB64IsNil() {
        XCTAssertNil(BridgeEnvelope.parse(json("{\"t\":\"img\",\"mime\":\"image/png\"}")))
    }

    func testLeadingNulNeverParsed() {
        // iOS media frames start with NUL magic; must never be seen as a bridge envelope.
        XCTAssertNil(BridgeEnvelope.parse(Data([0x00, 0x48, 0x43, 0x4D, 0x01])))
    }

    func testImageExtensionMapping() {
        XCTAssertEqual(BridgeEnvelope.imageExtension(forMime: "image/jpeg"), "jpg")
        XCTAssertEqual(BridgeEnvelope.imageExtension(forMime: "image/png"), "png")
        XCTAssertEqual(BridgeEnvelope.imageExtension(forMime: "application/octet-stream"), "img")
    }
}
