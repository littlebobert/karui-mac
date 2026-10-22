import XCTest
@testable import KaruiLinkKit

final class LooseMatchTests: XCTestCase {
    /// Spark for Mac says "No subject" where the iPhone's says nothing, and the
    /// iPhone sends subject and body as one text.
    func testTheSameSenderAndTextMatchEitherWayRound() {
        let mac = LooseMatch.Fields(title: "Mika", subtitle: "No subject", body: "See you at 7")
        let phone = LooseMatch.Fields(title: "Mika", subtitle: nil, body: "See you at 7")
        XCTAssertTrue(LooseMatch.sameNotification(app: "Spark", mac, phone))
        XCTAssertTrue(LooseMatch.sameNotification(app: "Spark", phone, mac))
        let withSubject = LooseMatch.Fields(title: "Mika", subtitle: "Dinner", body: "Dinner See you at 7")
        XCTAssertTrue(LooseMatch.sameNotification(app: "Spark", withSubject, mac))
        XCTAssertFalse(LooseMatch.sameNotification(app: "Spark", mac, LooseMatch.Fields(title: "Ken", subtitle: nil, body: "See you at 7")))
        XCTAssertFalse(LooseMatch.sameNotification(app: "Spark", mac, LooseMatch.Fields(title: "Mika", subtitle: nil, body: nil)))
    }

    /// A Slack thread reply, as each device words it.
    func testASlackThreadReplyMatchesEitherWayRound() {
        let phone = LooseMatch.Fields(title: "darai", subtitle: "In #app-tech", body: "In #app-tech\nShould we update the root CA list too?")
        let mac = LooseMatch.Fields(title: "Kotoba", subtitle: "app-tech", body: "darai: Should we update the root CA list too?")
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", phone, mac))
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", mac, phone))
        XCTAssertFalse(LooseMatch.sameNotification(app: "Messages", phone, mac))
    }
}
