# Drills

Each drill answers one question an operator team needs answered before running Multigres on EKS, and each one is tied to something specific: a claim in the multigres-operator docs, an open issue, or a failure every EKS user meets. The result of each drill is a number, a log excerpt and, where something breaks, a reproduction small enough to run again.

Versions are recorded per run (operator image digest, multigres commit, EKS version, EBS CSI version), because Multigres is alpha and results only hold for the version tested.

## Layout under test

- 3 cells, one per availability zone, pinned by zone ID (`topology.k8s.aws/zone-id`)
- 1 pooler per cell, durability `MULTI_CELL_AT_LEAST_2`: every commit is confirmed in a second zone
- one EKS managed node group per zone, so a zone can be taken away on purpose
- gp3 volumes through the EBS CSI driver, `WaitForFirstConsumer`, expansion allowed
- pgBackRest backups to S3 through IRSA
- the writer (`tools/ackcheck`) runs in a zone that is not being broken, and connects through the gateway

## What every failure drill records

| Measure | Why it matters |
|---|---|
| Acknowledged writes lost | the durability promise; expected 0 |
| Longest gap with no successful write | what an application experiences as the outage |
| Errors clients saw, by SQLSTATE and count | whether clients can tell "retry" from "give up" (see multigres#1728) |
| Seconds to a new primary | multiorch's part |
| Seconds until the Shard reports `Healthy` | whether the operator's status matches reality, in both directions |
| What happened to the pooler in the broken node or zone | Pending reason, volume re-attachment, time until that cell is back |

Each failure drill runs 3 times. A run that shows something unexpected keeps its logs (operator, multiorch, gateway, events) before anything is cleaned up.

## Part 1: do the documented EKS patterns work as written

These are claims in the operator docs that only a real EKS cluster can confirm. Each gets a pass/fail with the exact steps and any correction the docs need.

| Check | Source | How |
|---|---|---|
| C1 Install from scratch with server-side apply | README; #532 | follow the README install on EKS, record anything that differs |
| C2 Cells pinned by zone ID land in the right zone | operator cell topology docs | 3 cells by zone ID; check each pooler's node and volume zone |
| C3 Backups to S3 through IRSA | `docs/backup-restore.md` (IRSA "recommended for EKS") | the documented ServiceAccount annotation only, no static keys; confirm backup files in S3 |
| C4 Gateway reachable through an Elastic IP with `externalIPs` | `docs/external-gateway.md` "EKS / Cloud Deployment" | follow the section as written from outside the cluster; record the extra AWS steps it leaves to the administrator |
| C5 Online volume growth on EBS | `docs/storage.md` ("EBS CSI ≥ v1.5 ... online without pod restart") | raise the pool's storage size while the writer runs; record whether any pod restarts and any write gap |

## Part 2: failure drills

| Drill | Real-world event | How | The question |
|---|---|---|---|
| D1 Primary pod crash | process or container dies | force-delete the primary pod | baseline failover time through the gateway |
| D2 Planned node drain | node patching | `kubectl drain` the primary's node | does the operator's drain hand off the primary cleanly, with a smaller gap than D1? |
| D3 Sudden node loss | EC2 instance failure | terminate the primary's instance | failover when the node disappears without a drain; does the replacement node's pooler re-attach its gp3 volume? |
| D4 Whole zone down | AZ outage | scale the primary's zone node group to 0, wait, scale back | does the shard keep taking writes on 2 of 3 cells? An EBS volume cannot leave its zone, so that cell stays down: for how long, and does it rejoin cleanly? |
| D5 Managed node group upgrade | EKS version or AMI upgrade, every EKS user, several times a year | start a version or AMI update on the primary's zone node group | EKS evicts pods within a fixed time, honouring PodDisruptionBudgets, and then gives up or forces. Does the operator's drain finish inside that window? |
| D6 Operator upgrade on a live cluster | release day | install v0.11.1, create the cluster, upgrade the operator to the current release while the writer runs | does the #850 upgrade path work on EKS once worked around, and do clients notice the operator upgrade at all? |

## Part 3: what it costs to run

| Measure | How |
|---|---|
| Commit latency with `MULTI_CELL_AT_LEAST_2` across zones (p50/p95/p99) at 100, 500 and 1,000 writes/s | ackcheck at fixed rates, no faults |
| Cross-zone traffic at each rate, in GB/hour and USD/month at AWS's inter-AZ price | VPC flow or node network counters for the run |
| Total AWS cost of the whole project | the billing page, the day after teardown |

## What comes out

- `results/`: one folder per run with the checker's summary, the timeline and the logs.
- A results page: the Part 1 table with pass/fail and doc corrections, the drill table with numbers, and the cost table.
- For anything that breaks: a reproduction on the smallest setup that shows it, written up so a maintainer can run it without this repo. Each one is offered upstream as a single issue, only after it reproduces twice.

## Out of scope

- Karpenter consolidation and an NLB in front of the gateway. Both are real EKS patterns; they come after the core drills, if at all.
- Performance tuning or comparisons with other systems.
- Anything that needs a production account. The cluster is a throwaway, destroyed after each session.
