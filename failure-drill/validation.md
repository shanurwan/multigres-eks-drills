# Validation

A drill that silently fails to apply its fault produces a perfect result. Every result here is only as good as the proof that the fault happened, that the measurement survived it, and that nothing else was going on.

## Proof that each fault happened

| Drill | Recorded in `results/<run>/` | What it shows |
|---|---|---|
| `pod-kill` | `fault.txt`, `primary-before.txt`, `pods-after.txt` | the deleted pod's name and UID; the pod after the run has a different UID and age |
| `node-drain` | `fault.txt`, `events.txt` | the drain output with every evicted pod, and the uncordon |
| `node-terminate` | `fault.txt` | the EC2 instance ID taken from the node's `providerID`, and its state read back from EC2 after `instance-terminated` |
| `az-down` | `fault.txt`, `timeline.txt`, `pods-zone-down.txt` | the node group update ID, the time the zone had 0 nodes, every pod's state while the zone was empty, and the time a node was Ready again |

Every run also records which pooler was primary before and after (`primary-before.txt`, `primary-after.txt`), asked directly of each Postgres with `pg_is_in_recovery()`. A drill that targets the primary but finds the same primary afterwards is investigated before its numbers are used.

## Proof that the measurement survived

- The writer runs in a zone the drill does not break. `drill.sh` refuses to start a zone drill when the writer is in the target zone, and refuses a node drill when the writer shares the primary's node. `campaign.sh` moves the writer first when needed.
- Writes go through the gateway Service, the path an application uses, not to a pooler directly.
- `verify` reconnects after the run and checks every acknowledged write by its writer and sequence number. Its result does not depend on the writer having seen the whole run.
- The writer logs every attempt, not samples. Outage lengths come from the gaps between acknowledged writes, at microsecond resolution.

## Checks on the harness itself

| Check | How |
|---|---|
| The writer and verifier agree on an undisturbed cluster | a 10-second smoke run before the drills: 100 attempted, 100 acknowledged, 0 lost, p50 4 ms |
| The analysis does not edit data | `collect.py` and `plot.py` only read the run folders and write new files; rerunning `collect.py` reproduces the CSVs exactly, and the charts are redrawn from those CSVs |
| No account identifiers in published files | every file under `results/` is searched for 12-digit numbers before each commit |

## Mistakes found while building the harness

These happened. Each is kept because it is the kind of mistake that would have made a result wrong without anyone noticing.

| What happened | How it showed up | Fix |
|---|---|---|
| The default instance type was not allowed on a free-plan account, and the node groups stayed `CREATING` for 12 minutes | the Auto Scaling group's activity: "not eligible for Free Tier" | `m7i-flex.large` as the default; documented in [reproduce.md](reproduce.md) |
| The background deploy hung waiting for input that never came | no output and no namespace after minutes | scripts take no interactive input; documented runs pass `< /dev/null` |
| Git Bash on Windows rewrote `/ackcheck` into a Windows path inside `kubectl exec` | `exec: "C:/Program Files/Git/ackcheck": no such file` | `MSYS_NO_PATHCONV=1` in every script; no effect on Linux or macOS |
| `kubectl cp` read `C:/…` as a pod name | `one of src or dest must be a local file specification` | copy with a relative path |
| The first timeline chart drew failures as bars that were invisible next to 400 successes a second | looking at the rendered chart | the outage is drawn as a shaded window labelled with its length and error count |
| The checker's own `outages` field reported none for runs where the raw events showed ~2-second gaps between acknowledged writes | computing the largest gap between acknowledged writes directly from the events | outages are measured in `collect.py` from the raw events (gaps of 1 s or more, any writer); `verify.json` is still used for loss counts |
| "Scale the zone's node group to 0" was first treated as a zone outage. EKS drains the node and honours disruption budgets, so it is a graceful zone drain | the first attempt on `apse2-az3` sat in `Terminating:Wait` for 6 minutes (finding F4) | the drill is labelled `az-down` (zone drained); `az-outage` terminates the instance with no drain |
| Stopping a drill from the job runner did not stop its child processes; the drill kept polling for an empty zone | a `kubectl` process reappearing every 2 seconds | killed by process ID; noted for anyone stopping a drill early |
| A timeline chart showed writes collapsing at the end of a run | the writer's last second is partial | the last second of each series is dropped before plotting |
