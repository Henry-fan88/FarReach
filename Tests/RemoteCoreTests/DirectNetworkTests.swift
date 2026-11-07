import XCTest
import dnssd
@testable import RemoteCore

final class DirectNetworkTests: XCTestCase {
    func testPublicAddressCandidatesExcludeSpecialRanges() {
        for address in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertEqual(DirectNetworkSnapshot.classify(address), .global, address)
        }
        for address in ["0.0.0.0", "0.1.2.3", "192.0.2.1", "198.51.100.24", "203.0.113.99", "198.18.0.1", "198.19.1.1", "224.0.0.1", "255.255.255.255", "::", "::ffff:8.8.8.8", "ff02::1", "2001:db8::1", "2001:2::1", "2001:20::1", "2002:0808:0808::1", "3fff::1"] {
            XCTAssertEqual(DirectNetworkSnapshot.classify(address), .reserved, address)
        }
        for address in ["", "999.1.1.1", "example.com", "[::1]", "fe80::1%en0", "1.2.3.4\n"] {
            XCTAssertEqual(DirectNetworkSnapshot.classify(address), .invalid, address)
        }
    }
    func testPrivateCarrierAndLinkLocalClassifications() {
        for address in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.10.5", "fdfe:dcba:9876::1", "fc00::1"] {
            XCTAssertEqual(DirectNetworkSnapshot.classify(address), .privateNetwork, address)
        }
        XCTAssertEqual(DirectNetworkSnapshot.classify("172.32.0.1"), .global)
        XCTAssertEqual(DirectNetworkSnapshot.classify("100.64.0.1"), .sharedCarrierNAT)
        XCTAssertEqual(DirectNetworkSnapshot.classify("100.127.255.254"), .sharedCarrierNAT)
        XCTAssertEqual(DirectNetworkSnapshot.classify("100.128.0.1"), .global)
        for address in ["127.0.0.1", "127.12.34.56", "::1"] { XCTAssertEqual(DirectNetworkSnapshot.classify(address), .loopback) }
        for address in ["169.254.1.2", "fe80::1", "febf::1"] { XCTAssertEqual(DirectNetworkSnapshot.classify(address), .linkLocal) }
    }
    func testMappingMustReportPublicAddressTCPAndPorts() throws {
        let valid = try XCTUnwrap(result(address: "8.8.8.8"))
        XCTAssertEqual(valid.state, .mapped)
        XCTAssertEqual(valid.externalPort, 45678)
        XCTAssertTrue(valid.isPublicEndpointCandidate)
        XCTAssertNil(result(address: "0.0.0.0"), "Provisional zero address must wait for a subsequent callback or deadline")
        XCTAssertEqual(result(address: "192.168.1.2")?.state, .unavailable)
        XCTAssertFalse(try XCTUnwrap(result(address: "192.168.1.2")).isPublicEndpointCandidate)
        XCTAssertEqual(result(address: "8.8.8.8", externalPort: 0)?.state, .unavailable)
        XCTAssertEqual(result(address: "8.8.8.8", protocolValue: UInt32(kDNSServiceProtocol_UDP))?.state, .unavailable)
        XCTAssertEqual(result(address: "8.8.8.8", error: Int32(kDNSServiceErr_DoubleNAT))?.state, .doubleNAT)
        XCTAssertFalse(try XCTUnwrap(result(address: "8.8.8.8", error: Int32(kDNSServiceErr_DoubleNAT))).isPublicEndpointCandidate)
    }
    func testInspectionNeverClaimsPortMappingAndFailureFieldsAreDiscarded() throws {
        let inspected = try XCTUnwrap(result(address: "8.8.8.8", readOnly: true))
        XCTAssertEqual(inspected.state, .externalAddress)
        XCTAssertTrue(inspected.readOnly)
        XCTAssertNil(inspected.internalPort)
        XCTAssertNil(inspected.externalPort)
        XCTAssertFalse(inspected.isPublicEndpointCandidate)
        let failure = try XCTUnwrap(result(address: "8.8.8.8", error: Int32(kDNSServiceErr_NATPortMappingUnsupported)))
        XCTAssertEqual(failure.state, .unavailable)
        XCTAssertNil(failure.externalAddress)
        XCTAssertNil(failure.internalPort)
        XCTAssertNil(failure.externalPort)
        XCTAssertEqual(failure.lifetime, 0)
    }
    private func result(address: String, error: Int32 = 0, readOnly: Bool = false,
                        externalPort: UInt16 = 45678, protocolValue: UInt32 = UInt32(kDNSServiceProtocol_TCP)) -> RouterMappingResult? {
        RouterMappingResult.evaluate(readOnly: readOnly, errorCode: error, externalAddress: address,
            protocolValue: protocolValue, internalPort: 9877, externalPort: externalPort, lifetime: 300)
    }
}
