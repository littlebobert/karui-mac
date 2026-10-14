import XCTest
@testable import KaruiLinkKit

final class NotificationFingerprintTests: XCTestCase {
    func testMatchesReferenceDigest() {
        // Computed independently in Python (NFKC, invisible marks removed, whitespace
        // collapsed, lowercased, body cut to 60, joined with U+001F, SHA-256).
        let fingerprint = NotificationFingerprint.make(
            app: "Spark",
            title: "Ada Lovelace",
            subtitle: "Re:  Engine",
            body: "Shipped: \"Army Half Face\"\u{034F}\u{200C}\u{00AD} x"
        )
        XCTAssertEqual(fingerprint, "1a3d38520a85d0db083fd892d97aa991d645a5fa3b9972237f05873106880958")
    }

    func testNormalizationIgnoresPaddingCaseAndInvisibleMarks() {
        XCTAssertEqual(NotificationFingerprint.normalize("  Hello\u{200B}   World\n"), "hello world")
        XCTAssertEqual(NotificationFingerprint.normalize(nil), "")
        XCTAssertEqual(
            NotificationFingerprint.make(app: "Slack", title: "Ada", subtitle: nil, body: "ok"),
            NotificationFingerprint.make(app: "slack", title: " ADA ", subtitle: "", body: "OK ")
        )
    }

    func testOnlyTheStartOfTheBodyCounts() {
        let start = String(repeating: "a", count: 60)
        XCTAssertEqual(
            NotificationFingerprint.make(app: "Messages", title: nil, subtitle: nil, body: start + " first"),
            NotificationFingerprint.make(app: "Messages", title: nil, subtitle: nil, body: start + " second")
        )
        XCTAssertNotEqual(
            NotificationFingerprint.make(app: "Messages", title: nil, subtitle: nil, body: "first"),
            NotificationFingerprint.make(app: "Messages", title: nil, subtitle: nil, body: "second")
        )
    }

    func testKnownAppsMatchBundleIdentifiersIgnoringCase() {
        XCTAssertEqual(KnownApp(macBundleIdentifier: "com.readdle.SparkDesktop"), .spark)
        XCTAssertEqual(KnownApp(macBundleIdentifier: "com.apple.MobileSMS"), .messages)
        XCTAssertNil(KnownApp(macBundleIdentifier: "com.apple.mail"))
    }

    func testRecordExpiresADayAfterDelivery() {
        let delivered = Date(timeIntervalSince1970: 1_791_879_249)
        let record = DeepLinkRecord(
            fingerprint: "abc",
            app: "Slack",
            url: URL(string: "slack://open")!,
            opensExactContent: false,
            deliveredAt: delivered
        )
        XCTAssertEqual(record.expiresAt, delivered.addingTimeInterval(24 * 60 * 60))
    }
}
