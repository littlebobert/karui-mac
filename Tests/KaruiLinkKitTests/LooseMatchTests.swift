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

    /// A bot's post in a channel: the iPhone says "To channel"; the Mac's text has no
    /// sender before it, and its own "Tag: " isn't one.
    func testASlackBotPostMatchesEitherWayRound() {
        let phone = LooseMatch.Fields(
            title: "Build Bot (bot)", subtitle: "To app-tech",
            body: "To app-tech\n📦 iOS build uploaded to TestFlight by mika Tag: release/ios/2.0.0-207"
        )
        let mac = LooseMatch.Fields(title: "Kotoba", subtitle: "app-tech", body: "📦 iOS build uploaded to TestFlight by mika\nTag: release/ios/2.0.0-207 • Env: .env.production")
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", phone, mac))
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", mac, phone))
        let otherChannel = LooseMatch.Fields(title: "Kotoba", subtitle: "design", body: mac.body)
        XCTAssertFalse(LooseMatch.sameNotification(app: "Slack", phone, otherChannel))
        let otherBuild = LooseMatch.Fields(title: "Kotoba", subtitle: "app-tech", body: "📦 iOS build uploaded to TestFlight by mika\nTag: release/ios/2.0.0-206")
        XCTAssertFalse(LooseMatch.sameNotification(app: "Slack", phone, otherBuild))
    }

    /// A person's post in a channel, with "sender: " before the Mac's text.
    func testASlackChannelPostFromAPersonMatches() {
        let phone = LooseMatch.Fields(title: "Mika", subtitle: "To #design", body: "To #design\nNew mockups are up")
        let mac = LooseMatch.Fields(title: "Kotoba", subtitle: "design", body: "Mika: New mockups are up")
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", phone, mac))
    }

    /// A Slack direct message: the iPhone's titled by the sender, the Mac's by the
    /// workspace with the sender as its subtitle.
    func testASlackDirectMessageMatchesEitherWayRound() {
        let phone = LooseMatch.Fields(title: "Sam Reyes", subtitle: nil, body: "Sorry I gotta head out for lunch")
        let mac = LooseMatch.Fields(title: "Kotoba", subtitle: "Sam Reyes", body: "Sorry I gotta head out for lunch")
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", phone, mac))
        XCTAssertTrue(LooseMatch.sameNotification(app: "Slack", mac, phone))
        XCTAssertFalse(LooseMatch.sameNotification(app: "Messages", phone, mac), "Slack's shape only")
        let otherSender = LooseMatch.Fields(title: "Kotoba", subtitle: "Mika", body: mac.body)
        XCTAssertFalse(LooseMatch.sameNotification(app: "Slack", phone, otherSender))
        let otherText = LooseMatch.Fields(title: "Kotoba", subtitle: "Sam Reyes", body: "Back in an hour")
        XCTAssertFalse(LooseMatch.sameNotification(app: "Slack", phone, otherText))
        // A channel post from the same person isn't a direct message.
        let post = LooseMatch.Fields(title: "Sam Reyes", subtitle: "To #design", body: "To #design\nSorry I gotta head out for lunch")
        XCTAssertFalse(LooseMatch.slackDirectMessage(post, mac))
    }
}
