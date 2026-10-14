import XCTest
@testable import KaruiMac

final class SparkLinkTests: XCTestCase {
    // Expected links computed independently in Python with zlib.crc32, base64 wrapped
    // at 64 characters with CRLF, and urllib.parse.quote(safe="").

    func testGoogleAccountLinkCarriesGmailID() {
        let url = SparkLink.url(
            accountAddress: "ada@example.com",
            messageID: "20261013.1@mail.example.com",
            gmailMessageID: "1234567890123456789"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "readdle-spark://bl=QTphZGFAZXhhbXBsZS5jb207SUQ6MjAyNjEwMTMuMUBtYWlsLmV4YW1wbGUuY29t%0D%0AO2dJRDoxMjM0NTY3ODkwMTIzNDU2Nzg5OzIzNTkwNjEzMzQ%3D"
        )
    }

    func testOtherAccountsLeaveOutGmailID() {
        let expected = "readdle-spark://bl=QTphZGFAZXhhbXBsZS5jb207SUQ6MjAyNjEwMTMuMUBtYWlsLmV4YW1wbGUuY29t%0D%0AOzI2ODY1OTMzNjY%3D"
        XCTAssertEqual(
            SparkLink.url(accountAddress: "ada@example.com", messageID: "20261013.1@mail.example.com", gmailMessageID: nil)?.absoluteString,
            expected
        )
        // Spark stores 0 where an account has none.
        XCTAssertEqual(
            SparkLink.url(accountAddress: "ada@example.com", messageID: "20261013.1@mail.example.com", gmailMessageID: "0")?.absoluteString,
            expected
        )
    }

    func testChecksumMatchesZlib() {
        XCTAssertEqual(CRC32.checksum(Data("A:ada@example.com;ID:20261013.1@mail.example.com;gID:1234567890123456789".utf8)), 2_359_061_334)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testAccountAddressComesFromAdditionalInfoOnly() {
        let json = Data(#"{"accountAddress":"ada@example.com","mailServerAuthenticationKCKey":"secret-item"}"#.utf8)
        XCTAssertEqual(SparkLink.accountAddress(fromAccountInfo: json), "ada@example.com")
        XCTAssertNil(SparkLink.accountAddress(fromAccountInfo: Data("not json".utf8)))
    }
}
