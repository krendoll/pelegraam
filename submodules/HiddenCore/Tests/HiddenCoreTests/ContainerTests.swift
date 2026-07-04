import XCTest
@testable import HiddenCore

final class ContainerTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSerialiseRoundTripV5() {
        let media = MediaRef(id: "blob-1", kind: .image, filename: "a.jpg",
                             mime: "image/jpeg", size: 1234, width: 640, height: 480,
                             segmentBytes: 512 * 1024)
        let state = VaultState(
            hideOnline: true,
            autoDeleteDays: 7,
            conversations: [
                Conversation(id: "c1", kind: .relayPerson, title: "Alice",
                             relayToken: "tok", messages: [
                                StoredMessage(id: "m1", text: "hi", outgoing: true, timestamp: 100),
                                StoredMessage(id: "m2", text: "", outgoing: false, timestamp: 200, media: media),
                             ]),
                Conversation(id: "peer-x", kind: .telegramHidden, title: "Боб",
                             peerId: -1001234567890),
            ])
        let data = Container.serialise(state)
        // V5 magic 0x05545648 (LE): 48 56 54 05.
        XCTAssertEqual([UInt8](data.prefix(4)), [0x48, 0x56, 0x54, 0x05])
        guard let parsed = Container.deserialise(data) else { return XCTFail("deserialise") }
        XCTAssertEqual(parsed, state)
        XCTAssertTrue(parsed.hideOnline)
        XCTAssertEqual(parsed.autoDeleteDays, 7)
        XCTAssertEqual(parsed.conversations[1].peerId, -1001234567890)
        XCTAssertEqual(parsed.conversations[0].messages[1].media?.width, 640)
        XCTAssertEqual(parsed.conversations[0].messages[1].media?.segmentBytes, 512 * 1024)
    }

    func testMigrateV3ToConversations() {
        // Build a legacy V3 blob: hideOnline, one hidden chat, one relay message.
        var v3 = Data([0x48, 0x56, 0x54, 0x03])            // magic V3
        v3.append(0x01)                                    // hideOnline = true
        v3.append(contentsOf: [0x01, 0, 0, 0])             // chat count = 1
        let title = Data("Боб".utf8)
        v3.append(contentsOf: le32(UInt32(title.count))); v3.append(title)
        v3.append(contentsOf: [0, 0, 0, 0])                // lastMessage len = 0
        v3.append(contentsOf: le64(UInt64(bitPattern: -42)))   // peerId
        v3.append(contentsOf: [0x01, 0, 0, 0])             // message count = 1
        let text = Data("hello".utf8)
        v3.append(contentsOf: le32(UInt32(text.count))); v3.append(text)
        v3.append(0x01)                                    // outgoing = true
        v3.append(contentsOf: le64((100.0).bitPattern))    // timestamp

        guard let parsed = Container.deserialise(v3) else { return XCTFail("v3 migrate") }
        XCTAssertTrue(parsed.hideOnline)
        // legacy-relay conversation carries the flat message history.
        let relay = parsed.conversations.first { $0.id == "legacy-relay" }
        XCTAssertEqual(relay?.kind, .relayPerson)
        XCTAssertEqual(relay?.messages.first?.text, "hello")
        // The peer chat becomes a telegramHidden conversation.
        let hidden = parsed.conversations.first { $0.kind == .telegramHidden }
        XCTAssertEqual(hidden?.peerId, -42)
        XCTAssertEqual(hidden?.title, "Боб")
    }

    func testBootstrapThenReopenSeedsNothing() {
        let dir = makeTempDir()
        let c1 = Container(vaultDirectory: dir)
        XCTAssertTrue(c1.open(pin: SecurePIN("1234")))
        XCTAssertTrue(c1.isOpen)
        XCTAssertEqual(c1.state.conversations.count, 0)

        c1.mutateState {
            $0.conversations.append(Conversation(id: "c1", kind: .relayPerson,
                                                 title: "Vault", relayToken: "t"))
        }
        XCTAssertTrue(c1.save())
        c1.close()

        let c2 = Container(vaultDirectory: dir)
        XCTAssertTrue(c2.open(pin: SecurePIN("1234")))
        XCTAssertEqual(c2.state.conversations.first?.title, "Vault")
    }

    func testBlobEncryptRoundTrip() {
        let dir = makeTempDir()
        let c = Container(vaultDirectory: dir)
        XCTAssertTrue(c.open(pin: SecurePIN("4321")))
        let payload = Data((0..<5000).map { UInt8($0 & 0xff) })
        guard let sealed = c.encryptBlob(payload) else { return XCTFail("encryptBlob") }
        XCTAssertNotEqual(sealed, payload)
        XCTAssertEqual(c.decryptBlob(sealed), payload)
    }

    func testWrongPinFails() {
        let dir = makeTempDir()
        let c1 = Container(vaultDirectory: dir)
        XCTAssertTrue(c1.open(pin: SecurePIN("1234")))
        c1.close()

        let c2 = Container(vaultDirectory: dir)
        XCTAssertFalse(c2.open(pin: SecurePIN("9999")))
        XCTAssertFalse(c2.isOpen)
    }

    // MARK: helpers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    private func le64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> (8 * $0)) & 0xff) }
    }
}
