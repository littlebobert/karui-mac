import Contacts
import Foundation

/// The ready-made auto replies. Custom uses the person's own text.
public enum AutoReplyMessage: String, Codable, CaseIterable, Identifiable, Sendable {
    case busy
    case driving
    case meeting
    case asleep
    case away
    case custom

    public var id: String { rawValue }

    /// Stock messages in the order the menus list them, starting with the default.
    public static let stock: [AutoReplyMessage] = [.busy, .driving, .meeting, .asleep, .away]

    public var titleKey: String {
        switch self {
        case .busy: "Busy"
        case .driving: "Driving"
        case .meeting: "In a Meeting"
        case .asleep: "Asleep"
        case .away: "Away"
        case .custom: "Custom"
        }
    }

    public var systemImage: String {
        switch self {
        case .busy: "hourglass"
        case .driving: "car.fill"
        case .meeting: "person.3.fill"
        case .asleep: "bed.double.fill"
        case .away: "airplane"
        case .custom: "pencil"
        }
    }

    /// The stock text. Nil for Custom, which has none.
    public var stockTextKey: String? {
        switch self {
        case .busy: "I can’t reply right now. I’ll get back to you soon."
        case .driving: "I’m driving and will reply when I’m stopped."
        case .meeting: "I’m in a meeting and will reply afterward."
        case .asleep: "I’m asleep and will reply in the morning."
        case .away: "I’m away and checking messages less often. I’ll reply when I can."
        case .custom: nil
        }
    }
}

/// How long Auto Reply stays on once it's turned on.
public enum AutoReplyDuration: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case threeHours
    case untilMorning
    case untilTurnedOff

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .oneHour: "For 1 Hour"
        case .threeHours: "For 3 Hours"
        case .untilMorning: "Until Morning"
        case .untilTurnedOff: "Until I Turn It Off"
        }
    }

    /// Morning is Wake Me's wake-up time, so the two agree on when the night ends.
    public func endDate(from now: Date, wakeUpMinuteOfDay: Int, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: now.addingTimeInterval(60 * 60)
        case .threeHours: now.addingTimeInterval(3 * 60 * 60)
        case .untilMorning:
            calendar.nextDate(
                after: now,
                matching: DateComponents(hour: wakeUpMinuteOfDay / 60, minute: wakeUpMinuteOfDay % 60),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(8 * 60 * 60)
        case .untilTurnedOff: .distantFuture
        }
    }
}

public struct AutoReplySettings: Codable, Equatable, Sendable {
    public var message: AutoReplyMessage = .busy
    public var customText: String = ""
    /// Ends each reply with "(Auto-reply)", so no one mistakes it for you.
    public var addsLabel: Bool = true
    /// When Auto Reply turns itself off; nil while it's off. `.distantFuture` stays on
    /// until it's turned off.
    public var activeUntil: Date?
    /// When it was last turned on. Each VIP gets one reply per activation.
    public var activatedAt: Date?
    /// The number, email, or account chosen for each VIP in each app, keyed by
    /// `choiceKey`. Only set once someone picks; otherwise the app's default is used.
    public var replyChoices: [String: String] = [:]
    /// VIPs who never get auto replies, though they stay VIPs.
    public var excludedIdentityIDs: Set<UUID> = []
    /// Turn On During Meetings.
    public var meetings = AutoReplyMeetingRule()

    public init() {}

    public func chosenAddress(for identityID: UUID, in app: AutoReplyApp) -> String? {
        replyChoices[Self.choiceKey(identityID, app)]
    }

    public mutating func setChosenAddress(_ address: String, for identityID: UUID, in app: AutoReplyApp) {
        replyChoices[Self.choiceKey(identityID, app)] = address
    }

    public func includes(_ identityID: UUID) -> Bool {
        !excludedIdentityIDs.contains(identityID)
    }

    public mutating func setIncluded(_ isIncluded: Bool, _ identityID: UUID) {
        if isIncluded {
            excludedIdentityIDs.remove(identityID)
        } else {
            excludedIdentityIDs.insert(identityID)
        }
    }

    /// Drops a removed VIP's choices.
    public mutating func forget(_ identityID: UUID) {
        excludedIdentityIDs.remove(identityID)
        replyChoices = replyChoices.filter { !$0.key.hasPrefix(identityID.uuidString + "|") }
    }

    private static func choiceKey(_ identityID: UUID, _ app: AutoReplyApp) -> String {
        "\(identityID.uuidString)|\(app.rawValue)"
    }

    /// Turned on by hand and not yet ended. Meetings count too: see `activation`.
    public func isActive(at now: Date = .now) -> Bool {
        guard let activeUntil else { return false }
        return now < activeUntil
    }

    /// Why Auto Reply is on at `now`, or nil while it's off. Turning it on by hand wins
    /// over a meeting; a meeting counts only while the rule is on and not skipped.
    public func activation(at now: Date = .now, meeting: MeetingSession?) -> AutoReplyActivation? {
        if isActive(at: now), let activeUntil { return .manual(until: activeUntil) }
        guard meetings.isEnabled, let meeting, meeting.startDate <= now, now < meeting.endDate,
              !meetings.isSkipped(at: now) else {
            return nil
        }
        return .meeting(meeting)
    }

    /// The message this activation sends. A meeting falls back to In a Meeting when its
    /// message is Custom without text.
    public func message(for activation: AutoReplyActivation) -> AutoReplyMessage {
        switch activation {
        case .manual: message
        case .meeting: meetingMessage
        }
    }

    /// What meetings send: the rule's message, or In a Meeting while that's Custom
    /// without text.
    public var meetingMessage: AutoReplyMessage {
        usableMessages.contains(meetings.message) ? meetings.message : .meeting
    }

    public var staysOnUntilTurnedOff: Bool { activeUntil == .distantFuture }

    /// How long someone waits for another reply while Auto Reply stays on until turned
    /// off, which can last days: a message two days later is a new conversation.
    public static let untilTurnedOffRepeatInterval: TimeInterval = 12 * 60 * 60

    /// Replies since this count against someone getting another: the start of this
    /// session, or for Until I Turn It Off, the last 12 hours of it.
    public func replyWindowStart(now: Date = .now) -> Date? {
        guard let activatedAt else { return nil }
        guard staysOnUntilTurnedOff else { return activatedAt }
        return max(activatedAt, now.addingTimeInterval(-Self.untilTurnedOffRepeatInterval))
    }

    /// The reply window for this activation: for a meeting, the start of its run of
    /// back-to-back meetings.
    public func replyWindowStart(now: Date = .now, activation: AutoReplyActivation) -> Date? {
        switch activation {
        case .manual: replyWindowStart(now: now)
        case .meeting(let session): session.startDate
        }
    }

    public mutating func turnOn(_ message: AutoReplyMessage, until end: Date, now: Date = .now) {
        self.message = message
        activeUntil = end
        activatedAt = now
    }

    public mutating func turnOff() {
        activeUntil = nil
    }

    /// Turns it off, and keeps the meeting rule from turning it straight back on until
    /// the current meeting ends.
    public mutating func turnOff(now: Date = .now, meeting: MeetingSession?) {
        activeUntil = nil
        if meetings.isEnabled, let meeting, now < meeting.endDate {
            meetings.skippedUntil = meeting.endDate
        }
    }

    /// Custom only counts once it has text.
    public var usableMessages: [AutoReplyMessage] {
        AutoReplyMessage.stock + (customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.custom])
    }

    /// The reply as sent. Asleep adds how to get through when Wake Me would ring for
    /// this person, since a missed call is the one thing that can still wake you.
    public func text(
        for message: AutoReplyMessage? = nil,
        wakeMeHint: AutoReplyWakeMeHint? = nil,
        locale: Locale = .current
    ) -> String {
        let message = message ?? self.message
        var text = message.stockTextKey.map { KaruiLocalization.string($0, locale: locale) }
            ?? customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if message == .asleep, let wakeMeHint {
            text += " " + KaruiLocalization.string(wakeMeHint.textKey, locale: locale)
        }
        if addsLabel {
            text += " " + KaruiLocalization.string("(Auto-reply)", locale: locale)
        }
        return text
    }

    private enum CodingKeys: String, CodingKey {
        case message, customText, addsLabel, activeUntil, activatedAt, replyChoices, excludedIdentityIDs
        case meetings
        /// One choice per VIP, used by Messages, before choices were per app.
        case replyAddresses
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encode(customText, forKey: .customText)
        try container.encode(addsLabel, forKey: .addsLabel)
        try container.encodeIfPresent(activeUntil, forKey: .activeUntil)
        try container.encodeIfPresent(activatedAt, forKey: .activatedAt)
        try container.encode(replyChoices, forKey: .replyChoices)
        try container.encode(excludedIdentityIDs, forKey: .excludedIdentityIDs)
        try container.encode(meetings, forKey: .meetings)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(AutoReplyMessage.self, forKey: .message) ?? .busy
        customText = try container.decodeIfPresent(String.self, forKey: .customText) ?? ""
        addsLabel = try container.decodeIfPresent(Bool.self, forKey: .addsLabel) ?? true
        activeUntil = try container.decodeIfPresent(Date.self, forKey: .activeUntil)
        activatedAt = try container.decodeIfPresent(Date.self, forKey: .activatedAt)
        // Losing a choice beats losing every setting, so these never fail the decode.
        replyChoices = (try? container.decodeIfPresent([String: String].self, forKey: .replyChoices)) ?? [:]
        excludedIdentityIDs = (try? container.decodeIfPresent(Set<UUID>.self, forKey: .excludedIdentityIDs)) ?? []
        meetings = (try? container.decodeIfPresent(AutoReplyMeetingRule.self, forKey: .meetings)) ?? AutoReplyMeetingRule()
        if let legacy = try? container.decodeIfPresent([UUID: String].self, forKey: .replyAddresses) {
            for (identityID, address) in legacy where chosenAddress(for: identityID, in: .messages) == nil {
                setChosenAddress(address, for: identityID, in: .messages)
            }
        }
    }
}

public enum AutoReplyWakeMeHint: Sendable {
    /// Any missed call rings.
    case callOnce
    /// A second missed call rings.
    case callTwice

    public var textKey: String {
        switch self {
        case .callOnce: "If it’s urgent, call me."
        case .callTwice: "If it’s urgent, call me twice."
        }
    }

    /// Only for people who can ring Wake Me, and only when a call would.
    public static func hint(for identity: VIPIdentity, policy: TriagePolicy) -> AutoReplyWakeMeHint? {
        guard policy.wakeMeEnabled, policy.wakeMeIdentityIDs.contains(identity.id) else { return nil }
        if policy.wakeMeOnFirstMissedCall { return .callOnce }
        return policy.wakeMeOnRepeatedAttempts ? .callTwice : nil
    }
}

/// An account from a contact card's social profiles or instant message fields, such
/// as LINE or Facebook Messenger, for replying in that app.
public struct MessagingAccount: Codable, Equatable, Hashable, Sendable {
    public let service: String
    public let handle: String

    public init(
        service: String,
        handle: String
    ) {
        self.service = service
        self.handle = handle
    }

    /// Nil when the contact came without these fields, so settings can tell that
    /// apart from a card that has none.
    public static func accounts(from contact: CNContact) -> [MessagingAccount]? {
        guard contact.isKeyAvailable(CNContactSocialProfilesKey)
            || contact.isKeyAvailable(CNContactInstantMessageAddressesKey) else {
            return nil
        }
        var accounts: [MessagingAccount] = []
        if contact.isKeyAvailable(CNContactSocialProfilesKey) {
            for profile in contact.socialProfiles.map(\.value) {
                let handle = [profile.username, profile.userIdentifier, profile.urlString]
                    .first { !$0.isEmpty }
                if let handle { accounts.append(MessagingAccount(service: profile.service, handle: handle)) }
            }
        }
        if contact.isKeyAvailable(CNContactInstantMessageAddressesKey) {
            for address in contact.instantMessageAddresses.map(\.value) where !address.username.isEmpty {
                accounts.append(MessagingAccount(service: address.service, handle: address.username))
            }
        }
        var seen: Set<MessagingAccount> = []
        return accounts.filter { !$0.service.isEmpty && seen.insert($0).inserted }
    }
}

/// The apps Karui can reply in, each through its own step in the Shortcut.
public enum AutoReplyApp: String, CaseIterable, Sendable {
    case messages = "Messages"
    case whatsApp = "WhatsApp"
    case line = "LINE"
    case messenger = "Messenger"

    /// "Messages, WhatsApp, LINE, and Messenger", for settings.
    public static func listDescription(locale: Locale = .current) -> String {
        allCases.map(\.rawValue).formatted(.list(type: .and).locale(locale))
    }

    public init?(source: String) {
        guard let appName = SourceAppRouter.route(for: source)?.appName else { return nil }
        self.init(rawValue: appName)
    }

    /// Everywhere this app could reply to the VIP, from their contact card.
    public func options(for identity: VIPIdentity) -> [AutoReplyOption] {
        let phones = identity.phoneNumbers.map { AutoReplyOption(kind: .phoneNumber, value: $0) }
        let emails = identity.emails.map { AutoReplyOption(kind: .email, value: $0) }
        let accounts = (identity.messagingAccounts ?? [])
            .filter { matches(service: $0.service) }
            .map { AutoReplyOption(kind: .account, value: $0.handle, service: $0.service) }
        switch self {
        case .messages: return phones + emails
        case .whatsApp: return phones
        case .line: return phones + accounts
        case .messenger: return accounts
        }
    }

    /// Used until someone picks: the mobile number, as for Messages and WhatsApp. LINE
    /// prefers a number labeled LINE, which is surely the one they use there.
    public func defaultOption(for identity: VIPIdentity) -> AutoReplyOption? {
        let options = options(for: identity)
        let preferredPhone = Self.preferredPhoneNumber(of: identity)
        switch self {
        case .messages, .whatsApp:
            return options.first { $0.value == preferredPhone } ?? options.first
        case .line:
            return options.first { $0.kind == .phoneNumber && identity.phoneLabel(for: $0.value).map(matches(service:)) == true }
                ?? options.first { $0.value == preferredPhone }
                ?? options.first
        case .messenger:
            return options.first
        }
    }

    /// Where to send the reply: the number or email the message came from when the
    /// notification shows it, then the one chosen in settings, then the default.
    public func recipient(for identity: VIPIdentity, sender: String?, chosenAddress: String? = nil) -> AutoReplyRecipient? {
        let options = options(for: identity)
        guard !options.isEmpty else { return nil }
        let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if self != .messenger, Self.isPhoneNumber(sender) { return AutoReplyRecipient(phoneNumber: sender) }
        if self == .messages, Self.isEmail(sender) { return AutoReplyRecipient(email: sender) }
        if let chosenAddress, let chosen = options.first(where: { $0.value == chosenAddress }) {
            return chosen.recipient
        }
        return defaultOption(for: identity)?.recipient
    }

    /// Whether a contact card's service name or label means this app: "LINE",
    /// "LINE ID", "jp.naver.line", "Facebook Messenger", and so on. Whole words only,
    /// so "Online" isn't LINE.
    public func matches(service: String) -> Bool {
        let words = Set(service.lowercased().split { !$0.isLetter }.map(String.init))
        switch self {
        case .line: return words.contains("line") || words.contains("naver")
        case .messenger: return words.contains("messenger") || words.contains("facebook") || words.contains("fb")
        default: return false
        }
    }

    /// The apps this VIP can get a reply in, for the settings list.
    public static func apps(for identity: VIPIdentity) -> [AutoReplyApp] {
        allCases.filter { !$0.options(for: identity).isEmpty }
    }

    private static func preferredPhoneNumber(of identity: VIPIdentity) -> String? {
        let mobileLabels: Set<String> = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone]
        return identity.phoneNumbers.first { identity.phoneLabel(for: $0).map(mobileLabels.contains) == true }
            ?? identity.phoneNumbers.first
    }

    public static func isEmail(_ text: String) -> Bool {
        text.contains("@") && !text.contains(" ")
    }

    public static func isPhoneNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber).count
        return digits >= 7 && text.allSatisfy { $0.isNumber || " +-().".contains($0) }
    }
}

/// One place a reply can go: a number, an email, or an account in the app.
public struct AutoReplyOption: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case phoneNumber
        case email
        case account
    }

    public let kind: Kind
    public let value: String
    /// The account's service as written on the card, such as "LINE".
    public var service: String? = nil

    public init(
        kind: Kind,
        value: String,
        service: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.service = service
    }

    public var recipient: AutoReplyRecipient {
        switch kind {
        case .phoneNumber: AutoReplyRecipient(phoneNumber: value)
        case .email: AutoReplyRecipient(email: value)
        case .account: AutoReplyRecipient(account: value)
        }
    }
}

public struct AutoReplyRecipient: Equatable, Sendable {
    public var phoneNumber: String?
    public var email: String?
    /// The LINE or Messenger account from the contact card.
    public var account: String?

    public init(
        phoneNumber: String? = nil,
        email: String? = nil,
        account: String? = nil
    ) {
        self.phoneNumber = phoneNumber
        self.email = email
        self.account = account
    }
}

/// Everything the Shortcut needs to send one reply.
public struct AutoReplyPlan: Equatable, Sendable {
    public let identityID: UUID
    public let recipientName: String
    public let app: AutoReplyApp
    public let recipient: AutoReplyRecipient
    public let text: String

    public init(
        identityID: UUID,
        recipientName: String,
        app: AutoReplyApp,
        recipient: AutoReplyRecipient,
        text: String
    ) {
        self.identityID = identityID
        self.recipientName = recipientName
        self.app = app
        self.recipient = recipient
        self.text = text
    }
}

public enum AutoReplyPlanner {
    /// A reply for this notification, or nil: Auto Reply is off, the sender isn't a VIP
    /// Karui can reach in this app, it's a group chat or a code, or they already got one.
    /// `meeting` is the meeting under way, if any, for Turn On During Meetings; the
    /// reply window is passed to `alreadyReplied` so it can look back to its start.
    public static func plan(
        for notification: NotificationInput,
        recipients: String?,
        policy: TriagePolicy,
        meeting: MeetingSession? = nil,
        alreadyReplied: (UUID, _ since: Date?) -> Bool,
        now: Date = .now,
        locale: Locale = .current
    ) -> AutoReplyPlan? {
        let settings = policy.autoReply
        guard let activation = settings.activation(at: now, meeting: meeting) else { return nil }
        let message = settings.message(for: activation)
        let windowStart = settings.replyWindowStart(now: now, activation: activation)
        guard message != .custom
                || !settings.customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let app = AutoReplyApp(source: notification.source),
              !ConversationCooldown.isGroup(recipients: recipients),
              OneTimeCodeDetector.code(in: notification) == nil,
              let identity = ImportantPersonMatcher.resolveSender(
                  notification.sender,
                  identities: policy.vipIdentities
              )?.identity,
              settings.includes(identity.id),
              !alreadyReplied(identity.id, windowStart),
              let recipient = app.recipient(
                  for: identity,
                  sender: notification.sender,
                  chosenAddress: settings.chosenAddress(for: identity.id, in: app)
              ) else {
            return nil
        }
        return AutoReplyPlan(
            identityID: identity.id,
            recipientName: identity.displayName,
            app: app,
            recipient: recipient,
            text: settings.text(
                for: message,
                wakeMeHint: AutoReplyWakeMeHint.hint(for: identity, policy: policy),
                locale: locale
            )
        )
    }
}

/// The replies Karui handed to the Shortcut, newest first, and when the Shortcut last
/// asked for one, so settings can tell whether it's been updated.
public enum AutoReplyLog {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: Date { date }
        public let identityID: UUID
        public let name: String
        public let app: String
        public let date: Date
        /// The History item it answered, when Karui found it.
        public var recordID: UUID?

        public init(
            identityID: UUID,
            name: String,
            app: String,
            date: Date,
            recordID: UUID? = nil
        ) {
            self.identityID = identityID
            self.name = name
            self.app = app
            self.date = date
            self.recordID = recordID
        }
    }

    private static let entriesKey = "karui.autoReply.log"
    private static let lastRequestKey = "karui.autoReply.lastShortcutRequest"
    public static let limit = 20

    public static func entries(defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: entriesKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    public static func record(
        _ plan: AutoReplyPlan,
        recordID: UUID? = nil,
        at date: Date = .now,
        defaults: UserDefaults = .standard
    ) {
        let entry = Entry(
            identityID: plan.identityID,
            name: plan.recipientName,
            app: plan.app.rawValue,
            date: date,
            recordID: recordID
        )
        let updated = Array(([entry] + entries(defaults: defaults)).prefix(limit))
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: entriesKey)
        }
    }

    public static func hasReplied(to identityID: UUID, since start: Date?, defaults: UserDefaults = .standard) -> Bool {
        guard let start else { return false }
        return entries(defaults: defaults).contains { $0.identityID == identityID && $0.date >= start }
    }

    public static func recordShortcutRequest(at date: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastRequestKey)
    }

    public static func lastShortcutRequest(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastRequestKey) as? Date
    }
}
