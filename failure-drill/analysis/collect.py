#!/usr/bin/env python3
"""Turn raw drill runs into tables.

Reads results/<drill>-<run>/ (written by scripts/drill.sh) and writes:
  results/runs.csv          one row per run
  results/series/<run>.csv  successful and failed writes per second, aligned on the fault

Standard library only. Usage: python3 analysis/collect.py [results-dir]
"""
import csv
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
RUN_DIR = re.compile(r"^(pod-kill|node-drain|node-terminate|az-down|nodegroup-upgrade)-(\d+)$")
GAP = 1.0  # seconds without an acknowledged write that count as an outage
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z) (.*)$")


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def read_kv(path):
    out = {}
    with open(path) as f:
        for line in f:
            for part in line.split():
                if "=" in part:
                    k, v = part.split("=", 1)
                    out.setdefault(k, v)
    return out


def timeline(path):
    """Lines like '2026-11-26T13:06:53.912Z fault: ...' -> list of (epoch, text)."""
    out = []
    with open(path) as f:
        for line in f:
            m = STAMP.match(line.strip())
            if m:
                out.append((ts(m.group(1)), m.group(2)))
    return out


def shard_unhealthy(path, fault_t):
    """(seconds not Healthy, seconds from the fault until Healthy again).

    The observer samples every few seconds, so this has that resolution."""
    samples = []
    with open(path) as f:
        for line in f:
            m = re.match(r"^(\S+) shard=(\S*) pools_ready=\[(.*)\]", line.strip())
            if m:
                samples.append((ts(m.group(1)), m.group(2), m.group(3)))
    after = [s for s in samples if s[0] >= fault_t]
    first_bad = next((s for s in after if s[1] != "Healthy"), None)
    if not first_bad:
        return 0.0, 0.0
    back = next((s for s in after if s[0] > first_bad[0] and s[1] == "Healthy"), None)
    if not back:
        return None, None
    return round(back[0] - first_bad[0], 1), round(back[0] - fault_t, 1)


def main():
    rows = []
    os.makedirs(os.path.join(RESULTS, "series"), exist_ok=True)
    for name in sorted(os.listdir(RESULTS)):
        m = RUN_DIR.match(name)
        d = os.path.join(RESULTS, name)
        if not m or not os.path.exists(os.path.join(d, "verify.json")):
            continue
        drill, run = m.group(1), int(m.group(2))
        meta = read_kv(os.path.join(d, "run.txt"))
        with open(os.path.join(d, "verify.json")) as f:
            v = json.load(f)
        tl = timeline(os.path.join(d, "timeline.txt"))
        fault_t = next(t for t, text in tl if text.startswith("fault:"))
        zone_empty_t = next((t for t, text in tl if "has 0 nodes" in text), None)
        restore_t = next((t for t, text in tl if text.startswith("restore:")), None)

        events_path = os.path.join(d, "ackcheck", name + ".events.jsonl")
        per_sec_ok, per_sec_bad = Counter(), Counter()
        ack_times = []
        first_bad_after, last_bad_after = None, None
        with open(events_path) as f:
            for line in f:
                e = json.loads(line)
                t = e["t"] / 1e6
                sec = int(t - fault_t) if t >= fault_t else int(t - fault_t) - 1
                if e["r"] == "ok":
                    per_sec_ok[sec] += 1
                    ack_times.append(t)
                else:
                    per_sec_bad[sec] += 1
                    if t >= fault_t:
                        first_bad_after = t if first_bad_after is None else min(first_bad_after, t)
                        last_bad_after = t if last_bad_after is None else max(last_bad_after, t)

        # Outages: gaps of at least GAP seconds between consecutive acknowledged writes (any writer),
        # starting from one second before the fault. Measured from the raw events rather than
        # verify.json's "outages", which reported none for runs with ~2 s gaps.
        acks = sorted(ack_times)
        after = [t for t in acks if t >= fault_t - 1]
        outs = [(a, b, b - a) for a, b in zip(after, after[1:]) if b - a >= GAP]
        total_out = round(sum(o[2] for o in outs), 1)
        longest = round(max((o[2] for o in outs), default=0.0), 1)
        writes_back = round(max(o[1] for o in outs) - fault_t, 1) if outs else 0.0
        max_gap = round(max((b - a for a, b in zip(after, after[1:])), default=0.0), 2)

        unhealthy_s, healthy_back = shard_unhealthy(os.path.join(d, "shard-timeline.txt"), fault_t)
        primary_after = ""
        pa = os.path.join(d, "primary-after.txt")
        if os.path.exists(pa):
            for line in open(pa):
                p = line.split()
                if len(p) == 4 and p[3] == "primary":
                    primary_after = p[0]

        lat = v.get("ok_latency_ms") or {}
        rows.append({
            "drill": drill,
            "run": run,
            "target_zone": meta.get("target_zone", ""),
            "writer_zone": meta.get("writer_zone", ""),
            "primary_before_zone": meta.get("zone", ""),
            "primary_after_zone": primary_after,
            "acked": v["acked"],
            "failed": v["failed"],
            "ambiguous": v["ambiguous"],
            "lost_acked": v["lost_acked"],
            "outages": len(outs),
            "longest_outage_s": longest,
            "max_ack_gap_s": max_gap,
            "total_outage_s": total_out,
            "writes_back_after_fault_s": writes_back,
            "zone_empty_after_fault_s": round(zone_empty_t - fault_t, 1) if zone_empty_t else "",
            "zone_restore_after_fault_s": round(restore_t - fault_t, 1) if restore_t else "",
            "shard_not_healthy_s": "" if unhealthy_s is None else unhealthy_s,
            "shard_healthy_after_fault_s": "" if healthy_back is None else healthy_back,
            "errors": ";".join(f"{k}={n}" for k, n in sorted((v.get("error_kinds") or {}).items())),
            "p50_ms": lat.get("p50", ""),
            "p99_ms": lat.get("p99", ""),
            "max_ms": lat.get("p100", ""),
        })
        with open(os.path.join(RESULTS, "series", name + ".csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["second_from_fault", "ok", "failed_or_ambiguous"])
            for s in range(min(per_sec_ok) if per_sec_ok else 0, (max(per_sec_ok) if per_sec_ok else 0) + 1):
                w.writerow([s, per_sec_ok.get(s, 0), per_sec_bad.get(s, 0)])

    if not rows:
        print("no runs found", file=sys.stderr)
        return 1
    with open(os.path.join(RESULTS, "runs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} runs -> {os.path.join(RESULTS, 'runs.csv')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
