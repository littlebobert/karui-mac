import XCTest
@testable import KaruiMac

final class SlackLinkTests: XCTestCase {
    func testIdentifierSplitsIntoTeamAndTimestamp() {
        XCTAssertEqual(
            SlackLink.parseIdentifier("T0123ABCDEF_1791879249.798639"),
            SlackLink.MessageIdentifier(teamID: "T0123ABCDEF", timestamp: "1791879249.798639")
        )
        XCTAssertNil(SlackLink.parseIdentifier("9d6392ed-68e1-4d35-bbf8-e7142cdf37b8"))
    }

    func testPermalinkDropsTheDotFromTheTimestamp() {
        let url = SlackLink.permalink(
            workspace: URL(string: "https://example.slack.com/")!,
            channelID: "D0ABCDEFGHI",
            timestamp: "1791879249.798639"
        )
        XCTAssertEqual(url?.absoluteString, "https://example.slack.com/archives/D0ABCDEFGHI/p1791879249798639")
    }

    func testChannelURLOpensTheChannel() {
        XCTAssertEqual(
            SlackLink.channelURL(teamID: "T0123ABCDEF", channelID: "C0ABCDEFGHI")?.absoluteString,
            "slack://channel?team=T0123ABCDEF&id=C0ABCDEFGHI"
        )
    }

    /// Slack for Mac opens only its own links, so the permalink is opened as one.
    func testPermalinkOpensAsSlacksOwnLinkOnTheMac() {
        let state = Data(#"""
        {"workspaces":{"T0123ABCDEF":{"domain":"example","id":"T0123ABCDEF","name":"Example","url":"https://example.slack.com/"}}}
        """#.utf8)
        XCTAssertEqual(
            SlackLink.appURL(forPermalink: URL(string: "https://example.slack.com/archives/C0ABCDEFGHI/p1791879249798639")!, rootState: state)?.absoluteString,
            "slack://channel?team=T0123ABCDEF&id=C0ABCDEFGHI&message=1791879249.798639"
        )
        // A workspace not signed in on this Mac, or not a permalink, opens as it is.
        XCTAssertNil(SlackLink.appURL(forPermalink: URL(string: "https://other.slack.com/archives/C0ABCDEFGHI/p1791879249798639")!, rootState: state))
        XCTAssertNil(SlackLink.appURL(forPermalink: URL(string: "slack://channel?team=T0123ABCDEF&id=C0ABCDEFGHI")!, rootState: state))
        XCTAssertNil(SlackLink.appURL(forPermalink: URL(string: "https://example.slack.com/archives/C0ABCDEFGHI")!, rootState: state))
    }

    func testWorkspaceURLComesFromRootState() {
        let state = Data(#"""
        {"workspaces":{"T0123ABCDEF":{"domain":"example","id":"T0123ABCDEF","name":"Example","url":"https://example.slack.com/"}}}
        """#.utf8)
        XCTAssertEqual(SlackLink.workspaceURL(teamID: "T0123ABCDEF", rootState: state)?.absoluteString, "https://example.slack.com/")
        XCTAssertNil(SlackLink.workspaceURL(teamID: "T0000000000", rootState: state))
    }

    func testLastReadMarkerIsTheFurthestLoggedForTheChannel() {
        let log = """
        [17:14:20.100] info: [x] (T0123ABCDEF) Counting unreads in D0ABCDEFGHI because last_read changed to 1791879249.798639
        [17:20:00.100] info: [x] (T0123ABCDEF) Counting unreads in C0ZZZZZZZZZ because last_read changed to 1791879600.000100
        [17:21:00.100] info: [x] (T0123ABCDEF) Counting unreads in D0ABCDEFGHI because last_read changed to 1791879300.000001
        """
        XCTAssertEqual(SlackLog.lastRead(channelID: "D0ABCDEFGHI", in: log), "1791879300.000001")
        XCTAssertEqual(SlackLog.lastRead(channelID: "C0ZZZZZZZZZ", in: log), "1791879600.000100")
        XCTAssertNil(SlackLog.lastRead(channelID: "C0NOTTHERE0", in: log))
    }

    func testChannelIsReadFromTheLoggedNotification() {
        let log = """
        [17:14:09.001] info: showing notification
        {
          "title": "[REDACTED]",
          "teamId": "T0123ABCDEF",
          "userId": "U0ABCDEFGHI",
          "msg": "1791879249.798639",
          "channel": "D0ABCDEFGHI",
          "channelName": "[REDACTED]",
          "silent": false
        }
        [17:14:20.002] info: something else
        {
          "msg": "1791879300.000001",
          "channel": "C0ZZZZZZZZZ"
        }
        """
        XCTAssertEqual(SlackLog.channel(forMessageTimestamp: "1791879249.798639", in: log), "D0ABCDEFGHI")
        XCTAssertEqual(SlackLog.channel(forMessageTimestamp: "1791879300.000001", in: log), "C0ZZZZZZZZZ")
        XCTAssertNil(SlackLog.channel(forMessageTimestamp: "1791879999.000000", in: log))
    }
}
