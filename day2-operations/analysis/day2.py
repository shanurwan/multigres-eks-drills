#!/usr/bin/env python3
"""Day-2 measures that ../production-scenario/analysis/collect.py doesn't cover.

Run collect.py on this results/ first (it writes runs.csv, series/ and errors/), then this.
Writes results/day2.csv, one row per run:

  every run        fault and end times, how long the shard was not Healthy, which pooler was
                   primary before and after
  az-partition     the isolated-zone writer: writes acknowledged after the cut took effect,
                   writes acknowledged with a synchronous-replication warning, the errors it got,
                   and how long after the heal it could write again
  ng-upgrade       the node group update's result and duration, how long the pooler pod on the
                   replaced node took to run again
  disk-full        what the full primary did (from disk-observe.txt), when the volume grew
  mg-upgrade       how long the rollout took

Standard library only. Usage: python3 analysis/day2.py [results-dir]
"""
import csv
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z) (.*)$")


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def timeline(d):
    out = []
    p = os.path.join(d, "timeline.txt")
    if os.path.exists(p):
        for line in open(p):
            m = STAMP.match(line.strip())
            if m:
                out.append((ts(m.group(1)), m.group(2)))
    return out


def first(tl, prefix):
    return next((t for t, text in tl if text.startswith(prefix)), None)


def not_healthy_spans(d, start):
    """Spans (from, to) after `start` where the shard's phase was not Healthy."""
    spans, cur = [], None
    p = os.path.join(d, "shard-timeline.txt")
    if not os.path.exists(p):
        return spans
    for line in open(p):
        m = re.match(r"^(\S+) shard=(\S*) ", line.strip())
        if not m:
            continue
        t, phase = ts(m.group(1)), m.group(2)
        if t < start:
            continue
        if phase != "Healthy" and cur is None:
            cur = t
        elif phase == "Healthy" and cur is not None:
            spans.append((cur, t))
            cur = None
    if cur is not None:
        spans.append((cur, None))
    return spans


def role(d, name):
    p = os.path.join(d, name)
    if os.path.exists(p):
        for line in open(p):
            f = line.split()
            if len(f) == 4 and f[3] == "primary":
                return f[0]
    return ""


def events(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            e = json.loads(line)
            out.append((e["t"] / 1e6, e["r"], e.get("e", "")))
    return out


def norm(msg):
    msg = re.sub(r"\[?[0-9a-f:.]+\]?:\d+", "<addr>", msg)
    return re.sub(r"\b\d{4,}\b", "<n>", msg).strip()[:90]


def main():
    rows = []
    for name in sorted(os.listdir(RESULTS)):
        d = os.path.join(RESULTS, name)
        m = re.match(r"^storm-([a-z-]+?)-c\d+(?:-[a-z0-9]+)?-\d+$", name)
        if not m or not os.path.exists(os.path.join(d, "verify.json")):
            continue
        drill = m.group(1)
        tl = timeline(d)
        fault = first(tl, "fault:")
        if fault is None:
            continue
        spans = not_healthy_spans(d, fault)
        row = {
            "run": name, "drill": drill,
            "primary_before": role(d, "primary-before.txt"), "primary_after": role(d, "primary-after.txt"),
            "shard_not_healthy_s": round(sum((b or fault) - a for a, b in spans if b), 1),
            "shard_not_healthy_spans": len(spans),
            "shard_still_not_healthy_at_end": any(b is None for _, b in spans),
        }

        if drill == "az-partition":
            heal = first(tl, "heal:")
            # The cut takes effect when the ACL association is swapped, logged in fault.txt
            # a few seconds after the "fault:" line (which is when the drill starts creating it).
            cut = fault
            ft = os.path.join(d, "fault.txt")
            if os.path.exists(ft):
                mm = re.search(r"^partitioned .* at (\S+)$", open(ft).read(), re.M)
                if mm:
                    cut = ts(mm.group(1))
            row["cut_after_fault_line_s"] = round(cut - fault, 2)
            row["partition_s"] = round(heal - cut, 1) if heal else ""
            iso = events(os.path.join(d, "ackcheck-iso", name + "-iso.events.jsonl"))
            v = json.load(open(os.path.join(d, "verify-iso.json"))) if os.path.exists(os.path.join(d, "verify-iso.json")) else {}
            during = [e for e in iso if cut <= e[0] <= (heal or cut)]
            after_heal_ok = [e[0] for e in iso if heal and e[0] > heal and e[1] == "ok"]
            row.update({
                "iso_attempts": v.get("attempts", ""), "iso_acked": v.get("acked", ""),
                "iso_lost_acked": v.get("lost_acked", ""),
                "iso_acked_with_syncrep_warning": v.get("acked_with_syncrep_warning", ""),
                "iso_acked_during_partition": sum(1 for e in during if e[1] == "ok"),
                # The ACL swap returns before the rule reaches the instance; acks in the first
                # second are writes already in flight. This column is the one that matters.
                "iso_acked_1s_after_cut_or_later": sum(1 for e in during if e[1] == "ok" and e[0] >= cut + 1),
                "iso_last_ack_after_cut_s": round(max((e[0] for e in during if e[1] == "ok"), default=cut) - cut, 3),
                "iso_errors_during_partition": sum(1 for e in during if e[1] != "ok"),
                "iso_first_ack_after_heal_s": round(after_heal_ok[0] - heal, 1) if after_heal_ok else "",
                "iso_last_ack_before_cut_s": round(max((e[0] for e in iso if e[0] < cut and e[1] == "ok"), default=cut) - cut, 2),
            })
            kinds = Counter(norm(e[2]) for e in during if e[1] != "ok")
            with open(os.path.join(RESULTS, "errors", name + "-iso.txt"), "w") as f:
                for k, n in kinds.most_common():
                    f.write(f"{n:6d}  {k}\n")

        elif drill == "ng-upgrade":
            res = first(tl, "node group update")
            row["ng_update_s"] = round(res - fault, 1) if res else ""
            row["ng_update_result"] = next((text.split(": ")[-1] for t, text in tl if text.startswith("node group update")), "")
            p = os.path.join(d, "fault.txt")
            txt = open(p).read() if os.path.exists(p) else ""
            row["ng_update_errors"] = ";".join(sorted(set(re.findall(r'"errorCode": "([A-Za-z]+)"', txt))))
            # The pooler pod that had to move: not Ready -> Ready again in shard-timeline's pools_ready list.
            down = None
            longest = 0.0
            for line in open(os.path.join(d, "shard-timeline.txt")):
                mm = re.match(r"^(\S+) shard=\S* pools_ready=\[(.*)\]", line.strip())
                if not mm:
                    continue
                t = ts(mm.group(1))
                if t < fault:
                    continue
                all_ready = all(x.split("/")[0] == x.split("/")[1] for x in mm.group(2).split() if "/" in x) and len(mm.group(2).split()) == 3
                if not all_ready and down is None:
                    down = t
                elif all_ready and down is not None:
                    longest = max(longest, t - down)
                    down = None
            row["pooler_longest_not_ready_s"] = round(longest, 1)

        elif drill == "disk-full":
            fix = first(tl, "fix:")
            grown = first(tl, "pvc ")
            row["full_for_s"] = round(fix - fault, 1) if fix else ""
            row["grow_took_s"] = round(grown - fix, 1) if fix and grown else ""
            row["grow_result"] = next((text for t, text in tl if text.startswith("pvc ")), "")

        elif drill == "mg-upgrade":
            done = first(tl, "rollout:")
            row["rollout_s"] = round(done - fault, 1) if done else ""

        rows.append(row)

    if not rows:
        print("no runs", file=sys.stderr)
        return 1
    fields = []
    for r in rows:
        fields += [k for k in r if k not in fields]
    with open(os.path.join(RESULTS, "day2.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} runs -> {os.path.join(RESULTS, 'day2.csv')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
