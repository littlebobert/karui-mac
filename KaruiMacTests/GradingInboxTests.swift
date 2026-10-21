import KaruiLinkKit
import XCTest
@testable import KaruiMac

@MainActor
final class GradingInboxTests: XCTestCase {
    private func inboxItem(verdictCategory: String = "summary", chosenCategory: String? = nil) -> Inbox.Item {
        var item = Inbox.Item(id: "1", app: "Spark", fingerprint: "f", title: "Northwind Air", subtitle: nil, body: "Gate changed", deliveredAt: Date())
        item.verdict = VerdictRecord(
            fingerprint: "f", app: "Spark", category: verdictCategory, interest: 4,
            reason: "A change to the user's travel", triagedAt: Date(timeIntervalSince1970: 1_792_000_000),
            isUnread: true, title: "Northwind Air", body: "Your flight NW 204 has a new gate\nGate changed"
        )
        item.chosenCategory = chosenCategory
        return item
    }

    /// The Mac's copy uses the verdict's text and sort time, which are History's own,
    /// so it matches the same item in an export.
    func testUsesTheVerdictsTextAndTime() throws {
        let item = try XCTUnwrap(GradingSession.Item(inboxItem: inboxItem()))
        XCTAssertEqual(item.line.body, "Your flight NW 204 has a new gate\nGate changed")
        XCTAssertEqual(item.line.triagedAt, Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(item.line.category, "summary")
        XCTAssertFalse(item.wasRevised)
    }

    /// A category chosen here is the person's fix.
    func testAChosenCategoryIsAFix() throws {
        let item = try XCTUnwrap(GradingSession.Item(inboxItem: inboxItem(chosenCategory: "notifyNow")))
        XCTAssertEqual(item.line.category, "notifyNow")
        XCTAssertEqual(item.line.originalCategory, "summary")
        XCTAssertTrue(item.isFixedByPerson)
    }

    /// A notification the iPhone never sorted isn't History.
    func testNoVerdictIsNotAnItem() {
        var item = inboxItem()
        item.verdict = nil
        XCTAssertNil(GradingSession.Item(inboxItem: item))
    }
}
