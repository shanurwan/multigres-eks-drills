# Findings

Problems found while deploying and running the drills, each with the evidence collected at the time. The folder of each finding holds that evidence.

| ID | Finding | Impact | Workaround |
|---|---|---|---|
| [F1](F1-pool-fsgroup-ebs/README.md) | Pool pods set no `fsGroup` by default, so on EBS the pooler cannot create its directories and never starts | the default cluster never becomes ready on EKS | set `fsGroup: 999` on every pool |
| [F2](F2-rollout-blocked-cannot-repair/README.md) | After the spec is fixed, the operator will not replace the broken pods, because a rollout waits for a primary that cannot exist | a cluster created with the F1 problem stays stuck after the fix | delete the pool pods by hand once |
| [F3](F3-etcd-not-spread-across-zones/README.md) | By default the operator-managed global etcd has no zone spread; two of three members (and their zonal EBS volumes) landed in one zone. The spec supports a spread (`globalTopoServer.placement`), but nothing sets or documents it | losing that zone loses etcd quorum | set `placement.topologySpreadConstraints` at creation |

A finding is reported upstream only after it reproduces on a fresh cluster, as one issue with the smallest setup that shows it.
