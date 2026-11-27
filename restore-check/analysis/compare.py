#!/usr/bin/env python3
"""Compare a restored copy with the live cluster and time the restore.

Reads results/<name>/ (written by scripts/restore.sh) and prints a summary; with --json, a
JSON object. Standard library only. Usage: python3 analysis/compare.py results/<name> [--json]
"""
import json
import re
import sys
from datetime import datetime


def parse(path):
    runs, other = {}, {}
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "ackcheck":
            runs[p[1]] = {"count": int(p[2]), "hash": p[3], "upto_count": int(p[4]), "upto_hash": p[5]}
        else:
            other[p[0]] = p[1:]
    return runs, other


def stamp(s):
    return datetime.strptime(s[:23] + "Z", "%Y-%m-%dT%H:%M:%S.%fZ").timestamp()


def main():
    d = sys.argv[1]
    live_runs, live = parse(f"{d}/live.txt")
    rest_runs, rest = parse(f"{d}/restored.txt")
    tl = {}
    for line in open(f"{d}/timeline.txt"):
        m = re.match(r"^(\S+) (.*)$", line.strip())
        if m:
            for key in ("pgbackrest restore start", "pgbackrest restore done", "postgres started", "recovery done", "newest restored write"):
                if m.group(2).startswith(key):
                    tl[key] = stamp(m.group(1))
    pg = open(f"{d}/postgres.log", errors="replace").read() if __import__("os").path.exists(f"{d}/postgres.log") else ""
    segs = re.findall(r'restored log file "([0-9A-F]{24})" from archive', pg)
    timelines = sorted({s[:8] for s in segs})
    # A run that started after the target has no rows up to it, live or restored.
    empty = {"upto_count": 0, "upto_hash": "0"}
    mismatched = [r for r in live_runs if live_runs[r]["upto_count"] != rest_runs.get(r, empty)["upto_count"]
                  or live_runs[r]["upto_hash"] != rest_runs.get(r, empty)["upto_hash"]]
    missing_runs = [r for r in live_runs if live_runs[r]["upto_count"] > 0 and r not in rest_runs]
    archiver = open(f"{d}/live-archiver.txt").read().strip().split("|")
    s = {
        "runs_compared": len(live_runs),
        "rows_expected": sum(v["upto_count"] for v in live_runs.values()),
        "rows_restored": sum(v["upto_count"] for v in rest_runs.values()),
        "runs_mismatched": mismatched,
        "runs_missing": missing_runs,
        "rows_after_target_plus_1s_in_restore": int(rest.get("rows_after_target_plus_1s", ["-1"])[0]),
        "newest_restored_write": " ".join(rest.get("newest_ackcheck_row", [])),
        "newest_live_write": " ".join(live.get("newest_ackcheck_row", [])),
        "supafirehose_users": [live.get("supafirehose_users"), rest.get("supafirehose_users")],
        "auth_users": [live.get("auth_users"), rest.get("auth_users")],
        "auth_sessions_upto_target": [live.get("auth_sessions", ["?"])[0], rest.get("auth_sessions", ["?"])[0]],
        "database_size_mib": round(int(rest.get("database_size_bytes", ["0"])[0]) / 2**20),
        "copy_backup_s": round(tl["pgbackrest restore done"] - tl["pgbackrest restore start"], 1) if len(tl) > 1 else None,
        "replay_and_promote_s": round(tl["recovery done"] - tl["postgres started"], 1) if "recovery done" in tl else None,
        "wal_segments_replayed": len(segs),
        "timelines_crossed": len(timelines),
        "live_archiver": {"checked_at": archiver[0], "current_wal": archiver[1], "last_archived_wal": archiver[3],
                          "last_archived_at": archiver[4], "failed": archiver[5], "archive_timeout": archiver[6]},
    }
    s["verdict"] = "PASS" if not mismatched and not missing_runs and s["rows_after_target_plus_1s_in_restore"] == 0 else "FAIL"
    if "--json" in sys.argv:
        print(json.dumps(s, indent=1))
        return
    for k, v in s.items():
        print(f"{k:40s} {v}")


if __name__ == "__main__":
    main()
