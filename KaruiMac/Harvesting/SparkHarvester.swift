import Foundation
import KaruiLinkKit

/// Spark's notification doesn't identify the email, so the email is found in
/// Spark's own database by subject and time, and the link built from that row.
/// The same works from the iPhone's verdict, for an email this Mac didn't notify
/// about: Spark here has every email, whatever it chose to announce.
struct SparkHarvester: NotificationHarvester {
    let bundleIdentifiers = Set(KnownApp.spark.macBundleIdentifiers)
    var databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Spark Desktop/core-data/messages.sqlite")
    /// How long before a notification the email may have arrived: Spark announces
    /// what it fetched while the Mac slept once it wakes, long after.
    static let lookBack: TimeInterval = 2 * 60 * 60
    /// And after it, for clocks that disagree a little.
    static let lookAhead: TimeInterval = 5 * 60

    /// An email in Spark's database, and its link.
    struct Email: Equatable {
        let url: URL
        /// When the email arrived: what the iPhone's own notification of it is
        /// near, whenever this Mac's came.
        let receivedAt: Date
        let primaryKey: Int64?
    }

    func harvest(_ record: NotificationRecord) async -> HarvestedLink? {
        guard let subject = record.subtitle, !subject.isEmpty, let deliveredAt = record.deliveredAt else {
            // Spark's calendar reminders have none; there's no email to open.
            SafeDiagnosticLog.shared.record("spark: no subject, nothing to look up")
            return nil
        }
        guard let email = email(subject: subject, near: deliveredAt) else { return nil }
        return HarvestedLink(
            link: record.deepLink(as: .spark, url: email.url, opensExactContent: true, deliveredAt: email.receivedAt),
            readProbe: email.primaryKey.map { .spark(messagePrimaryKey: $0) },
            notificationID: record.id
        )
    }

    /// The link for an email the iPhone notified about, named by the iPhone's
    /// fingerprint so its lookup finds it.
    func harvest(fingerprint: String, subject: String, near date: Date) -> HarvestedLink? {
        guard !subject.isEmpty, let email = email(subject: subject, near: date) else { return nil }
        return HarvestedLink(
            link: DeepLinkRecord(
                fingerprint: fingerprint, app: KnownApp.spark.rawValue, url: email.url,
                opensExactContent: true, deliveredAt: email.receivedAt
            ),
            readProbe: email.primaryKey.map { .spark(messagePrimaryKey: $0) },
            notificationID: nil
        )
    }

    /// The email with this subject that arrived nearest the time, within the window.
    /// The range on `receivedDate` lets SQLite use Spark's index on it rather than
    /// read every email.
    func email(subject: String, near date: Date) -> Email? {
        let time = date.timeIntervalSince1970
        do {
            let database = try SQLiteDatabase.opening(databaseURL)
            let rows = try database.rows("""
                select messages.messageId, messages.gmailMessageId, accounts.additionalInfo, messages.pk, messages.receivedDate
                from messages join accounts on accounts.pk = messages.accountPk
                where messages.receivedDate between ?2 and ?3 and messages.subject = ?1
                order by abs(messages.receivedDate - ?4)
                limit 1
                """, [.text(subject), .real(time - Self.lookBack), .real(time + Self.lookAhead), .real(time)])
            guard let row = rows.first, let messageID = row[0].text, let accountInfo = row[2].text,
                  let received = row[4].real else {
                SafeDiagnosticLog.shared.record("spark: no email matched the notification")
                return nil
            }
            guard let address = SparkLink.accountAddress(fromAccountInfo: Data(accountInfo.utf8)),
                  let url = SparkLink.url(accountAddress: address, messageID: messageID, gmailMessageID: row[1].text) else {
                SafeDiagnosticLog.shared.record("spark: matched an email but couldn't build its link")
                return nil
            }
            return Email(url: url, receivedAt: Date(timeIntervalSince1970: received), primaryKey: row[3].integer)
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
