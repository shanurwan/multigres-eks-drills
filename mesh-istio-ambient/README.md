# Multigres inside an Istio ambient mesh

Can a three-zone Multigres cluster run inside Istio's ambient mesh (ztunnel, mTLS between every pod, no sidecars), and what changes when it does? It was tested on the same EKS cluster as [`../failure-drill`](../failure-drill/failure-drill.md), with the same writer and supafirehose load as [`../production-scenario`](../production-scenario/scenario.md).

## Summary

| Question | Result |
|---|---|
| Does it install and run? | Yes. All 17 pods joined the mesh live without restarting, and all switched to HBONE (mTLS). The shard stayed Healthy, replication stayed in quorum, and Prometheus kept scraping |
| Does STRICT mTLS work? | Only if the operator's namespace is enrolled too. With only the data namespace enrolled, a client from outside the mesh can open TCP but `psql` is cut off, and a **restarted operator loses etcd and its Shard reconciler errors**. Enrolling `multigres-operator` fixed both |
| Latency at 500 connections, no fault | read p50 1.8 → **2.6 ms**, write p50 4.8 → **6.4 ms** once every connection was inside the mesh. Up to 3x right after enrollment (see below) |
| Failover after a primary pod kill | **Different from outside the mesh.** The standbys took the "suspected divergence → rewind" path in **4 of 4** kills, against **0 of 14** without the mesh. 3 of 4 recovered |
| **1 of 4 kills: no primary for 47 minutes** | a deadlock in Multigres's recruit floor (below), until one pooler's floor was cleared by hand |
| Acknowledged writes lost | 0 |

## The stuck failover

After the primary's pod was killed, the shard had no primary from 06:17:38 to about 07:04:50 UTC. multiorch reported `ShardStuck` ("needs a new leader (LeaderResigned) but cannot reach a sufficient recruitment quorum") every 10 minutes.

**What happened:**
1. The killed primary (az1) came back as a standby.
2. Both other poolers decided they had stopped streaming from "the recorded leader" (az1), marked suspected divergence, and started a rewind toward it.
3. Before rewinding, each recorded a recruit floor at its position, term 25 at `0/A30000A0`.
4. The pg_rewind dry run found no divergence and skipped the rewind, but the floor stayed.
5. Both restarted streaming from az1. A restarted WAL receiver reports `pg_last_wal_receive_lsn()` from the start of the segment (`0/A3000000`), so their consensus position, which uses the receive LSN first, sat 0xA0 bytes below the floor, even though they had replayed to `0/A30000A0`.
6. No primary meant no new WAL, so the position never passed the floor. 2 of 3 cohort members stayed unrecruitable, and there was no majority for a new term.

**What didn't fix it:** restarting all three multiorch pods, and taking the namespace back out of the mesh.

**What fixed it:** removing `recruitBlockedUntil` from az2's `consensus_promises.json` and restarting that pod. az2 had replayed exactly to its floor, so this was safe. A new primary was elected about 70 s later.

The deadlock itself is in Multigres's floor logic and doesn't need a mesh. The mesh is what made the standbys take the rewind path every time. For the first 25–30 s after the kill, multiorch's gRPC calls to the restarted pooler were reset ("error reading server preface: connection reset by peer"). Separately, the operator's backup health check kept dialling the killed pod's old IP through a cached connection.

Evidence, kept before any recovery step:
- [`results/stall-evidence/`](results/stall-evidence/): every component's logs, all three `consensus_promises.json` files, the LSNs, the shard status and events
- [`actions.txt`](results/stall-evidence/actions.txt) and the before/after of the one file edited

## STRICT mTLS

| Step | What worked | What broke |
|---|---|---|
| `multigres-demo` enrolled, PERMISSIVE | everything | nothing |
| STRICT on `multigres-demo` | existing connections (operator, Prometheus) kept working, and the shard stayed Healthy | **new** connections from outside the mesh: `psql` from an unenrolled pod is closed, and a restarted operator can't reach etcd (`retrying of unary invoker failed`, Shard `Reconciler error`) |
| + `multigres-operator` enrolled | everything, with 0 operator errors | nothing |

STRICT only bites when connections are re-made, for example at the next operator upgrade. So test it by restarting clients, not by watching an already-running cluster.

## Latency

The same supafirehose load (500 connections, 2,000 reads/s, 200 writes/s) for 3 minutes, a few minutes apart:

| Run | read p50 / p99 | write p50 / p99 |
|---|---|---|
| Without the mesh | 1.8 / 7.5 ms | 4.8 / 9.9 ms |
| Mesh, right after enrollment | 6.4 / 23.4 ms | 11.4 / 29.0 ms |
| Mesh, after failovers had re-made every connection | 2.6 / 9.4 ms | 6.4 / 14.5 ms |

The second mesh run is the steady state, about +1 ms at p50. Two caveats on the first:
- In ambient mode, connections opened before enrollment stay outside the mesh until they're re-made, so it measured a mix.
- The primary sat on a different node in each run, and the primary's node was at 1.72 of 2 cores during the steady-state run. ztunnel used 0.14–0.37 cores per node.

On larger nodes the overhead would be smaller. These numbers are for 2-vCPU nodes, not a general claim.

## How it was run

```sh
ISTIOCTL=~/istio-1.32.0/bin/istioctl scripts/install.sh       # ambient profile, small requests
scripts/health.sh 0-before                                     # snapshot: shard, writes, replication, operator, Prometheus, ztunnel
kubectl label ns multigres-demo istio.io/dataplane-mode=ambient
scripts/health.sh 1-enrolled
(cd ../production-scenario && TAG=mesh CONNS=500 scripts/scenario.sh storm 1)   # a primary pod kill inside the mesh
kubectl apply -f - <<EOF   # STRICT
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: default, namespace: multigres-demo}
spec: {mtls: {mode: STRICT}}
EOF
kubectl label ns multigres-operator istio.io/dataplane-mode=ambient
```

The Istio release was downloaded from github.com/istio/istio/releases and checked against its published SHA-256. Run results are in `../production-scenario/results/*mesh*`, and the health snapshots in `results/<step>/`.

## Limits

- 4 fault runs in the mesh: enough to show the rewind path fires every time and can deadlock, not how often it deadlocks.
- One Istio version (1.32.0) on EKS with the VPC CNI. No waypoints, no L7 policy.
- The default buffer settings were changed to 30 s / 40 s before these runs (see `../production-scenario`). That doesn't affect the consensus path.
