# Karui for Mac

The Mac companion to [Karui](https://karui.jp), the notification filter for iPhone. It watches the notifications that reach this Mac and works out where each one opens, so that tapping Karui's alert on the iPhone lands on the exact email in Spark, the exact message in Slack, or the right conversation in Messages.

Its window is the day's notifications from those apps, as Notification Center has them, with:

- what Karui on the iPhone decided about each (a `Verdict` record per notification, sent by the iPhone when Settings → Karui for Mac → Show History on your Mac is on),
- whether each has been read,
- and the link that opens it.

With the iPhone's *Include notifications only your iPhone gets* switch on, notifications from apps the Mac doesn't have appear too, from their encrypted text in the verdict, without a link.

On launch it also catches up on the last day's notifications, so a relaunch or an update loses nothing.

## Download

[Download Karui for Mac 0.7.9 for Apple Silicon](https://github.com/littlebobert/karui-mac/releases/download/0.7.9/Karui-0.7.9-mac.zip)

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

[Experiments/FINDINGS.md](Experiments/FINDINGS.md) documents each app's notifications and how its links are built, with the script that was used to look.

## What it sends to the iPhone

Everything goes through the person's own iCloud, in Karui's container. The record types are defined in [CloudKit/schema.ckdb](CloudKit/schema.ckdb). A Developer ID app can only use CloudKit's Production environment, so the schema must be deployed there before links can be sent.

### Links

Each link is a `DeepLink` record named by a fingerprint of the notification (`KaruiLinkKit`), with the URL stored encrypted. Records are deleted after a day.

### Notifications only this Mac received

The notification's text leaves the Mac only when the person turns on *Send notifications only this Mac received to your iPhone* in Settings (`SortRequests`).

Two minutes after a notification arrives, if the iPhone hasn't sent its verdict, the Mac creates a `Verdict` record named by the fingerprint, with the title, subtitle, and body end-to-end encrypted, `deliveredAt`, `sortRequestedAt`, and no category. (The iPhone never got the notification, because the app held the push back while the person was at the Mac, or the phone was off.)

Karui on the iPhone then:

- sorts it, or files the verdict this Mac already gave it (see [Sorting on this Mac](#sorting-on-this-mac)),
- adds it to History,
- alerts when it's Important and unread here,
- and writes its verdict onto the same record.

The Mac asks only while verdicts from the iPhone are arriving, since without them every notification would look unsorted, and only about notifications from the last six hours.

### Read on the Mac

Once an item is read on the Mac, the iPhone's alert about it goes away. The app notices the read in the app's own data (Spark's `unseen`, Slack's read marker in its log, Messages' `is_read`), or the notification leaving Notification Center, and sets `readAt` on the link's record, which the iPhone subscribes to.

### People the person writes to

Once a day it sends the people the person has written to, from the recipients of Spark's sent mail and the Messages chats the person has written in, as a `Correspondents` record of hashes (`CorrespondentHash`). The iPhone hashes a notification's sender the same way, and a match alerts like a saved contact's. Only address columns are read, never a message, and nothing readable is sent.

### This Mac

While it runs, the app keeps one `Companion` record with this Mac's name, the app version, when it was last seen, and the apps it covers. The iPhone uses it to show the Mac in its settings, and to skip waiting for a link when no Mac has been seen for a day.

### Quiet while you use this Mac

While the person is using the Mac (a key or the pointer moved in the last three minutes, the screen unlocked and awake), it keeps a `MacPresence` record with only whether it's in use and when (`MacPresenceReporter`). It's written every 30 seconds, with App Nap held off meanwhile so the writes stay on time, and marked idle at once when the screen locks or the Mac sleeps.

For the next 90 seconds, Karui on the iPhone sends its alerts quietly, to Notification Center, and the Mac shows its own banner for an Important notification only the iPhone received (`MacBanners`). Wake Me and one-time codes still alert on the iPhone. *Quiet your iPhone while you use this Mac* in Settings turns this off.

### Hearing back

The Mac learns of the iPhone's verdicts and settings by CloudKit push (`MacSubscriptions`), with a slower poll as a fallback.

## Sorting on this Mac

With macOS 26 or later and Apple Intelligence on, the Mac sorts each notification from Messages, Spark, and Slack as it arrives, with the iPhone's own settings and Apple's on-device model, so the inbox has a category at once (Settings → *Sort notifications on this Mac*, on by default). Nothing leaves the Mac to do it.

Its verdict shows until the iPhone's arrives. For a notification only the Mac received, the sort request carries it (`macCategory` and friends on the `Verdict` record), and the iPhone files it as is.

### The iPhone's settings

The settings come from Karui on the iPhone while *Show History on your Mac* is on there: one `SortingSettings` record in the person's iCloud private database, end-to-end encrypted, with:

- the iPhone's sorting settings: VIPs without their photos, names, terms, important and quiet apps, work hours;
- what Karui learned from fixes in History, kept as hashes of three-letter pieces of text, never the text.

The Mac keeps a copy in `~/Library/Application Support/Karui` so it sorts offline, and deletes it when the iPhone deletes the record. Settings → Sorting shows them, read only, under *Your iPhone's sorting settings*; they change in Karui on the iPhone.

### Setup card

Until it's working, a card at the top of the inbox offers the next missing step, one at a time (`SetupNudge`):

1. turning on *Show History on your Mac* on the iPhone,
2. getting the Second Opinion Shortcut when Second Opinion is on there,
3. sending notifications only this Mac received to the iPhone.

Each goes once done or dismissed. In debug builds, Help → Show Setup Banner shows any of them.

### Second Opinion

When Second Opinion is on in Karui on the iPhone, the Mac follows its *When to Ask* setting and asks Apple's Private Cloud Compute through a Shortcut of the person's own, by default named **Karui Second Opinion** (Settings → *Second Opinion Shortcut*). It runs `shortcuts run` with the same prompt the iPhone sends and reads the answer the same way.

Karui for Mac can't use Private Cloud Compute itself, since a Developer ID profile can't carry the entitlement.

[Get the Shortcut](https://www.icloud.com/shortcuts/5e5dadea36134e56ab3d7f372eedd747); Settings shows whether it's installed and links to it. It has three actions:

1. receives Text,
2. runs **Use Model** set to Private Cloud Compute with the Shortcut Input as the request (follow-up off),
3. stops and outputs the model's Response, doing nothing when there's nowhere to output.

## KaruiLinkKit and KaruiSorting

The Swift package at the repository root holds what the Mac app and the iPhone app share. The iPhone app depends on both by this repository's URL.

- **KaruiLinkKit** is what they must agree on: how a notification is fingerprinted and the shape of the records each sends.
- **KaruiSorting** is how Karui sorts a notification: the rules, prompts, and on-device classifier the iPhone app uses too, so the two sort the same way. What depends on the app it runs in comes in through `SortingEnvironment`.

## Builds from source

Anyone can build and run the app. Syncing with the App Store version of Karui needs the same iCloud container, which only builds signed by the same team can use, so a build from source will find links but not send them.

## License

Karui for Mac is open source under the [MIT License](LICENSE). Copyright © 2026 Justin Garcia.
