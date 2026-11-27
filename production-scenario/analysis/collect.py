#!/usr/bin/env python3
"""Turn production-scenario runs into tables.

Reads results/<run>/ (written by scripts/scenario.sh) and writes
  results/runs.csv            one row per run
  results/series/<run>.csv    per second, aligned on the fault: the drill writer's acked
                              writes, and supafirehose or Auth successes and errors
  results/errors/<run>.txt    every distinct client-side error message with its count

Standard library only. Usage: python3 analysis/collect.py [results-dir]
"""
import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
RUN_DIR = re.compile(r"^(storm|auth)-([a-z-]+?)-(c\d+|r\d+)-(\d+)$")
GAP = 1.0  # seconds without an acknowledged write (or a successful request) that count as an outage
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z) (.*)$")


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def timeline(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            m = STAMP.match(line.strip())
            if m:
                out.append((ts(m.group(1)), m.group(2)))
    return out


def gaps(times, start, gap=GAP):
    """Gaps of at least `gap` seconds between consecutive successes from `start` on."""
    t = sorted(x for x in times if x >= start)
    return [(a, b, b - a) for a, b in zip(t, t[1:]) if b - a >= gap]


def sec(t, fault_t):
    return int(t - fault_t) if t >= fault_t else int(t - fault_t) - 1


def shard_healthy_after(path, fault_t):
    samples = []
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"^(\S+) shard=(\S*) ", line.strip())
            if m:
                samples.append((ts(m.group(1)), m.group(2)))
    after = [s for s in samples if s[0] >= fault_t]
    bad = next((s for s in after if s[1] != "Healthy"), None)
    if not bad:
        return 0.0
    back = next((s for s in after if s[0] > bad[0] and s[1] == "Healthy"), None)
    return round(back[0] - fault_t, 1) if back else ""


def normalise(msg):
    """Group error messages that differ only in addresses, ports or ids."""
    msg = re.sub(r"\[?[0-9a-f:.]+\]?:\d+", "<addr>", msg)
    msg = re.sub(r"\b\d{4,}\b", "<n>", msg)
    return msg.strip()


DETECTIONS = ("LeaderUnhealthy", "LeaderUnreachableByCohort", "LeaderQuorumWritesStalled")


def iso(s):
    return datetime.strptime(s[:26].rstrip("Z") + "Z" if len(s) >= 26 else s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def gateway_and_orch(d, fault_t):
    """What the gateways' failover buffer did and which multiorch detection fired first, from the logs."""
    out = {"buffer_start_s": "", "buffer_stop_s": "", "buffer_stop_reason": "", "buffer_drained": 0,
           "buffer_timeouts_logged": 0, "credential_lookup_failed": 0, "detection": "", "detection_s": ""}
    logs = os.path.join(d, "logs")
    if not os.path.isdir(logs):
        return out
    starts, stops, reasons = [], [], set()
    first = None
    for f in sorted(os.listdir(logs)):
        path = os.path.join(logs, f)
        if "multigateway" in f and not f.endswith(".previous.log"):
            for line in open(path, errors="replace"):
                if "buffer" not in line and "credential" not in line and "MTB02" not in line:
                    continue
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                t, msg = iso(j["time"]), j.get("msg", "")
                if t < fault_t - 5:
                    continue
                if msg.startswith("failover detected, starting buffering"):
                    starts.append(t)
                elif msg.startswith("stopping buffering"):
                    stops.append(t)
                    reasons.add(j.get("reason", ""))
                elif msg == "draining entries":
                    out["buffer_drained"] += int(j.get("count", 0))
                elif msg == "credential lookup failed":
                    out["credential_lookup_failed"] += 1
                if "MTB02" in line:
                    out["buffer_timeouts_logged"] += 1
        elif "multiorch" in f and not f.endswith(".previous.log"):
            for line in open(path, errors="replace"):
                k = next((k for k in DETECTIONS if k in line), None)
                if not k:
                    continue
                try:
                    t = iso(json.loads(line)["time"])
                except (ValueError, KeyError):
                    continue
                if t >= fault_t and (first is None or t < first[0]):
                    first = (t, k)
    if starts:
        out["buffer_start_s"] = round(min(starts) - fault_t, 1)
    if stops:
        out["buffer_stop_s"] = round(max(stops) - fault_t, 1)
        out["buffer_stop_reason"] = "/".join(sorted(reasons))
    if first:
        out["detection"], out["detection_s"] = first[1], round(first[0] - fault_t, 1)
    return out


def resources(path, fault_t):
    """Peak memory (MiB) and peak CPU (cores, between samples) per pod kind."""
    per_pod = defaultdict(list)
    if os.path.exists(path):
        for line in open(path):
            p = line.split()
            if len(p) == 4:
                per_pod[p[1]].append((float(p[0]), int(p[2]), int(p[3])))
    out = {}
    for pod, s in per_pod.items():
        kind = "gateway" if "multigateway" in pod else ("auth" if pod.startswith("auth-") else "loadgen")
        mem = max(x[1] for x in s) / 2**20
        cpu = 0.0
        for (t0, _, u0), (t1, _, u1) in zip(s, s[1:]):
            if t1 > t0 and u1 >= u0:
                cpu = max(cpu, (u1 - u0) / 1e6 / (t1 - t0))
        k = out.setdefault(kind, {"mem_mib": 0.0, "cpu_cores": 0.0})
        k["mem_mib"] = max(k["mem_mib"], mem)
        k["cpu_cores"] = max(k["cpu_cores"], cpu)
    return out


def main():
    rows = []
    for sub in ("series", "errors"):
        os.makedirs(os.path.join(RESULTS, sub), exist_ok=True)
    for name in sorted(os.listdir(RESULTS)):
        m = RUN_DIR.match(name)
        d = os.path.join(RESULTS, name)
        load = os.path.join(d, "load", "metrics.jsonl" if m and m.group(1) == "storm" else "auth.jsonl")
        if not m or not os.path.exists(os.path.join(d, "verify.json")) or not os.path.exists(load):
            continue  # not a run, or still running
        scenario, drill, level = m.group(1), m.group(2), m.group(3)
        v = json.load(open(os.path.join(d, "verify.json")))
        tl = timeline(os.path.join(d, "timeline.txt"))
        fault_t = next((t for t, text in tl if text.startswith("fault:")), None)
        series = defaultdict(Counter)
        errors = Counter()

        # The drill writer (ackcheck): acknowledged writes and the outage it saw.
        acks = []
        for line in open(os.path.join(d, "ackcheck", name + ".events.jsonl")):
            e = json.loads(line)
            t = e["t"] / 1e6
            if fault_t is None:
                fault_t = t  # a no-fault baseline: align on the first write
            if e["r"] == "ok":
                acks.append(t)
                series[sec(t, fault_t)]["writer_ok"] += 1
            else:
                series[sec(t, fault_t)]["writer_err"] += 1
        w_out = gaps(acks, fault_t - 1)
        row = {
            "run": name, "scenario": scenario, "drill": drill, "level": level,
            "writer_acked": v["acked"], "writer_lost_acked": v["lost_acked"],
            "writer_ambiguous": v["ambiguous"], "writer_ambiguous_present": v.get("ambiguous_present", 0),
            "writer_failed_present": v.get("failed_present", 0),
            "writer_longest_outage_s": round(max((o[2] for o in w_out), default=0.0), 1),
            "writer_back_after_fault_s": round(max(o[1] for o in w_out) - fault_t, 1) if w_out else 0.0,
            "shard_healthy_after_fault_s": shard_healthy_after(os.path.join(d, "shard-timeline.txt"), fault_t),
        }

        if scenario == "storm":
            snaps = [json.loads(l) for l in open(os.path.join(d, "load", "metrics.jsonl"))]
            target = int(level[1:])
            pre = [s["msg"] for s in snaps if fault_t - 30 <= s["recv_ms"] / 1e3 < fault_t]
            base_qps = sum(s["reads"]["qps"] + s["writes"]["qps"] for s in pre) / max(len(pre), 1)
            ok_times, min_conns, conn_floor_t = [], target, None
            per_sec_q, per_sec_e, per_sec_c = Counter(), Counter(), {}
            for s in snaps:
                t, msg = s["recv_ms"] / 1e3, s["msg"]
                q = msg["reads"]["qps"] + msg["writes"]["qps"]
                e = msg["reads"]["errors"] + msg["writes"]["errors"]
                c = msg["pool"]["active_connections"]
                k = sec(t, fault_t)
                per_sec_q[k] += q / 10  # 100 ms windows: qps/10 queries in each
                per_sec_e[k] += e
                per_sec_c[k] = min(per_sec_c.get(k, c), c)
                if q > 0 and e == 0:
                    ok_times.append(t)
                if fault_t <= t <= fault_t + 60 and c < min_conns:
                    min_conns, conn_floor_t = c, t
            # Back to full throughput: from the fault until 3 s in a row at >= 95% of the pre-fault rate.
            back = ""
            secs_after = sorted(k for k in per_sec_q if k >= 0)
            for k in secs_after:
                if all(per_sec_q.get(k + j, 0) >= 0.95 * base_qps for j in range(3)) and per_sec_e.get(k, 0) == 0 \
                        and any(per_sec_e.get(x, 0) or per_sec_q.get(x, 0) < 0.95 * base_qps for x in range(0, k)):
                    back = k
                    break
            # Connections: lowest count after the fault and when all were open again.
            reopen = ""
            if conn_floor_t:
                reopen = next((round(s["recv_ms"] / 1e3 - fault_t, 1) for s in snaps
                               if s["recv_ms"] / 1e3 > conn_floor_t and s["msg"]["pool"]["active_connections"] >= target), "")
            fh_out = gaps(ok_times, fault_t - 1, 0.5)
            total_e = snaps[-1]["msg"]["totals"]["errors"] if snaps else 0
            for line in open(os.path.join(d, "load", "supafirehose.log")):
                mm = re.search(r"Connection failed \(total failures: \d+\): (.*)$", line)
                if mm:
                    errors["connect (1 in 100 logged): " + normalise(mm.group(1))] += 1
            seen = set()
            for s in snaps:
                for er in s["msg"].get("recent_errors") or []:
                    key = (er["timestamp"], er["message"])
                    if key not in seen:
                        seen.add(key)
                        errors["sampled error (supafirehose keeps 1 per 10 s): " + normalise(er["message"])] += 1
            for k in per_sec_q:
                series[k]["fh_queries"] = round(per_sec_q[k])
                series[k]["fh_errors"] = per_sec_e[k]
                series[k]["fh_connections"] = per_sec_c[k]
            row.update({
                "fh_connections": target, "fh_base_qps": round(base_qps),
                "fh_errors_total": total_e,
                "fh_longest_no_success_s": round(max((o[2] for o in fh_out), default=0.0), 1),
                "fh_full_rate_after_fault_s": back,
                "fh_min_connections_after_fault": min_conns,
                "fh_all_connections_open_after_fault_s": reopen,
            })
        else:
            evs = [json.loads(l) for l in open(os.path.join(d, "load", "auth.jsonl"))]
            ok_times = []
            after = Counter()
            for e in evs:
                t = e["t"] / 1e6
                k = sec(t, fault_t)
                good = e["st"] == 200 or (e["op"] == "wrong" and e.get("code") == "invalid_credentials")
                series[k]["auth_ok" if good else "auth_err"] += 1
                if not good:
                    series[k]["auth_err_5xx" if e["st"] >= 500 else ("auth_err_no_response" if e["st"] == 0 else "auth_err_other")] += 1
                if e["op"] == "login" and e.get("code") == "invalid_credentials":
                    series[k]["auth_valid_login_rejected"] += 1
                if good and e["op"] != "wrong":
                    ok_times.append(t)
                if not good or (e["op"] == "login" and e.get("code") == "invalid_credentials"):
                    errors[f'{e["op"]} -> {e["st"]} {e.get("code", "")}: {normalise(e.get("msg", ""))}'] += 1
                if t >= fault_t:
                    after[(e["op"], e["st"], e.get("code", ""))] += 1
            a_out = gaps(ok_times, fault_t - 1)
            lat = sorted(e["lat"] / 1e3 for e in evs if e["st"] == 200 and e["op"] == "login")
            row.update({
                "auth_requests": len(evs),
                "auth_errors": sum(n for (op, st, code), n in after.items() if not (st == 200 or (op == "wrong" and code == "invalid_credentials"))),
                "auth_5xx": sum(n for (op, st, code), n in after.items() if st >= 500),
                "auth_no_response": sum(n for (op, st, code), n in after.items() if st == 0),
                "auth_valid_login_told_invalid_credentials": sum(n for (op, st, code), n in after.items() if op == "login" and code == "invalid_credentials"),
                "auth_wrong_password_answered_correctly": sum(n for (op, st, code), n in after.items() if op == "wrong" and code == "invalid_credentials"),
                "auth_longest_no_success_s": round(max((o[2] for o in a_out), default=0.0), 1),
                "auth_back_after_fault_s": round(max(o[1] for o in a_out) - fault_t, 1) if a_out else 0.0,
                "auth_login_p50_ms": round(lat[len(lat) // 2]) if lat else "",
                "auth_login_p99_ms": round(lat[int(len(lat) * 0.99)]) if lat else "",
            })

        if drill != "none":
            row.update(gateway_and_orch(d, fault_t))
        else:
            row["fh_full_rate_after_fault_s"] = ""
        for kind, r in resources(os.path.join(d, "resources.txt"), fault_t).items():
            row[f"{kind}_peak_mem_mib"] = round(r["mem_mib"])
            row[f"{kind}_peak_cpu_cores"] = round(r["cpu_cores"], 2)
        ga = os.path.join(d, "gateways-after.txt")
        row["gateway_restarts_total"] = sum(int(x) for x in re.findall(r"restarts=(\d+)", open(ga).read())) if os.path.exists(ga) else ""
        rows.append(row)

        cols = sorted({c for s in series.values() for c in s})
        with open(os.path.join(RESULTS, "series", name + ".csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["second_from_fault"] + cols)
            for k in range(min(series), max(series) + 1):
                w.writerow([k] + [series[k].get(c, 0) for c in cols])
        with open(os.path.join(RESULTS, "errors", name + ".txt"), "w") as f:
            for msg, n in errors.most_common():
                f.write(f"{n:6d}  {msg}\n")

    if not rows:
        print("no runs found", file=sys.stderr)
        return 1
    fields = []
    for r in rows:
        fields += [k for k in r if k not in fields]
    with open(os.path.join(RESULTS, "runs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} runs -> {os.path.join(RESULTS, 'runs.csv')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
