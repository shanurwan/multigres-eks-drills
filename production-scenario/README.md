# production-scenario

Two Supabase-shaped workloads run through the Multigres gateway while the primary's pod is killed: a reconnect storm with Multigres's own load tool, and Supabase Auth logins. **Results: [`scenario.md`](scenario.md).**

This builds on [`../failure-drill`](../failure-drill/failure-drill.md): same EKS cluster, same fault, same acknowledged-write checker. What's new is what real clients and a real Supabase service see.

## System under test

| Part | Version | Where |
|---|---|---|
| Multigres operator | `c9ef95f1` (`sha256:767d2dfa…`) | `../failure-drill/results/_versions/` |
| multigateway, multipooler, multiorch | `ghcr.io/multigres/multigres@sha256:ed65d714…` | every run's `run.txt` |
| Postgres + pgBackRest (pgctld) | `ghcr.io/multigres/pgctld@sha256:35f53ecf…` (Postgres 17) | `run.txt` |
| supafirehose | commit `05edf8a`, unmodified | built by `scripts/build.sh` |
| Supabase Auth (GoTrue) | `supabase/gotrue:v2.199.0` | `manifests/auth.yaml` |
| EKS | 1.35, 3 zones, one `m7i-flex.large` (2 vCPU) per zone | `../terraform/` |

Gateway buffer settings are the operator's defaults, except in runs tagged `buf30` (window 30 s, max failover 40 s): buffering on, `--buffer-window 10s`, `--buffer-max-failover-duration 20s`, `--buffer-size 1000`, `--buffer-drain-concurrency 1`.

## Workloads

**Reconnect storm (`storm`)**
- supafirehose opens N direct connections through the gateway Service: 80% readers running `SELECT … FROM users WHERE id = $1`, 20% writers inserting into `users`.
- It's capped at 2,000 reads/s and 200 writes/s in total, so the runs compare connection behaviour, not throughput.
- On any error a worker closes its connection and opens a new one after 100 ms. That's supafirehose's own behaviour, and the source of the storm.
- Its 100 ms metrics stream (queries, errors, latency, open connections) is recorded by `tools/fhrec`, because supafirehose itself only shows it in a browser.

**Auth (`auth`)**
- Supabase Auth runs as one replica, with `DATABASE_URL` pointing at the gateway as `supabase_auth_admin`, the role a Supabase Postgres image creates.
- `tools/authload` signs up 200 users once, then sends 20 requests/s from 16 clients, picking a random user for each:
  - 5% log in with a wrong password, as a control for what a real typo returns
  - after that, about half fetch the user (`GET /user`) and about 15% refresh the token, once the user has a session
  - the rest log in with the right password
- Every request's HTTP status, error code, message and latency is recorded, with a 10 s client timeout.

**Drill writer, in every run:** the `failure-drill` checker. It runs 8 connections × 50 inserts/s through the gateway, logs every attempt, and verifies every acknowledged key afterwards.

## One run

`scripts/scenario.sh <storm|auth> <n> [drill]`:

1. Start the load in the `loadgen` pod (`apse2-az1`) and give it 25 s to open every connection.
2. Start one sampler per gateway pod and per client pod, reading the pod's cgroup memory and CPU about once a second.
3. Run `../failure-drill/scripts/drill.sh pod-kill` with this run's name. It starts the drill writer, force-deletes the primary's pod 60 s later, waits for the writer to finish (6 min), waits for the shard to be `Healthy`, verifies every acknowledged write, and collects every component's logs.
4. Collect the load's own records, Auth's server log, and each gateway's restart count.

A baseline is the same with `none` as the drill: load and writer, no fault.

## What is measured, and how

All times are seconds after the pod kill. They come from `analysis/collect.py`, which reads only the files in `results/<run>/`.

| Measure | Source | Definition |
|---|---|---|
| Longest gap for clients | supafirehose metrics / Auth events | longest stretch with no successful request. Storm: 100 ms windows with queries and no errors. Auth: any correct answer, counting a wrong password answered `invalid_credentials` as correct |
| Client errors | the same | supafirehose's error counters / Auth requests that weren't answered correctly |
| Open connections | supafirehose metrics | its own count of open connections |
| Full query rate again | supafirehose metrics | first second after which 3 seconds in a row run at ≥95% of the 30 s before the fault, with no errors |
| Detection | multiorch logs | the first `LeaderUnhealthy`, `LeaderUnreachableByCohort` or `LeaderQuorumWritesStalled` after the fault |
| Buffering | multigateway logs | `failover detected, starting buffering`, `stopping buffering` (with its reason), `draining entries` (count), and `MTB02` lines |
| Credential lookups failed | multigateway logs | `credential lookup failed` lines (a client connecting while no primary can answer) |
| Lost acknowledged writes | drill writer | acknowledged keys missing afterwards |
| Peak memory and CPU | cgroup samples | highest `memory.current`; highest CPU rate between two samples |

## Validation

- **The fault happened.** Each run's `fault.txt` has the deleted pod's UID. `primary-before.txt` and `primary-after.txt` show a different primary. `shard-timeline.txt` shows the shard leave and return to `Healthy`.
- **The load was there before the fault.** Every fault run has a full rate for at least 30 s before the kill (`series/<run>.csv`). Baselines show the same load runs with 0 errors for 3 minutes (500 and 2,000 connections, and Auth).
- **The client wasn't the bottleneck.** The loadgen pod peaked at 0.65 of a core, and Auth at 0.96 of a core in a 2-vCPU node. Gateway memory peaked at half its limit with no restarts (`gateways-after.txt`).
- **The baseline answers matched the expected ones.** Without a fault every wrong password got `400 invalid_credentials`, and every right one got a session. During faults, no right password ever got `invalid_credentials` (searched across all Auth events, and `password authentication failed` across every client record and server log: 0 hits).
- **Every chart and table number traces to a CSV:** `results/runs.csv`, `results/series/`, `results/errors/`.

### Mistakes found and fixed along the way

| Mistake | Effect | Fix |
|---|---|---|
| The first baseline reused a run name from a smoke test | the writer's inserts hit primary-key conflicts with the earlier rows, and 47,784 of 55,216 showed as "failed" | run discarded; `scenario.sh` now refuses a run name that already has rows |
| The wait for the load to finish matched its own `grep` command line | the script waited forever after a completed run | `[a]uthload`-style pattern; that run's files were collected by hand, and nothing was lost |
| The client pod has no init process, so finished processes stay as zombies | `pgrep` saw finished tools as running | the wait skips processes in state `Z` |
| `drill.sh` read the operator image from the first pod in its namespace, which became Grafana once monitoring was installed | `run.txt` named the wrong image in 7 runs here and 2 in `failure-drill/` | fixed in `drill.sh`; each affected `run.txt` has an `operator_image_corrected` line. The operator was unchanged throughout |
| The kubelet's 10 MiB log rotation dropped the start of two failovers before the logs were collected | the buffer start is missing for 2 of 7 runs | marked "not in log" in the tables. Client-side records are complete. This is also finding P4 |
| The first batch ran its control loop on a memory-starved workstation, which stopped it | one baseline was cut short | discarded; batches now run from a separate host under `nohup` |

## Reproduce

You need the cluster from [`../terraform/aws-setup.md`](../terraform/aws-setup.md) with Multigres deployed and `Healthy` (`../failure-drill/reproduce.md`, steps 4–5), plus Docker on the machine you run from.

```sh
cd production-scenario
scripts/build.sh                       # supafirehose at 05edf8a, fhrec, authload, ackcheck -> bin/
scripts/setup.sh apse2-az1             # loadgen pod, supafirehose table, Auth roles, Auth, 200 users
../failure-drill/scripts/writer.sh apse2-az2   # the drill writer, if it isn't running

WRITE_FOR=3m CONNS=500 scripts/scenario.sh storm 1 none   # baseline
CONNS=500  scripts/scenario.sh storm 1                    # about 11 minutes each
CONNS=2000 scripts/scenario.sh storm 1
scripts/scenario.sh auth 1

# The buffer fix: set multigateway.buffer.window: 30s and maxFailoverDuration: 40s on every cell, then
TAG=buf30 CONNS=500 scripts/scenario.sh storm 1     # TAG is added to the run name

python3 analysis/collect.py            # -> results/runs.csv, series/, errors/
python3 analysis/plot.py               # -> results/charts/ (needs matplotlib)
```

Use your own zone IDs (`kubectl get nodes -L topology.k8s.aws/zone-id`). Leave at least a minute between pod kills: the gateway won't buffer two failovers of one shard within `--buffer-min-time-between-failovers` (1 min).

## Layout

| Path | What it is |
|---|---|
| [`scenario.md`](scenario.md) | results, findings P1–P4, what to check, limits |
| `scripts/build.sh`, `setup.sh`, `scenario.sh` | build the tools, prepare the cluster, run one scenario |
| `manifests/loadgen.yaml`, `auth.yaml` | the client pod; Supabase Auth and its Service |
| `sql/auth-roles.sql` | the roles Auth expects. `sql/supafirehose-init.sql` is supafirehose's own schema and seed |
| `tools/fhrec/` | records supafirehose's metrics WebSocket to JSONL |
| `tools/authload/` | signs up users and drives Auth, recording every response |
| `analysis/collect.py`, `plot.py` | runs to CSV, CSV to charts |
| `results/<run>/` | `timeline.txt`, `fault.txt`, `verify.json`, `ackcheck/`, `load/`, `logs/`, `resources.txt`, `gateways-after.txt` |
