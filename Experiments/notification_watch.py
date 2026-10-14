#!/usr/bin/env python3
"""Watches macOS Notification Center's database for Messages and LINE notifications.

An experiment for a Mac companion to Karui. It answers two questions:

1. Do the notifications carry something usable as a deep link (a conversation or
   message identifier, a URL)? `dump` prints every field in each payload, and marks
   anything that looks like a link or an identifier.
2. When a message is unsent, does its notification leave the database? `watch` polls
   the database and prints each notification that appears or disappears, with what it
   said, so you can unsend a message from another device and see.

Reading the database needs Full Disk Access for whatever runs this script (System
Settings → Privacy & Security → Full Disk Access → Terminal). It only reads: each
poll copies the database to a temporary folder and opens the copy.

    python3 notification_watch.py schema            # tables and columns, no contents
    python3 notification_watch.py dump              # recent Messages and LINE notifications
    python3 notification_watch.py dump --all-apps   # every app's
    python3 notification_watch.py dump --hide-text  # field names and identifiers only, for sharing
    python3 notification_watch.py watch             # live: appeared / disappeared
    python3 notification_watch.py watch --log out.jsonl
    python3 notification_watch.py messages <GUID> …    # read, unsent, or neither, per chat.db

Text is shown in full on this Mac only; nothing is sent anywhere.
"""

import argparse
import datetime as dt
import json
import plistlib
import re
import shutil
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

DB = Path.home() / "Library/Group Containers/group.com.apple.usernoted/db2/db"
# Messages' own database, which marks a message retracted (unsent) separately from read.
CHAT_DB = Path.home() / "Library/Messages/chat.db"
# Bundle identifiers, matched as substrings: Messages is com.apple.MobileSMS (iChat
# on older macOS); LINE is jp.naver.line.mac.
DEFAULT_APPS = ["MobileSMS", "iChat", "naver.line"]
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
LINKISH = re.compile(r"^[a-z][a-z0-9+.-]*://|^(chat|thread|conv|room|message|msg)", re.I)
# Keys whose values are what the notification said, hidden by --hide-text.
TEXT_KEYS = re.compile(r"(titl|subt|body|text|message|msg|name|nam)$", re.I)
HIDE_TEXT = False


# MARK: Reading the database

def snapshot(database=DB):
    """A consistent copy of a database and its write-ahead log, opened read-only."""
    if not database.exists():
        sys.exit(f"Not found: {database}")
    folder = Path(tempfile.mkdtemp(prefix="karui-experiment-"))
    try:
        for suffix in ("", "-wal", "-shm"):
            source = Path(str(database) + suffix)
            if source.exists():
                shutil.copy2(source, folder / ("db" + suffix))
    except PermissionError:
        shutil.rmtree(folder, ignore_errors=True)
        sys.exit("Permission denied. Give Full Disk Access to the app running this script "
                 "(System Settings → Privacy & Security → Full Disk Access), then rerun.")
    connection = sqlite3.connect(f"file:{folder / 'db'}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection, folder


def tables(connection):
    return [row[0] for row in connection.execute("select name from sqlite_master where type = 'table' order by name")]


def columns(connection, table):
    return [row[1] for row in connection.execute(f"pragma table_info('{table}')")]


def records(connection):
    """Every notification record, with its app's bundle identifier when the schema has one."""
    record_columns = columns(connection, "record")
    if "app" in tables(connection) and "identifier" in columns(connection, "app") and "app_id" in record_columns:
        query = "select record.*, app.identifier as bundle from record left join app using (app_id)"
    else:
        query = "select record.*, null as bundle from record"
    return [dict(row) for row in connection.execute(query)]


# MARK: Decoding payloads

def unarchive(archive):
    """Turns an NSKeyedArchiver plist into plain dicts and lists."""
    objects = archive["$objects"]

    def resolve(value, depth=0):
        if depth > 40:
            return "…"
        if isinstance(value, plistlib.UID):
            return resolve(objects[value.data], depth + 1)
        if isinstance(value, dict):
            if "NS.keys" in value and "NS.objects" in value:
                return {str(resolve(k, depth + 1)): resolve(v, depth + 1) for k, v in zip(value["NS.keys"], value["NS.objects"])}
            if "NS.objects" in value:
                return [resolve(v, depth + 1) for v in value["NS.objects"]]
            if "NS.string" in value:
                return value["NS.string"]
            if "NS.relative" in value:
                return resolve(value["NS.relative"], depth + 1)
            if "NS.time" in value:
                return apple_date(value["NS.time"])
            if "NS.bytes" in value:
                return decode(value["NS.bytes"])
            if "NS.data" in value:
                return decode(value["NS.data"])
            return {k: resolve(v, depth + 1) for k, v in value.items() if k != "$class"}
        if isinstance(value, list):
            return [resolve(v, depth + 1) for v in value]
        return value

    return resolve(archive["$top"]["root"] if "root" in archive["$top"] else archive["$top"])


def decode(value):
    """Plists inside plists, as apps nest them, decoded all the way down."""
    if isinstance(value, bytes):
        if value.startswith(b"bplist") or value.lstrip().startswith(b"<?xml"):
            try:
                return decode(plistlib.loads(value))
            except Exception:
                pass
        try:
            text = value.decode("utf-8")
            if text.isprintable():
                return text
        except UnicodeDecodeError:
            pass
        return f"<{len(value)} bytes>"
    if isinstance(value, dict):
        if "$archiver" in value and "$objects" in value:
            return decode(unarchive(value))
        return {str(k): decode(v) for k, v in value.items()}
    if isinstance(value, list):
        return [decode(v) for v in value]
    return value


def apple_date(seconds):
    if seconds is None:
        return None
    try:
        return (APPLE_EPOCH + dt.timedelta(seconds=float(seconds))).astimezone().isoformat(timespec="seconds")
    except (OverflowError, ValueError, TypeError):
        return seconds


def flatten(value, prefix=""):
    """Key paths and values, for printing every field in a payload."""
    if isinstance(value, dict):
        for key, inner in value.items():
            yield from flatten(inner, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, list):
        for index, inner in enumerate(value):
            yield from flatten(inner, f"{prefix}[{index}]")
    else:
        yield prefix, value


def summary(record):
    """What the notification said, and its payload's fields."""
    payload = decode(record.get("data")) if record.get("data") is not None else {}
    fields = dict(flatten(payload))

    def first(*names):
        for path, value in fields.items():
            if path.rsplit(".", 1)[-1] in names and isinstance(value, str) and value:
                return value
        return None

    return {
        "id": record.get("rec_id"),
        "uuid": record.get("uuid").hex() if isinstance(record.get("uuid"), bytes) else record.get("uuid"),
        "app": record.get("bundle"),
        "delivered": apple_date(record.get("delivered_date")),
        "title": first("titl", "title"),
        "subtitle": first("subt", "subtitle"),
        "body": first("body"),
        "thread": first("thre", "threadIdentifier"),
        "fields": {path: value for path, value in fields.items()},
    }


def wanted(record, apps):
    bundle = (record.get("bundle") or "").lower()
    return apps is None or any(app.lower() in bundle for app in apps)


def show(note, label=""):
    print(f"\n{label}{note['app']}  #{note['id']}  delivered {note['delivered']}")
    for name in ("title", "subtitle", "body", "thread"):
        if note[name]:
            print(f"  {name:9} {'<%d chars hidden>' % len(note[name]) if HIDE_TEXT else note[name]}")
    print("  fields:")
    for path, value in note["fields"].items():
        text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
        if HIDE_TEXT and TEXT_KEYS.search(path.rsplit(".", 1)[-1]):
            text = f"<{len(text)} chars hidden>"
        mark = "  ← link or identifier?" if isinstance(value, str) and (LINKISH.search(value) or re.search(r"(?i)(iden|thre|chat|url|link|conv|guid|mid)", path)) else ""
        print(f"    {path} = {text[:160]}{mark}")


# MARK: Messages' database

# Columns that say what happened to a message, where this macOS has them.
STATUS_COLUMNS = ["is_read", "date_read", "date_retracted", "date_edited", "date_delivered",
                  "is_delivered", "is_empty", "is_from_me", "item_type", "was_data_detected"]


def messages_date(value):
    """chat.db dates: nanoseconds since 2001 on current macOS, seconds on old ones."""
    if not value:
        return value
    seconds = value / 1e9 if abs(value) > 1e11 else value
    return apple_date(seconds)


def message_status(guid):
    """What chat.db says about one message, by the GUID its notification carried."""
    connection, folder = snapshot(CHAT_DB)
    try:
        available = columns(connection, "message")
        wanted_columns = [c for c in STATUS_COLUMNS if c in available]
        extra = [c for c in available if ("retract" in c or "unsend" in c or "edit" in c) and c not in wanted_columns]
        selected = ["guid", "text", "length(attributedBody) as body_bytes", "message_summary_info"] \
            if "message_summary_info" in available else ["guid", "text", "length(attributedBody) as body_bytes"]
        query = f"select {', '.join(selected + wanted_columns + extra)} from message where guid = ?"
        row = connection.execute(query, (guid,)).fetchone()
        if row is None:
            return {"guid": guid, "found": False}
        status = dict(row)
        if status.get("message_summary_info") is not None:
            status["message_summary_info"] = decode(status["message_summary_info"])
        for name, value in list(status.items()):
            if name.startswith("date_"):
                status[name] = messages_date(value)
        status["found"] = True
        return status
    finally:
        connection.close()
        shutil.rmtree(folder, ignore_errors=True)


def message_guid(note):
    for path in ("req.iden", "req.usda.CKBBContextKeyMessageGUID"):
        value = note["fields"].get(path)
        if isinstance(value, str) and value:
            return value
    return None


def verdict(status):
    if not status.get("found"):
        return "not in chat.db (deleted, or not synced to this Mac)"
    if status.get("date_retracted"):
        return "UNSENT (date_retracted is set)"
    # On macOS 27 an unsend is stored as an edit that empties the message: date_edited
    # is set and the text is gone. An ordinary edit keeps its text.
    emptied = not status.get("text") and not status.get("body_bytes")
    if status.get("date_edited") and (emptied or status.get("is_empty")):
        return "UNSENT (edited and emptied)"
    if status.get("date_edited"):
        return "edited (text kept)"
    if status.get("is_read") or status.get("date_read"):
        return "read (no retraction)"
    return "neither read nor retracted yet"


def show_status(guid):
    status = message_status(guid)
    print(f"  chat.db: {verdict(status)}")
    for name, value in status.items():
        if name == "message_summary_info" and isinstance(value, (dict, list)):
            for path, inner in flatten(value, name):
                print(f"    {path} = {str(inner)[:120]}")
        elif name not in ("found",):
            print(f"    {name} = {str(value)[:120]}")


# MARK: Commands

def command_schema(_):
    connection, folder = snapshot()
    try:
        for table in tables(connection):
            count = connection.execute(f"select count(*) from '{table}'").fetchone()[0]
            print(f"{table} ({count} rows): {', '.join(columns(connection, table))}")
    finally:
        connection.close()
        shutil.rmtree(folder, ignore_errors=True)


def command_dump(arguments):
    apps = None if arguments.all_apps else arguments.apps
    connection, folder = snapshot()
    try:
        notes = [summary(r) for r in records(connection) if wanted(r, apps)]
    finally:
        connection.close()
        shutil.rmtree(folder, ignore_errors=True)
    notes.sort(key=lambda n: n["delivered"] or "")
    for note in notes[-arguments.limit:]:
        show(note)
    if not notes:
        print("No matching notifications. Send yourself a Messages or LINE message on this Mac's account first.")


def command_watch(arguments):
    apps = None if arguments.all_apps else arguments.apps
    log = open(arguments.log, "a", encoding="utf-8") if arguments.log else None
    seen = {}
    print(f"Watching {DB} every {arguments.interval}s for {', '.join(apps) if apps else 'all apps'}. Ctrl-C to stop.")
    first_pass = True
    try:
        while True:
            connection, folder = snapshot()
            try:
                current = {r.get("rec_id"): summary(r) for r in records(connection) if wanted(r, apps)}
            finally:
                connection.close()
                shutil.rmtree(folder, ignore_errors=True)
            now = dt.datetime.now().astimezone().isoformat(timespec="seconds")
            if first_pass:
                print(f"{len(current)} matching notifications already there.")
                first_pass = False
            else:
                for key in current.keys() - seen.keys():
                    show(current[key], f"[{now}] APPEARED  ")
                    if log:
                        log.write(json.dumps({"event": "appeared", "at": now, **current[key]}, ensure_ascii=False, default=str) + "\n")
                for key in seen.keys() - current.keys():
                    show(seen[key], f"[{now}] DISAPPEARED  ")
                    guid = message_guid(seen[key]) if "mobilesms" in (seen[key]["app"] or "").lower() else None
                    if guid and CHAT_DB.exists():
                        # The retraction can land in chat.db a moment after the notification goes.
                        time.sleep(2)
                        show_status(guid)
                    if log:
                        log.write(json.dumps({"event": "disappeared", "at": now, **seen[key]}, ensure_ascii=False, default=str) + "\n")
                for key in current.keys() & seen.keys():
                    if current[key]["fields"] != seen[key]["fields"]:
                        show(current[key], f"[{now}] CHANGED  ")
                        if log:
                            log.write(json.dumps({"event": "changed", "at": now, "before": seen[key], "after": current[key]}, ensure_ascii=False, default=str) + "\n")
                if log:
                    log.flush()
            seen = current
            time.sleep(arguments.interval)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        if log:
            log.close()


def command_messages(arguments):
    for guid in arguments.guids:
        print(guid)
        show_status(guid)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    filters = argparse.ArgumentParser(add_help=False)
    filters.add_argument("--apps", nargs="+", default=DEFAULT_APPS, help="bundle identifier substrings to include")
    filters.add_argument("--all-apps", action="store_true", help="include every app")
    filters.add_argument("--hide-text", action="store_true", help="print field names and identifiers, not what was said")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("schema").set_defaults(run=command_schema)
    dump = commands.add_parser("dump", parents=[filters])
    dump.add_argument("--limit", type=int, default=20)
    dump.set_defaults(run=command_dump)
    messages = commands.add_parser("messages", help="what chat.db says about message GUIDs")
    messages.add_argument("guids", nargs="+")
    messages.set_defaults(run=command_messages)
    watch = commands.add_parser("watch", parents=[filters])
    watch.add_argument("--interval", type=float, default=1.0)
    watch.add_argument("--log", help="also append each event to this JSON Lines file")
    watch.set_defaults(run=command_watch)
    arguments = parser.parse_args()
    global HIDE_TEXT
    HIDE_TEXT = getattr(arguments, "hide_text", False)
    arguments.run(arguments)


if __name__ == "__main__":
    main()
