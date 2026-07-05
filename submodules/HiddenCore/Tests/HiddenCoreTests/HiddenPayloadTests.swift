import XCTest
@testable import HiddenCore

final class HiddenPayloadTests: XCTestCase {

    func testTextIsRawUTF8AndDecodesBack() {
        let payload = HiddenPayload.text("привет 👋")
        let wire = payload.encode()
        // Legacy compatibility: text on the wire is plain UTF-8, no framing.
        XCTAssertEqual(wire, Data("привет 👋".utf8))
        XCTAssertEqual(HiddenPayload.decode(wire), payload)
    }

    func testLegacyPlainBytesDecodeAsText() {
        // A raw message from the old desktop peer (no framing) must read as text.
        let raw = Data("hello from desktop".utf8)
        XCTAssertEqual(HiddenPayload.decode(raw), .text("hello from desktop"))
    }

    func testMediaMetaRoundTrip() {
        let meta = HiddenMediaMeta(fileId: "f1", kind: 1, filename: "clip.mp4",
                                   mime: "video/mp4", size: 999_999, chunks: 21,
                                   width: 1920, height: 1080, durationMs: 12345)
        let decoded = HiddenPayload.decode(HiddenPayload.mediaMeta(meta).encode())
        XCTAssertEqual(decoded, .mediaMeta(meta))
    }

    func testMediaChunkRoundTrip() {
        let bytes = Data((0..<300).map { UInt8($0 & 0xff) })
        let payload = HiddenPayload.mediaChunk(fileId: "f1", index: 3, total: 21, data: bytes)
        let decoded = HiddenPayload.decode(payload.encode())
        XCTAssertEqual(decoded, payload)
    }

    func testMagicPrefixIsNotValidTextStart() {
        // The media magic starts with NUL, which real text messages never do.
        XCTAssertEqual(HiddenPayload.magic.first, 0x00)
    }
}
