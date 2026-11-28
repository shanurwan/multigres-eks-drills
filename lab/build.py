#!/usr/bin/env python3
"""Bundle recorded day-2 runs into lab/data/runs.json for the replay page.

  python3 lab/build.py                                  # this repo's runs
  python3 lab/build.py path/to/results -o my-runs.json  # your own runs, to load on the page

Reads only the files a run already has (timeline.txt, shard-timeline.txt, verify.json,
primary-before/after.txt, the observers' files) plus runs.csv and day2.csv from
../production-scenario/analysis/collect.py and day2-operations/analysis/day2.py.
Standard library only.
"""
import argparse
import csv
import json
import os
import re
from collections import Counter
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z) (.*)$")
ZONES = ["apse2-az1", "apse2-az2", "apse2-az3"]
BASELINE = 45          # seconds shown before the operation starts


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def read(path, default=""):
    return open(path).read() if os.path.exists(path) else default


def lines_with_time(path):
    out = []
    for line in read(path).splitlines():
        m = STAMP.match(line.strip())
        if m:
            out.append((ts(m.group(1)), m.group(2)))
    return out


def roles(path):
    """zone -> role, from primary.sh output."""
    out = {}
    for line in read(path).splitlines():
        f = line.split()
        if len(f) == 4 and f[0].startswith("apse2-"):
            out[f[0]] = f[3]
    return out


def table(results, name):
    p = os.path.join(results, name)
    return {r["run"]: r for r in csv.DictReader(open(p))} if os.path.exists(p) else {}


def num(v, digits=1):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return round(x, digits) if digits else int(round(x))


def build_run(results, name, row, extra):
    d = os.path.join(results, name)
    m = re.match(r"^storm-([a-z-]+?)-c\d+(?:-([a-z0-9]+))?-(\d+)$", name)
    drill, tag, n = m.group(1), m.group(2) or "", int(m.group(3))
    tl = lines_with_time(os.path.join(d, "timeline.txt"))
    fault = next(t for t, x in tl if x.startswith("fault:"))
    writer_start = next((t for t, x in tl if x.startswith("writer start")), fault - 60)

    # Per-second series, from the operation start minus BASELINE to the end.
    rows = list(csv.DictReader(open(os.path.join(results, "series", name + ".csv"))))
    t0 = max(int(writer_start - fault) + 2, -BASELINE)
    rows = [r for r in rows if int(r["second_from_fault"]) >= t0]
    end = int(rows[-1]["second_from_fault"]) if rows else 0
    series = {"t0": t0, "ok": [], "werr": [], "ferr": [], "conns": []}
    by = {int(r["second_from_fault"]): r for r in rows}
    for s in range(t0, end + 1):
        r = by.get(s, {})
        series["ok"].append(int(float(r.get("writer_ok", 0) or 0)))
        series["werr"].append(int(float(r.get("writer_err", 0) or 0)))
        series["ferr"].append(int(float(r.get("fh_errors", 0) or 0)))
        series["conns"].append(int(float(r.get("fh_connections", 0) or 0)))

    before, after = roles(os.path.join(d, "primary-before.txt")), roles(os.path.join(d, "primary-after.txt"))
    p_before = next((z for z, r in before.items() if r == "primary"), ZONES[0])
    p_after = next((z for z, r in after.items() if r == "primary"), p_before)
    back = num(row.get("writer_back_after_fault_s"))
    run = {
        "id": name, "drill": drill, "n": n, "tag": tag,
        "started": datetime.fromtimestamp(fault, timezone.utc).isoformat().replace("+00:00", "Z"),
        "baseline_s": -t0, "observe_s": end,
        "zones": ZONES, "primary_before": p_before, "primary_after": p_after,
        # When writes came back is when clients could reach the new primary; the record
        # has no finer clock for the role change itself.
        "switch_s": back if p_after != p_before and back is not None else None,
        "writer_zone": (re.search(r"writer_zone=(\S+)", read(os.path.join(d, "run.txt"))) or [None, None])[1],
        "series": series,
    }

    # Shard phase and pool readiness, kept only where something changes.
    shard, last = [], None
    for t, text in lines_with_time(os.path.join(d, "shard-timeline.txt")):
        mm = re.match(r"shard=(\S*) pools_ready=\[(.*)\]", text)
        if not mm or t < fault + t0:
            continue
        ready = [x.split("/")[0] == x.split("/")[1] for x in mm.group(2).split() if "/" in x]
        cur = (mm.group(1), ready)
        if cur != last:
            shard.append([round(t - fault, 1), mm.group(1), ready])
            last = cur
    run["shard"] = shard

    # Events: the run's own timeline, as seconds from the operation start.
    run["events"] = [{"t": round(t - fault, 1), "text": x} for t, x in tl if not x.startswith(("waiting", "done"))]

    if drill == "az-partition":
        heal = next((t for t, x in tl if x.startswith("heal:")), None)
        cut = fault + float(extra.get("cut_after_fault_line_s") or 0)
        target = (re.search(r"target_zone=(\S+)", read(os.path.join(d, "run.txt"))) or [None, p_before])[1]
        run["cut"] = {"zone": target, "from_s": round(cut - fault, 1), "heal_s": round(heal - fault, 1) if heal else end}
        ok, err = Counter(), Counter()
        p = os.path.join(d, "ackcheck-iso", name + "-iso.events.jsonl")
        for line in open(p) if os.path.exists(p) else []:
            e = json.loads(line)
            s = int(e["t"] / 1e6 - fault) if e["t"] / 1e6 >= fault else int(e["t"] / 1e6 - fault) - 1
            (ok if e["r"] == "ok" else err)[s] += 1
        run["iso"] = {"ok": [ok.get(s, 0) for s in range(t0, end + 1)], "err": [err.get(s, 0) for s in range(t0, end + 1)]}

    if drill == "disk-full":
        disk, at = [], None
        for line in read(os.path.join(d, "disk-observe.txt")).splitlines():
            mm = re.match(r"^== (\S+) (\S+)", line)
            if mm:
                at = ts(mm.group(1))
                continue
            f = line.split()
            if at and len(f) == 6 and f[5] == "/var/lib/pooler":
                size, used, avail = int(f[1]), int(f[2]), int(f[3])
                disk.append([round(at - fault, 1), size, used, avail])
                at = None
        run["disk"] = disk
        fill = next((x for t, x in tl if x.startswith("fault:")), "")
        run["fill_leave_mb"] = int((re.search(r"leaving (\d+) MiB", fill) or [0, 0])[1])

    if drill == "mg-upgrade":
        rolled = []
        for t, text in lines_with_time(os.path.join(d, "rollout.txt")):
            mm = re.match(r"pods_on_old_image=(\d+)", text)
            if mm:
                rolled.append([round(t - fault, 1), int(mm.group(1))])
        run["rollout"] = rolled

    if drill == "ng-upgrade":
        steps = []
        for t, text in lines_with_time(os.path.join(d, "ng-update.txt")):
            steps.append([round(t - fault, 1), text.split()[0]])
        run["ng_update"] = steps

    v = json.loads(read(os.path.join(d, "verify.json"), "{}") or "{}")
    run["verify"] = {k: v.get(k) for k in ("attempts", "acked", "failed", "ambiguous", "lost_acked")}
    if os.path.exists(os.path.join(d, "verify-iso.json")):
        vi = json.loads(read(os.path.join(d, "verify-iso.json")))
        run["verify_iso"] = {k: vi.get(k) for k in ("attempts", "acked", "lost_acked")}
    run["facts"] = {
        "writer_longest_outage_s": num(row.get("writer_longest_outage_s")),
        "fh_errors_total": num(row.get("fh_errors_total"), 0),
        "fh_min_connections": num(row.get("fh_min_connections_after_fault"), 0),
        "fh_connections": num(row.get("fh_connections"), 0),
        "buffer_drained": num(row.get("buffer_drained"), 0),
        "credential_lookup_failed": num(row.get("credential_lookup_failed"), 0),
        "detection": row.get("detection") or "",
        "detection_s": num(row.get("detection_s")),
        "shard_not_healthy_s": num(extra.get("shard_not_healthy_s")),
        "iso_acked_after_cut": num(extra.get("iso_acked_1s_after_cut_or_later"), 0),
        "iso_errors": num(extra.get("iso_errors_during_partition"), 0),
        "iso_back_after_heal_s": num(extra.get("iso_first_ack_after_heal_s")),
        "ng_update_s": num(extra.get("ng_update_s")),
        "rollout_s": num(extra.get("rollout_s")),
        "grow_took_s": num(extra.get("grow_took_s")),
    }

    # What the terminal prints: the command, the run's timeline as it happened, then the check.
    out = [f"$ scripts/day2.sh {drill} {n}"]
    for e in run["events"]:
        out.append(f"  {'+' if e['t'] >= 0 else '-'}{abs(e['t']):.1f}s  {e['text']}")
    vv = run["verify"]
    out.append(f"  verify: {vv['attempts']:,} writes, {vv['acked']:,} acknowledged, {vv['lost_acked']} acknowledged writes lost")
    if "verify_iso" in run:
        vi = run["verify_iso"]
        out.append(f"  verify (writer inside the cut-off zone): {vi['attempts']:,} writes, {vi['acked']:,} acknowledged, {vi['lost_acked']} lost")
    run["output"] = "\n".join(out)
    return run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="?", default=os.path.join(HERE, "..", "day2-operations", "results"))
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "data", "runs.json"))
    a = ap.parse_args()
    runs_csv, day2_csv = table(a.results, "runs.csv"), table(a.results, "day2.csv")
    runs = []
    for name in sorted(os.listdir(a.results)):
        if name in runs_csv and os.path.exists(os.path.join(a.results, name, "timeline.txt")):
            runs.append(build_run(a.results, name, runs_csv[name], day2_csv.get(name, {})))
    first = os.path.join(a.results, "storm-switchover-c500-1")
    bundle = {
        "source": "https://github.com/shanurwan/multigres-eks-drills/tree/main/day2-operations",
        "pods": read(os.path.join(first, "pods-before.txt")).rstrip(),
        "primary": read(os.path.join(first, "primary-before.txt")).strip(),
        "runs": runs,
    }
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(bundle, f, separators=(",", ":"))
    print(f"{len(runs)} runs -> {a.out} ({os.path.getsize(a.out) // 1024} KiB)")


if __name__ == "__main__":
    main()
