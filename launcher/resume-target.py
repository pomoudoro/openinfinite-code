"""Read-only lookups in the OpenCode session DB for the quota-resume flow.

Commands (all print one JSON object on stdout):
  target  --since-ms N            chat that hit the free limit most recently
  check   --session S --since-ms N --text T   was T already sent after N?
  status  --session S --since-ms N          first assistant token / new limit after N
"""
import argparse
import datetime
import json
import os
import re
import sqlite3
import sys

FREE_LIMIT_LIKE = ("%provider.free-limit%", "%FreeUsageLimitError%", "%Free usage limit%")


def data_dir():
    d = os.environ.get("OC_DATA_DIR")
    if d and os.path.isdir(d):
        return d
    return os.path.join(os.path.expanduser("~"), ".local", "share", "opencode")


def connect():
    path = os.path.join(data_dir(), "opencode.db").replace("\\", "/")
    con = sqlite3.connect("file:" + path + "?mode=ro", uri=True, timeout=10)
    con.execute("pragma query_only=1")
    return con


def session_info(con, sid):
    # A subagent chat is never the target: walk up to the chat the user talks to.
    for _ in range(10):
        row = con.execute(
            "select id, directory, title, time_viewed, parent_id from session_v2 where id=?", (sid,)
        ).fetchone()
        if not row:
            return None
        if not row[4]:
            break
        sid = row[4]
    return {"session": row[0], "directory": row[1], "title": row[2], "viewed_ms": row[3]}


def free_limit_clause(alias="m"):
    return "(" + " or ".join(alias + ".data like ?" for _ in FREE_LIMIT_LIKE) + ")"


def from_db(con, since_ms):
    row = con.execute(
        "select m.session_id, m.time_created from session_message m "
        "where m.type='idle' and m.time_created>=? and " + free_limit_clause() +
        " order by m.time_created desc limit 1",
        (since_ms, *FREE_LIMIT_LIKE),
    ).fetchone()
    if not row:
        return None
    info = session_info(con, row[0])
    if info:
        info["error_ms"] = row[1]
    return info


def from_log(con, since_ms):
    path = os.path.join(data_dir(), "log", "opencode.log")
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 4 * 1024 * 1024))
        lines = fh.read().decode("utf-8", "replace").splitlines()
    since_iso = datetime.datetime.fromtimestamp(since_ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    for i in range(len(lines) - 1, -1, -1):
        line = lines[i]
        if "level=ERROR" not in line or not re.search(r"free usage limit|FreeUsageLimit|free-limit", line, re.I):
            continue
        ts = re.search(r"timestamp=(\S+)", line)
        if ts and ts.group(1)[:19] < since_iso:
            return None
        for j in range(i, max(-1, i - 400), -1):
            m = re.search(r"sessionID=(ses_[A-Za-z0-9]+)", lines[j])
            if m:
                return session_info(con, m.group(1))
        return None
    return None


def from_viewed(con, since_ms):
    row = con.execute(
        "select id from session_v2 where time_viewed>=? order by time_viewed desc limit 1",
        (since_ms,),
    ).fetchone()
    return session_info(con, row[0]) if row else None


def cmd_target(con, a):
    for source, fn in (("db", from_db), ("log", from_log), ("viewed", from_viewed)):
        try:
            info = fn(con, a.since_ms)
        except Exception as exc:  # a broken source must not hide the next one
            print(json.dumps({"warn": source + ": " + str(exc)}), file=sys.stderr)
            info = None
        if info and info.get("directory"):
            info["source"] = source
            return info
    return {"session": None, "source": "unknown"}


def last_free_limit_ms(con, sid, since_ms):
    row = con.execute(
        "select max(m.time_created) from session_message m where m.session_id=? and m.type='idle' "
        "and m.time_created>=? and " + free_limit_clause(),
        (sid, since_ms, *FREE_LIMIT_LIKE),
    ).fetchone()
    return row[0] if row and row[0] else since_ms


def cmd_check(con, a):
    ref = last_free_limit_ms(con, a.session, a.since_ms)
    needle = "%" + a.text[:60].replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    # openinfinite-code: the hidden resume is a synthetic message; until the turn runs it waits
    # in session_inbox (payload), afterwards it is a session_message of type synthetic.
    row = con.execute(
        "select count(*), max(time_created) from session_message where session_id=? and type in ('user', 'synthetic') "
        "and time_created>? and data like ? escape '\\'",
        (a.session, ref, needle),
    ).fetchone()
    count, sent = row[0], row[1]
    try:
        inbox = con.execute(
            "select count(*), max(time_created) from session_inbox where session_id=? and type in ('user', 'synthetic') "
            "and time_created>? and payload like ? escape '\\'",
            (a.session, ref, needle),
        ).fetchone()
        if inbox and inbox[0]:
            count += inbox[0]
            sent = max(sent or 0, inbox[1] or 0)
    except sqlite3.Error:
        pass  # older OpenCode without session_inbox
    return {"session": a.session, "after_ms": ref, "already_sent": bool(count), "sent_ms": sent}


def cmd_status(con, a):
    out = {"session": a.session, "since_ms": a.since_ms, "first_token_ms": None, "limit_ms": None}
    for t, kind, data in con.execute(
        "select time_created, type, data from session_message where session_id=? and time_created>=? "
        "and type in ('assistant','idle') order by time_created",
        (a.session, a.since_ms),
    ):
        try:
            d = json.loads(data)
        except ValueError:
            continue
        if kind == "assistant" and out["first_token_ms"] is None:
            out["first_token_ms"] = (d.get("time") or {}).get("firstToken")
        if kind == "idle" and d.get("outcome") == "failed" and any(k.strip("%") in data for k in FREE_LIMIT_LIKE):
            out["limit_ms"] = t
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("command", choices=["target", "check", "status"])
    p.add_argument("--since-ms", type=int, required=True)
    p.add_argument("--session")
    p.add_argument("--text", default="")
    a = p.parse_args()
    try:
        con = connect()
        result = {"target": cmd_target, "check": cmd_check, "status": cmd_status}[a.command](con, a)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
