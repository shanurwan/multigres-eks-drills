# AWS account, IAM and GitHub Actions for the EKS lab

Optional. The runbook applies `terraform/` from a laptop; this is the layout for running the same infrastructure from GitHub Actions instead, split into separate states, with no long-lived AWS keys.

Goal: all infrastructure is Terraform, split into several states, and only GitHub Actions applies it. No long-lived AWS keys anywhere.

## 0. The account (do once, by hand)

1. Turn on MFA for the root user. Never create root access keys. Do not use root after this step.
2. Create one admin identity for yourself (IAM Identity Center user, or an IAM user with MFA). You need it only for the bootstrap in step 2 and for reading things in the console.
3. Billing:
   - set up AWS Budgets alerts at $20, $50 and $80 to your email
   - turn on Cost Anomaly Detection
   - check how much credit is left, and the plan's end date, on the Billing page
4. Check what the free plan allows before relying on it. Credits run out faster than you expect with EKS, and a free-plan account may close at the end of the period unless upgraded. If EKS turns out to be blocked on the free plan, upgrading to the paid plan keeps the credits.

**Rough cost:** EKS control plane about $0.10/hour, plus 3 nodes (one per AZ), plus small EBS and S3, plus public IPv4 addresses. Expect around $0.40–0.60/hour. **$100 is roughly 170–250 cluster-hours**, so destroy every evening (the nightly destroy workflow below does it for you).

## 1. Repository layout (one repo, several states)

```
infra/
  bootstrap/          # applied ONCE from your laptop with the admin identity
  stacks/
    10-network/       # VPC, 3 public subnets (one per AZ), no NAT
    20-eks/           # EKS, one node group per AZ, EBS CSI (IRSA), gp3 StorageClass, access entries
    30-backups/       # S3 bucket for backups + IRSA role for the backup service account
    40-platform/      # optional: cert-manager, operators via helm/kubernetes providers
.github/workflows/
  plan.yml   apply.yml   destroy.yml
```

- **Separate state for each stack,** all in one S3 bucket, key `stacks/<name>/terraform.tfstate`.
- **Locking:** use S3 native locking (`use_lockfile = true`, Terraform 1.10+), so no DynamoDB table is needed.
- **Passing values between stacks:** later stacks read earlier ones with `terraform_remote_state` (e.g. 20-eks reads the subnet IDs from 10-network).
- **Destroy order:** the reverse of apply (40 → 30 → 20 → 10).

## 2. Bootstrap (the only local apply)

`infra/bootstrap` creates what GitHub Actions needs before it can do anything:

1. **The state bucket:** versioning on, default encryption, all public access blocked, and a bucket policy that denies non-TLS access. Keep this bucket out of any stack that gets destroyed.
2. **The GitHub OIDC identity provider:** URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
3. **Two roles that GitHub Actions can assume:**
   - **`gha-plan`**
     - permissions: `ReadOnlyAccess`, plus read/write on the state bucket (the plan writes the lock file)
     - trust: only pull requests from your repo
   - **`gha-apply`**
     - permissions: `AdministratorAccess` is the pragmatic choice for a dedicated lab account. EKS creates IAM roles, so `PowerUserAccess` is not enough. The account holds nothing else, and the trust policy plus a protected environment is the real gate.
     - trust: only jobs running in the GitHub environment `aws-lab` of your repo

Trust policy condition for `gha-apply` (the shape):

```json
"Condition": {
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": "repo:shanurwan/<repo>:environment:aws-lab"
  }
}
```

For `gha-plan`, `sub` is `repo:shanurwan/<repo>:pull_request`.

Check the real `sub` format before you trust it:
- **When a job uses an environment, `sub` is the environment form, not the branch form.**
- Some repositories get GitHub's immutable form (`repo:<owner>@<owner-id>/<repo>@<repo-id>:...`). If this one does, the condition must match that.
- How to check: run one debug job that prints the decoded token claims, or read the exact `sub` from the first failed assume-role error, then fix the trust policy.

After the bootstrap, remove or disable any access keys you used. Everything from here is GitHub Actions.

## 3. GitHub settings

**Environment `aws-lab`** (Settings → Environments):
- **Required reviewer:** you. Every apply waits for your click.
- **Deployment branches:** `main` only.

**Variables** (Settings → Secrets and variables → Actions → Variables; none of these are secret):
- `AWS_REGION`, e.g. `ap-southeast-1`
- `AWS_ROLE_PLAN_ARN`, the ARN of `gha-plan`
- `AWS_ROLE_APPLY_ARN`, the ARN of `gha-apply`
- `TF_STATE_BUCKET`, the state bucket name

**Secrets** (only things you'd rather not show publicly):
- `ADMIN_CIDR`: your public IP /32, for the EKS API endpoint allowlist
- `ALERT_EMAIL`: for budget or alarm emails, if a stack needs it

**No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY`.** OIDC replaces them.

## 4. Workflows

All three need `permissions: { id-token: write, contents: read }` and use `aws-actions/configure-aws-credentials` with `role-to-assume`. Pin actions to a commit SHA.

| Workflow | Trigger | Role | What it does |
|---|---|---|---|
| `plan.yml` | pull request | `gha-plan` | `fmt -check`, `validate`, `plan` for each changed stack; posts the plan as a PR comment |
| `apply.yml` | push to `main` | `gha-apply`, environment `aws-lab` | applies stacks in order 10 → 20 → 30 → 40, each with its own backend key |
| `destroy.yml` | manual (with a "type DESTROY" input) and a nightly schedule | `gha-apply`, environment `aws-lab` | destroys 40 → 30 → 20 → 10; keeps the bootstrap |

- **Nightly destroy, e.g. `0 15 * * *` = 23:00 Malaysia time.** It's what keeps the $100 alive. Keep the bootstrap and the backup bucket's state outside what it destroys, or empty the bucket first.
- **Concurrency:** add `concurrency: { group: terraform-${{ matrix.stack }}, cancel-in-progress: false }` so two runs never apply the same state at once.

## 5. Things that bite on EKS

- **Cluster access:** with the apply role as the cluster creator, add an access entry for your own admin identity too. Otherwise you can't run `kubectl` from your laptop for the drills.
- **Zones:** use zone IDs (`apse1-az1`) for Multigres cells; read them from the `aws_availability_zones` data source in 10-network.
- **Destroy order:** delete the Multigres cluster (and its PVCs) before `terraform destroy` on 20-eks, or the EBS volumes outlive the cluster and keep costing.
- **Load balancers:** anything that created one (an NLB for the gateway) must be deleted inside Kubernetes first, or the VPC destroy hangs on its network interfaces.
- **Versions:** pick a Kubernetes version in standard support. Older versions in extended support cost far more per hour.

## 6. What to keep out of the public repo

- **No account IDs.** Put the role ARNs in variables, not in the code.
- **No IP addresses.** `ADMIN_CIDR` goes in a secret.
- **No `.tfvars` with personal values.** Commit only a `.tfvars.example`.
