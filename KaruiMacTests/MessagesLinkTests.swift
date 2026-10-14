import XCTest
@testable import KaruiMac

final class MessagesLinkTests: XCTestCase {
    func testOnePersonOpensTheirThread() {
        XCTAssertEqual(MessagesLink.url(handles: ["+819012345678"])?.absoluteString, "sms:+819012345678")
        XCTAssertEqual(MessagesLink.url(handles: ["ada@example.com"])?.absoluteString, "sms:ada@example.com")
    }

    func testAGroupListsEveryone() {
        XCTAssertEqual(
            MessagesLink.url(handles: ["+819012345678", "ada@example.com"])?.absoluteString,
            "sms://open?addresses=+819012345678,ada@example.com"
        )
    }

    func testNoHandlesMeansNoLink() {
        XCTAssertNil(MessagesLink.url(handles: []))
    }
}
