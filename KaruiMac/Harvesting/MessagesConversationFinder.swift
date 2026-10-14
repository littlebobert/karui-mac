import Contacts
import Foundation
import KaruiLinkKit

/// Opens a Messages conversation for a notification that has no link of its own:
/// one the iPhone reported before this Mac saw it, or one whose notification is
/// gone. The same rule as Karui for iPhone's `ConversationRouter`: a sender given
/// as a number or address is used as is; a name resolves through Contacts to
/// their one number, or their one mobile number, or their one address. The Mac
/// also asks Messages' own database, which knows which of those handles has a
/// conversation, and that settles a contact with several. A group's name opens
/// the group when Messages has a chat by that name; otherwise there's no way to
/// tell a group from a person, and nothing opens.
struct MessagesConversationFinder: Sendable {
    var chatDatabase = ChatDatabase.standard

    func url(sender: String, subtitle: String?) async -> URL? {
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
        if let handle = Self.handle(fromAddressOrNumber: sender) {
            return MessagesLink.url(handles: [handle])
        }
        let chatHandles = (try? chatDatabase.handles()) ?? []
        if let members = try? chatDatabase.handles(forChatNamed: sender), !members.isEmpty {
            return MessagesLink.url(handles: members)
        }
        guard let contact = await Self.contact(named: sender) else {
            SafeDiagnosticLog.shared.record("messages: no contact for the sender")
            return nil
        }
        let numbers = contact.phoneNumbers.map { Self.dialable($0.value.stringValue) }.filter { !$0.isEmpty }
        let emails = contact.emailAddresses.map { String($0.value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        // The handles Messages has talked to, matched loosely: numbers by their
        // digits, addresses by case.
        let known = (numbers + emails).filter { candidate in
            chatHandles.contains { Self.sameHandle($0, candidate) }
        }
        if known.count == 1 {
            return MessagesLink.url(handles: [chatHandles.first { Self.sameHandle($0, known[0]) } ?? known[0]])
        }
        let mobile = contact.phoneNumbers.filter { $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone }
            .map { Self.dialable($0.value.stringValue) }.filter { !$0.isEmpty }
        if let number = numbers.count == 1 ? numbers.first : (mobile.count == 1 ? mobile.first : nil) {
            return MessagesLink.url(handles: [number])
        }
        if numbers.isEmpty, emails.count == 1 {
            return MessagesLink.url(handles: [emails[0]])
        }
        SafeDiagnosticLog.shared.record("messages: the sender has several numbers, none with a conversation")
        return nil
    }

    /// The sender when it is already a number or address.
    static func handle(fromAddressOrNumber sender: String) -> String? {
        if sender.contains("@"), sender.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil {
            return sender.lowercased()
        }
        let digits = sender.filter(\.isNumber)
        guard digits.count >= 7, sender.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) else { return nil }
        return dialable(sender)
    }

    static func dialable(_ number: String) -> String {
        let kept = number.filter { $0.isNumber || $0 == "+" }
        guard kept.filter(\.isNumber).count >= 7 else { return "" }
        return kept.hasPrefix("+") ? "+" + kept.dropFirst().filter(\.isNumber) : kept
    }

    /// Numbers match on their last nine digits, so a saved number without a
    /// country code still finds the handle Messages has; addresses match by case.
    static func sameHandle(_ handle: String, _ candidate: String) -> Bool {
        if candidate.contains("@") { return handle.lowercased() == candidate }
        let a = handle.filter(\.isNumber), b = candidate.filter(\.isNumber)
        guard a.count >= 7, b.count >= 7 else { return false }
        return a.suffix(9) == b.suffix(9)
    }

    /// The one contact with this name, asking for access the first time.
    private static func contact(named name: String) async -> CNContact? {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
        } else if status != .authorized {
            SafeDiagnosticLog.shared.record("messages: no Contacts access")
            return nil
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        guard let matches = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys) else { return nil }
        let wanted = normalized(name)
        let exact = matches.filter { contact in
            [CNContactFormatter.string(from: contact, style: .fullName), contact.nickname, contact.organizationName,
             "\(contact.givenName) \(contact.familyName)", "\(contact.familyName) \(contact.givenName)", "\(contact.familyName)\(contact.givenName)"]
                .compactMap { $0 }.map(normalized).contains(wanted)
        }
        return exact.count == 1 ? exact[0] : (matches.count == 1 ? matches[0] : nil)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

extension ChatDatabase {
    /// Everyone Messages has a handle for.
    func handles() throws -> [String] {
        let database = try SQLiteDatabase.opening(url)
        return try database.rows("select id from handle").compactMap { $0[0].text }
    }

    /// The members of the group chat with this name, if Messages has one.
    func handles(forChatNamed name: String) throws -> [String] {
        let database = try SQLiteDatabase.opening(url)
        let rows = try database.rows("""
            select handle.id from chat
            join chat_handle_join on chat_handle_join.chat_id = chat.ROWID
            join handle on handle.ROWID = chat_handle_join.handle_id
            where chat.display_name = ?1
            order by handle.id
            """, [.text(name)])
        return rows.compactMap { $0[0].text }
    }
}
