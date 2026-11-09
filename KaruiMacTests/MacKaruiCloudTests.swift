import KaruiSorting
import XCTest
@testable import KaruiMac

final class MacKaruiCloudTests: XCTestCase {
    private let notification = NotificationInput.fromMac(
        app: "Mail", title: "Vercel", subtitle: "Your deployment failed", body: "The build for karui-backend failed.", receivedAt: Date()
    )

    /// The backend's reply, read as the iPhone reads it.
    func testReadsTheBackendsReply() {
        let decided = MacKaruiCloud.outcome(
            from: Data(#"{"category":"Important","probabilities":{"Important":0.82,"Neutral":0.15,"Spam":0.03}}"#.utf8),
            status: 200, seconds: 0.6
        )
        XCTAssertEqual(decided, .decided(.init(category: .notifyNow, probability: 0.82), seconds: 0.6))
        XCTAssertEqual(MacKaruiCloud.outcome(from: Data(#"{"refused":true}"#.utf8), status: 200, seconds: 1), .refused)
        guard case .failed = MacKaruiCloud.outcome(from: Data(#"{"error":"revoked"}"#.utf8), status: 403, seconds: 1) else {
            return XCTFail("a revoked invite isn't an answer")
        }
        guard case .failed = MacKaruiCloud.outcome(from: Data(#"{"category":"Urgent"}"#.utf8), status: 200, seconds: 1) else {
            return XCTFail("an unknown category isn't an answer")
        }
    }

    /// Only what a model sorted goes, never what the rules decided or a silenced sender.
    func testAsksOnlyAboutWhatAModelSorted() {
        let policy = TriagePolicy.standard
        let model = TriageResult(category: .summary, confidence: 0.7, reason: "", engine: .onDeviceModel)
        XCTAssertTrue(MacKaruiCloud.shouldAsk(about: model, notification: notification, policy: policy))

        var fallback = TriageResult(category: .summary, confidence: 0.5, reason: "", engine: .deterministicRules)
        fallback.isModelFallback = true
        XCTAssertTrue(MacKaruiCloud.shouldAsk(about: fallback, notification: notification, policy: policy))

        let rule = TriageResult(category: .notifyNow, confidence: 1, reason: "", engine: .deterministicRules)
        XCTAssertFalse(MacKaruiCloud.shouldAsk(about: rule, notification: notification, policy: policy))

        var silenced = policy
        silenced.addSilencedSender("Vercel", in: "Mail")
        XCTAssertFalse(MacKaruiCloud.shouldAsk(about: model, notification: notification, policy: silenced))
    }

    /// Agreeing keeps the on-device reason; disagreeing says what the cloud decided.
    func testTheCloudsCategoryOverTheOnDeviceAnswer() {
        let policy = TriagePolicy.standard
        let onDevice = TriageResult(category: .summary, confidence: 0.7, reason: "A build notice.", engine: .onDeviceModel)

        let agreeing = MacKaruiCloud.result(
            applying: .init(category: .summary, probability: 0.9), seconds: 0.5,
            to: onDevice, notification: notification, policy: policy, environment: .mac
        )
        XCTAssertEqual(agreeing.engine, .karuiCloud)
        XCTAssertEqual(agreeing.category, .summary)
        XCTAssertEqual(agreeing.reason, "A build notice.")
        XCTAssertEqual(agreeing.modelDuration, 0.5)

        let disagreeing = MacKaruiCloud.result(
            applying: .init(category: .notifyNow, probability: 0.82), seconds: 0.5,
            to: onDevice, notification: notification, policy: policy, environment: .mac
        )
        XCTAssertEqual(disagreeing.engine, .karuiCloud)
        XCTAssertEqual(disagreeing.category, .notifyNow)
        XCTAssertTrue(disagreeing.reason.contains("82"), disagreeing.reason)
    }
}
