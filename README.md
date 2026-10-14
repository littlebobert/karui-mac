# Karui for Mac

The Mac companion to [Karui](https://karui.jp), the notification filter for iPhone. It watches the notifications that reach this Mac and works out where each one opens, so that tapping Karui's alert on the iPhone lands on the exact email in Spark, the exact message in Slack, or the right conversation in Messages.

Early days: it finds links and shows them in its window. Sending them to the iPhone, and showing the iPhone's sorted notifications here, come next.

## Download

[Download Karui for Mac 0.2.0 for Apple Silicon](https://github.com/littlebobert/karui-mac/releases/download/0.2.0/Karui-0.2.0-mac.zip)

## Build and run

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
./Scripts/reset-build-run.sh
```

`swift test` runs the shared package's tests; the app's run from the `KaruiMac` scheme.

## Required permissions

- **Full Disk Access** — macOS keeps Notification Center's database behind it. There is no prompt, and macOS does not list an app whose reads it refused: in System Settings → Privacy & Security → Full Disk Access, press + and choose Karui.

## What it reads

Only what it needs to build a link, and only for the apps it knows:

- Notification Center's database, for notifications from Messages, Spark, and Slack. Other apps' notifications are never decoded.
- Spark's mail database, to find the email a notification is about. From the account's settings it reads the address and nothing else.
- Slack's notification log and saved workspace list, for the channel and the workspace's address.
- Messages' database, for who is in the conversation.

LINE is not supported: its notifications identify nothing, and LINE for Mac keeps its data encrypted.

Each link goes to the iPhone through the person's own iCloud, as a `DeepLink` record in Karui's container named by a fingerprint of the notification (`KaruiLinkKit`), with the URL stored encrypted; the notification's text never leaves the Mac, and records are deleted after a day. Once an item is read on the Mac, the iPhone's alert about it goes away: the app notices the read in the app's own data (Spark's `unseen`, Slack's read marker in its log, Messages' `is_read`), or the notification leaving Notification Center, and sets `readAt` on the link's record, which the iPhone subscribes to. While it runs, the app also keeps one `Companion` record with this Mac's name, the app version, when it was last seen, and the apps it covers, so the iPhone can show the Mac in its settings and skip waiting for a link when no Mac has been seen for a day. Both record types are defined in [CloudKit/schema.ckdb](CloudKit/schema.ckdb); a Developer ID app can only use CloudKit's Production environment, so the schema must be deployed there before links can be sent. [Experiments/FINDINGS.md](Experiments/FINDINGS.md) documents each app's notifications and how its links are built, with the script that was used to look.

## KaruiLinkKit

The Swift package at the repository root holds what the Mac app and the iPhone app must agree on: how a notification is fingerprinted and the shape of the record the Mac sends. The iPhone app depends on it by this repository's URL.

## Builds from source

Anyone can build and run the app. Syncing with the App Store version of Karui needs the same iCloud container, which only builds signed by the same team can use, so a build from source will find links but not send them.

## License

Karui for Mac is open source under the [MIT License](LICENSE). Copyright © 2026 Justin Garcia.
