import XCTest
@testable import KaruiMac

/// Whether a notification's app is on this Mac, which shows its own banner then.
@MainActor
final class InstalledAppTests: XCTestCase {
    func testKnownAndUnknownApps() {
        XCTAssertEqual(AppLauncher.installedBundleIdentifier(for: "Messages"), "com.apple.MobileSMS", "by its known identifier")
        XCTAssertEqual(AppLauncher.installedBundleIdentifier(for: "Calculator"), "com.apple.calculator", "by its name in the Applications folders")
        XCTAssertNil(AppLauncher.installedBundleIdentifier(for: "No Such App Here"))
    }
}
