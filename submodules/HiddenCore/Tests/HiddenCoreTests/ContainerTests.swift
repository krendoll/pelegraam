import XCTest
@testable import HiddenCore

final class ContainerTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSerialiseRoundTrip() {
        let state = VaultState(chats: [
            ChatEntry(title: "Alice", lastMessage: "hi"),
            ChatEntry(title: "Боб", lastMessage: "привет", peerId: -1001234567890),
        ], hideOnline: true)
        let data = Container.serialise(state)
        // V2 magic 0x02545648 (LE): 48 56 54 02.
        XCTAssertEqual([UInt8](data.prefix(4)), [0x48, 0x56, 0x54, 0x02])
        guard let parsed = Container.deserialise(data) else { return XCTFail("deserialise") }
        XCTAssertEqual(parsed, state)
        XCTAssertTrue(parsed.hideOnline)
        XCTAssertEqual(parsed.chats[1].peerId, -1001234567890)
    }

    func testDeserialiseV1BackwardCompat() {
        // A V1 blob (magic 0x01545648, no hideOnline, no peerId) must still read.
        var v1 = Data([0x48, 0x56, 0x54, 0x01])       // magic V1
        v1.append(contentsOf: [0x01, 0, 0, 0])         // count = 1
        let title = Data("Old".utf8)
        v1.append(contentsOf: [UInt8(title.count), 0, 0, 0]); v1.append(title)
        v1.append(contentsOf: [0, 0, 0, 0])            // msg len = 0
        guard let parsed = Container.deserialise(v1) else { return XCTFail("v1 deserialise") }
        XCTAssertEqual(parsed.chats, [ChatEntry(title: "Old", lastMessage: "", peerId: 0)])
        XCTAssertFalse(parsed.hideOnline)
    }

    func testBootstrapThenReopen() {
        let dir = makeTempDir()
        let c1 = Container(vaultDirectory: dir)
        XCTAssertTrue(c1.open(pin: SecurePIN("1234")))
        XCTAssertTrue(c1.isOpen)
        XCTAssertEqual(c1.state.chats.count, 0)

        // Add a chat and persist.
        c1.addChat(ChatEntry(title: "Vault", lastMessage: "created"))
        XCTAssertTrue(c1.save())
        c1.close()
        XCTAssertFalse(c1.isOpen)

        // Reopen with the same PIN from disk.
        let c2 = Container(vaultDirectory: dir)
        XCTAssertTrue(c2.open(pin: SecurePIN("1234")))
        XCTAssertEqual(c2.state.chats, [ChatEntry(title: "Vault", lastMessage: "created")])
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
}
