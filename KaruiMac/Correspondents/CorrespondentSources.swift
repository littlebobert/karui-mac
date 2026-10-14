import Foundation
import KaruiLinkKit

/// Where the Mac finds the people the person has written to. Only the address
/// columns are read, never a message.
protocol CorrespondentSource: Sendable {
    /// Addresses, numbers, and names, as the app has them; not yet hashed.
    func handles() throws -> [String]
}

/// The recipients of every email the person sent: anyone they wrote to, which
/// covers replies as well as mail they started.
struct SparkCorrespondents: CorrespondentSource {
    var databaseURL = SparkHarvester().databaseURL

    func handles() throws -> [String] {
        let database = try SQLiteDatabase.opening(databaseURL)
        let rows = try database.rows("select messageTo, messageCc from messages where inSent = 1")
        var handles: [String] = []
        for row in rows {
            for column in row {
                guard let list = column.text else { continue }
                for mailbox in MailboxList.parse(list) {
                    handles.append(mailbox.address)
                    if let name = mailbox.name { handles.append(name) }
                }
            }
        }
        return handles
    }
}

/// Everyone in a Messages chat the person has written in.
struct MessagesCorrespondents: CorrespondentSource {
    var chatDatabase = ChatDatabase.standard

    func handles() throws -> [String] {
        let database = try SQLiteDatabase.opening(chatDatabase.url)
        let rows = try database.rows("""
            select distinct handle.id from handle
            join chat_handle_join on chat_handle_join.handle_id = handle.ROWID
            where chat_handle_join.chat_id in (
                select distinct chat_message_join.chat_id from chat_message_join
                join message on message.ROWID = chat_message_join.message_id
                where message.is_from_me = 1
            )
            """)
        return rows.compactMap { $0[0].text }
    }
}

/// `Name <address>` lists as mail apps write them, comma-separated, with bare
/// addresses allowed.
enum MailboxList {
    struct Mailbox: Equatable {
        let name: String?
        let address: String
    }

    static func parse(_ list: String) -> [Mailbox] {
        list.split(separator: ",").compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") {
                let address = trimmed[trimmed.index(after: open)...].dropLast().trimmingCharacters(in: .whitespaces)
                let name = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard address.contains("@") else { return nil }
                return Mailbox(name: name.isEmpty ? nil : name, address: address)
            }
            guard trimmed.contains("@") else { return nil }
            return Mailbox(name: nil, address: trimmed)
        }
    }
}
