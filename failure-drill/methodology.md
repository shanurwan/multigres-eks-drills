# Methodology

## Question

What does an application connected to Multigres on EKS experience when a pod, a node or a whole availability zone fails, and does the operator's view of the cluster match what the application experiences?

Two answers matter more than any latency number:

1. **Durability:** is any write that the database acknowledged missing afterwards?
2. **Availability:** for how long can the application not write, and what errors does it see meanwhile?

## System under test

| Layer | Configuration |
|---|---|
| AWS | `ap-southeast-2`, three availability zones (`apse2-az1`, `apse2-az2`, `apse2-az3`), free-plan account |
| Network | one VPC, one public subnet per zone, no NAT gateway |
| EKS | Kubernetes 1.35 (standard support), one managed node group per zone, one `m7i-flex.large` node each (2 vCPU, 8 GiB) |
| Storage | EBS CSI driver (EKS add-on, IRSA), StorageClass `multigres-gp3`: gp3, `WaitForFirstConsumer`, expansion allowed, set as default |
| Multigres operator | the `current` release (built from `main` on 2026-11-26), image `ghcr.io/multigres/multigres-operator@sha256:767d2dfa…`; install manifest and its SHA-256 in `results/_versions/` |
| Multigres cluster | 3 cells, one per zone, pinned by zone ID; one pooler per cell (3 in total); durability `MULTI_CELL_AT_LEAST_2`; global topology on the operator-managed 3-member etcd; `fsGroup: 999` on the pool (see finding F1) |
| Backups | pgBackRest to S3, credentials through IRSA (no static keys) |
| PostgreSQL | 17, as shipped in the operator's default images |

Exact image digests for every container are recorded per run in `results/<run>/run.txt`.

### Why this layout

- **One pooler per zone with `MULTI_CELL_AT_LEAST_2`:** every commit waits for a standby in a second zone. Losing any one zone should therefore lose no acknowledged write. That is the claim the zone drill tests.
- **One node per zone:** removing a zone's node group removes the zone completely, with nothing left to absorb the zone's pods. This is the harshest version of a zone outage, and the simplest to reason about.
- **Cells pinned by zone ID, not zone name:** zone names (`ap-southeast-2a`) map to different physical zones in different AWS accounts; zone IDs do not.

## The workload

`tools/ackcheck` is a small Go program that writes through the Multigres gateway (`demo-multigateway:5432`), exactly as an application would.

- 8 writers, one connection each, each inserting 50 rows a second: about 400 writes a second in total.
- Every insert has a 2-second statement timeout.
- Every attempt is logged with a microsecond timestamp, the writer, a per-writer sequence number, the outcome and the latency:
  - **acknowledged:** the commit returned successfully
  - **failed:** the server returned an error; the write is known not to have committed
  - **ambiguous:** the connection broke or timed out after the statement was sent; the write may or may not have committed
- After the drill, `ackcheck verify` reconnects and checks every acknowledged write is present. It also reports which ambiguous and failed writes ended up committed.

The writer runs in a pod pinned to a zone that the drill does not break, so the measurement survives the fault.

## One run

`scripts/drill.sh <drill> <run> [zone]` does the following, and `scripts/campaign.sh` runs a list of drills in order:

1. **Before:** record which pooler is primary (`scripts/primary.sh` asks each Postgres `pg_is_in_recovery()`), the pods and their nodes, and every container's image digest.
2. **Observe:** start a background loop that samples the Shard's phase and each pooler's readiness. (On the machine used here each sample took 6 to 9 seconds, so Shard timings have that resolution. The writer's timings are exact.)
3. **Write:** start the writer for 6 minutes.
4. **Fault:** at 60 seconds, apply the fault and record proof that it happened (see [validation.md](validation.md)).
5. **After:** wait for the writer to finish and the Shard to report `Healthy` (up to 15 minutes), run `verify`, then collect the primary after the run, pods, events and the logs of the operator, every multiorch, every gateway and every pooler container, including the previous container's log where one restarted.

Every run writes to its own folder, `results/<drill>-<run>/`. Nothing is overwritten.

## What is measured

| Measure | Source | Definition |
|---|---|---|
| Acknowledged writes lost | `verify.json: lost_acked` | acknowledged writes missing afterwards |
| Client-visible outage | `verify.json: outages` | time with no acknowledged write, counting gaps of one second or more; summed per run |
| Writes back after the fault | event log | from the fault command to the end of the last outage |
| Errors | `verify.json: error_kinds` | count of each error text clients received |
| Shard back to Healthy | `shard-timeline.txt` | from the fault to the first `Healthy` sample after a non-`Healthy` one |
| New primary | `primary-before.txt`, `primary-after.txt` | which zone holds the primary before and after |
| Commit latency | `verify.json: ok_latency_ms` | of acknowledged writes, across the whole run |

`analysis/collect.py` turns the run folders into `results/runs.csv` and per-second series; `analysis/plot.py` draws the charts from those files. Neither edits the raw data.

## Drill order

Drills that leave the cluster healthy run first. The zone loss that takes 2 of the 3 etcd members with it (finding F3) runs last, because it may leave the cluster in a state that needs manual repair.

## What this does not establish

See [Limits](failure-drill.md#limits) in the summary.
