# From a new AWS account to a running EKS cluster

This guide takes you from no AWS account to three EKS nodes in three availability zones, ready for the Multigres drills. It follows what we did on a new free-plan account. Expect about 45 minutes, most of it waiting for EKS.

When `kubectl get nodes` shows three nodes, carry on with [step 4 of the reproduce guide](../failure-drill/reproduce.md#4-operator-about-1-minute).

## Before you start: what it costs

- **EKS is not part of the free tier, but free-plan credits pay for it.** A new account gets promotional credits, and this lab spends them at about **USD 0.50 an hour** while the cluster exists. That covers the EKS control plane (USD 0.10), three `m7i-flex.large` nodes, public IPv4 addresses, small gp3 volumes and logs.
- A full round (cluster up, every drill, teardown) takes about 4 hours, so about USD 2.
- **Destroy the cluster at the end of every session** (step 8). A cluster you forget overnight costs more than the whole round.
- Terraform also creates a monthly AWS Budget, in case you do forget. It emails you when actual spend passes 50% of `budget_usd` (default USD 40), and when the month's forecast passes 100%.

## 1. Create the account

1. Sign up at <https://aws.amazon.com/free/> and choose the **free plan**. A card is needed for verification. You are not charged while credits last.
2. Wait for the email saying the account is ready. Some services stay blocked for a few minutes after sign-up.
3. Sign in as the root user, open **IAM → Dashboard**, and **add MFA for the root user**.
4. Open **Billing and Cost Management → Credits** and note how much credit you have and when it expires.

## 2. Create a user for Terraform

You will not use root again. Create one IAM user that Terraform and kubectl run as.

1. **IAM → Users → Create user**. Name it `multigres-terraform`. Leave console access unticked.
2. **Permissions:** choose *Attach policies directly* and tick **`AdministratorAccess`**.

   That's broad on purpose. EKS and its add-ons create IAM roles, and the narrower managed policies can't do that. Keep this account for the lab and nothing else.
3. Open the new user, then **Security credentials → Create access key → Command Line Interface (CLI)**. Tick the confirmation and create it.
4. Keep the page open, or download the CSV. You need both values once, in step 4, and AWS never shows the secret again.

Never paste the secret key into chat tools, issues, commits or scripts. You type it into `aws configure` and nowhere else.

## 3. Install the tools

| Tool | Version | macOS (Homebrew) | Linux | Windows |
|---|---|---|---|---|
| AWS CLI | v2 | `brew install awscli` | [installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | [MSI installer](https://awscli.amazonaws.com/AWSCLIV2.msi) |
| Terraform | 1.10 or later | `brew install hashicorp/tap/terraform` | [packages](https://developer.hashicorp.com/terraform/install) | `winget install Hashicorp.Terraform` |
| kubectl | within one minor version of the cluster (1.34–1.36) | `brew install kubectl` | [binary](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) | `winget install Kubernetes.kubectl` |
| git, openssl, Python 3.8+ | any | preinstalled or `brew install` | your package manager | [Git for Windows](https://git-scm.com/download/win) includes openssl and Git Bash; Python from [python.org](https://www.python.org/downloads/) |

On Windows, run every command in this repository from **Git Bash**, not PowerShell or cmd.

Check the tools are installed:

```sh
aws --version && terraform version && kubectl version --client && git --version
```

## 4. Connect the CLI to your account

```sh
aws configure --profile multigres-lab
#   AWS Access Key ID:     <from step 2>
#   AWS Secret Access Key: <from step 2>
#   Default region name:   ap-southeast-2      (or another region, see step 5)
#   Default output format: json

aws sts get-caller-identity --profile multigres-lab
```

The last command should print an ARN ending in `user/multigres-terraform`. If it does, delete the downloaded CSV.

Set these in every new terminal you use for the lab:

```sh
export AWS_PROFILE=multigres-lab AWS_REGION=ap-southeast-2
```

## 5. Check your account can run the lab

Three quick checks before you apply anything. The second one is the problem that cost us most time.

```sh
# 1. The region has at least 3 availability zones (the lab puts one cell in each)
aws ec2 describe-availability-zones --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output table

# 2. m7i-flex.large is allowed. Free-plan accounts can only launch some instance types,
#    and a node group with any other type sits in CREATING for a long time and then fails.
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].InstanceType' --output text | tr '\t' '\n' | grep -x m7i-flex.large

# 3. Kubernetes 1.35 is in standard support (extended support costs about 6 times more per hour)
aws eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,versionStatus]' --output table
```

If check 2 prints nothing, pick another type from the full list (2 vCPU and 8 GiB is enough) and set `instance_type` in step 6. If 1.35 has left standard support, set `kubernetes_version` to one that is in it.

## 6. Create the cluster (about 20 minutes)

```sh
git clone https://github.com/shanurwan/multigres-eks-drills
cd multigres-eks-drills/terraform
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com       # your public IP, for admin_cidrs
```

Edit `terraform.tfvars`:

```hcl
region      = "ap-southeast-2"        # the region you checked in step 5
profile     = "multigres-lab"
owner       = "your-name"             # a tag on every resource
alert_email = "you@example.com"       # budget alerts go here
admin_cidrs = ["198.51.100.7/32"]     # the IP from checkip, with /32
```

`admin_cidrs` is the only address allowed to reach the cluster's API. Your IP stays out of the repository, because `terraform.tfvars` is ignored by git.

Then apply it:

```sh
terraform init
terraform plan -out tfplan                  # should say: 76 to add
terraform apply tfplan
```

When it finishes, point kubectl at the cluster:

```sh
$(terraform output -raw kubeconfig_command)
kubectl get nodes -L topology.k8s.aws/zone-id
cd ..
```

You should see three `Ready` nodes, each in a different zone ID. The IAM user that ran Terraform is the cluster's admin, so kubectl works straight away.

**Next:** [step 4 of the reproduce guide](../failure-drill/reproduce.md#4-operator-about-1-minute) installs the operator, deploys Multigres and runs the drills.

## 7. If something goes wrong

| What you see | Why | What to do |
|---|---|---|
| `terraform plan` says `No valid credential sources found` or `ExpiredToken` | the profile isn't set in this terminal | `export AWS_PROFILE=multigres-lab`, or check `profile` in `terraform.tfvars` |
| Node groups stay `CREATING` for over 10 minutes; the Auto Scaling group's activity says `The specified instance type is not eligible for Free Tier` | the account can't launch that instance type | set `instance_type` to one from step 5. If an apply is already stuck, run `aws eks delete-nodegroup` for each group, wait until they are gone (10 to 20 minutes), then `terraform plan` and `apply` again |
| `VcpuLimitExceeded` | the account's on-demand vCPU quota is below the 6 vCPU the three nodes need | request more in **Service Quotas → Amazon EC2 → Running On-Demand Standard instances**, then apply again |
| `kubectl` times out (`dial tcp ... i/o timeout`) | your public IP changed since you set `admin_cidrs` | update `admin_cidrs` with the new IP, then `terraform apply` |
| `kubectl` says `You must be logged in to the server (Unauthorized)` | kubectl is using a different AWS identity from the one that created the cluster | rerun the `kubeconfig_command` with the same profile Terraform used |
| `terraform destroy` hangs on the VPC or subnets | something in Kubernetes created a load balancer or volumes that still exist | delete the Multigres cluster first (step 8), then `terraform destroy` again |

## 8. Tear down at the end of every session

From the repository root:

```sh
kubectl -n multigres-demo delete multigrescluster demo --wait=true   # also deletes its EBS volumes
kubectl get pv                                                       # should list nothing
aws s3 rm "s3://$(terraform -chdir=terraform output -raw backup_bucket)" --recursive
terraform -chdir=terraform destroy
aws ec2 describe-volumes --filters Name=tag:Project,Values=multigres-lab --query 'Volumes[].VolumeId'   # should be []
```

The next day, check **Billing and Cost Management → Bills**, to confirm nothing is still running.

When you are done with the lab for good, also delete the access key: **IAM → Users → multigres-terraform → Security credentials → Actions → Delete**.
