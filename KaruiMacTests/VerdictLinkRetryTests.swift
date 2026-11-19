import XCTest
@testable import KaruiMac

/// A Spark lookup from the iPhone's verdict that misses (Spark here hadn't fetched
/// the email yet) is tried again a few minutes on, up to a limit.
@MainActor
final class VerdictLinkRetryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    func testNeverTriedIsLookedUp() {
        XCTAssertTrue(AppCoordinator.shouldLookUp(nil, now: now))
    }

    func testMissIsRetriedOnlyAfterTheInterval() {
        let missed = AppCoordinator.VerdictLinkAttempt(count: 1, lastAt: now)
        XCTAssertFalse(AppCoordinator.shouldLookUp(missed, now: now.addingTimeInterval(30)))
        XCTAssertTrue(AppCoordinator.shouldLookUp(missed, now: now.addingTimeInterval(AppCoordinator.verdictLinkRetryInterval)))
    }

    func testGivesUpAfterTheLastAttempt() {
        let spent = AppCoordinator.VerdictLinkAttempt(count: AppCoordinator.verdictLinkMaxAttempts, lastAt: now)
        XCTAssertFalse(AppCoordinator.shouldLookUp(spent, now: now.addingTimeInterval(60 * 60)))
    }
}
