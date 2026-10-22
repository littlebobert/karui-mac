import Foundation

public enum TriageCategory: String, Codable, CaseIterable, Sendable {
    case notifyNow
    case summary
    case silence

    public func title(locale: Locale = .current) -> String {
        switch self {
        case .notifyNow: KaruiLocalization.string("Important", locale: locale)
        case .summary: KaruiLocalization.string("Neutral", locale: locale)
        case .silence: KaruiLocalization.string("Spam", locale: locale)
        }
    }

    public var title: String { title() }

    public var systemImage: String {
        switch self {
        case .notifyNow: "bell.badge.fill"
        case .summary: "bell.slash.fill"
        case .silence: "trash.fill"
        }
    }
}

public enum SenderPromotionPolicy {
    public static func eligibleSender(
        category: TriageCategory,
        sender: String?,
        vipIdentities: [VIPIdentity]
    ) -> String? {
        guard category == .summary || category == .silence else { return nil }
        guard let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sender.isEmpty else {
            return nil
        }
        guard ImportantPersonMatcher.resolveSender(
            sender,
            identities: vipIdentities
        ) == nil else {
            return nil
        }
        return sender
    }

    public static func adding(_ sender: String, to importantPeople: [String]) -> [String] {
        guard !importantPeople.contains(where: {
            ImportantPersonMatcher.namesMatch($0, sender)
        }) else {
            return importantPeople
        }
        return importantPeople + [sender]
    }
}

public enum ImportantAppMatcher {
    public static func matchingApp(for source: String, in importantApps: [String]) -> String? {
        let sourceKey = canonicalKey(source)
        guard !sourceKey.isEmpty else { return nil }
        return importantApps.first { canonicalKey($0) == sourceKey }
    }

    public static func canonicalKey(_ appName: String) -> String {
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalName = SourceAppRouter.route(for: trimmedName)?.appName ?? trimmedName
        return canonicalName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

/// The short lists Add App offers: apps people most often want as Important (where
/// people reach them) or Quiet (social apps whose "someone liked your post" pings
/// sound personal). Japan gets LINE, Chatwork, and Mercari in place of apps less used
/// there. Names are the ones SourceAppRouter knows, so they match however iOS names
/// the app.
public enum SuggestedApps {
    public static func important(locale: Locale = .current) -> [String] {
        if isJapan(locale) {
            return ["LINE", "Messages", "Slack", "Microsoft Teams", "Chatwork", "Gmail", "Calendar"]
        }
        if isKorea(locale) {
            return ["KakaoTalk", "Messages", "Slack", "Microsoft Teams", "Gmail", "Calendar"]
        }
        return ["Messages", "WhatsApp", "Slack", "Microsoft Teams", "Gmail", "Outlook", "Calendar"]
    }

    public static func quiet(locale: Locale = .current) -> [String] {
        if isJapan(locale) {
            return ["Instagram", "X", "TikTok", "Facebook", "Threads", "Mercari", "PayPay"]
        }
        if isKorea(locale) {
            return ["Instagram", "YouTube", "TikTok", "Facebook", "Threads", "X"]
        }
        return ["Instagram", "Facebook", "LinkedIn", "X", "TikTok", "Threads", "Reddit"]
    }

    /// What Japanese and Korean iPhones call Apple's apps (and Mercari and KakaoTalk),
    /// so the menu shows the names people see. Either spelling matches the same app.
    public static func displayName(for appName: String, locale: Locale = .current) -> String {
        switch locale.language.languageCode {
        case .japanese?: return japaneseNames[appName] ?? appName
        case .korean?: return koreanNames[appName] ?? appName
        default: return appName
        }
    }

    private static let japaneseNames = [
        "Messages": "メッセージ",
        "Mail": "メール",
        "Calendar": "カレンダー",
        "Reminders": "リマインダー",
        "Wallet": "ウォレット",
        "Mercari": "メルカリ",
    ]

    private static let koreanNames = [
        "Messages": "메시지",
        "Mail": "메일",
        "Calendar": "캘린더",
        "Reminders": "미리 알림",
        "Wallet": "지갑",
        "KakaoTalk": "카카오톡",
    ]

    private static func isJapan(_ locale: Locale) -> Bool {
        locale.region == .japan || locale.language.languageCode == .japanese
    }

    private static func isKorea(_ locale: Locale) -> Bool {
        locale.region == .southKorea || locale.language.languageCode == .korean
    }
}

/// When work apps count as important. Mon–Fri, 9:00 to 18:00 unless changed.
public enum WorkHours {
    public static let defaultDays = [2, 3, 4, 5, 6]
    public static let defaultStartMinuteOfDay = 9 * 60
    public static let defaultEndMinuteOfDay = 18 * 60

    private static let knownWorkApps = ["Slack", "Microsoft Teams", "Chatwork", "Zoom", "GitHub", "Linear", "Notion"]

    public static func isKnownWorkApp(_ appName: String) -> Bool {
        ImportantAppMatcher.matchingApp(for: appName, in: knownWorkApps) != nil
    }

    /// Hours that cross midnight belong to the day they start on. Equal start and end
    /// times mean the whole of each work day.
    public static func contains(
        _ date: Date,
        days: [Int],
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        calendar: Calendar = .current
    ) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday else { return false }
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let isWorkDay = days.contains(weekday)
        if startMinuteOfDay == endMinuteOfDay { return isWorkDay }
        if startMinuteOfDay < endMinuteOfDay {
            return isWorkDay && minute >= startMinuteOfDay && minute < endMinuteOfDay
        }
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return (isWorkDay && minute >= startMinuteOfDay)
            || (days.contains(previousWeekday) && minute < endMinuteOfDay)
    }
}

public enum UserMentionDetector {
    public static func mentionedName(in notification: NotificationInput, userNames: [String]) -> String? {
        let text = "\(notification.title)\n\(notification.body)"
        return userNames
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@").union(.whitespaces)) }
            .sorted { $0.count > $1.count }
            .first { containsMention(of: $0, in: text) }
    }

    private static func containsMention(of name: String, in text: String) -> Bool {
        let nameWords = name
            .split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !nameWords.isEmpty else { return false }
        let pattern = "@" + nameWords.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        return text.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

/// The @names in a notification that aren't the user's. "@Bob can you send me that
/// report?" in a channel is a request to Bob, and the model read it as one to the user.
/// Only an "@" starting a word counts, so email addresses don't.
public enum OtherMentionDetector {
    public static let maximumMentions = 3

    public static func mentions(in notification: NotificationInput, userNames: [String]) -> [String] {
        // Slack can end a reply with "@Sender in #channel": the sender isn't addressed.
        let names = userNames + [notification.sender].compactMap { $0 }
        let userWords = Set(names.flatMap { name in
            let words = name
                .trimmingCharacters(in: CharacterSet(charactersIn: "@").union(.whitespaces))
                .lowercased()
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            // "@Justin" and "@JustinGarcia" both mean Justin Garcia.
            return words.prefix(1) + [words.joined()]
        })
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}._%+-])@([\p{L}\p{N}][\p{L}\p{N}._-]*)"#) else {
            return []
        }
        let body = notification.body
        var mentions: [String] = []
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let range = Range(match.range(at: 1), in: body) else { continue }
            let handle = String(body[range]).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
            guard !handle.isEmpty,
                  !userWords.contains(handle.lowercased()),
                  !mentions.contains(where: { $0.caseInsensitiveCompare(handle) == .orderedSame }) else { continue }
            mentions.append(handle)
            if mentions.count == maximumMentions { break }
        }
        return mentions
    }
}

/// The on-device model kept calling a question to someone else Important even when
/// told who it's for ("@Yuta When will this happen?"). After it answers, a message
/// addressed only to other people drops to Neutral, unless something the user set up
/// says otherwise. Needs the user's names, or Karui can't know it isn't them.
public enum AddressedElsewhereCheck {
    public static func applying(to result: TriageResult, for notification: NotificationInput, policy: TriagePolicy) -> TriageResult {
        guard result.category == .notifyNow, notification.isTimeSensitive != true else { return result }
        let userNames = policy.commaSeparatedValues(from: policy.userNames)
        guard !userNames.isEmpty else { return result }
        let mentions = OtherMentionDetector.mentions(in: notification, userNames: userNames)
        guard !mentions.isEmpty,
              RuleBasedClassifier.firstMatch(
                  in: "\(notification.title)\n\(notification.body)",
                  terms: policy.terms(from: policy.urgentKeywords)
              ) == nil else {
            return result
        }
        var checked = TriageResult(
            category: .summary,
            confidence: 0.7,
            reason: KaruiLocalization.formatted(
                "Addressed to %@, not you.",
                mentions.map { "@\($0)" }.formatted(.list(type: .and))
            ),
            engine: result.engine,
            engineDetail: result.engineDetail,
            interest: result.interest
        )
        checked.isModelFallback = result.isModelFallback
        checked.rateLimitResetDate = result.rateLimitResetDate
        checked.tags = result.tags
        return checked
    }
}

/// When Second Opinion asks Private Cloud Compute.
public enum SecondOpinionMode: String, Codable, CaseIterable, Sendable {
    /// Only when the on-device model couldn't sort the notification.
    case whenNeeded
    /// After every on-device answer, which alerts first and is then corrected.
    case always
    /// Before alerting: an on-device Important is held until the cloud answers, and
    /// sent anyway if it doesn't within `SecondOpinion.heldAlertDelay`.
    case first

    /// Asks about everything the on-device model decided, not only what it couldn't.
    public var asksAboutEveryModelAnswer: Bool { self != .whenNeeded }
}

public struct NotificationInput: Sendable, Equatable {
    public let source: String
    public let title: String
    public let body: String
    public let sender: String?
    public let isTimeSensitive: Bool?
    public var translation: NotificationTranslation?
    /// The subtitle on its own, such as a group chat's name. `body` already starts
    /// with it; this lets the model's prompt label it separately.
    public var subtitle: String?
    /// When the notification arrived. Nil means now; set when reclassifying history.
    public var receivedAt: Date?
    /// The other people in the conversation, as the Shortcut gave them: a group
    /// chat's members besides the sender.
    public var recipients: String?
    /// Whether it was written to the user alone rather than in a channel or group.
    /// Nil: taken from the notification's shape (`ConversationCooldown.looksLikeDirectMessage`),
    /// which needs the sender apart from the title, as the iPhone's Shortcut gives them.
    /// False where it can't be told, as on the Mac, whose sender is the title.
    public var isDirectMessage: Bool?

    public init(
        source: String,
        title: String,
        body: String,
        sender: String? = nil,
        isTimeSensitive: Bool? = nil,
        translation: NotificationTranslation? = nil,
        subtitle: String? = nil,
        receivedAt: Date? = nil,
        recipients: String? = nil,
        isDirectMessage: Bool? = nil
    ) {
        self.source = source
        self.title = title
        self.body = body
        self.sender = sender
        self.isTimeSensitive = isTimeSensitive
        self.translation = translation
        self.subtitle = subtitle
        self.receivedAt = receivedAt
        self.recipients = recipients
        self.isDirectMessage = isDirectMessage
    }

    public var translatedText: String? {
        guard let translation else { return nil }
        let text = [translation.title, translation.displayBody].compactMap { $0 }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

public struct TriageResult: Sendable, Equatable {
    public let category: TriageCategory
    public let confidence: Double
    public let reason: String
    public let engine: ClassificationEngine
    public let engineDetail: String?
    public let resolvedVIPIdentityID: UUID?
    public let resolvedVIPDisplayName: String?
    /// How much the person would want to see this later, 1 through 5, from the
    /// on-device model. Ranks the daily summary; nil when rules decided.
    public let interest: Int?
    /// The on-device model failed or was unavailable, so rules decided instead. Lets
    /// callers avoid replacing a model result with a fallback; the iPhone keeps it
    /// with each History revision.
    public var isModelFallback = false
    /// When iOS said the on-device model's rate limit ends, for a fallback it caused.
    /// Nil when iOS didn't say, as its older error never does.
    public var rateLimitResetDate: Date?
    /// How long the model took, in seconds, including attempts that failed or timed
    /// out. Nil when rules decided without trying a model. For a second opinion, the
    /// whole round trip through the Shortcut.
    public var modelDuration: TimeInterval?
    /// Something the notification asks the person to do by a certain day, found by a
    /// model while deadline reminders are on. Not stored. Only Private Cloud Compute's
    /// becomes a reminder; the on-device model's is a reason to ask it.
    public var deadline: ExtractedDeadline?
    /// Search tags from the on-device model, kept on the History item. See `SearchTags`.
    public var tags: [String]?

    public init(
        category: TriageCategory,
        confidence: Double,
        reason: String,
        engine: ClassificationEngine,
        engineDetail: String? = nil,
        resolvedVIPIdentityID: UUID? = nil,
        resolvedVIPDisplayName: String? = nil,
        interest: Int? = nil
    ) {
        self.category = category
        self.confidence = confidence
        self.reason = reason
        self.engine = engine
        self.engineDetail = engineDetail
        self.resolvedVIPIdentityID = resolvedVIPIdentityID
        self.resolvedVIPDisplayName = resolvedVIPDisplayName
        self.interest = interest
    }
}

public enum ClassificationEngine: String, Codable, Sendable {
    case onDeviceModel = "On-device model"
    case deterministicRules = "Transparent rules"
    /// Apple's larger model, asked by the Shortcut for a second opinion.
    case privateCloudCompute = "Private Cloud Compute"
    /// The person, fixing the category from History.
    case person = "Your correction"
    /// A value from a newer Karui, read by an older one: the item still shows.
    case unknown = "Unknown"

    /// Tolerates values a newer Karui wrote, so going back to an older build never
    /// hides an item or its revisions.
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    public func title(locale: Locale = .current) -> String {
        KaruiLocalization.string(rawValue, locale: locale)
    }
}

public enum VIPIdentityProvenance: String, Codable, Equatable, Sendable {
    case contact
    case manual
}

public struct VIPIdentity: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    /// The contact's nickname, matched as a whole name alongside `displayName`.
    public var nickname: String?
    public var contactIdentifier: String?
    public var emails: [String]
    public var phoneNumbers: [String]
    /// The Contacts label for each phone number, keyed by the number as stored
    /// (raw label such as `_$!<Mobile>!$_`, or a custom label). Absent for snapshots
    /// taken before labels were captured.
    public var phoneLabels: [String: String]?
    public var provenance: VIPIdentityProvenance
    /// A small JPEG of the contact's photo, shown on replacement notifications. Stored
    /// with the rest of the snapshot so removing the VIP removes it too.
    public var thumbnailImageData: Data?
    /// LINE, Messenger, and similar accounts from the contact card, for Auto Reply.
    /// Nil for snapshots taken before they were captured.
    public var messagingAccounts: [MessagingAccount]?

    public init(
        id: UUID = UUID(),
        displayName: String,
        nickname: String? = nil,
        contactIdentifier: String? = nil,
        emails: [String] = [],
        phoneNumbers: [String] = [],
        phoneLabels: [String: String]? = nil,
        provenance: VIPIdentityProvenance,
        thumbnailImageData: Data? = nil,
        messagingAccounts: [MessagingAccount]? = nil
    ) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nickname = trimmedNickname?.isEmpty == false ? trimmedNickname : nil
        self.contactIdentifier = contactIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emails = Self.nonemptyUniqueValues(emails)
        let uniquePhoneNumbers = Self.nonemptyUniqueValues(phoneNumbers)
        self.phoneNumbers = uniquePhoneNumbers
        let keptLabels = (phoneLabels ?? [:]).filter { uniquePhoneNumbers.contains($0.key) && !$0.value.isEmpty }
        self.phoneLabels = keptLabels.isEmpty ? nil : keptLabels
        self.provenance = provenance
        self.thumbnailImageData = thumbnailImageData
        self.messagingAccounts = messagingAccounts
    }

    public func phoneLabel(for phoneNumber: String) -> String? {
        phoneLabels?[phoneNumber]
    }

    public static func manual(
        displayName: String,
        emails: [String] = [],
        phoneNumbers: [String] = [],
        id: UUID = UUID()
    ) -> VIPIdentity {
        VIPIdentity(
            id: id,
            displayName: displayName,
            emails: emails,
            phoneNumbers: phoneNumbers,
            provenance: .manual
        )
    }

    public static func contact(
        displayName: String,
        nickname: String? = nil,
        contactIdentifier: String,
        emails: [String],
        phoneNumbers: [String],
        phoneLabels: [String: String]? = nil,
        id: UUID = UUID(),
        thumbnailImageData: Data? = nil,
        messagingAccounts: [MessagingAccount]? = nil
    ) -> VIPIdentity {
        VIPIdentity(
            id: id,
            displayName: displayName,
            nickname: nickname,
            contactIdentifier: contactIdentifier,
            emails: emails,
            phoneNumbers: phoneNumbers,
            phoneLabels: phoneLabels,
            provenance: .contact,
            thumbnailImageData: thumbnailImageData,
            messagingAccounts: messagingAccounts
        )
    }

    /// "2 phone numbers · 1 email": everything on the card is matched, so count it all
    /// rather than showing whichever number or email happens to come first.
    public func contactDetailSummary(locale: Locale = .current) -> String? {
        var parts: [String] = []
        if !phoneNumbers.isEmpty {
            parts.append(KaruiLocalization.formatted(
                phoneNumbers.count == 1 ? "%lld phone number" : "%lld phone numbers",
                Int64(phoneNumbers.count),
                locale: locale
            ))
        }
        if !emails.isEmpty {
            parts.append(KaruiLocalization.formatted(
                emails.count == 1 ? "%lld email" : "%lld emails",
                Int64(emails.count),
                locale: locale
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func nonemptyUniqueValues(_ values: [String]) -> [String] {
        var normalizedValues: Set<String> = []
        return values.compactMap { value in
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            let normalizedValue = trimmedValue.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard normalizedValues.insert(normalizedValue).inserted else { return nil }
            return trimmedValue
        }
    }
}

public struct TriagePolicy: Codable, Equatable, Sendable {
    /// When the Neutral summary arrives by default: 9:00.
    public static let defaultNeutralDigestMinuteOfDay = 9 * 60
    /// Wake Me's default night, 22:00 to 6:00.
    public static let defaultWakeMeSleepStartMinuteOfDay = 22 * 60
    public static let defaultWakeMeSleepEndMinuteOfDay = 6 * 60
    public var vipIdentities: [VIPIdentity]
    public var importantApps: [String]
    /// Important apps that only count during work hours, named as in `importantApps`.
    public var workApps: [String]
    /// Apps where only VIPs, codes, urgent terms, and @mentions alert.
    public var quietApps: [String]
    /// Calendar weekday numbers, 1 being Sunday.
    public var workDays: [Int]
    /// Work hours as minutes after midnight.
    public var workStartMinuteOfDay: Int
    public var workEndMinuteOfDay: Int
    public var userNames: String
    public var translateNotifications: Bool
    public var readLanguages: [String]
    public var urgentKeywords: String
    public var summaryKeywords: String
    public var silenceKeywords: String
    public var prioritizeCalendarAndTravel: Bool
    public var silencePromotions: Bool
    /// A third message from the same sender within ten minutes is Important.
    public var escalateRepeatedSenders: Bool
    /// One notification a day summarizing the Neutral notifications.
    public var neutralDigestEnabled: Bool
    /// When the summary arrives, as minutes after midnight.
    public var neutralDigestMinuteOfDay: Int
    /// Messages carrying a verification code are Important.
    public var alertOneTimeCodes: Bool
    /// Wake Me: an emergency from a chosen person rings an alarm that breaks through
    /// silent mode and Focus.
    public var wakeMeEnabled: Bool
    /// The VIPs allowed to wake you, by `VIPIdentity.id`.
    public var wakeMeIdentityIDs: [UUID]
    public var wakeMeKeywords: String
    /// Several messages or calls from a Wake Me person within a few minutes ring too.
    public var wakeMeOnRepeatedAttempts: Bool
    /// A single missed call from a Wake Me person rings. Off by default: a pocket-dial
    /// at night would wake you.
    public var wakeMeOnFirstMissedCall: Bool
    /// Wake Me only rings between these times, as minutes after midnight. The window
    /// usually crosses midnight.
    public var wakeMeSleepStartMinuteOfDay: Int
    public var wakeMeSleepEndMinuteOfDay: Int
    /// Messages from one sender in quick succession arrive as one notification.
    public var combineRapidMessages: Bool
    /// After an alert about a conversation, more from it wait out a cooldown.
    public var conversationCooldown: Bool
    /// Replies to VIPs for you while it's on, through the Shortcut.
    public var autoReply: AutoReplySettings
    /// When the on-device model can't answer, the Shortcut asks Apple's Private Cloud
    /// Compute instead of settling for the rules. Off by default: it's the one feature
    /// that sends notification text off the device.
    public var secondOpinionEnabled: Bool
    /// When the Shortcut asks Private Cloud Compute, with Second Opinion on.
    public var secondOpinionMode = SecondOpinionMode.whenNeeded
    /// Off for setup's "Just keep unsent messages for now": with no Focus, the original
    /// notifications still arrive, so Karui saves and sorts them in History but never
    /// sends its own alerts, which would be duplicates.
    public var filtersNotifications = true
    /// A notification that asks for something by a certain day gets a reminder the
    /// day before. Off until the person asks for it, in setup or Settings. Needs
    /// Second Opinion: only Private Cloud Compute's reading of a deadline is trusted.
    public var deadlineRemindersEnabled = false
    /// Reminders are on and can actually be made: turning either setting on turns the
    /// other on too, but a restored backup can hold one without the other.
    public var deadlineRemindersActive: Bool { deadlineRemindersEnabled && secondOpinionEnabled }
    /// A one-to-one message or missed call from someone saved in Contacts alerts
    /// unless it looks like spam or an automated message. See `SavedContacts`.
    public var alertSavedContacts = true
    /// Karui for Mac's list of people the person has written to, as a Saved Contacts rule for every app.
    public var alertKnownCorrespondents = true
    /// Karui's verdicts go to the Mac so Karui for Mac can show History; the text stays here.
    public var showsHistoryOnMac = false
    /// With History on the Mac: also the text of notifications from apps the Mac doesn't have, encrypted.
    public var sendsPhoneOnlyNotificationsToMac = false
    /// Saved contacts the person took off that rule from History, by the name their
    /// notifications show.
    public var savedContactExceptions: [String] = []
    /// Chats the person asked to always alert about, for a while or for good, from
    /// the prompt after making one of their messages Important in History. See
    /// `ImportantConversations`.
    public var importantConversations: [ImportantConversation] = []
    /// Search tags come with each sort (`SearchTags`); off, only the tagging pass
    /// writes them. On by default.
    public var tagsWhenSorting = true
    /// A search also finds what means the same, by expanded terms
    /// (`HistorySimilarSearch`). On by default.
    public var searchByMeaning = true

    public var importantPeople: String {
        get { vipIdentities.map(\.displayName).joined(separator: ", ") }
        set { replaceManualVIPs(withCommaSeparatedNames: newValue) }
    }

    public var manualVIPNamesText: String {
        vipIdentities
            .filter { $0.provenance == .manual }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    public static let standard = TriagePolicy(
        vipIdentities: [],
        importantApps: [],
        workApps: [],
        quietApps: [],
        workDays: WorkHours.defaultDays,
        workStartMinuteOfDay: WorkHours.defaultStartMinuteOfDay,
        workEndMinuteOfDay: WorkHours.defaultEndMinuteOfDay,
        userNames: "",
        translateNotifications: false,
        readLanguages: [],
        urgentKeywords: "urgent, emergency, asap, action required, security alert",
        summaryKeywords: "newsletter, digest, update, receipt, delivered",
        silenceKeywords: "sale, promo, offer, streak, suggested for you",
        prioritizeCalendarAndTravel: true,
        silencePromotions: true,
        escalateRepeatedSenders: true,
        neutralDigestEnabled: false,
        neutralDigestMinuteOfDay: TriagePolicy.defaultNeutralDigestMinuteOfDay,
        alertOneTimeCodes: true,
        wakeMeEnabled: false,
        wakeMeIdentityIDs: [],
        wakeMeKeywords: "emergency, 911, hospital, ambulance, accident, call me now, wake up",
        wakeMeOnRepeatedAttempts: true,
        wakeMeOnFirstMissedCall: false,
        wakeMeSleepStartMinuteOfDay: TriagePolicy.defaultWakeMeSleepStartMinuteOfDay,
        wakeMeSleepEndMinuteOfDay: TriagePolicy.defaultWakeMeSleepEndMinuteOfDay,
        combineRapidMessages: true,
        conversationCooldown: true,
        autoReply: AutoReplySettings(),
        secondOpinionEnabled: false
    )

    public static func defaults(locale: Locale = .current) -> TriagePolicy {
        var policy = TriagePolicy.standard
        policy.adoptLocalizedDefaultTerms(locale: locale)
        return policy
    }

    /// Japanese and Korean users get terms in their language in front of the English
    /// ones, because they also receive English notifications. Only terms still at the
    /// English defaults change, so customized terms are never overwritten.
    public mutating func adoptLocalizedDefaultTerms(locale: Locale = .current) {
        if KaruiLocalization.isKorean(locale) {
            adoptKoreanDefaultTerms()
            return
        }
        guard KaruiLocalization.isJapanese(locale) else { return }
        let standard = TriagePolicy.standard
        if urgentKeywords == standard.urgentKeywords {
            urgentKeywords = "緊急, 至急, 早急に, 要対応, セキュリティ警告, " + standard.urgentKeywords
        }
        if summaryKeywords == standard.summaryKeywords {
            summaryKeywords = "ニュースレター, ダイジェスト, お知らせ, 領収書, 配達完了, " + standard.summaryKeywords
        }
        if silenceKeywords == standard.silenceKeywords {
            silenceKeywords = "セール, キャンペーン, クーポン, 期間限定, 連続記録, おすすめ, " + standard.silenceKeywords
        }
        if wakeMeKeywords == standard.wakeMeKeywords {
            wakeMeKeywords = "緊急, 救急, 病院, 事故, 今すぐ電話, 起きて, 119, 110, " + standard.wakeMeKeywords
        }
    }

    private mutating func adoptKoreanDefaultTerms() {
        let standard = TriagePolicy.standard
        if urgentKeywords == standard.urgentKeywords {
            urgentKeywords = "긴급, 급함, 즉시, 확인 필요, 보안 경고, " + standard.urgentKeywords
        }
        if summaryKeywords == standard.summaryKeywords {
            summaryKeywords = "뉴스레터, 다이제스트, 공지, 영수증, 배송 완료, " + standard.summaryKeywords
        }
        if silenceKeywords == standard.silenceKeywords {
            silenceKeywords = "세일, 할인, 쿠폰, 기간 한정, 연속 기록, 추천, " + standard.silenceKeywords
        }
        if wakeMeKeywords == standard.wakeMeKeywords {
            wakeMeKeywords = "응급, 긴급, 병원, 사고, 지금 전화, 일어나, 119, 112, " + standard.wakeMeKeywords
        }
    }

    public init(
        vipIdentities: [VIPIdentity],
        importantApps: [String] = [],
        workApps: [String] = [],
        quietApps: [String] = [],
        workDays: [Int] = WorkHours.defaultDays,
        workStartMinuteOfDay: Int = WorkHours.defaultStartMinuteOfDay,
        workEndMinuteOfDay: Int = WorkHours.defaultEndMinuteOfDay,
        userNames: String = "",
        translateNotifications: Bool = false,
        readLanguages: [String] = [],
        urgentKeywords: String,
        summaryKeywords: String,
        silenceKeywords: String,
        prioritizeCalendarAndTravel: Bool,
        silencePromotions: Bool,
        escalateRepeatedSenders: Bool = true,
        neutralDigestEnabled: Bool = false,
        neutralDigestMinuteOfDay: Int = TriagePolicy.defaultNeutralDigestMinuteOfDay,
        alertOneTimeCodes: Bool = true,
        wakeMeEnabled: Bool = false,
        wakeMeIdentityIDs: [UUID] = [],
        wakeMeKeywords: String = "",
        wakeMeOnRepeatedAttempts: Bool = true,
        wakeMeOnFirstMissedCall: Bool = false,
        wakeMeSleepStartMinuteOfDay: Int = TriagePolicy.defaultWakeMeSleepStartMinuteOfDay,
        wakeMeSleepEndMinuteOfDay: Int = TriagePolicy.defaultWakeMeSleepEndMinuteOfDay,
        combineRapidMessages: Bool = true,
        conversationCooldown: Bool = true,
        autoReply: AutoReplySettings = AutoReplySettings(),
        secondOpinionEnabled: Bool = false
    ) {
        self.vipIdentities = vipIdentities
        self.importantApps = importantApps
        self.workApps = workApps
        self.quietApps = quietApps
        self.workDays = workDays
        self.workStartMinuteOfDay = workStartMinuteOfDay
        self.workEndMinuteOfDay = workEndMinuteOfDay
        self.userNames = userNames
        self.translateNotifications = translateNotifications
        self.readLanguages = readLanguages
        self.urgentKeywords = urgentKeywords
        self.summaryKeywords = summaryKeywords
        self.silenceKeywords = silenceKeywords
        self.prioritizeCalendarAndTravel = prioritizeCalendarAndTravel
        self.silencePromotions = silencePromotions
        self.escalateRepeatedSenders = escalateRepeatedSenders
        self.neutralDigestEnabled = neutralDigestEnabled
        self.neutralDigestMinuteOfDay = neutralDigestMinuteOfDay
        self.alertOneTimeCodes = alertOneTimeCodes
        self.wakeMeEnabled = wakeMeEnabled
        self.wakeMeIdentityIDs = wakeMeIdentityIDs
        self.wakeMeKeywords = wakeMeKeywords
        self.wakeMeOnRepeatedAttempts = wakeMeOnRepeatedAttempts
        self.wakeMeOnFirstMissedCall = wakeMeOnFirstMissedCall
        self.wakeMeSleepStartMinuteOfDay = wakeMeSleepStartMinuteOfDay
        self.wakeMeSleepEndMinuteOfDay = wakeMeSleepEndMinuteOfDay
        self.combineRapidMessages = combineRapidMessages
        self.conversationCooldown = conversationCooldown
        self.autoReply = autoReply
        self.secondOpinionEnabled = secondOpinionEnabled
    }

    public mutating func replaceImportantApps(withNames names: [String]) {
        var seenKeys: Set<String> = []
        importantApps = names.compactMap { name in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ImportantAppMatcher.canonicalKey(trimmedName)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { return nil }
            return trimmedName
        }
        workApps.removeAll { !seenKeys.contains(ImportantAppMatcher.canonicalKey($0)) }
    }

    /// Well-known work apps start out as work apps; the person can change that. An app
    /// is important or quiet, never both.
    public mutating func addImportantApp(_ appName: String) {
        removeQuietApp(appName)
        let isNew = ImportantAppMatcher.matchingApp(for: appName, in: importantApps) == nil
        replaceImportantApps(withNames: importantApps + [appName])
        if isNew, WorkHours.isKnownWorkApp(appName),
           let added = ImportantAppMatcher.matchingApp(for: appName, in: importantApps) {
            setWorkApp(added, true)
        }
    }

    public mutating func removeImportantApp(_ appName: String) {
        let key = ImportantAppMatcher.canonicalKey(appName)
        importantApps.removeAll { ImportantAppMatcher.canonicalKey($0) == key }
        workApps.removeAll { ImportantAppMatcher.canonicalKey($0) == key }
    }

    public func isQuietApp(_ appName: String) -> Bool {
        ImportantAppMatcher.matchingApp(for: appName, in: quietApps) != nil
    }

    public mutating func addQuietApp(_ appName: String) {
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ImportantAppMatcher.canonicalKey(trimmedName).isEmpty, !isQuietApp(trimmedName) else { return }
        removeImportantApp(trimmedName)
        quietApps.append(trimmedName)
    }

    public mutating func removeQuietApp(_ appName: String) {
        let key = ImportantAppMatcher.canonicalKey(appName)
        quietApps.removeAll { ImportantAppMatcher.canonicalKey($0) == key }
    }

    public func isSavedContactException(_ name: String) -> Bool {
        let key = Self.normalizedManualName(name)
        return savedContactExceptions.contains { Self.normalizedManualName($0) == key }
    }

    public mutating func addSavedContactException(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSavedContactException(trimmed) else { return }
        savedContactExceptions.append(trimmed)
    }

    /// The Important Conversation a notification belongs to, if it's still running.
    public func importantConversation(for notification: NotificationInput, now: Date = .now) -> ImportantConversation? {
        let keys = Set(ConversationCooldown.keys(for: notification, recipients: notification.recipients))
        guard !keys.isEmpty else { return nil }
        return importantConversations.first { $0.isActive(at: now) && !Set($0.keys).isDisjoint(with: keys) }
    }

    /// Adds a conversation, replacing any entry for the same chat, and drops the
    /// ones that have run out.
    public mutating func addImportantConversation(_ conversation: ImportantConversation, now: Date = .now) {
        let keys = Set(conversation.keys)
        importantConversations.removeAll { !$0.isActive(at: now) || !Set($0.keys).isDisjoint(with: keys) }
        importantConversations.append(conversation)
    }

    public mutating func removeImportantConversation(id: UUID) {
        importantConversations.removeAll { $0.id == id }
    }

    public mutating func pruneImportantConversations(now: Date = .now) {
        importantConversations.removeAll { !$0.isActive(at: now) }
    }

    public func isWorkApp(_ appName: String) -> Bool {
        ImportantAppMatcher.matchingApp(for: appName, in: workApps) != nil
    }

    public mutating func setWorkApp(_ appName: String, _ isWorkApp: Bool) {
        let key = ImportantAppMatcher.canonicalKey(appName)
        workApps.removeAll { ImportantAppMatcher.canonicalKey($0) == key }
        if isWorkApp { workApps.append(appName) }
    }

    public func isWorkTime(_ date: Date = .now, calendar: Calendar = .current) -> Bool {
        WorkHours.contains(
            date,
            days: workDays,
            startMinuteOfDay: workStartMinuteOfDay,
            endMinuteOfDay: workEndMinuteOfDay,
            calendar: calendar
        )
    }

    /// The important apps that count right now: work apps drop out outside work hours
    /// and are judged like any other app.
    public func importantApps(activeAt date: Date = .now, calendar: Calendar = .current) -> [String] {
        guard !workApps.isEmpty, !isWorkTime(date, calendar: calendar) else { return importantApps }
        return importantApps.filter { !isWorkApp($0) }
    }

    /// Work apps that don't count right now, for the model's prompt.
    public func offHoursWorkApps(at date: Date = .now, calendar: Calendar = .current) -> [String] {
        guard !workApps.isEmpty, !isWorkTime(date, calendar: calendar) else { return [] }
        return importantApps.filter { isWorkApp($0) }
    }

    public mutating func replaceManualVIPs(withCommaSeparatedNames names: String) {
        replaceManualVIPs(withNames: commaSeparatedValues(from: names))
    }

    public mutating func replaceManualVIPs(withNames names: [String]) {
        let contactVIPs = vipIdentities.filter { $0.provenance == .contact }
        let contactNames = Set(contactVIPs.map { Self.normalizedManualName($0.displayName) })
        var existingManualVIPsByName: [String: VIPIdentity] = [:]
        for identity in vipIdentities where identity.provenance == .manual {
            existingManualVIPsByName[Self.normalizedManualName(identity.displayName)] = identity
        }

        var seenNames: Set<String> = []
        let manualVIPs = names.compactMap { name -> VIPIdentity? in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let normalizedName = Self.normalizedManualName(trimmedName)
            guard !contactNames.contains(normalizedName),
                  seenNames.insert(normalizedName).inserted else { return nil }
            if let existingIdentity = existingManualVIPsByName[normalizedName] {
                return .manual(displayName: trimmedName, id: existingIdentity.id)
            }
            return .manual(displayName: trimmedName)
        }
        vipIdentities = manualVIPs + contactVIPs
    }

    public mutating func addManualVIP(named name: String) {
        let existingNames = vipIdentities
            .filter { $0.provenance == .manual }
            .map(\.displayName)
        replaceManualVIPs(withNames: existingNames + [name])
    }

    /// Promotes a notification's sender to the contact the person picked for them.
    /// A contact whose name, numbers, and emails wouldn't match the sender also gets
    /// the sender's own number or email. Returns whether the sender now matches.
    @discardableResult
    public mutating func promoteSender(_ sender: String, toContact snapshot: VIPIdentity) -> Bool {
        mergeContactVIPs([snapshot])
        guard let contactIdentifier = snapshot.contactIdentifier,
              let index = vipIdentities.firstIndex(where: { $0.contactIdentifier == contactIdentifier }) else {
            return false
        }
        let contact = vipIdentities[index]
        func senderMatches() -> Bool {
            ImportantPersonMatcher.resolveSender(sender, identities: vipIdentities)?.identity.id == contact.id
        }
        if senderMatches() { return true }
        guard let senderDetails = ImportantPersonMatcher.promotedIdentity(from: sender),
              !senderDetails.emails.isEmpty || !senderDetails.phoneNumbers.isEmpty else {
            return false
        }
        vipIdentities[index] = VIPIdentity(
            id: contact.id,
            displayName: contact.displayName,
            nickname: contact.nickname,
            contactIdentifier: contact.contactIdentifier,
            emails: contact.emails + senderDetails.emails,
            phoneNumbers: contact.phoneNumbers + senderDetails.phoneNumbers,
            phoneLabels: contact.phoneLabels,
            provenance: .contact,
            thumbnailImageData: contact.thumbnailImageData,
            messagingAccounts: contact.messagingAccounts
        )
        return senderMatches()
    }

    public mutating func addPromotedSender(_ sender: String) {
        guard ImportantPersonMatcher.resolveSender(sender, identities: vipIdentities) == nil,
              let promotedIdentity = ImportantPersonMatcher.promotedIdentity(from: sender) else {
            return
        }
        vipIdentities.append(promotedIdentity)
    }

    /// Puts a freshly picked contact in a VIP's place, keeping the VIP's id so Wake Me,
    /// Auto Reply choices, and History stay with them.
    public mutating func replaceVIP(id: UUID, with snapshot: VIPIdentity) {
        guard let index = vipIdentities.firstIndex(where: { $0.id == id }) else { return }
        vipIdentities[index] = VIPIdentity(
            id: id,
            displayName: snapshot.displayName,
            nickname: snapshot.nickname,
            contactIdentifier: snapshot.contactIdentifier,
            emails: snapshot.emails,
            phoneNumbers: snapshot.phoneNumbers,
            phoneLabels: snapshot.phoneLabels,
            provenance: .contact,
            thumbnailImageData: snapshot.thumbnailImageData,
            messagingAccounts: snapshot.messagingAccounts
        )
    }

    public mutating func removeVIP(id: UUID) {
        vipIdentities.removeAll { $0.id == id }
        wakeMeIdentityIDs.removeAll { $0 == id }
        autoReply.forget(id)
    }

    /// The current VIP a history item matched. A VIP removed and added back gets a new
    /// UUID, so when the stored one is gone this finds them by sender, then by name,
    /// as History's grouping does. Nil when the item never matched a VIP.
    public func vip(resolvedID: UUID?, sender: String?, displayName: String?) -> VIPIdentity? {
        guard let resolvedID else { return nil }
        if let identity = vipIdentities.first(where: { $0.id == resolvedID }) { return identity }
        if let sender,
           let identity = ImportantPersonMatcher.resolveSender(sender, identities: vipIdentities)?.identity {
            return identity
        }
        guard let displayName else { return nil }
        let matches = vipIdentities.filter { ImportantPersonMatcher.namesMatch($0.displayName, displayName) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The VIPs allowed to wake you, skipping any since removed from the VIP list.
    public var wakeMeIdentities: [VIPIdentity] {
        vipIdentities.filter { wakeMeIdentityIDs.contains($0.id) }
    }

    public mutating func removeVIPs(named name: String) {
        let normalizedName = Self.normalizedManualName(name)
        vipIdentities.removeAll {
            Self.normalizedManualName($0.displayName) == normalizedName
        }
    }

    /// A picked contact that is already a VIP without a contact card, typed in or
    /// added from a notification, takes that VIP's place and keeps its id, so Wake Me
    /// and History grouping carry over.
    public mutating func mergeContactVIPs(_ snapshots: [VIPIdentity]) {
        let existingContactIdentifiers = Set(vipIdentities.compactMap(\.contactIdentifier))
        var replacedIDs: Set<UUID> = []
        let snapshots = snapshots.map { snapshot -> VIPIdentity in
            guard let contactIdentifier = snapshot.contactIdentifier,
                  !existingContactIdentifiers.contains(contactIdentifier),
                  let replaced = vipIdentities.first(where: {
                      $0.provenance == .manual
                          && !replacedIDs.contains($0.id)
                          && ImportantPersonMatcher.isSamePerson($0, as: snapshot)
                  }) else {
                return snapshot
            }
            replacedIDs.insert(replaced.id)
            return .contact(
                displayName: snapshot.displayName,
                nickname: snapshot.nickname,
                contactIdentifier: contactIdentifier,
                emails: snapshot.emails,
                phoneNumbers: snapshot.phoneNumbers,
                phoneLabels: snapshot.phoneLabels,
                id: replaced.id,
                thumbnailImageData: snapshot.thumbnailImageData,
                messagingAccounts: snapshot.messagingAccounts
            )
        }
        vipIdentities.removeAll { replacedIDs.contains($0.id) }
        let existingContactVIPs = vipIdentities.filter { $0.provenance == .contact }
        reconcileContactVIPs(with: snapshots + existingContactVIPs)
    }

    /// VIPs by name, for display; the stored order is the order they were added.
    public var vipIdentitiesByName: [VIPIdentity] {
        vipIdentities.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Contacts already saved as VIPs, grayed out in the contact picker.
    public var vipContactIdentifiers: [String] {
        vipIdentities.compactMap(\.contactIdentifier).filter { !$0.isEmpty }
    }

    public mutating func reconcileContactVIPs(with snapshots: [VIPIdentity]) {
        let manualVIPs = vipIdentities.filter { $0.provenance == .manual }
        var existingContactVIPsByIdentifier: [String: VIPIdentity] = [:]
        for identity in vipIdentities where identity.provenance == .contact {
            guard let contactIdentifier = identity.contactIdentifier else { continue }
            existingContactVIPsByIdentifier[contactIdentifier] = identity
        }
        var seenContactIdentifiers: Set<String> = []
        let contactVIPs = snapshots.compactMap { snapshot -> VIPIdentity? in
            guard snapshot.provenance == .contact,
                  let contactIdentifier = snapshot.contactIdentifier,
                  !contactIdentifier.isEmpty,
                  seenContactIdentifiers.insert(contactIdentifier).inserted else {
                return nil
            }
            if let existingIdentity = existingContactVIPsByIdentifier[contactIdentifier] {
                return VIPIdentity(
                    id: existingIdentity.id,
                    displayName: snapshot.displayName,
                    nickname: snapshot.nickname,
                    contactIdentifier: contactIdentifier,
                    emails: snapshot.emails,
                    phoneNumbers: snapshot.phoneNumbers,
                    phoneLabels: snapshot.phoneLabels ?? existingIdentity.phoneLabels,
                    provenance: .contact,
                    thumbnailImageData: snapshot.thumbnailImageData ?? existingIdentity.thumbnailImageData,
                    messagingAccounts: snapshot.messagingAccounts ?? existingIdentity.messagingAccounts
                )
            }
            return snapshot
        }
        vipIdentities = manualVIPs + contactVIPs
    }

    public func terms(from commaSeparatedText: String) -> [String] {
        commaSeparatedValues(from: commaSeparatedText).map { $0.lowercased() }
    }

    public func commaSeparatedValues(from text: String) -> [String] {
        text
            .split(whereSeparator: { [",", "、", "，"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedManualName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private enum CodingKeys: String, CodingKey {
        case vipIdentities
        case importantApps
        case workApps
        case quietApps
        case workDays
        case workStartMinuteOfDay
        case workEndMinuteOfDay
        case userNames
        case translateNotifications
        case readLanguages
        case importantPeople
        case urgentKeywords
        case summaryKeywords
        case silenceKeywords
        case prioritizeCalendarAndTravel
        case silencePromotions
        case escalateRepeatedSenders
        case neutralDigestEnabled
        case neutralDigestMinuteOfDay
        case alertOneTimeCodes
        case wakeMeEnabled
        case wakeMeIdentityIDs
        case wakeMeKeywords
        case wakeMeOnRepeatedAttempts
        case wakeMeOnFirstMissedCall
        case wakeMeSleepStartMinuteOfDay
        case wakeMeSleepEndMinuteOfDay
        case combineRapidMessages
        case conversationCooldown
        case autoReply
        case secondOpinionEnabled
        case secondOpinionMode
        case filtersNotifications
        case deadlineRemindersEnabled
        case alertSavedContacts
        case alertKnownCorrespondents
        case showsHistoryOnMac
        case sendsPhoneOnlyNotificationsToMac
        case savedContactExceptions
        case importantConversations
        case tagsWhenSorting
        case searchByMeaning
        /// Replaced by `secondOpinionMode`; read once so the setting carries over.
        case secondOpinionAlways
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let structuredVIPs = try container.decodeIfPresent([VIPIdentity].self, forKey: .vipIdentities) {
            vipIdentities = structuredVIPs
        } else {
            let legacyNames = try container.decodeIfPresent(String.self, forKey: .importantPeople) ?? ""
            var migratedPolicy = TriagePolicy.standard
            migratedPolicy.replaceManualVIPs(withCommaSeparatedNames: legacyNames)
            vipIdentities = migratedPolicy.vipIdentities
        }
        importantApps = try container.decodeIfPresent([String].self, forKey: .importantApps) ?? []
        workApps = try container.decodeIfPresent([String].self, forKey: .workApps) ?? []
        quietApps = try container.decodeIfPresent([String].self, forKey: .quietApps) ?? []
        workDays = try container.decodeIfPresent([Int].self, forKey: .workDays) ?? WorkHours.defaultDays
        workStartMinuteOfDay = try container.decodeIfPresent(Int.self, forKey: .workStartMinuteOfDay)
            ?? WorkHours.defaultStartMinuteOfDay
        workEndMinuteOfDay = try container.decodeIfPresent(Int.self, forKey: .workEndMinuteOfDay)
            ?? WorkHours.defaultEndMinuteOfDay
        userNames = try container.decodeIfPresent(String.self, forKey: .userNames) ?? ""
        translateNotifications = try container.decodeIfPresent(Bool.self, forKey: .translateNotifications) ?? false
        readLanguages = try container.decodeIfPresent([String].self, forKey: .readLanguages) ?? []
        urgentKeywords = try container.decode(String.self, forKey: .urgentKeywords)
        summaryKeywords = try container.decode(String.self, forKey: .summaryKeywords)
        silenceKeywords = try container.decode(String.self, forKey: .silenceKeywords)
        prioritizeCalendarAndTravel = try container.decode(Bool.self, forKey: .prioritizeCalendarAndTravel)
        silencePromotions = try container.decode(Bool.self, forKey: .silencePromotions)
        escalateRepeatedSenders = try container.decodeIfPresent(Bool.self, forKey: .escalateRepeatedSenders) ?? true
        neutralDigestEnabled = try container.decodeIfPresent(Bool.self, forKey: .neutralDigestEnabled) ?? false
        neutralDigestMinuteOfDay = try container.decodeIfPresent(Int.self, forKey: .neutralDigestMinuteOfDay)
            ?? TriagePolicy.defaultNeutralDigestMinuteOfDay
        alertOneTimeCodes = try container.decodeIfPresent(Bool.self, forKey: .alertOneTimeCodes) ?? true
        wakeMeEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeMeEnabled) ?? false
        wakeMeIdentityIDs = try container.decodeIfPresent([UUID].self, forKey: .wakeMeIdentityIDs) ?? []
        wakeMeKeywords = try container.decodeIfPresent(String.self, forKey: .wakeMeKeywords)
            ?? TriagePolicy.standard.wakeMeKeywords
        wakeMeOnRepeatedAttempts = try container.decodeIfPresent(Bool.self, forKey: .wakeMeOnRepeatedAttempts) ?? true
        wakeMeOnFirstMissedCall = try container.decodeIfPresent(Bool.self, forKey: .wakeMeOnFirstMissedCall) ?? false
        wakeMeSleepStartMinuteOfDay = try container.decodeIfPresent(Int.self, forKey: .wakeMeSleepStartMinuteOfDay)
            ?? TriagePolicy.defaultWakeMeSleepStartMinuteOfDay
        wakeMeSleepEndMinuteOfDay = try container.decodeIfPresent(Int.self, forKey: .wakeMeSleepEndMinuteOfDay)
            ?? TriagePolicy.defaultWakeMeSleepEndMinuteOfDay
        combineRapidMessages = try container.decodeIfPresent(Bool.self, forKey: .combineRapidMessages) ?? true
        conversationCooldown = try container.decodeIfPresent(Bool.self, forKey: .conversationCooldown) ?? true
        autoReply = try container.decodeIfPresent(AutoReplySettings.self, forKey: .autoReply) ?? AutoReplySettings()
        secondOpinionEnabled = try container.decodeIfPresent(Bool.self, forKey: .secondOpinionEnabled) ?? false
        // Always is no longer offered: Before Alerting (`first`) asks about the same
        // notifications and holds an Important alert for the answer instead of sending
        // it and taking it back, so people who chose Always get that.
        if let mode = try container.decodeIfPresent(SecondOpinionMode.self, forKey: .secondOpinionMode) {
            secondOpinionMode = mode == .always ? .first : mode
        } else if try container.decodeIfPresent(Bool.self, forKey: .secondOpinionAlways) == true {
            secondOpinionMode = .first
        }
        filtersNotifications = try container.decodeIfPresent(Bool.self, forKey: .filtersNotifications) ?? true
        deadlineRemindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .deadlineRemindersEnabled) ?? false
        alertSavedContacts = try container.decodeIfPresent(Bool.self, forKey: .alertSavedContacts) ?? true
        alertKnownCorrespondents = try container.decodeIfPresent(Bool.self, forKey: .alertKnownCorrespondents) ?? true
        showsHistoryOnMac = try container.decodeIfPresent(Bool.self, forKey: .showsHistoryOnMac) ?? false
        sendsPhoneOnlyNotificationsToMac = try container.decodeIfPresent(Bool.self, forKey: .sendsPhoneOnlyNotificationsToMac) ?? false
        savedContactExceptions = try container.decodeIfPresent([String].self, forKey: .savedContactExceptions) ?? []
        importantConversations = try container.decodeIfPresent([ImportantConversation].self, forKey: .importantConversations) ?? []
        tagsWhenSorting = try container.decodeIfPresent(Bool.self, forKey: .tagsWhenSorting) ?? true
        searchByMeaning = try container.decodeIfPresent(Bool.self, forKey: .searchByMeaning) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vipIdentities, forKey: .vipIdentities)
        try container.encode(importantApps, forKey: .importantApps)
        try container.encode(workApps, forKey: .workApps)
        try container.encode(quietApps, forKey: .quietApps)
        try container.encode(workDays, forKey: .workDays)
        try container.encode(workStartMinuteOfDay, forKey: .workStartMinuteOfDay)
        try container.encode(workEndMinuteOfDay, forKey: .workEndMinuteOfDay)
        try container.encode(userNames, forKey: .userNames)
        try container.encode(translateNotifications, forKey: .translateNotifications)
        try container.encode(readLanguages, forKey: .readLanguages)
        try container.encode(urgentKeywords, forKey: .urgentKeywords)
        try container.encode(summaryKeywords, forKey: .summaryKeywords)
        try container.encode(silenceKeywords, forKey: .silenceKeywords)
        try container.encode(prioritizeCalendarAndTravel, forKey: .prioritizeCalendarAndTravel)
        try container.encode(silencePromotions, forKey: .silencePromotions)
        try container.encode(escalateRepeatedSenders, forKey: .escalateRepeatedSenders)
        try container.encode(neutralDigestEnabled, forKey: .neutralDigestEnabled)
        try container.encode(neutralDigestMinuteOfDay, forKey: .neutralDigestMinuteOfDay)
        try container.encode(alertOneTimeCodes, forKey: .alertOneTimeCodes)
        try container.encode(wakeMeEnabled, forKey: .wakeMeEnabled)
        try container.encode(wakeMeIdentityIDs, forKey: .wakeMeIdentityIDs)
        try container.encode(wakeMeKeywords, forKey: .wakeMeKeywords)
        try container.encode(wakeMeOnRepeatedAttempts, forKey: .wakeMeOnRepeatedAttempts)
        try container.encode(wakeMeOnFirstMissedCall, forKey: .wakeMeOnFirstMissedCall)
        try container.encode(wakeMeSleepStartMinuteOfDay, forKey: .wakeMeSleepStartMinuteOfDay)
        try container.encode(wakeMeSleepEndMinuteOfDay, forKey: .wakeMeSleepEndMinuteOfDay)
        try container.encode(combineRapidMessages, forKey: .combineRapidMessages)
        try container.encode(conversationCooldown, forKey: .conversationCooldown)
        try container.encode(autoReply, forKey: .autoReply)
        try container.encode(secondOpinionEnabled, forKey: .secondOpinionEnabled)
        try container.encode(secondOpinionMode, forKey: .secondOpinionMode)
        try container.encode(filtersNotifications, forKey: .filtersNotifications)
        try container.encode(deadlineRemindersEnabled, forKey: .deadlineRemindersEnabled)
        try container.encode(alertSavedContacts, forKey: .alertSavedContacts)
        try container.encode(alertKnownCorrespondents, forKey: .alertKnownCorrespondents)
        try container.encode(showsHistoryOnMac, forKey: .showsHistoryOnMac)
        try container.encode(sendsPhoneOnlyNotificationsToMac, forKey: .sendsPhoneOnlyNotificationsToMac)
        try container.encode(savedContactExceptions, forKey: .savedContactExceptions)
        try container.encode(importantConversations, forKey: .importantConversations)
        try container.encode(tagsWhenSorting, forKey: .tagsWhenSorting)
        try container.encode(searchByMeaning, forKey: .searchByMeaning)
    }
}

public extension NotificationInput {
    /// A notification as Karui for Mac has it from Notification Center, shaped as the
    /// iPhone's Shortcut would hand it over. In Messages, Slack, and Spark the title
    /// names the sender.
    static func fromMac(app: String, title: String?, subtitle: String?, body: String?, receivedAt: Date) -> NotificationInput {
        NotificationInput(
            source: app,
            title: title ?? "",
            body: [subtitle, body].compactMap { $0 }.joined(separator: "\n"),
            sender: title,
            subtitle: subtitle,
            receivedAt: receivedAt,
            // The sender is the title here, so every notification would look direct.
            isDirectMessage: false
        )
    }
}
