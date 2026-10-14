# Mac notification findings

What `notification_watch.py` turned up about a Mac companion that harvests deep links from Notification Center so Karui's replacement notifications on iPhone can open the exact email or conversation. Observed on macOS 27 with Spark Desktop and Slack, October 2026.

## The database

- `~/Library/Group Containers/group.com.apple.usernoted/db2/db`, SQLite with a write-ahead log. Each `record` row's `data` is a binary plist; `app.identifier` gives its bundle identifier.
- Reading it needs Full Disk Access for the process doing the reading (for the script, the terminal app; it takes effect after the app relaunches). That rules out the Mac App Store sandbox for the companion.
- A notification's fields live under `req`: `titl`, `subt`, `body`, `iden`, and, when the app attached any, `usda` (its user info). Bodies are truncated at about 160 characters.

## Spark

Bundle identifier `com.readdle.SparkDesktop`. The notification carries no link and no user info:

| Field | Value |
|---|---|
| `req.titl` | sender's display name |
| `req.subt` | subject |
| `req.body` | start of the message |
| `req.iden` | a UUID that appears nowhere in Spark's data, as text or as bytes: the notification's own identifier, not the email's |
| `req.soun.nam` | `spark_sound_newmail.mp3` |

Marketing mail pads its preview text with invisible characters (U+034F, U+200C, U+00AD), which show up in `req.body`; matching on the body has to strip them and compare prefixes.

### Spark's own database

Spark Desktop isn't sandboxed. Its mail store is `~/Library/Application Support/Spark Desktop/core-data/messages.sqlite`, whose `messages` table has, among others, `messageId` (the RFC 5322 Message-ID without angle brackets), `gmailMessageId`, `subject`, `messageFrom`, `receivedDate` (Unix seconds), and `accountPk`, a key into `accounts`. An account's address is `accountAddress` in the JSON of its `additionalInfo` column; `accountTitle` is usually empty. The same JSON names Keychain items for its server credentials (`mailServerAuthenticationKCKey` and the like), so the companion should read `accountAddress` and nothing else from it.

A notification finds its row by `subject` = `req.subt` and `receivedDate` within a few seconds of the delivery date, with the sender to break ties.

### Spark links

Spark's per-email links (Copy Link on a message) are plain data, not server tokens:

```
readdle-spark://bl=<percent-encoded base64 of the payload, wrapped at 64 characters with CRLF>

payload = "A:<accountAddress>;ID:<messageId>"
payload += ";gID:<gmailMessageId>"          // only when it isn't 0: Gmail and Google Workspace accounts
payload += ";" + <CRC32 of the payload so far, UTF-8, in decimal>
```

Links built this way matched the ones Spark copied, byte for byte, for a Google Workspace account and an iCloud account (which has no `gID`). Still open:

- Opening such a link on an iPhone lands on that email in Spark: confirmed.
- Whether Exchange and other account types add fields of their own.
- Whether Spark also accepts the base64 unwrapped.

## Messages

Bundle identifier `com.apple.MobileSMS`. The notification carries the message's GUID in `req.iden` and `req.usda.CKBBContextKeyMessageGUID`. In `~/Library/Messages/chat.db` the GUID leads to the message's chat and its members' handles, which would give `ConversationRouter` a complete `sms://open?addresses=` list even for groups with people Karui has no number for. iOS has no public URL for one message, so this opens the thread. The companion's `MessagesHarvester` does this lookup and works: a one-to-one chat yields `sms:<number>`, which opens the thread on an iPhone (on a Mac the same URL starts a draft). That is the URL the iPhone app already builds for itself, so for one-to-one chats the Mac adds nothing. Its contribution is groups: the iPhone can only list a group's members when each is a VIP with a known number, while `chat.db` has everyone.

## Slack

Bundle identifier `com.tinyspeck.slackmacgap` (Slack 4.52, the direct download). The notification has `req.titl` (sender), `req.subt`, `req.body`, a `req.cate` of the form `CATEGORY_<number>`, and `req.iden` = `<team ID>_<message ts>`, for example `T0123ABCDEF_1791879249.798639`. That is two of the three parts of a link to the message; the channel is missing.

Slack posts nothing while its own window is in front, and a notification first seen in the database had been delivered about ten seconds earlier. A notification may also go away once the message is read elsewhere, which hasn't been checked; the companion should take what it needs as soon as a record appears.

### The channel, from Slack's log

Slack logs each notification it shows to `~/Library/Application Support/Slack/logs/default/browser.log` as a JSON object:

| Key | Value |
|---|---|
| `teamId` | `T…`, as in `req.iden` |
| `msg` | the message ts, as in `req.iden` |
| `channel` | `C…`, `D…` (direct message), or `G…` |
| `userId` | the sender, `U…` |
| `title`, `subtitle`, `content`, `body`, `authorName`, `avatarImage`, `channelName`, `launchUri` | all the same 13 characters: apparently a redaction placeholder, so the log seems to keep no text |

So `req.iden`'s ts finds the object, and the object gives the channel. A log is a weak contract (its format, level, and rotation are Slack's to change), so a missing match falls back to opening Slack; `req.subt`, the channel's name, might be mapped to an ID from Slack's IndexedDB if that turns out to be needed. The IndexedDB didn't contain the ts in plain text, probably because it is compressed.

### Slack links

- `slack://channel?team=<team ID>&id=<channel ID>` opens the channel or direct message (documented).
- `https://<workspace domain>.slack.com/archives/<channel ID>/p<ts without the dot>` is the message's permalink, a universal link that opens Slack on iPhone at the message; a reply adds `?thread_ts=<parent ts>`. Opening the permalink on an iPhone lands on the message: confirmed.

The workspace's address isn't in the notification or the log object. It is in `~/Library/Application Support/Slack/storage/root-state.json`, plain JSON: `workspaces.<team ID>` has `domain`, `name`, and `url` (`https://<domain>.slack.com/`). The permalink should start from `url` instead of being built from `domain`, which covers Enterprise Grid workspaces with addresses of their own (not yet seen). Slack's Local Storage and IndexedDB hold the same thing, but compressed in LevelDB.

## LINE

Bundle identifier `jp.naver.line.mac`. Not feasible. The notification identifies nothing: `req.iden` is `1`, `req.usda` holds only `toastId = 1`, and `req.cate` is `REPLY_CATEGORY`; it carries the sender's name as the title and the text as the body, with no subtitle. And LINE for Mac keeps its data encrypted: its databases are `.edb` files under `~/Library/Containers/jp.naver.line.mac/Data/Library/Containers/jp.naver.line/Data/db/`, whose first bytes are not SQLite's header. Reading them would mean breaking the app's encryption of its own store, which Karui won't do. LINE stays on the iPhone app's existing route, which opens the app.

## Matching across devices

Confirmed end to end on 2026-10-14: a Spark email's notification reached a locked Mac, the Mac sent its link through iCloud, and a tap on the iPhone opened Spark on that email. Spark notifies the Mac while the person is away, which is the case that matters; while the person is active on the Mac, Spark may hold the iPhone's push back.

The fingerprint's inputs are the notification's title, subtitle, and body as each platform's notification carries them. Spark's title is the sender as the mail shows it (an address when there is no name) on both. On the iPhone, the Shortcut's Body field is the one to use: Karui's stored History body is the subtitle and body joined for display, and fingerprinting that was the first mismatch.
