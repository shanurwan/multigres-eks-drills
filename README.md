# multigres-eks-drills

Failure drills for [Multigres](https://github.com/multigres/multigres) on Amazon EKS across three availability zones: what an application sees when a pod, a node or a whole zone fails, measured through the gateway, and whether the operator's documented EKS patterns work as written.

This is an independent test lab, not an official Multigres or Supabase project, and not a production reference architecture.

**Start with [`failure-drill/failure-drill.md`](failure-drill/failure-drill.md)**: the results, findings and what to check before running Multigres on EKS.

**What a Supabase-style app sees** during a failover, with Multigres's own load tool and Supabase Auth: [`production-scenario/scenario.md`](production-scenario/scenario.md).

**Do the backups restore, completely?** [`restore-check/`](restore-check/README.md).

**Day-2 operations under load**: a zone cut off from the network, node group upgrades, a full disk grown online, a rolling upgrade and switchovers: [`day2-operations/blog.md`](day2-operations/blog.md).

**Under a service mesh**: Multigres with Istio ambient and STRICT mTLS: [`mesh-istio-ambient/`](mesh-istio-ambient/README.md).

**To run it yourself**, you need only an AWS free-plan account. Follow [`terraform/aws-setup.md`](terraform/aws-setup.md) to get a cluster, then [`failure-drill/reproduce.md`](failure-drill/reproduce.md) for the drills.

## Layout

| Path | What it is |
|---|---|
| [`terraform/`](terraform/) | the AWS infrastructure: VPC across 3 zones, EKS with one node group per zone, EBS CSI and backups through IRSA, a budget alarm |
| [`terraform/aws-setup.md`](terraform/aws-setup.md) | from a new AWS free-plan account to a running 3-zone EKS cluster, step by step |
| [`failure-drill/failure-drill.md`](failure-drill/failure-drill.md) | summary: results, charts, findings, readiness checklist, limits |
| [`failure-drill/methodology.md`](failure-drill/methodology.md) | system under test, workload, how one run works, what is measured |
| [`failure-drill/scenarios.md`](failure-drill/scenarios.md) | every check and drill, the real-world event behind it, and the question it answers |
| [`failure-drill/failure-modes.md`](failure-drill/failure-modes.md) | how the system can fail, the expected behaviour, and what covers each case |
| [`failure-drill/validation.md`](failure-drill/validation.md) | how each fault is proven applied, checks on the harness, mistakes found |
| [`failure-drill/observability.md`](failure-drill/observability.md) | what is recorded per run and how to read a failover from it |
| [`failure-drill/findings/`](failure-drill/findings/) | problems found, each with evidence, cause, workaround and suggested fix |
| [`failure-drill/reproduce.md`](failure-drill/reproduce.md) | from a new AWS free-plan account to teardown, with known problems |
| `failure-drill/scripts/` | deploy, writer, drill, campaign, primary, scrub |
| `failure-drill/manifests/` | the 3-zone `MultigresCluster` and the writer pod |
| `failure-drill/tools/ackcheck/` | the write checker (Go): records every write, verifies every acknowledged write afterwards |
| `failure-drill/analysis/` | raw runs to CSV (`collect.py`), CSV to charts (`plot.py`) |
| `failure-drill/results/` | one folder per run, `runs.csv`, per-second series, charts, tested versions |
| [`production-scenario/scenario.md`](production-scenario/scenario.md) | reconnect storm (supafirehose, 500 and 2,000 connections) and Supabase Auth logins through a primary pod kill: results, findings P1–P4 |
| [`production-scenario/`](production-scenario/README.md) | how those runs work, what is measured, validation, reproduce |
| [`restore-check/`](restore-check/README.md) | restores the pgBackRest backup from S3 and checks every acknowledged write against live; point-in-time restore; how far behind a quiet database's backup can be |
| [`day2-operations/blog.md`](day2-operations/blog.md) | a zone cut off from the VPC, managed node group upgrades, a full primary volume grown online, a rolling Multigres upgrade and switchovers, under the production-scenario load: results, findings D1–D6 |
| [`day2-operations/`](day2-operations/README.md) | how those runs work, the settings, `day2.py` columns, validation |
| [`mesh-istio-ambient/`](mesh-istio-ambient/README.md) | Multigres under Istio ambient: what enrollment and STRICT mTLS need, latency, and the stuck-standby problem seen after primary kills in the mesh |
