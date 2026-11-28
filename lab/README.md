# lab

An interactive replay of the recorded [day-2 runs](../day2-operations/blog.md): six short lessons where you type the command, the terminal prints the run's own timeline, and a 3D picture plays back the cluster second by second. **Open it: https://shanurwan.github.io/multigres-eks-drills/**

Nothing in it talks to a cluster. Every number on the page is computed in the browser from `data/runs.json`, which `build.py` makes from the files in `../day2-operations/results/`.

## Two modes

**Replay.** The recorded runs from 27 November 2026: switchovers, a rolling Multigres upgrade, node group upgrades, a zone cut off from the VPC, and a full primary disk. Links can point at a moment: `?drill=disk-full&run=2&at=100`.

**Live.** The page's "Run it yourself" section walks through the Terraform template and scripts in this repository, from a new AWS account to the same commands on your own cluster. Then build your runs into a file and load it on the page to replay them on the same picture:

```sh
python3 production-scenario/analysis/collect.py day2-operations/results
python3 day2-operations/analysis/day2.py
python3 lab/build.py day2-operations/results -o my-runs.json      # then "Load my runs.json" on the page
```

The longer written guide is [`../terraform/aws-setup.md`](../terraform/aws-setup.md) followed by [`../day2-operations/README.md`](../day2-operations/README.md).

## What is drawn and what is measured

Measured, from the run's files: which zone held the primary, which zone was cut off and when, the Shard's phase and pool pod readiness (every few seconds), how full the primary's disk was, acknowledged and failed writes and app errors per second, and the rollout and node group progress.

Drawn only to make it readable: the dots (the record keeps counts per second, not paths), which gateway a dot passes through, and the moment the primary changes, drawn when the writer's writes came back.

## Run it locally

```sh
python3 lab/build.py                      # refresh data/runs.json from day2-operations/results
python3 -m http.server -d lab 8000        # then open http://localhost:8000
```

`?tiktok=1` plays a scripted 40-second vertical tour (1080×1920) of the zone cut-off and the full disk, used for the short video.

## Files

| File | What it is |
|---|---|
| `index.html`, `style.css` | the page |
| `app.js` | replay engine, terminal, 3D scene (three.js 0.160 from jsDelivr), strip chart, results table |
| `lessons.js` | the lessons, and the outcome each computes from its run |
| `build.py` | results folder to `data/runs.json` (Python standard library) |
| `data/runs.json` | the 11 recorded runs |
