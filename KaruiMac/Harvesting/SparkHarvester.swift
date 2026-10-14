import Foundation
import KaruiLinkKit

/// Spark's notification doesn't identify the email, so the email is found in
/// Spark's own database by subject and time, and the link built from that row.
struct SparkHarvester: NotificationHarvester {
    let bundleIdentifiers = Set(KnownApp.spark.macBundleIdentifiers)
    var databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Spark Desktop/core-data/messages.sqlite")
    /// How far the email's `receivedDate` may be from the notification's delivery.
    static let receivedTolerance: TimeInterval = 300

    func harvest(_ record: NotificationRecord) async -> HarvestedLink? {
        guard let subject = record.subtitle, let deliveredAt = record.deliveredAt else { return nil }
        do {
            let database = try SQLiteDatabase.opening(databaseURL)
            let rows = try database.rows("""
                select messages.messageId, messages.gmailMessageId, accounts.additionalInfo, messages.pk
                from messages join accounts on accounts.pk = messages.accountPk
                where messages.subject = ?1 and abs(messages.receivedDate - ?2) <= ?3
                order by abs(messages.receivedDate - ?2)
                limit 1
                """, [.text(subject), .real(deliveredAt.timeIntervalSince1970), .real(Self.receivedTolerance)])
            guard let row = rows.first, let messageID = row[0].text, let accountInfo = row[2].text else {
                SafeDiagnosticLog.shared.record("spark: no email matched the notification")
                return nil
            }
            guard let address = SparkLink.accountAddress(fromAccountInfo: Data(accountInfo.utf8)),
                  let url = SparkLink.url(accountAddress: address, messageID: messageID, gmailMessageID: row[1].text) else {
                SafeDiagnosticLog.shared.record("spark: matched an email but couldn't build its link")
                return nil
            }
            return HarvestedLink(
                link: record.deepLink(as: .spark, url: url, opensExactContent: true),
                readProbe: row[3].integer.map { .spark(messagePrimaryKey: $0) },
                notificationID: record.id
            )
        } catch {
            SafeDiagnosticLog.shared.record("spark: database read failed: \(error)")
            return nil
        }
    }

    /// Spark clears `unseen` once the email is opened, on any device.
    func isRead(_ probe: ReadProbe) async -> Bool? {
        guard case .spark(let primaryKey) = probe else { return nil }
        do {
            let database = try SQLiteDatabase.opening(databaseURL)
            let rows = try database.rows("select unseen from messages where pk = ?1", [.integer(primaryKey)])
            guard let unseen = rows.first?[0].integer else { return nil }
            return unseen == 0
        } catch {
            return nil
        }
    }
}

/// Spark's per-email link, as Copy Link makes it: base64 of
/// `A:<account>;ID:<Message-ID>[;gID:<Gmail ID>];<CRC32 of the rest>`.
enum SparkLink {
    static func url(accountAddress: String, messageID: String, gmailMessageID: String?) -> URL? {
        var payload = "A:\(accountAddress);ID:\(messageID)"
        // Only Gmail and Google Workspace accounts have one; others store 0.
        if let gmailMessageID, !gmailMessageID.isEmpty, gmailMessageID != "0" {
            payload += ";gID:\(gmailMessageID)"
        }
        payload += ";\(CRC32.checksum(Data(payload.utf8)))"
        let base64 = Data(payload.utf8).base64EncodedString(
            options: [.lineLength64Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
        guard let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "readdle-spark://bl=" + encoded)
    }

    /// The address in an `accounts.additionalInfo` JSON column, and nothing else from
    /// it: the same JSON names the Keychain items holding the account's passwords.
    static func accountAddress(fromAccountInfo json: Data) -> String? {
        guard let info = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return info["accountAddress"] as? String
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
