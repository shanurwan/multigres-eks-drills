# Reproduce from a new AWS account

Everything here works on an AWS free-plan account (tested in `ap-southeast-2`). It uses credits while the cluster exists, roughly USD 0.50 an hour, so destroy it at the end of every session.

## What you need

| Tool | Version used | Check |
|---|---|---|
| AWS CLI | v2 | `aws --version` |
| Terraform | 1.12 | `terraform version` |
| kubectl | within one minor version of the cluster (1.35) | `kubectl version --client` |
| Go | 1.21 or later, only to build the write checker; `go.mod` asks for 1.27.4 and Go downloads that toolchain itself | `go version` |

## 1. AWS account and credentials (once)

1. Create an AWS account. The free plan is enough.
2. Turn on MFA for the root user, then stop using root.
3. In IAM, create a user for Terraform (here `multigres-terraform`), attach `AdministratorAccess`, and create an access key for "Command Line Interface".

   `AdministratorAccess` is broad on purpose: EKS creates IAM roles, so narrower managed policies are not enough. Use an account that holds nothing else. [`aws-setup.md`](aws-setup.md) describes the alternative with no long-lived keys (GitHub Actions and OIDC).
4. In your own terminal (it prompts for input), configure a profile:

   ```sh
   aws configure --profile multigres-lab     # region: the one you will use, output: json
   aws sts get-caller-identity --profile multigres-lab
   ```

   Never paste the secret key into chat tools, issues or scripts. Delete the downloaded CSV once configured.

## 2. Check the account can run this

```sh
export AWS_PROFILE=multigres-lab AWS_REGION=ap-southeast-2

# The Kubernetes version must be in standard support. Extended support costs about 6x per hour.
aws eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,versionStatus]' --output table

# Free-plan accounts can only launch some instance types. The default, m7i-flex.large, is one of them.
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' --output table

# The region needs at least 3 availability zones.
aws ec2 describe-availability-zones --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output table
```

## 3. Create the infrastructure

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars     # then edit: region, profile, owner, alert_email, admin_cidrs
curl -s https://checkip.amazonaws.com             # your public IP, for admin_cidrs as <ip>/32
terraform init
terraform plan -out tfplan
terraform apply tfplan                            # about 20 minutes
$(terraform output -raw kubeconfig_command)
kubectl get nodes -L topology.k8s.aws/zone-id
```

Expect 76 resources and one node in each of the three zones.

## Known problems and fixes

| Symptom | Cause | Fix |
|---|---|---|
| Node groups stay `CREATING` for more than 10 minutes; the Auto Scaling group's activity says `The specified instance type is not eligible for Free Tier` | the account is on the free plan and the instance type is not on its list | use a type from the `free-tier-eligible=true` list (the default `m7i-flex.large` is). If an apply is already stuck: delete the node groups (`aws eks delete-nodegroup`), wait until they are gone (10 to 20 minutes), then `terraform plan` and `apply` again |
