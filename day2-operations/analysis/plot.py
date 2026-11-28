#!/usr/bin/env python3
"""Draw the day-2 charts. Run ../production-scenario/analysis/collect.py results and
analysis/day2.py first; every number here comes from their CSVs or the runs' own records.

  python3 analysis/plot.py [results-dir]      # needs matplotlib

Writes results/charts/:
  partition.png        acknowledged writes per second, outside and inside the cut-off zone
  <run>.png            every other run: acknowledged writes and client errors over the whole
                       operation, with its steps from timeline.txt marked
"""
import csv
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
CHARTS = os.path.join(RESULTS, "charts")

# Same palette as failure-drill/ and production-scenario/.
BLUE, CRITICAL, ORANGE = "#257de0", "#dc3c3d", "#f47230"
INK, INK2, GRID, SHADE = "#191919", "#666666", "#e6e6e6", "#efefef"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10, "axes.edgecolor": INK2,
    "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.titlesize": 11,
    "axes.titlecolor": INK, "axes.titleweight": "bold", "figure.dpi": 150,
})
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z) (.*)$")


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def table(name):
    p = os.path.join(RESULTS, name)
    return {r["run"]: r for r in csv.DictReader(open(p))} if os.path.exists(p) else {}


def series(run):
    rows = list(csv.DictReader(open(os.path.join(RESULTS, "series", run + ".csv"))))
    return [{k: float(v) for k, v in r.items()} for r in rows]


def timeline(run):
    out = []
    for line in open(os.path.join(RESULTS, run, "timeline.txt")):
        m = STAMP.match(line.strip())
        if m:
            out.append((ts(m.group(1)), m.group(2)))
    return out


def not_healthy(run, start):
    """(from, to) spans after `start` where shard-timeline.txt shows a phase other than Healthy."""
    spans, cur = [], None
    for line in open(os.path.join(RESULTS, run, "shard-timeline.txt")):
        m = re.match(r"^(\S+) shard=(\S*) ", line.strip())
        if not m or ts(m.group(1)) < start:
            continue
        t, healthy = ts(m.group(1)), m.group(2) == "Healthy"
        if not healthy and cur is None:
            cur = t
        elif healthy and cur is not None:
            spans.append((cur, t))
            cur = None
    return spans + ([(cur, None)] if cur is not None else [])


def per_second(path, t0):
    c = Counter()
    for line in open(path):
        e = json.loads(line)
        if e["r"] == "ok":
            c[int(e["t"] / 1e6 - t0) if e["t"] / 1e6 >= t0 else int(e["t"] / 1e6 - t0) - 1] += 1
    return c


def style(ax, ylabel):
    ax.grid(axis="y", color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_ylabel(ylabel)


def partition(runs, day2):
    names = [r for r in sorted(day2) if day2[r]["drill"] == "az-partition"]
    if not names:
        return
    fig, axes = plt.subplots(len(names), 1, figsize=(9, 2.9 * len(names)), sharex=True, squeeze=False)
    for ax, run in zip(axes[:, 0], names):
        d, r = day2[run], runs[run]
        tl = timeline(run)
        fault = next(t for t, x in tl if x.startswith("fault:"))
        cut = fault + float(d["cut_after_fault_line_s"])
        heal = next(t for t, x in tl if x.startswith("heal:"))
        main = per_second(os.path.join(RESULTS, run, "ackcheck", run + ".events.jsonl"), cut)
        iso = per_second(os.path.join(RESULTS, run, "ackcheck-iso", run + "-iso.events.jsonl"), cut)
        xs = range(-30, int(heal - cut) + 150)
        ax.axvspan(0, heal - cut, color=SHADE, zorder=0)
        ax.plot(xs, [main.get(x, 0) for x in xs], color=BLUE, lw=1.6, label="writer outside the zone (all gateways)")
        ax.plot(xs, [iso.get(x, 0) for x in xs], color=ORANGE, lw=1.6, label="writer inside the zone (its own gateway)")
        ax.set_ylim(0, 470)
        ax.set_title(f"Run {run[-1:]}: {d['primary_before']} cut off (the primary's zone)", loc="left", fontsize=10)
        ax.text((heal - cut) / 2, 235,
                f"partition, {float(d['partition_s']):.0f} s\ninside: {d['iso_acked_1s_after_cut_or_later']} acked, "
                f"{d['iso_errors_during_partition']} errors\nlost acked writes: {int(r['writer_lost_acked']) + int(d['iso_lost_acked'])}",
                ha="center", va="center", color=INK, fontsize=8.5,
                bbox={"boxstyle": "round,pad=0.4", "fc": "white", "ec": GRID, "alpha": 0.92})
        ax.annotate(f"writes again {float(d['iso_first_ack_after_heal_s']):.0f} s after the heal", xy=(heal - cut + float(d["iso_first_ack_after_heal_s"]), 0),
                    xytext=(heal - cut + 8, 190), color=INK, fontsize=8.5,
                    bbox={"boxstyle": "round,pad=0.3", "fc": "white", "ec": GRID, "alpha": 0.92},
                    arrowprops={"arrowstyle": "->", "color": INK2, "lw": 0.8})
        style(ax, "acked writes / s")
    axes[-1, 0].set_xlabel("seconds from the cut (shaded: the partition)")
    fig.suptitle("A zone cut off from the VPC: the isolated side acknowledged nothing", x=0.01, ha="left", fontweight="bold", color=INK)
    h, l = axes[0, 0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper left", bbox_to_anchor=(0.01, 0.955), frameon=False, fontsize=8.5, ncol=2)
    fig.tight_layout(rect=(0, 0, 1, 0.92))
    fig.savefig(os.path.join(CHARTS, "partition.png"))
    plt.close(fig)


def operation(run, r):
    s = series(run)
    tl = timeline(run)
    fault = next(t for t, x in tl if x.startswith("fault:"))
    start = next(t for t, x in tl if x.startswith("writer start")) - fault
    s = [x for x in s if x["second_from_fault"] >= start]
    xs = [x["second_from_fault"] for x in s]
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(9, 4.6), sharex=True, gridspec_kw={"height_ratios": [3, 2]})
    a1.plot(xs, [x.get("writer_ok", 0) for x in s], color=BLUE, lw=1.2)
    a1.set_ylim(0, 470)
    style(a1, "acked writes / s")
    a2.bar(xs, [x.get("fh_errors", 0) for x in s], width=1.0, color=CRITICAL)
    style(a2, "client errors / s")
    a2.set_xlabel("seconds from the start of the operation (shaded: shard phase not Healthy)")
    end = xs[-1] if xs else 0
    for a, b in not_healthy(run, fault):
        for ax in (a1, a2):
            ax.axvspan(a - fault, (b or fault + end) - fault, color=SHADE, zorder=0, lw=0)
    for t, text in tl:
        x = t - fault
        if x < -5 or text.startswith(("waiting", "writer", "done", "isolated")):
            continue
        for ax in (a1, a2):
            ax.axvline(x, color=INK2, lw=0.8, ls=":")
        label = {"fault": "operation starts", "node group update": "node group update done", "shard Healthy": "shard Healthy",
                 "heal": "heal", "fix": "volume grow requested", "pvc ": "volume grown", "rollout": "rollout done",
                 "switch-primary returned": "switch-primary returned", "fill file removed": "fill removed"}
        name = next((v for k, v in label.items() if text.startswith(k)), None)
        if name is None:
            continue
        a1.text(x + 4, 20, name, rotation=90, va="bottom", fontsize=7.5, color=INK2,
                bbox={"boxstyle": "square,pad=0.1", "fc": "white", "ec": "none", "alpha": 0.85})
    a1.set_title(f"{r['drill']}: {int(r['writer_lost_acked'])} acked writes lost, longest write gap {float(r['writer_longest_outage_s']):.1f} s, "
                 f"{int(float(r['fh_errors_total']))} client errors", loc="left")
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS, run + ".png"))
    plt.close(fig)


NAMES = {"az-partition": "zone cut off", "ng-upgrade": "node group upgrade", "disk-full": "disk full",
         "mg-upgrade": "Multigres upgrade", "switchover": "switchover"}
ORDER = ["az-partition", "ng-upgrade", "disk-full", "mg-upgrade", "switchover"]


def summary(runs):
    """One row per run: longest stretch with no acknowledged write, and client errors (log scale)."""
    rows = sorted(runs.values(), key=lambda r: (ORDER.index(r["drill"]), r["run"]))
    labels = [f"{NAMES[r['drill']]} {r['run'].rsplit('-', 1)[1]}" + (" (new image)" if r.get("tag") else "") for r in rows]
    gap = [float(r["writer_longest_outage_s"]) for r in rows]
    err = [int(float(r["fh_errors_total"])) for r in rows]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(10.5, 4.8), sharey=True)
    y = range(len(rows))
    a1.barh(y, gap, color=BLUE, height=0.62)
    a2.barh(y, [max(e, 0.8) if e else 0 for e in err], color=CRITICAL, height=0.62)
    a2.set_xscale("log")
    a2.set_xlim(0.8, 3e5)
    a1.set_xlim(0, 260)
    for i, (g, e) in enumerate(zip(gap, err)):
        a1.text(g + 3, i, f"{g:.1f} s", va="center", fontsize=8, color=INK)
        a2.text(max(e, 1) * 1.25, i, f"{e:,}", va="center", fontsize=8, color=INK)
    a1.set_yticks(list(y), labels)
    a1.invert_yaxis()
    for ax, t in ((a1, "Longest gap with no acknowledged write"), (a2, "supafirehose client errors (log scale)")):
        ax.grid(axis="x", color=GRID, lw=0.8)
        ax.set_axisbelow(True)
        ax.set_title(t, loc="left", fontsize=10)
    a1.set_xlabel("seconds")
    a2.set_xlabel("errors in the run")
    lost = sum(int(r["writer_lost_acked"]) for r in rows)
    fig.suptitle(f"{len(rows)} day-2 runs under 500 client connections: {lost} acknowledged writes lost",
                 x=0.01, ha="left", fontweight="bold", color=INK)
    fig.subplots_adjust(left=0.2, right=0.97, top=0.85, bottom=0.12, wspace=0.08)
    fig.savefig(os.path.join(CHARTS, "summary.png"))
    plt.close(fig)


def main():
    os.makedirs(CHARTS, exist_ok=True)
    runs, day2 = table("runs.csv"), table("day2.csv")
    summary(runs)
    partition(runs, day2)
    for run, r in runs.items():
        if r["drill"] != "az-partition":
            operation(run, r)
    print("charts ->", CHARTS)


if __name__ == "__main__":
    main()
