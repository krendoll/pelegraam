import XCTest
@testable import HiddenCore

final class HiddenPeersTests: XCTestCase {

    func testAddContainsRemovePersistsInMemory() {
        let id = Int64.random(in: 1_000_000...9_000_000)
        XCTAssertFalse(HiddenPeers.shared.contains(id))
        HiddenPeers.shared.add(id)
        XCTAssertTrue(HiddenPeers.shared.contains(id))
        XCTAssertTrue(HiddenPeers.shared.all().contains(id))
        HiddenPeers.shared.remove(id)
        XCTAssertFalse(HiddenPeers.shared.contains(id))
    }

    func testZeroIsIgnored() {
        HiddenPeers.shared.add(0)
        XCTAssertFalse(HiddenPeers.shared.contains(0))
    }
}
