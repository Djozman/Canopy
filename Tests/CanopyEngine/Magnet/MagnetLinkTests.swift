import XCTest
@testable import CanopyEngine

final class MagnetLinkTests: XCTestCase {

    func testParseHexHash() {
        let uri = "magnet:?xt=urn:btih:3b1de9cb7011350fa152ec47419620aa153e19e7"
        let link = MagnetLink.parse(uri)
        XCTAssertNotNil(link)
        XCTAssertEqual(link?.infoHash.hexString, "3b1de9cb7011350fa152ec47419620aa153e19e7")
        XCTAssertNil(link?.displayName)
        XCTAssertEqual(link?.trackers.count, 0)
    }

    func testParseUppercaseHex() {
        let uri = "magnet:?xt=urn:btih:3B1DE9CB7011350FA152EC47419620AA153E19E7"
        let link = MagnetLink.parse(uri)
        XCTAssertNotNil(link)
        XCTAssertEqual(link?.infoHash.hexString, "3b1de9cb7011350fa152ec47419620aa153e19e7")
    }

    func testParseBase32Hash() {
        // 32-char base32 equivalent of all-zeros
        let uri = "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let link = MagnetLink.parse(uri)
        XCTAssertNotNil(link)
        XCTAssertEqual(link?.infoHash.count, 20)
    }

    func testParseWithDisplayName() {
        let uri = "magnet:?xt=urn:btih:3b1de9cb7011350fa152ec47419620aa153e19e7&dn=Hello%20World"
        let link = MagnetLink.parse(uri)
        XCTAssertEqual(link?.displayName, "Hello World")
    }

    func testParseMultipleTrackers() {
        let uri = "magnet:?xt=urn:btih:3b1de9cb7011350fa152ec47419620aa153e19e7&tr=http%3A%2F%2Ftracker1.com&tr=http%3A%2F%2Ftracker2.com"
        let link = MagnetLink.parse(uri)
        XCTAssertEqual(link?.trackers.count, 2)
        XCTAssertEqual(link?.trackers[0], "http://tracker1.com")
        XCTAssertEqual(link?.trackers[1], "http://tracker2.com")
    }

    func testMissingXtReturnsNil() {
        let uri = "magnet:?dn=test"
        XCTAssertNil(MagnetLink.parse(uri))
    }

    func testInvalidHashLengthReturnsNil() {
        let uri = "magnet:?xt=urn:btih:3b1de9cb"
        XCTAssertNil(MagnetLink.parse(uri))
    }

    func testNonMagnetReturnsNil() {
        XCTAssertNil(MagnetLink.parse("http://example.com"))
    }
}
