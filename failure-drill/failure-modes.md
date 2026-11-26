# Failure modes

How Multigres on EKS can fail, what each failure should do to a client, and where this round covers it. "Expected" is what the design promises; the measured behaviour is in the [summary](failure-drill.md).

## Data plane

| Failure | Expected behaviour | Covered by |
|---|---|---|
| Primary Postgres process or pod dies | multiorch promotes a standby in another zone; writes resume through the same gateway address; no acknowledged write lost | drill `pod-kill` |
| Primary's node is drained for maintenance | the pod is evicted within its PodDisruptionBudget; same as above, ideally with a shorter gap | drill `node-drain` |
| Primary's EC2 instance disappears | same as a pod crash, plus a replacement node in the same zone re-attaching the pooler's EBS volume | drill `node-terminate` |
| A standby dies | no client impact: `MULTI_CELL_AT_LEAST_2` still has the other standby to confirm commits | not run separately; happens inside `az-down` when the lost zone holds a standby |
| Two of three poolers lost at once | writes must stop (no second zone to confirm a commit) rather than be acknowledged unsafely | not run |
| The gateway pod serving a client dies | the client reconnects to another gateway through the Service | not run separately; gateways in the lost zone die in `az-down` |

## Zone

| Failure | Expected behaviour | Covered by |
|---|---|---|
| A zone with no etcd member is lost | one cell gone; the shard keeps taking writes on the remaining two zones; the lost cell's pooler stays `Pending` (its EBS volume cannot leave the zone) until the zone returns | drill `az-down` on `apse2-az1` |
| The zone holding two of three etcd members is lost | as above, and the global topology loses quorum; what that does to an already-running shard is the question | drill `az-down` on `apse2-az3`, finding F3 |
| A zone returns | the lost cell's pooler starts on the new node, re-attaches its volume and rejoins as a standby | the second half of `az-down` |

## Control plane and platform

| Failure | Expected behaviour | Covered by |
|---|---|---|
| Volume cannot be written by the pooler | the pod should start on any CSI driver | finding F1 (it does not without `fsGroup`) |
| A spec fix for a cluster that never started | the operator applies it | finding F2 (it does not without a manual pod delete) |
| etcd members concentrated in one zone | spread by default in a multi-zone cluster | finding F3 (not spread by default) |
| No default StorageClass (EKS 1.30+) | a clear error before anything is created | the admission webhook rejects the cluster with a precise message: works as intended |
| The operator itself restarts during a failover | the data plane keeps working; multiorch, not the operator, handles failover | not run |
| Operator upgrade on a live cluster | no client impact | not run; see multigres-operator issue #850 for the upgrade path |
| EKS managed node group version upgrade | nodes replaced one at a time within PodDisruptionBudgets and EKS's drain time limit | not run |

## Backups

| Failure | Expected behaviour | Covered by |
|---|---|---|
| Backups to S3 through IRSA | full backup and WAL archive arrive without static keys | check C3 |
| Restore from S3 into a new cluster | a working cluster with the expected data | not run |
