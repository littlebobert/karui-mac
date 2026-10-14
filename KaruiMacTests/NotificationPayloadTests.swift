import XCTest
@testable import KaruiMac

final class NotificationPayloadTests: XCTestCase {
    func testReadsTheRequestFromAPlainPlist() throws {
        let plist: [String: Any] = [
            "app": "com.readdle.SparkDesktop",
            "req": [
                "titl": "Ada Lovelace",
                "subt": "Re: Engine",
                "body": "Hello",
                "iden": "9d6392ed-68e1-4d35-bbf8-e7142cdf37b8",
                "usda": ["CKBBContextKeyMessageGUID": "ABC-123", "count": 2]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let payload = try XCTUnwrap(NotificationPayload(data: data))
        XCTAssertEqual(payload.title, "Ada Lovelace")
        XCTAssertEqual(payload.subtitle, "Re: Engine")
        XCTAssertEqual(payload.body, "Hello")
        XCTAssertEqual(payload.identifier, "9d6392ed-68e1-4d35-bbf8-e7142cdf37b8")
        XCTAssertEqual(payload.userInfo, ["CKBBContextKeyMessageGUID": "ABC-123"])
    }

    func testIgnoresKeyedArchives() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["$archiver": "NSKeyedArchiver", "req": ["titl": "x"]],
            format: .binary,
            options: 0
        )
        XCTAssertNil(NotificationPayload(data: data))
    }

    func testRegistryRoutesByBundleIdentifier() async {
        let registry = HarvesterRegistry(harvesters: [SparkHarvester(), SlackHarvester(), MessagesHarvester()])
        XCTAssertTrue(registry.bundleIdentifiers.contains("com.readdle.sparkdesktop"))
        XCTAssertTrue(registry.bundleIdentifiers.contains("com.apple.mobilesms"))
        let record = NotificationRecord(
            id: 1, bundleIdentifier: "com.apple.mail", deliveredAt: nil,
            title: nil, subtitle: nil, body: nil, identifier: nil, userInfo: [:]
        )
        let link = await registry.harvest(record)
        XCTAssertNil(link)
    }
}
