# terraform

AWS infrastructure for the drills. To create it from a new AWS account, follow [`aws-setup.md`](aws-setup.md).

## What it creates (76 resources)

| Part | Details | Why |
|---|---|---|
| VPC | `10.42.0.0/16`, one public subnet per zone, internet gateway, no NAT gateway | three zones to break independently; no NAT keeps a lab cheap (production would use private subnets) |
| EKS | Kubernetes 1.35, API reachable only from `admin_cidrs`, secrets encrypted with a KMS key, control-plane logs to CloudWatch | a version in standard support; nothing public by default |
| Node groups | one managed node group per zone, 1 node each (`m7i-flex.large`, 2 vCPU, 8 GiB) | a zone can be removed by scaling its group to 0 |
| EBS CSI driver | EKS add-on with an IRSA role | gp3 volumes for etcd and Postgres |
| Backups | S3 bucket (public access blocked), IAM role usable only by the `multigres-backup` ServiceAccount | pgBackRest without static keys |
| Budget | monthly budget with email alerts | a lab left running is the most likely cost |

## Variables

| Variable | Default | Notes |
|---|---|---|
| `region` | (required) | needs 3 availability zones |
| `profile` | none | AWS CLI profile |
| `owner` | (required) | tag value |
| `alert_email` | (required) | budget alerts |
| `admin_cidrs` | (required) | who may reach the EKS API, e.g. your IP `/32` |
| `kubernetes_version` | `1.35` | must be in EKS standard support |
| `instance_type` | `m7i-flex.large` | allowed on free-plan accounts; `m6i.large` is not |
| `budget_usd` | `40` | monthly |
| `name` | `multigres-lab` | prefix for every resource |

## Cost

About USD 0.50 an hour while it exists in `ap-southeast-2`: the EKS control plane (USD 0.10), three nodes, public IPv4 addresses, small gp3 volumes and logs. The KMS key costs about USD 1 a month until deleted. Destroy it after every session.
