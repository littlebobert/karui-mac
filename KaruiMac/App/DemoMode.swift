import AppKit
import Foundation
import KaruiLinkKit

/// Screenshots for the site: `Karui --demo <view>` shows fictional notifications
/// in a window of a fixed size, touches neither Notification Center nor iCloud nor
/// the inbox on disk, and prints the window number so a script can capture it.
/// The view is `expanded`, `compact`, or `detail`. Launch with `-AppleLanguages (ja)`
/// for the Japanese set.
@MainActor
enum DemoMode {
    static var view: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo") else { return nil }
        return arguments.indices.contains(index + 1) ? arguments[index + 1] : "expanded"
    }
    static var isActive: Bool { view != nil }
    /// Where the window number is written, from `--demo-window-file <path>`.
    static var windowFile: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-window-file"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static let windowSize = NSSize(width: 720, height: 452)

    static func items() -> [Inbox.Item] {
        let japanese = Locale.preferredLanguages.first?.hasPrefix("ja") ?? false
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int) -> Date { today.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60)) }

        struct Seed {
            var app: String
            var title: String
            var subtitle: String?
            var body: String
            var time: Date
            var category: String
            var reason: String
            var link: Bool = false
            var read: Bool = false
        }
        let seeds: [Seed] = japanese ? [
            Seed(app: "メッセージ", title: "サム", body: "パーティー8時に変更になった！スピーカー持ってこれる？", time: at(17, 42), category: "notifyNow", reason: "友だちからの予定変更。", link: true),
            Seed(app: "Spark", title: "田中ミカ", subtitle: "Re: 金曜のスライド", body: "いい感じです。3ページ目だけ少し直したいので、明日話せますか？", time: at(17, 31), category: "notifyNow", reason: "同僚からの返信で、返事を求めている。", link: true),
            Seed(app: "Slack", title: "#design", subtitle: "レア", body: "アイコンセットを更新しました。どう思いますか？", time: at(17, 18), category: "summary", reason: "チャンネルへの投稿。急ぎではない。", link: true),
            Seed(app: "Spark", title: "Pebble Outfitters", subtitle: "40%オフは今夜まで", body: "秋の新作が全品セール。お見逃しなく！", time: at(16, 55), category: "silence", reason: "宣伝メール。"),
            Seed(app: "ウォレット", title: "配達完了", body: "ご注文の商品は11:32に配達されました。", time: at(16, 40), category: "summary", reason: "自動の配達通知。対応は不要。"),
            Seed(app: "メッセージ", title: "お母さん", body: "無事に着いたよ。今夜電話するね", time: at(17, 35), category: "notifyNow", reason: "家族からのメッセージ。", link: true, read: true),
            Seed(app: "Spark", title: "GitHub", subtitle: "[karui] CI passed on main", body: "すべてのチェックに合格しました。", time: at(14, 58), category: "summary", reason: "自動通知。確認だけで十分。", link: true),
            Seed(app: "Slack", title: "#general", subtitle: "レン", body: "12:30にロビーでランチどう？", time: at(11, 47), category: "summary", reason: "軽い誘い。急ぎではない。", link: true, read: true),
            Seed(app: "カレンダー", title: "歯医者", body: "明日 10:00", time: at(10, 0), category: "summary", reason: "翌日の予定のリマインダー。"),
            Seed(app: "LINE", title: "ユキ", body: "今日の試合、来る？", time: at(9, 36), category: "notifyNow", reason: "友だちからの質問。"),
            Seed(app: "Spark", title: "Northwind銀行", subtitle: "明細書のご案内", body: "9月分の明細書をご確認いただけます。", time: at(9, 5), category: "summary", reason: "定期の明細通知。"),
            Seed(app: "Spark", title: "Daily Deals", subtitle: "本日限定！", body: "人気商品が最大70%オフ。", time: at(8, 20), category: "silence", reason: "宣伝メール。"),
        ] : [
            Seed(app: "Messages", title: "Sam", body: "Party’s moved to 8! Can you bring the speaker?", time: at(17, 42), category: "notifyNow", reason: "A friend changing plans.", link: true),
            Seed(app: "Spark", title: "Mika Tanaka", subtitle: "Re: Friday deck", body: "Looks great. One tweak on page 3, can we talk tomorrow?", time: at(17, 31), category: "notifyNow", reason: "A reply from a colleague that asks for an answer.", link: true),
            Seed(app: "Slack", title: "#design", subtitle: "Lea", body: "Updated the icon set, thoughts?", time: at(17, 18), category: "summary", reason: "A channel post, nothing urgent.", link: true),
            Seed(app: "Spark", title: "Pebble Outfitters", subtitle: "40% off ends tonight", body: "The whole fall line is on sale. Don’t miss out!", time: at(16, 55), category: "silence", reason: "A promotional email."),
            Seed(app: "Wallet", title: "Order delivered", body: "Your order was delivered at 11:32.", time: at(16, 40), category: "summary", reason: "An automated delivery update, no action needed."),
            Seed(app: "Messages", title: "Mom", body: "Landed safely. Call you tonight", time: at(17, 35), category: "notifyNow", reason: "A message from family.", link: true, read: true),
            Seed(app: "Spark", title: "GitHub", subtitle: "[karui] CI passed on main", body: "All checks have passed.", time: at(14, 58), category: "summary", reason: "An automated notice, worth a glance.", link: true),
            Seed(app: "Slack", title: "#general", subtitle: "Ren", body: "Lunch at 12:30 by the lobby?", time: at(11, 47), category: "summary", reason: "A casual invitation, not urgent.", link: true, read: true),
            Seed(app: "Calendar", title: "Dentist", body: "Tomorrow at 10:00", time: at(10, 0), category: "summary", reason: "A reminder for tomorrow."),
            Seed(app: "LINE", title: "Yuki", body: "Are you coming to the game today?", time: at(9, 36), category: "notifyNow", reason: "A question from a friend."),
            Seed(app: "Spark", title: "Northwind Bank", subtitle: "Your statement is ready", body: "Your September statement is available.", time: at(9, 5), category: "summary", reason: "A routine statement notice."),
            Seed(app: "Spark", title: "Daily Deals", subtitle: "Today only!", body: "Up to 70% off bestsellers.", time: at(8, 20), category: "silence", reason: "A promotional email."),
        ]

        return seeds.enumerated().map { index, seed in
            let fingerprint = "demo-\(index)"
            var item = Inbox.Item(id: fingerprint, app: seed.app, fingerprint: fingerprint, title: seed.title, subtitle: seed.subtitle, body: seed.body, deliveredAt: seed.time)
            if seed.link {
                item.link = DeepLinkRecord(fingerprint: fingerprint, app: seed.app, url: URL(string: "about:blank")!, opensExactContent: true, deliveredAt: seed.time)
            }
            item.verdict = VerdictRecord(fingerprint: fingerprint, app: seed.app, category: seed.category, interest: nil, reason: seed.reason, triagedAt: seed.time, isUnread: !seed.read)
            if seed.read { item.readAt = seed.time.addingTimeInterval(120) }
            return item
        }
    }

    /// Puts the inbox in the asked-for view, with the second item open for `detail`.
    static func configure(_ inbox: Inbox) {
        // The table's columns start from their default widths each time.
        UserDefaults.standard.removeObject(forKey: "inbox.columns.demo")
        UserDefaults.standard.removeObject(forKey: "inbox.groupColumns.demo")
        inbox.replaceItems(items())
        inbox.grouping = .none
        inbox.search = ""
        inbox.shownCategories = Set(Inbox.categories)
        inbox.shownReadStates = Set(Inbox.ReadState.allCases)
        inbox.showsOnlyOpenable = false
        inbox.barDisplayMode = .iconAndText
        inbox.sortOrder = [KeyPathComparator(\.deliveredAt, order: .reverse)]
        inbox.showsPreview = view == "preview"
        switch view {
        case "compact":
            inbox.isCompact = true
        case "selected":
            inbox.isCompact = true
            if let second = inbox.items.dropFirst().first { inbox.selection = [second.id] }
        case "preview":
            inbox.isCompact = true
            if let second = inbox.items.dropFirst().first { inbox.selection = [second.id] }
        case "threads":
            inbox.isCompact = true
            inbox.grouping = .threads
        case "detail":
            inbox.isCompact = false
            // Yuki's LINE message, read here: the line about the iPhone's alert shows.
            if let yuki = inbox.items.first(where: { $0.app == "LINE" }) {
                inbox.markRead(ids: [yuki.id], at: yuki.deliveredAt.addingTimeInterval(90))
                inbox.openItemID = yuki.id
            }
        default:
            inbox.isCompact = false
        }
    }
}
