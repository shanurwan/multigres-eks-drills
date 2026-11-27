#!/usr/bin/env python3
"""Draw the charts from results/runs.csv and results/series/*.csv.

  python3 analysis/plot.py [results-dir]      # needs matplotlib

Writes results/charts/*.png. Every number in a chart comes from those CSVs.
"""
import csv
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
CHARTS = os.path.join(RESULTS, "charts")

# Same palette as failure-drill/: blue for successful work, the status "critical" step for
# errors, orange for the slow detection path, text inks for everything else.
BLUE, CRITICAL, ORANGE = "#257de0", "#dc3c3d", "#f47230"
INK, INK2, GRID, SHADE = "#191919", "#666666", "#e6e6e6", "#efefef"
WINDOW_S, MAX_FAILOVER_S = 10, 20  # multigateway defaults: --buffer-window, --buffer-max-failover-duration

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10, "axes.edgecolor": INK2,
    "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.titlesize": 11,
    "axes.titlecolor": INK, "axes.titleweight": "bold", "figure.dpi": 150,
})


def runs():
    with open(os.path.join(RESULTS, "runs.csv")) as f:
        return {r["run"]: r for r in csv.DictReader(f)}


def series(name, lo=-15, hi=45):
    with open(os.path.join(RESULTS, "series", name + ".csv")) as f:
        rows = [r for r in csv.DictReader(f)]
    rows = [{k: float(v) for k, v in r.items()} for r in rows]
    return [r for r in rows if lo <= r["second_from_fault"] <= hi]


def f(v):
    return float(v) if v not in ("", None) else None


def window(r):
    return 30 if r.get("tag") == "buf30" else WINDOW_S


def marks(ax, r, y_text=True):
    """Fault at 0, buffering window, and the moment multiorch detected the dead primary."""
    ax.axvline(0, color=INK2, lw=1, ls=":")
    b0 = f(r.get("buffer_start_s"))
    det = f(r.get("detection_s"))
    if b0 is not None:
        ax.axvspan(b0, b0 + window(r), color=SHADE, zorder=0)
    if det is not None:
        ax.axvline(det, color=ORANGE if det > 10 else BLUE, lw=1.2)
    ax.grid(axis="y", color=GRID, lw=0.8)
    ax.set_axisbelow(True)


def label_marks(ax, r):
    b0, det = f(r.get("buffer_start_s")), f(r.get("detection_s"))
    tr = ax.get_xaxis_transform()
    box = {"facecolor": "white", "edgecolor": "none", "alpha": 0.85, "pad": 1.5}
    ax.text(-0.6, 0.97, "pod killed", transform=tr, ha="right", va="top", color=INK2, fontsize=7.5, bbox=box)
    if b0 is not None:
        ax.text(b0 + min(window(r), 18) / 2, 0.97, f"gateway holds\nqueries (up to {window(r)} s)", transform=tr,
                ha="center", va="top", color=INK2, fontsize=7.5)
    if det is not None:
        ax.text(det + 0.6, 0.45, f"multiorch detects\n{r['detection']}\nat {det:.1f} s", transform=tr,
                va="center", color=ORANGE if det > 10 else BLUE, fontsize=7.5, bbox=box)


def storm_panels(R, names, out, title):
    fig, axes = plt.subplots(2, len(names), figsize=(5.2 * len(names), 5.2), sharex=True, squeeze=False,
                             gridspec_kw={"height_ratios": [3, 2]})
    for i, name in enumerate(names):
        r, s = R[name], series(name)
        x = [p["second_from_fault"] for p in s]
        top, bot = axes[0][i], axes[1][i]
        top.plot(x, [p.get("fh_queries", 0) for p in s], color=BLUE, lw=2, label="queries answered / s")
        top.bar(x, [p.get("fh_errors", 0) for p in s], width=0.9, color=CRITICAL, label="errors / s")
        marks(top, r)
        label_marks(top, r)
        buf = "buffer 30 s / 40 s" if r.get("tag") == "buf30" else "default buffer"
        top.set_title(f"{r['fh_connections']} conns, {buf}, {'fast' if f(r['detection_s']) < 10 else 'slow'} detection",
                      loc="left", pad=10, fontsize=10)
        top.set_ylabel("per second")
        conns = [p.get("fh_connections", 0) for p in s]
        bot.plot(x, conns, color=INK, lw=1.8)
        marks(bot, r)
        bot.set_ylim(0, int(r["fh_connections"]) * 1.1)
        bot.set_ylabel("open client\nconnections")
        bot.set_xlabel("seconds from the primary pod kill")
        if f(r.get("buffer_start_s")) is None:
            top.text(0.99, 0.02, "buffer start not in the logs (rotated)", transform=top.transAxes, ha="right",
                     fontsize=7, color=INK2)
    h, l = axes[0][0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper right", ncol=2, frameon=False, fontsize=8.5)
    fig.suptitle(title, x=0.01, ha="left", fontsize=12, fontweight="bold", color=INK)
    fig.text(0.01, 0.005, "supafirehose (unmodified) through the gateway; 100 ms snapshots summed per second. "
             "Shaded: up to the per-query buffer window (default 10 s).",
             fontsize=7.5, color=INK2)
    fig.tight_layout(rect=(0, 0.03, 1, 0.95))
    fig.savefig(os.path.join(CHARTS, out))
    plt.close(fig)


def auth_panels(R, names, out):
    fig, axes = plt.subplots(1, len(names), figsize=(5.2 * len(names), 4.0), sharey=True, squeeze=False)
    for i, name in enumerate(names):
        r, s = R[name], series(name)
        x = [p["second_from_fault"] for p in s]
        ax = axes[0][i]
        ax.plot(x, [p.get("auth_ok", 0) for p in s], color=BLUE, lw=2, label="requests answered correctly / s")
        e5 = [p.get("auth_err_5xx", 0) for p in s]
        en = [p.get("auth_err_no_response", 0) for p in s]
        ax.bar(x, e5, width=0.9, color=CRITICAL, label="HTTP 500/504")
        ax.bar(x, en, bottom=e5, width=0.9, color=CRITICAL, alpha=0.45, label="no answer within 10 s")
        marks(ax, r)
        label_marks(ax, r)
        ax.set_title(f"Auth at 20 req/s, {'fast' if f(r['detection_s']) < 10 else 'slow'} detection, run {name[-1]}", loc="left", pad=10)
        if f(r.get("buffer_start_s")) is None:
            ax.text(0.99, 0.97, "buffer start not in the logs (rotated)", transform=ax.transAxes, ha="right", va="top",
                    fontsize=7, color=INK2)
        ax.set_xlabel("seconds from the primary pod kill")
        if i == 0:
            ax.set_ylabel("requests per second")
    h, l = axes[0][0].get_legend_handles_labels()
    fig.legend(h, l, loc="lower center", ncol=3, frameon=False, fontsize=8.5, bbox_to_anchor=(0.5, 0.04))
    fig.text(0.01, 0.005, "Supabase Auth v2.199.0 through the gateway. Logins, token refreshes and GET /user; "
             "wrong-password logins answered 400 invalid_credentials count as correct.", fontsize=7.5, color=INK2)
    fig.tight_layout(rect=(0, 0.12, 1, 1))
    fig.savefig(os.path.join(CHARTS, out))
    plt.close(fig)


def gap_by_run(R):
    rows = [r for r in R.values() if r["drill"] != "none" and not r.get("tag")]
    rows.sort(key=lambda r: (r.get("tag", ""), r["scenario"], f(r["detection_s"]) or 0))
    names, gaps, dets, cols = [], [], [], []
    for r in rows:
        gap = f(r.get("fh_longest_no_success_s")) if r["scenario"] == "storm" else f(r.get("auth_longest_no_success_s"))
        label = (f"storm {r['fh_connections']} conns" if r["scenario"] == "storm" else "Auth 20 req/s") + f", run {r['run'][-1]}"
        if r.get("tag") == "buf30":
            label = "buffer 30 s/40 s: " + label
        names.append(label)
        gaps.append(gap or 0)
        det = f(r["detection_s"])
        dets.append(det)
        cols.append(ORANGE if det and det > 10 else BLUE)
    fig, ax = plt.subplots(figsize=(8.6, 0.42 * len(rows) + 1.9))
    y = range(len(rows))
    ax.barh(y, gaps, color=cols, height=0.6)
    for yi, g, d in zip(y, gaps, dets):
        ax.text(max(g, d or 0) + 0.5, yi, f"{g:.1f} s", va="center", fontsize=8.5, color=INK)
        if d is not None:
            ax.plot([d], [yi], marker="|", markersize=14, color=INK, mew=1.5)
    for x, t in ((WINDOW_S, "buffer window"), (MAX_FAILOVER_S, "max failover duration")):
        ax.axvline(x, color=INK2, ls=":", lw=1)
        ax.text(x, -0.75, f"{t} ({x} s)", ha="center", fontsize=7.5, color=INK2)
    ax.set_yticks(list(y), names)
    ax.set_xlabel("longest time with no successful client request (s)")
    ax.set_title("What clients saw after a primary pod kill, by detection path", loc="left")
    ax.grid(axis="x", color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_xlim(0, 30)
    ax.set_ylim(len(rows) - 0.5, -1.1)
    from matplotlib.lines import Line2D
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(color=BLUE, label="fast: LeaderUnhealthy"),
                       Patch(color=ORANGE, label="slow: quorum / cohort detection"),
                       Line2D([], [], marker="|", ls="", color=INK, markersize=12, label="multiorch detection")],
              loc="upper center", bbox_to_anchor=(0.45, -0.16), ncol=3, frameon=False, fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS, "client-gap-by-run.png"))
    plt.close(fig)


def main():
    os.makedirs(CHARTS, exist_ok=True)
    R = runs()
    storm_panels(R, ["storm-pod-kill-c500-1", "storm-pod-kill-c500-2"], "storm-500-fast-vs-slow.png",
                 "500 client connections: the same fault, two detection paths")
    storm_panels(R, ["storm-pod-kill-c2000-1", "storm-pod-kill-c2000-2"], "storm-2000.png",
                 "2,000 client connections: every connection dropped and reopened")
    auth_panels(R, ["auth-pod-kill-r20-3", "auth-pod-kill-r20-1"], "auth-fast-vs-slow.png")
    storm_panels(R, ["storm-pod-kill-c2000-1", "storm-pod-kill-c2000-buf30-1"], "buffer-default-vs-30s.png",
                 "Slow detection, 2,000 connections: default buffer vs window 30 s / max 40 s")
    gap_by_run(R)
    print("charts ->", CHARTS)


if __name__ == "__main__":
    main()
