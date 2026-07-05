import XCTest
@testable import HiddenCore

final class ProtocolTests: XCTestCase {

    private func object(_ data: Data) -> [String: String] {
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return raw.mapValues { "\($0)" }
    }

    func testOutboundAuth() {
        let o = object(RelayOutbound.auth(token: "abc").jsonData())
        XCTAssertEqual(o["t"], "auth")
        XCTAssertEqual(o["token"], "abc")
    }

    func testOutboundSend() {
        let o = object(RelayOutbound.send(msgId: "id1", blobBase64: "aGVsbG8=").jsonData())
        XCTAssertEqual(o["t"], "send")
        XCTAssertEqual(o["msg_id"], "id1")
        XCTAssertEqual(o["blob"], "aGVsbG8=")
    }

    func testOutboundAck() {
        let o = object(RelayOutbound.ack(msgId: "id2").jsonData())
        XCTAssertEqual(o["t"], "ack")
        XCTAssertEqual(o["msg_id"], "id2")
    }

    func testInboundParsing() {
        XCTAssertEqual(RelayInbound(jsonData: Data(#"{"t":"auth_ok"}"#.utf8)), .authOk)
        XCTAssertEqual(RelayInbound(jsonData: Data(#"{"t":"auth_err"}"#.utf8)), .authErr)
        XCTAssertEqual(RelayInbound(jsonData: Data(#"{"t":"queued"}"#.utf8)), .queued)

        let deliver = RelayInbound(jsonData: Data(#"{"t":"deliver","msg_id":"x","blob":"aGk="}"#.utf8))
        XCTAssertEqual(deliver, .deliver(msgId: "x", blobBase64: "aGk="))
    }

    func testInboundGarbage() {
        XCTAssertNil(RelayInbound(jsonData: Data("not json".utf8)))
    }
}

extension RelayInbound: Equatable {
    public static func == (lhs: RelayInbound, rhs: RelayInbound) -> Bool {
        switch (lhs, rhs) {
        case (.authOk, .authOk), (.authErr, .authErr), (.queued, .queued):
            return true
        case let (.deliver(a, b), .deliver(c, d)):
            return a == c && b == d
        case let (.unknown(a), .unknown(b)):
            return a == b
        default:
            return false
        }
    }
}
