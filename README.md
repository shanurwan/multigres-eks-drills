# multigres-eks-drills

Failure drills for [Multigres](https://github.com/multigres/multigres) on Amazon EKS across three availability zones: what an application sees when a pod, a node or a whole zone fails, measured through the gateway, and whether the operator's documented EKS patterns work as written.

This is an independent test lab, not an official Multigres or Supabase project, and not a production reference architecture.

**Start with [`failure-drill/failure-drill.md`](failure-drill/failure-drill.md)**: the results, findings and what to check before running Multigres on EKS.

## Layout

| Path | What it is |
|---|---|
| [`terraform/`](terraform/) | the AWS infrastructure: VPC across 3 zones, EKS with one node group per zone, EBS CSI and backups through IRSA, a budget alarm |
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
