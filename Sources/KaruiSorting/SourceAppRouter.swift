import Foundation

public struct SourceAppRoute: Equatable, Sendable {
    public let appName: String
    public let url: URL
    public let opensExactContent: Bool

    public init(
        appName: String,
        url: URL,
        opensExactContent: Bool
    ) {
        self.appName = appName
        self.url = url
        self.opensExactContent = opensExactContent
    }
}

public enum SourceAppRouter {
    /// One supported source app. `aliases` match exactly or as a leading/trailing
    /// word of the normalized source name ("GitHub Mobile" → GitHub); `exactAliases`
    /// match only the whole name, for generic words that would otherwise swallow
    /// other apps ("Google Calendar" must not open Apple Calendar).
    private struct Entry {
        let appName: String
        let url: String
        var aliases: [String] = []
        var exactAliases: [String] = []
    }

    /// Order matters: an app whose name contains another app's name is listed first
    /// (Messenger before Facebook, Gmail before Mail, Google Calendar before Calendar).
    private static let entries: [Entry] = [
        Entry(appName: "Spark", url: "readdle-spark://", aliases: ["spark", "spark mail"]),
        // Japanese, Korean, and German iPhones name Apple's apps in their language, so
        // those are exact aliases too.
        Entry(appName: "Messages", url: "iChat://", aliases: ["messages", "message", "imessage"], exactAliases: ["メッセージ", "메시지", "nachrichten"]),
        Entry(appName: "Gmail", url: "googlegmail://", aliases: ["gmail", "google gmail"]),
        Entry(appName: "Outlook", url: "ms-outlook://", aliases: ["outlook", "microsoft outlook"]),
        Entry(appName: "Mail", url: "message://", exactAliases: ["mail", "apple mail", "メール", "메일"]),
        Entry(appName: "Slack", url: "slack://open", aliases: ["slack"]),
        Entry(appName: "LINE", url: "https://line.me/R/", aliases: ["line", "line messenger"]),
        Entry(appName: "WhatsApp", url: "whatsapp://", aliases: ["whatsapp", "whatsapp messenger"]),
        Entry(appName: "Messenger", url: "fb-messenger://", aliases: ["messenger", "facebook messenger", "meta messenger"]),
        Entry(appName: "Signal", url: "sgnl://", aliases: ["signal"]),
        Entry(appName: "Telegram", url: "tg://", aliases: ["telegram"]),
        Entry(appName: "Viber", url: "viber://", aliases: ["viber", "rakuten viber"]),
        Entry(appName: "WeChat", url: "weixin://", aliases: ["wechat", "weixin"]),
        Entry(appName: "KakaoTalk", url: "kakaotalk://", aliases: ["kakaotalk", "kakao talk"], exactAliases: ["카카오톡"]),
        Entry(appName: "Discord", url: "discord://-/", aliases: ["discord"]),
        Entry(appName: "Microsoft Teams", url: "msteams://", aliases: ["teams", "microsoft teams", "ms teams"]),
        Entry(appName: "Chatwork", url: "chatwork://", aliases: ["chatwork"]),
        Entry(appName: "Zoom", url: "zoomus://", aliases: ["zoom", "zoom workplace"]),
        Entry(appName: "Google Voice", url: "googlevoice:", aliases: ["google voice", "voice"]),
        Entry(appName: "Instagram", url: "https://www.instagram.com", aliases: ["instagram"]),
        Entry(appName: "Threads", url: "barcelona://", aliases: ["threads"]),
        Entry(appName: "Facebook", url: "fb://", aliases: ["facebook", "meta"]),
        Entry(appName: "X", url: "https://x.com", aliases: ["x", "twitter", "x twitter"]),
        Entry(appName: "Bluesky", url: "bluesky://", aliases: ["bluesky"]),
        Entry(appName: "LinkedIn", url: "https://www.linkedin.com", aliases: ["linkedin", "linked in"]),
        Entry(appName: "Reddit", url: "reddit://", aliases: ["reddit"]),
        Entry(appName: "Snapchat", url: "snapchat://", aliases: ["snapchat"]),
        Entry(appName: "TikTok", url: "tiktok://", aliases: ["tiktok", "tik tok"]),
        Entry(appName: "YouTube", url: "youtube://", exactAliases: ["youtube"]),
        Entry(appName: "GitHub", url: "github://", aliases: ["github", "github mobile"]),
        Entry(appName: "Linear", url: "linear://", aliases: ["linear"]),
        Entry(appName: "Notion", url: "notion://", aliases: ["notion"]),
        // Universal links: the apps' own schemes are unconfirmed. Codex notifies as ChatGPT.
        Entry(appName: "ChatGPT", url: "https://chatgpt.com", aliases: ["chatgpt", "chat gpt", "codex"]),
        Entry(appName: "Claude", url: "https://claude.ai", aliases: ["claude"]),
        Entry(appName: "Google Calendar", url: "comgooglecalendar://", aliases: ["google calendar"]),
        Entry(appName: "Calendar", url: "calshow://", exactAliases: ["calendar", "apple calendar", "カレンダー", "캘린더", "kalender"]),
        Entry(appName: "Reminders", url: "x-apple-reminderkit://", aliases: ["reminders"], exactAliases: ["リマインダー", "미리 알림", "erinnerungen"]),
        Entry(appName: "Luma", url: "luma://", aliases: ["luma", "lu ma", "luma events"]),
        Entry(appName: "Wallet", url: "shoebox://", exactAliases: ["wallet", "apple wallet", "ウォレット", "지갑"]),
        Entry(appName: "PayPay", url: "paypay://", aliases: ["paypay", "pay pay"]),
        Entry(appName: "PayPal", url: "paypal://", aliases: ["paypal"]),
        Entry(appName: "Venmo", url: "venmo://", aliases: ["venmo"]),
        Entry(appName: "Amazon", url: "com.amazon.mobile.shopping://", exactAliases: ["amazon", "amazon shopping"]),
        Entry(appName: "Mercari", url: "mercari://", aliases: ["mercari"], exactAliases: ["メルカリ"]),
        Entry(appName: "Uber", url: "uber://", aliases: ["uber"]),
        Entry(appName: "Lyft", url: "lyft://", aliases: ["lyft"]),
        Entry(appName: "Strava", url: "strava://", aliases: ["strava"])
    ]

    public static let supportedAppNames = entries.map(\.appName)

    public static var supportedRoutes: [SourceAppRoute] {
        supportedAppNames.compactMap(route(for:))
    }

    public static func route(for source: String) -> SourceAppRoute? {
        let normalizedSource = normalize(source)
        guard !normalizedSource.isEmpty else { return nil }

        for entry in entries {
            if matches(normalizedSource, aliases: entry.aliases)
                || entry.exactAliases.contains(normalizedSource) {
                return route(appName: entry.appName, url: entry.url)
            }
        }
        return nil
    }

    private static func route(
        appName: String,
        url: String
    ) -> SourceAppRoute? {
        guard let destination = URL(string: url) else {
            return nil
        }
        return SourceAppRoute(
            appName: appName,
            url: destination,
            opensExactContent: false
        )
    }

    private static func matches(_ source: String, aliases: [String]) -> Bool {
        aliases.contains { alias in
            source == alias || source.hasPrefix("\(alias) ") || source.hasSuffix(" \(alias)")
        }
    }

    public static func normalize(_ source: String) -> String {
        source
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            // Letters from any script stay, so Japanese names like メッセージ can match.
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
