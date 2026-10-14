import XCTest
import KaruiLinkKit
@testable import KaruiMac

final class CorrespondentTests: XCTestCase {
    func testMailboxListsParseNamesAndBareAddresses() {
        let parsed = MailboxList.parse("Ada Lovelace <ada@example.com>, \"Babbage, Charles\" <charles@example.com>,ops@example.com")
        XCTAssertEqual(parsed, [
            MailboxList.Mailbox(name: "Ada Lovelace", address: "ada@example.com"),
            // A quoted name with a comma splits on the comma; the address still comes through.
            MailboxList.Mailbox(name: "Charles", address: "charles@example.com"),
            MailboxList.Mailbox(name: nil, address: "ops@example.com")
        ])
        XCTAssertEqual(MailboxList.parse(""), [])
        XCTAssertEqual(MailboxList.parse("not an address"), [])
    }

    func testHashesIgnoreCaseSpacingAndNumberPunctuation() {
        XCTAssertEqual(CorrespondentHash.make("Ada@Example.com "), CorrespondentHash.make("ada@example.com"))
        XCTAssertEqual(CorrespondentHash.make("Ada  Lovelace"), CorrespondentHash.make("ada lovelace"))
        XCTAssertEqual(CorrespondentHash.make("+81 90-1234-5678"), CorrespondentHash.make("+819012345678"))
        XCTAssertEqual(CorrespondentHash.normalize("(090) 1234-5678"), "09012345678")
        XCTAssertNotEqual(CorrespondentHash.make("ada@example.com"), CorrespondentHash.make("ada@example.org"))
        XCTAssertNil(CorrespondentHash.make("   "))
    }
}
