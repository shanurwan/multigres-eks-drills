# multigres-eks-drills

Failure drills for [Multigres](https://github.com/multigres/multigres) on Amazon EKS across three availability zones: what clients see when a pod, a node or a whole zone fails, measured through the gateway, and whether the operator's documented EKS patterns work as written.

This is an independent test lab, not an official Multigres or Supabase project, and not a production reference architecture.

## The setup

| Choice | Why |
|---|---|
| 3 cells, one per availability zone, pinned by zone ID | zone IDs (`apse1-az1`) are the same physical zone in every AWS account; zone names are not |
| `MULTI_CELL_AT_LEAST_2` durability | every commit is confirmed in a second zone, so losing a zone should lose no acknowledged write |
| One EKS managed node group per zone | lets a whole zone be taken away on purpose |
| gp3 through the EBS CSI driver, `WaitForFirstConsumer` | EBS volumes are zonal: the volume must be created where its pod is scheduled |
| pgBackRest backups to S3 through IRSA | no long-lived keys in the cluster |
| Public subnets, no NAT gateway | keeps a throwaway lab cheap; production would use private subnets |

## Contents

| Path | What it is |
|---|---|
| `terraform/` | VPC, EKS, one node group per zone, EBS CSI with IRSA, S3 backup bucket and role, budget alarm |
| `manifests/cluster.yaml` | the gp3 StorageClass, backup ServiceAccount and the 3-cell MultigresCluster |
| `tools/ackcheck/` | the writer: inserts through the gateway, records every acknowledged write and every error, then verifies which acknowledged writes survived |
| `docs/drills.md` | what is tested and why: documented EKS patterns, failure drills, cost |
| `docs/runbook.md` | step-by-step commands, from `terraform apply` to teardown |
| `docs/aws-setup.md` | account, IAM and GitHub OIDC setup, with no long-lived AWS keys |
| `results/` | one folder per run |

## Running it

Follow [`docs/runbook.md`](docs/runbook.md). The cluster costs roughly USD 0.40 to 0.60 an hour while it exists; destroy it at the end of every session.
