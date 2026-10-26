import AppKit
import Foundation

/// Opens the app a notification came from, by its Mac bundle, or its website when
/// the app isn't installed. Only the app, not the thread: the thread needs a link
/// the harvesters make for Messages, Spark, and Slack.
@MainActor
enum AppLauncher {
    struct Target {
        let bundleIdentifiers: [String]
        let website: URL?
    }

    private static let targets: [String: Target] = [
        "Messages": Target(bundleIdentifiers: ["com.apple.MobileSMS"], website: nil),
        "Spark": Target(bundleIdentifiers: ["com.readdle.SparkDesktop", "com.readdle.sparkdesktop", "com.readdle.smartmail"], website: URL(string: "https://sparkmailapp.com")),
        "Slack": Target(bundleIdentifiers: ["com.tinyspeck.slackmacgap"], website: URL(string: "https://app.slack.com")),
        "LINE": Target(bundleIdentifiers: ["jp.naver.line.mac"], website: URL(string: "https://line.me")),
        "Discord": Target(bundleIdentifiers: ["com.hnc.Discord"], website: URL(string: "https://discord.com/app")),
        "Telegram": Target(bundleIdentifiers: ["ru.keepcoder.Telegram", "org.telegram.desktop"], website: URL(string: "https://web.telegram.org")),
        "WhatsApp": Target(bundleIdentifiers: ["net.whatsapp.WhatsApp"], website: URL(string: "https://web.whatsapp.com")),
        "X": Target(bundleIdentifiers: ["com.atebits.Tweetie2", "com.twitter.twitter-mac"], website: URL(string: "https://x.com")),
        "Instagram": Target(bundleIdentifiers: [], website: URL(string: "https://www.instagram.com")),
        "Threads": Target(bundleIdentifiers: [], website: URL(string: "https://www.threads.com")),
        "Facebook": Target(bundleIdentifiers: [], website: URL(string: "https://www.facebook.com")),
        "LinkedIn": Target(bundleIdentifiers: [], website: URL(string: "https://www.linkedin.com")),
        "Reddit": Target(bundleIdentifiers: [], website: URL(string: "https://www.reddit.com")),
        "Mail": Target(bundleIdentifiers: ["com.apple.mail"], website: nil),
        "Gmail": Target(bundleIdentifiers: [], website: URL(string: "https://mail.google.com")),
        "Outlook": Target(bundleIdentifiers: ["com.microsoft.Outlook"], website: URL(string: "https://outlook.live.com")),
        "Calendar": Target(bundleIdentifiers: ["com.apple.iCal"], website: nil),
        "FaceTime": Target(bundleIdentifiers: ["com.apple.FaceTime"], website: nil),
        "Google Voice": Target(bundleIdentifiers: [], website: URL(string: "https://voice.google.com")),
        "PayPal": Target(bundleIdentifiers: [], website: URL(string: "https://www.paypal.com")),
        "PayPay": Target(bundleIdentifiers: [], website: URL(string: "https://paypay.ne.jp")),
        "Strava": Target(bundleIdentifiers: [], website: URL(string: "https://www.strava.com")),
        "Linear": Target(bundleIdentifiers: ["com.linear"], website: URL(string: "https://linear.app")),
        "GitHub": Target(bundleIdentifiers: ["com.github.GitHubClient"], website: URL(string: "https://github.com/notifications")),
        "ChatGPT": Target(bundleIdentifiers: ["com.openai.chat"], website: URL(string: "https://chatgpt.com")),
        "Claude": Target(bundleIdentifiers: ["com.anthropic.claudefordesktop"], website: URL(string: "https://claude.ai")),
        "Luma": Target(bundleIdentifiers: [], website: URL(string: "https://lu.ma")),
        "Wise": Target(bundleIdentifiers: [], website: URL(string: "https://wise.com")),
        "Microsoft Teams": Target(bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"], website: URL(string: "https://teams.microsoft.com")),
        "Chatwork": Target(bundleIdentifiers: [], website: URL(string: "https://www.chatwork.com")),
        "Wallet": Target(bundleIdentifiers: [], website: nil),
        "Auto Clock-in": Target(bundleIdentifiers: [], website: nil),
    ]

    /// Where opening this app would go: its bundle on this Mac, else its website.
    static func destination(for app: String) -> URL? {
        guard let target = targets[app] else { return nil }
        for identifier in target.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        return target.website
    }

    static func canOpen(_ app: String) -> Bool { destination(for: app) != nil }

    /// The app's bundle identifier when it's on this Mac: by the identifiers known for
    /// it, else by its name in the Applications folders, as "LINE.app".
    static func installedBundleIdentifier(for app: String) -> String? {
        for identifier in targets[app]?.bundleIdentifiers ?? [] where NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil {
            return identifier
        }
        let folders = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appending(path: app + ".app")
            if FileManager.default.fileExists(atPath: url.path), let identifier = Bundle(url: url)?.bundleIdentifier {
                return identifier
            }
        }
        return nil
    }

    static func open(_ app: String) {
        guard let destination = destination(for: app) else { return }
        if destination.isFileURL {
            NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(destination)
        }
    }
}
