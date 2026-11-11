import XCTest
@testable import KaruiMac

/// A Spark email harvested twice during the 2026-11-11 iCloud outage left two inbox
/// rows with one fingerprint. Both went in one sort-request batch, CloudKit refused
/// the whole batch ("You can't save the same record twice"), and no sort request
/// reached the iPhone for hours.
@MainActor
final class SortRequestDuplicateTests: XCTestCase {
    func testOneRequestPerFingerprint() {
        let now = Date()
        let items = [
            Inbox.Item(id: "notification-1", app: "Spark", fingerprint: "same-print", title: "Nesting House", subtitle: "Hello", body: "First", deliveredAt: now),
            Inbox.Item(id: "notification-2", app: "Spark", fingerprint: "same-print", title: "Nesting House", subtitle: "Hello", body: "Again", deliveredAt: now.addingTimeInterval(1)),
            Inbox.Item(id: "notification-3", app: "Messages", fingerprint: "other-print", title: "Mom", subtitle: nil, body: "Dinner?", deliveredAt: now),
        ]
        let unique = SortRequests.unique(items.map(SortRequests.Request.init))
        XCTAssertEqual(unique.map(\.fingerprint), ["same-print", "other-print"])
        XCTAssertEqual(unique.first?.body, "First")
    }
}
