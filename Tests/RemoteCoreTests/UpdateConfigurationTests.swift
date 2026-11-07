import XCTest
@testable import RemoteCore

final class UpdateConfigurationTests: XCTestCase {
    private let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    func testNoReleaseConfigurationDoesNotEnableNetworkChecks() {
        XCTAssertEqual(UpdateConfiguration(info: [:]), .unconfigured)
        XCTAssertEqual(UpdateConfiguration(info: ["SUFeedURL": "", "SUPublicEDKey": ""]), .unconfigured)
    }

    func testOnlyHTTPSWithCompletePublicKeyEnablesUpdates() {
        XCTAssertEqual(UpdateConfiguration(info: ["SUFeedURL": "https://updates.example/appcast.xml", "SUPublicEDKey": publicKey]), .configured)
        for url in ["http://updates.example/appcast.xml", "file:///tmp/appcast.xml", "https://", "https://user:secret@example.com/feed", "https://example.com/feed?token=x", "https://example.com/feed#section"] {
            XCTAssertEqual(UpdateConfiguration(info: ["SUFeedURL": url, "SUPublicEDKey": publicKey]), .invalid, url)
        }
        for key in ["", "not-base64", Data(repeating: 7, count: 31).base64EncodedString(), publicKey + "\n"] {
            XCTAssertEqual(UpdateConfiguration(info: ["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": key]), .invalid)
        }
        XCTAssertEqual(UpdateConfiguration(info: ["SUPublicEDKey": publicKey]), .invalid)
        XCTAssertEqual(UpdateConfiguration(info: ["SUFeedURL": 42]), .invalid)
    }
}
