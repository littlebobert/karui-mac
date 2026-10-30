import XCTest
@testable import KaruiSorting

final class GermanLocalizationTests: XCTestCase {
    private let german = Locale(identifier: "de_DE")

    func testModelsWriteInGerman() {
        XCTAssertEqual(KaruiLocalization.modelLanguageName(german), "German")
        XCTAssertEqual(KaruiLocalization.modelLanguageName(Locale(identifier: "fr_FR")), "English")
    }

    func testGermanDefaultsPrependGermanTermsAndKeepEnglish() {
        var policy = TriagePolicy.standard
        policy.adoptLocalizedDefaultTerms(locale: german)
        XCTAssertTrue(policy.urgentKeywords.hasPrefix("dringend, "))
        XCTAssertTrue(policy.urgentKeywords.hasSuffix(TriagePolicy.standard.urgentKeywords))
        XCTAssertTrue(policy.wakeMeKeywords.contains("112"))
        // Customized terms are left alone, and adopting twice changes nothing.
        policy.silenceKeywords = "Werbung"
        let once = policy
        policy.adoptLocalizedDefaultTerms(locale: german)
        XCTAssertEqual(policy, once)
    }

    func testGermanAppNamesRouteToApplesApps() {
        XCTAssertEqual(SourceAppRouter.route(for: "Nachrichten")?.appName, "Messages")
        XCTAssertEqual(SourceAppRouter.route(for: "Kalender")?.appName, "Calendar")
        XCTAssertEqual(SourceAppRouter.route(for: "Erinnerungen")?.appName, "Reminders")
        XCTAssertEqual(SuggestedApps.displayName(for: "Messages", locale: german), "Nachrichten")
    }

    func testSecondOpinionReadsGermanAnswers() throws {
        let important = try XCTUnwrap(SecondOpinionPrompt.parse(answer: "Kategorie: Wichtig\nSicherheit: 0,9\nGrund: Mama bittet um Rückruf."))
        XCTAssertEqual(important.category, .notifyNow)
        XCTAssertEqual(important.reason, "Mama bittet um Rückruf.")
        let notImportant = try XCTUnwrap(SecondOpinionPrompt.parse(answer: "Kategorie: Nicht wichtig\nGrund: Ein Newsletter."))
        XCTAssertEqual(notImportant.category, .summary)
        let unwichtig = try XCTUnwrap(SecondOpinionPrompt.parse(answer: "Kategorie: Unwichtig"))
        XCTAssertEqual(unwichtig.category, .summary)
    }
}
