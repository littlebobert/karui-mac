import XCTest
@testable import KaruiMac

final class SecondOpinionBackoffTests: XCTestCase {
    /// Three failures in a row pause asking for 5 minutes; after that, each failed
    /// first ask doubles the pause, up to an hour; an answer starts it over.
    func testPausesAfterThreeFailuresAndDoublesUpToAnHour() {
        var backoff = SecondOpinionBackoff()
        let start = Date()
        XCTAssertNil(backoff.recordFailure(at: start))
        XCTAssertNil(backoff.recordFailure(at: start))
        XCTAssertEqual(backoff.recordFailure(at: start), 5 * 60)
        XCTAssertTrue(backoff.isPaused(at: start.addingTimeInterval(4 * 60)))
        XCTAssertFalse(backoff.isPaused(at: start.addingTimeInterval(5 * 60)))

        var now = start.addingTimeInterval(5 * 60)
        for minutes in [10, 20, 40, 60, 60] {
            XCTAssertEqual(backoff.recordFailure(at: now), TimeInterval(minutes * 60))
            now = backoff.pausedUntil!
        }

        XCTAssertTrue(backoff.recordAnswer())
        XCTAssertFalse(backoff.isPaused(at: now))
        XCTAssertNil(backoff.recordFailure(at: now), "three in a row again before a pause")
        XCTAssertNil(backoff.recordFailure(at: now))
        XCTAssertEqual(backoff.recordFailure(at: now), 5 * 60)
    }

    /// A failure or two between answers never pauses.
    func testAnAnswerClearsEarlierFailures() {
        var backoff = SecondOpinionBackoff()
        let now = Date()
        XCTAssertNil(backoff.recordFailure(at: now))
        XCTAssertNil(backoff.recordFailure(at: now))
        XCTAssertFalse(backoff.recordAnswer())
        XCTAssertNil(backoff.recordFailure(at: now))
        XCTAssertNil(backoff.recordFailure(at: now))
        XCTAssertFalse(backoff.isPaused(at: now))
    }

    /// A pause outlives a relaunch: kept in the defaults, and read back as it was.
    func testAPauseSurvivesARelaunch() {
        let suite = "SecondOpinionBackoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(SecondOpinionBackoff.load(from: defaults), SecondOpinionBackoff(), "nothing kept: a fresh start")

        var backoff = SecondOpinionBackoff()
        let start = Date()
        for _ in 0..<3 { _ = backoff.recordFailure(at: start) }
        backoff.save(to: defaults)

        var relaunched = SecondOpinionBackoff.load(from: defaults)
        XCTAssertEqual(relaunched, backoff)
        XCTAssertTrue(relaunched.isPaused(at: start.addingTimeInterval(60)))
        // After the pause, one failure is enough for the next, twice as long.
        XCTAssertEqual(relaunched.recordFailure(at: start.addingTimeInterval(5 * 60)), 10 * 60)
    }

    /// A pause running out is told once; an answer after pauses is told as the end
    /// of them, even once the last pause has run out.
    func testThePauseEndingIsToldOnce() {
        var backoff = SecondOpinionBackoff()
        let start = Date()
        for _ in 0..<3 { _ = backoff.recordFailure(at: start) }
        XCTAssertFalse(backoff.takeEndedPause(at: start.addingTimeInterval(60)))
        XCTAssertTrue(backoff.takeEndedPause(at: start.addingTimeInterval(5 * 60)))
        XCTAssertFalse(backoff.takeEndedPause(at: start.addingTimeInterval(6 * 60)))
        XCTAssertFalse(backoff.isPaused(at: start.addingTimeInterval(6 * 60)))
        XCTAssertTrue(backoff.recordAnswer())
        XCTAssertFalse(backoff.recordAnswer(), "started over")
    }

    func testTheQuotaIsDescribed() {
        XCTAssertFalse(PrivateCloudComputeQuota.describe().isEmpty)
    }
}
