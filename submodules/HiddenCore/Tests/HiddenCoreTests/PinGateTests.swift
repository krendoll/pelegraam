import XCTest
@testable import HiddenCore

final class PinGateTests: XCTestCase {

    func testValidPin() {
        XCTAssertTrue(PinGate.isPinCandidate("1234"))
        XCTAssertTrue(PinGate.isPinCandidate("0000"))
        XCTAssertTrue(PinGate.isPinCandidate("  9876  ")) // trimmed
    }

    func testRejects() {
        XCTAssertFalse(PinGate.isPinCandidate("123"))    // too short
        XCTAssertFalse(PinGate.isPinCandidate("12345"))  // too long
        XCTAssertFalse(PinGate.isPinCandidate("12a4"))   // non-digit
        XCTAssertFalse(PinGate.isPinCandidate("hello"))
        XCTAssertFalse(PinGate.isPinCandidate(""))
        XCTAssertFalse(PinGate.isPinCandidate("१२३४"))   // non-ASCII digits
    }
}
