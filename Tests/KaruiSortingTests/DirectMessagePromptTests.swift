import XCTest
@testable import KaruiSorting

final class DirectMessagePromptTests: XCTestCase {
    private func prompt(_ notification: NotificationInput) -> String {
        NotificationPromptFormatter.format(notification, isImportantApp: true)
    }

    /// A Slack message whose title is its sender was written to the user alone, and
    /// the model is told so; a channel's or thread's title is the channel.
    func testASlackDirectMessageIsSaidToBeOne() {
        let direct = NotificationInput(source: "Slack", title: "Mika Tanaka", body: "thanks!", sender: "Mika Tanaka")
        XCTAssertTrue(ConversationCooldown.looksLikeDirectMessage(direct))
        XCTAssertTrue(prompt(direct).contains("Direct message:"))

        let channel = NotificationInput(source: "Slack", title: "#design", body: "thanks!", sender: "Mika Tanaka")
        XCTAssertFalse(ConversationCooldown.looksLikeDirectMessage(channel))
        XCTAssertFalse(prompt(channel).contains("Direct message:"))
    }

    /// Only workplace apps: a messaging app's title is the chat either way.
    func testOnlyWorkplaceApps() {
        let line = NotificationInput(source: "LINE", title: "Mika Tanaka", body: "thanks!", sender: "Mika Tanaka")
        XCTAssertFalse(ConversationCooldown.looksLikeDirectMessage(line))
    }

    /// The Mac's notifications give the title as the sender, so every one would look
    /// direct; the Mac says it can't tell.
    func testTheMacsNotificationsAreNotCalledDirect() {
        let mac = NotificationInput.fromMac(app: "Slack", title: "Mika Tanaka", subtitle: "#design", body: "thanks!", receivedAt: .now)
        XCTAssertFalse(prompt(mac).contains("Direct message:"))
    }
}
