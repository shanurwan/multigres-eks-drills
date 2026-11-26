#!/usr/bin/env python3
"""Draw the charts from results/runs.csv and results/series/*.csv.

  python3 analysis/plot.py [results-dir]      # needs matplotlib

Writes results/charts/*.png. Every number in a chart comes from those CSVs.
"""
import csv
import os
import statistics
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
CHARTS = os.path.join(RESULTS, "charts")

# Palette: one categorical hue for writes, the status "critical" step for failures,
# text inks for everything else.
BLUE, CRITICAL = "#257de0", "#dc3c3d"
INK, INK2, GRID, SHADE = "#191919", "#666666", "#e6e6e6", "#efefef"

DRILLS = [
    ("pod-kill", "Primary pod killed"),
    ("node-drain", "Primary's node drained"),
    ("node-terminate", "Primary's EC2 instance terminated"),
    ("az-down", "Zone drained (node group scaled to 0)"),
    ("az-outage", "Zone outage (instance terminated, no drain)"),
    ("nodegroup-upgrade", "Managed node group upgrade"),
]
LABEL = dict(DRILLS)

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10, "axes.edgecolor": INK2,
    "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.titlesize": 11,
    "axes.titlecolor": INK, "axes.titleweight": "bold", "figure.dpi": 150,
})


def read_runs():
    with open(os.path.join(RESULTS, "runs.csv")) as f:
        return list(csv.DictReader(f))


def read_series(name):
    with open(os.path.join(RESULTS, "series", name + ".csv")) as f:
        return [(int(r["second_from_fault"]), int(r["ok"]), int(r["failed_or_ambiguous"])) for r in csv.DictReader(f)]


def fnum(v):
    return float(v) if v not in ("", None) else None


def timelines(runs):
    """One panel per drill type: acknowledged writes per second around the fault (first run of each)."""
    chosen = []
    for drill, _ in DRILLS:
        rs = sorted((r for r in runs if r["drill"] == drill), key=lambda r: int(r["run"]))
        if rs:
            chosen.append(rs[0])
    if not chosen:
        return
    fig, axes = plt.subplots(len(chosen), 1, figsize=(9, 2.3 * len(chosen)), sharex=False, squeeze=False)
    for ax, r in zip(axes[:, 0], chosen):
        name = f"{r['drill']}-{r['run']}"
        s = read_series(name)
        restore = fnum(r["zone_restore_after_fault_s"])
        right = max(120, int((restore or 0) + 120))
        s = s[:-1]  # the writer's last second is partial
        s = [p for p in s if -30 <= p[0] <= right]
        xs = [p[0] for p in s]
        if r["drill"] in ("az-down", "az-outage") and restore:
            empty = fnum(r["zone_empty_after_fault_s"]) or 0
            ax.axvspan(empty, restore, color=SHADE, zorder=0)
            ax.text((empty + restore) / 2, 0.45, "zone has no nodes", transform=ax.get_xaxis_transform(),
                    ha="center", va="center", color=INK2, fontsize=8.5)
        # Seconds after the fault with no acknowledged write, as one or more spans.
        zero = [p[0] for p in s if p[0] >= 0 and p[1] == 0]
        spans, start, prev = [], None, None
        for x in zero:
            if start is None:
                start = prev = x
            elif x == prev + 1:
                prev = x
            else:
                spans.append((start, prev + 1)); start = prev = x
        if start is not None:
            spans.append((start, prev + 1))
        errs = sum(p[2] for p in s if p[0] >= 0)
        for i, (a, b) in enumerate(spans):
            ax.axvspan(a, b, color=CRITICAL, alpha=0.14, lw=0, zorder=1)
            if i == 0:
                ax.text(b + 1.5, 0.55, "no acknowledged write\n"
                        f"{float(r['total_outage_s']):.1f} s, {errs} errors",
                        transform=ax.get_xaxis_transform(), va="center", color=INK, fontsize=8.5)
        ax.plot(xs, [p[1] for p in s], color=BLUE, lw=2, zorder=3)
        ax.axvline(0, color=INK2, lw=1, ls="--", zorder=2)
        ax.text(-1, 1.02, "fault", transform=ax.get_xaxis_transform(), ha="right", va="bottom", color=INK2, fontsize=8.5)
        ax.set_title(f"{LABEL[r['drill']]} (run {r['run']}): {r['lost_acked']} acknowledged writes lost",
                     loc="left", fontsize=10, pad=14)
        ax.set_ylabel("writes / s")
        ax.set_xlim(-30, right)
        ax.set_ylim(0, None)
        ax.grid(axis="y", color=GRID, lw=0.8)
        ax.set_axisbelow(True)
    axes[-1, 0].set_xlabel("seconds from the fault")
    fig.suptitle("Acknowledged writes per second through the gateway, around each fault", x=0.01, ha="left",
                 fontweight="bold", color=INK)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(os.path.join(CHARTS, "timelines.png"))
    plt.close(fig)


def outage_by_drill(runs):
    """Seconds without a successful write, every run as a dot, median as a tick."""
    groups = [(d, [r for r in runs if r["drill"] == d]) for d, _ in DRILLS]
    groups = [(d, rs) for d, rs in groups if rs]
    if not groups:
        return
    fig, ax = plt.subplots(figsize=(8, 0.75 * len(groups) + 1.2))
    for i, (d, rs) in enumerate(groups):
        y = len(groups) - 1 - i
        vals = [float(r["total_outage_s"]) for r in rs]
        ax.scatter(vals, [y] * len(vals), s=60, color=BLUE, edgecolor="white", linewidth=2, zorder=3)
        med = statistics.median(vals)
        ax.plot([med, med], [y - 0.28, y + 0.28], color=INK, lw=2, zorder=2)
        ax.text(max(vals) + 1.5, y, f"median {med:.1f} s  (n={len(vals)})", va="center", color=INK2, fontsize=9)
    ax.set_yticks(range(len(groups)))
    ax.set_yticklabels([LABEL[d] for d, _ in reversed(groups)])
    ax.set_xlabel("seconds with no acknowledged write (per run)")
    ax.set_xlim(0, max(float(r["total_outage_s"]) for r in runs) * 1.45 + 5)
    ax.grid(axis="x", color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_title("Client-visible write outage by failure type", loc="left")
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS, "outage-by-drill.png"))
    plt.close(fig)


def recovery_phases(runs):
    """Median seconds until writes succeed again vs until the Shard reports Healthy."""
    groups = [(d, [r for r in runs if r["drill"] == d]) for d, _ in DRILLS]
    groups = [(d, rs) for d, rs in groups if rs]
    if not groups:
        return
    fig, ax = plt.subplots(figsize=(8, 0.8 * len(groups) + 1.4))
    h = 0.34
    for i, (d, rs) in enumerate(groups):
        y = len(groups) - 1 - i
        wb = statistics.median(float(r["writes_back_after_fault_s"]) for r in rs)
        sh = [fnum(r["shard_healthy_after_fault_s"]) for r in rs]
        sh = [v for v in sh if v is not None]
        ax.barh(y + h / 2 + 0.02, wb, height=h, color=BLUE, label="writes succeed again" if i == 0 else None)
        ax.text(wb + 2, y + h / 2 + 0.02, f"{wb:.0f} s", va="center", color=INK2, fontsize=9)
        if sh:
            m = statistics.median(sh)
            ax.barh(y - h / 2 - 0.02, m, height=h, color="#f47230", label="Shard back to Healthy" if i == 0 else None)
            ax.text(m + 2, y - h / 2 - 0.02, f"{m:.0f} s", va="center", color=INK2, fontsize=9)
    ax.set_yticks(range(len(groups)))
    ax.set_yticklabels([LABEL[d] for d, _ in reversed(groups)])
    ax.set_xlabel("seconds after the fault (median across runs)")
    ax.set_xlim(0, ax.get_xlim()[1] * 1.15)
    ax.grid(axis="x", color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), frameon=False, ncol=2)
    ax.set_title("What clients see vs what the operator reports", loc="left", pad=28)
    fig.text(0.01, 0.01, "Shard status is sampled every 6 to 9 s. Node drain: 2 of 3 runs drained the node holding two "
             "etcd members and hit finding F4.", fontsize=8, color=INK2)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(os.path.join(CHARTS, "recovery-phases.png"))
    plt.close(fig)


def main():
    os.makedirs(CHARTS, exist_ok=True)
    runs = read_runs()
    timelines(runs)
    outage_by_drill(runs)
    recovery_phases(runs)
    print("charts ->", CHARTS)


if __name__ == "__main__":
    main()
