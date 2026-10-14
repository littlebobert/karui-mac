import Foundation
import KaruiLinkKit

/// Slack's notification identifier carries the team and the message's timestamp.
/// The channel comes from Slack's log of the notifications it showed, and the
/// workspace's address from its saved state; see Experiments/FINDINGS.md.
struct SlackHarvester: NotificationHarvester {
    let bundleIdentifiers = Set(KnownApp.slack.macBundleIdentifiers)
    var supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Slack")

    func harvest(_ record: NotificationRecord) async -> HarvestedLink? {
        guard let identifier = record.identifier, let message = SlackLink.parseIdentifier(identifier) else {
            SafeDiagnosticLog.shared.record("slack: notification identifier not in the expected form")
            return nil
        }
        let log = try? String(contentsOf: supportDirectory.appending(path: "logs/default/browser.log"), encoding: .utf8)
        guard let log, let channelID = SlackLog.channel(forMessageTimestamp: message.timestamp, in: log) else {
            SafeDiagnosticLog.shared.record("slack: channel not found in the log")
            return nil
        }
        let rootState = try? Data(contentsOf: supportDirectory.appending(path: "storage/root-state.json"))
        let probe = ReadProbe.slack(channelID: channelID, timestamp: message.timestamp)
        if let rootState, let workspace = SlackLink.workspaceURL(teamID: message.teamID, rootState: rootState),
           let url = SlackLink.permalink(workspace: workspace, channelID: channelID, timestamp: message.timestamp) {
            return HarvestedLink(link: record.deepLink(as: .slack, url: url, opensExactContent: true), readProbe: probe, notificationID: record.id)
        }
        SafeDiagnosticLog.shared.record("slack: workspace address not found; linking the channel")
        guard let url = SlackLink.channelURL(teamID: message.teamID, channelID: channelID) else { return nil }
        return HarvestedLink(link: record.deepLink(as: .slack, url: url, opensExactContent: false), readProbe: probe, notificationID: record.id)
    }

    /// Slack logs each channel's read marker as it moves; the message is read once
    /// the marker has reached its timestamp.
    func isRead(_ probe: ReadProbe) async -> Bool? {
        guard case .slack(let channelID, let timestamp) = probe else { return nil }
        guard let log = try? String(contentsOf: supportDirectory.appending(path: "logs/default/webapp-console.log"), encoding: .utf8),
              let lastRead = SlackLog.lastRead(channelID: channelID, in: log) else {
            return nil
        }
        return (Double(lastRead) ?? 0) >= (Double(timestamp) ?? .infinity)
    }
}

enum SlackLink {
    struct MessageIdentifier: Equatable {
        let teamID: String
        /// Slack's `ts`, seconds and a six-digit sequence: `1791879249.798639`.
        let timestamp: String
    }

    /// `req.iden` is `<team ID>_<ts>`.
    static func parseIdentifier(_ identifier: String) -> MessageIdentifier? {
        guard let match = identifier.wholeMatch(of: /(T[A-Z0-9]+)_(\d+\.\d+)/) else { return nil }
        return MessageIdentifier(teamID: String(match.1), timestamp: String(match.2))
    }

    /// The message's permalink, which opens Slack on the iPhone at the message.
    static func permalink(workspace: URL, channelID: String, timestamp: String) -> URL? {
        workspace.appending(path: "archives/\(channelID)/p\(timestamp.replacingOccurrences(of: ".", with: ""))")
    }

    /// Opens the channel or direct message, when the message itself can't be linked.
    static func channelURL(teamID: String, channelID: String) -> URL? {
        URL(string: "slack://channel?team=\(teamID)&id=\(channelID)")
    }

    /// `workspaces.<team ID>.url` in Slack's `storage/root-state.json`. The `url` is
    /// used rather than the `domain`, for workspaces with addresses of their own.
    static func workspaceURL(teamID: String, rootState: Data) -> URL? {
        guard let state = try? JSONSerialization.jsonObject(with: rootState) as? [String: Any],
              let workspaces = state["workspaces"] as? [String: Any],
              let workspace = workspaces[teamID] as? [String: Any],
              let url = workspace["url"] as? String else {
            return nil
        }
        return URL(string: url)
    }
}

enum SlackLog {
    /// The furthest read marker logged for a channel: lines like
    /// `Counting unreads in D0123456789 because last_read changed to 1791879249.798639`.
    static func lastRead(channelID: String, in log: String) -> String? {
        var latest: (value: Double, text: String)?
        for line in log.split(separator: "\n") where line.contains("Counting unreads in \(channelID) ") {
            guard let match = line.firstMatch(of: /last_read changed to (\d+\.\d+)/),
                  let value = Double(match.1) else { continue }
            if latest == nil || value > latest!.value { latest = (value, String(match.1)) }
        }
        return latest?.text
    }

    /// Slack logs each notification it shows as a pretty-printed JSON object, one
    /// key per line, with `"msg": "<ts>"` and `"channel": "<ID>"` among them. The
    /// search stays inside that object: its lines between a lone `{` and a lone `}`.
    static func channel(forMessageTimestamp timestamp: String, in log: String) -> String? {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        let marker = "\"msg\": \"\(timestamp)\""
        guard let index = lines.lastIndex(where: { $0.contains(marker) }) else { return nil }
        let isBoundary = { (line: Substring, brace: String) in
            line.trimmingCharacters(in: .whitespaces) == brace
        }
        let start = lines[...index].lastIndex { isBoundary($0, "{") } ?? index
        let end = lines[index...].firstIndex { isBoundary($0, "}") } ?? index
        for line in lines[start...end] {
            if let match = line.firstMatch(of: /"channel":\s*"([A-Z0-9]+)"/) {
                return String(match.1)
            }
        }
        return nil
    }
}
