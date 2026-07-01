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
            ChatEntry(title: "Боб", lastMessage: "привет"),
        ])
        let data = Container.serialise(state)
        // First 4 bytes must be the desktop magic 0x01545648 (LE): 48 56 54 01.
        XCTAssertEqual([UInt8](data.prefix(4)), [0x48, 0x56, 0x54, 0x01])
        guard let parsed = Container.deserialise(data) else { return XCTFail("deserialise") }
        XCTAssertEqual(parsed, state)
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
