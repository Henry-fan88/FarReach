import XCTest
@testable import RemoteCore

final class ProtocolTests: XCTestCase {
    func testInvitationRoundTripSupportsIPv4DNSAndIPv6() throws {
        let key = Data(0..<32)
        for host in ["100.101.102.103", "my-mac.tail123.ts.net", "192.168.1.12", "::1", "fd7a:115c:a1e0::1"] {
            let invitation = try PairingInvitation(host: host, port: 48888, key: key)
            XCTAssertEqual(try PairingInvitation(string: invitation.urlString), invitation)
        }
    }

    func testRejectsMalformedOrAmbiguousInvitations() throws {
        let valid = try PairingInvitation(host: "localhost", port: 48888, key: Data(repeating: 0x22, count: 32)).urlString
        for input in [
            valid.replacingOccurrences(of: "remotemac:", with: "http:"),
            valid.replacingOccurrences(of: "48888", with: "0"),
            valid.replacingOccurrences(of: "48888", with: "65536"),
            valid + "&key=duplicate", valid + "#fragment",
            valid.replacingOccurrences(of: "localhost", with: "user@localhost"),
            valid.replacingOccurrences(of: "?key=", with: "/path?key="),
            valid + "=", "remotemac://localhost:48888?key=a",
        ] { XCTAssertThrowsError(try PairingInvitation(string: input), input) }
        XCTAssertThrowsError(try PairingInvitation(host: "localhost\n.invalid", port: 1, key: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try PairingInvitation(host: "localhost", port: 1, key: Data(repeating: 0, count: 31)))
        for host in ["999.999.999.999", ":::1", "host..invalid", "-host.invalid"] {
            XCTAssertThrowsError(try PairingInvitation(host: host, port: 1, key: Data(repeating: 0, count: 32)))
        }
    }

    func testRandomKeysAreFullLengthAndDifferent() throws {
        let first = try PairingInvitation.generateKey()
        let second = try PairingInvitation.generateKey()
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(second.count, 32)
        XCTAssertNotEqual(first, second)
    }

    func testFramingUsesNetworkOrderAndBoundedLengths() throws {
        let payload = Data(repeating: 42, count: 300)
        let encoded = try WireMessage(kind: .video, payload: payload).encoded()
        XCTAssertEqual(Array(encoded.prefix(5)), [2, 0, 0, 1, 44])
        let header = try WireMessage.decodeHeader(Data(encoded.prefix(5)))
        XCTAssertEqual(header.kind, .video)
        XCTAssertEqual(header.length, 300)
        XCTAssertEqual(Data(encoded.dropFirst(5)), payload)
        XCTAssertThrowsError(try WireMessage.decodeHeader(Data([0, 0, 0, 0, 0])))
        XCTAssertThrowsError(try WireMessage.decodeHeader(Data([2, 255, 255, 255, 255])))
        XCTAssertThrowsError(try WireMessage.decodeHeader(Data([3, 0, 1, 0, 0])))
        XCTAssertThrowsError(try WireMessage.decodeHeader(Data([2, 0])))
        XCTAssertThrowsError(try WireMessage(kind: .ping, payload: Data(count: 33)).encoded())
    }

    func testHostInfoRejectsUnsupportedVersionAndDimensions() throws {
        XCTAssertTrue(HostInfo(name: "Mac", width: 1920, height: 1080).isValid)
        XCTAssertFalse(HostInfo(name: "Mac", width: Int.max, height: 1).isValid)
        let json = Data(#"{"protocolVersion":99,"name":"Mac","width":1920,"height":1080,"pointWidth":1920,"pointHeight":1080,"fps":30}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(HostInfo.self, from: json).isValid)
    }
}
