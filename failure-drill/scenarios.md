# Scenarios

Each scenario answers one question a team needs answered before running Multigres on EKS. Each is tied to something specific: a claim in the operator's docs, an open issue, or an event every EKS cluster goes through.

## Part 1: do the documented EKS patterns work as written

| ID | Check | Source of the claim | How |
|---|---|---|---|
| C1 | Install from scratch with server-side apply | operator README | apply the `current` release's `install.yaml` with `--server-side`; time to a Ready operator |
| C2 | Cells pinned by zone ID land in their zone, with their volume | operator cell topology docs | compare each pooler's node zone and its PersistentVolume's zone with its cell |
| C3 | Backups to S3 through IRSA | `docs/backup-restore.md` ("recommended for EKS") | only the documented ServiceAccount annotation, no static keys; list the backup and WAL archive in S3 |
| C4 | Gateway reachable through an Elastic IP with `externalIPs` | `docs/external-gateway.md`, "EKS / Cloud Deployment" | not run in this round |
| C5 | Online volume growth on EBS | `docs/storage.md` ("EBS CSI ≥ v1.5 … online without pod restart") | not run in this round |

## Part 2: failure drills

| Drill ID (`scripts/drill.sh`) | Real-world event | How it is injected | The question |
|---|---|---|---|
| `pod-kill` | the Postgres process or its container dies | force-delete the primary pooler pod (`--grace-period=0 --force`) | baseline: how long until writes succeed through the gateway again? |
| `node-drain` | planned maintenance: patching, scaling down | `kubectl drain` the primary's node, then `uncordon` | does a graceful drain hand the primary off with a shorter gap than a crash? Does the drain finish? |
| `node-terminate` | an EC2 instance fails or is reclaimed | `aws ec2 terminate-instances` on the primary's node | failover when the node disappears without warning; does the replacement node's pooler re-attach its EBS volume? |
| `az-down` | an availability zone outage | scale the zone's node group to 0, hold 4 minutes, scale back to 1 | does the shard keep taking writes on 2 of 3 zones? What happens to the cell whose EBS volume cannot leave the zone, and to the etcd members in that zone? |

The zone drill runs against two different zones, because the zones are not equal (finding F3):

- a zone holding **no** etcd member (`apse2-az1`): the clean case, where only one pooler is lost
- the zone holding **two of the three** etcd members (`apse2-az3`): the global topology loses quorum along with the zone

## Part 3: cost and capacity

| Measure | How |
|---|---|
| Commit latency with every commit confirmed in a second zone | from every run's acknowledged writes (p50, p99) |
| Total AWS cost of the round | the billing page, after teardown |

## Not in this round

- Managed node group version upgrade, Karpenter consolidation, a Network Load Balancer in front of the gateway, operator upgrades on a live cluster, and restores from the S3 backups. All are real EKS events worth testing; they come after these results.
- Performance tuning, load beyond 400 writes a second, or comparisons with other systems.
