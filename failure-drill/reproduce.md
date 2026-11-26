# Reproduce from a new AWS account

Everything here was run on an AWS free-plan account in `ap-southeast-2`. The cluster uses about USD 0.50 an hour of credit while it exists; a full round (deploy, all drills, teardown) takes about 4 hours. Destroy it at the end of every session (step 8).

Commands run from the repository root unless a step says otherwise. They work in bash on Linux and macOS, and in Git Bash on Windows.

## What you need

| Tool | Version used | Check |
|---|---|---|
| AWS CLI | v2 | `aws --version` |
| Terraform | 1.12 | `terraform version` |
| kubectl | 1.34 to 1.36 (within one minor version of the cluster) | `kubectl version --client` |
| openssl | any | `openssl version` |
| Python | 3.8+ (standard library) for the tables; with `matplotlib` for the charts | `python3 --version` |
| Go | only if you rebuild the write checker; `go.mod` asks for 1.27.4 and Go fetches it | `go version` |

## 1. AWS account and credentials (once)

1. Create an AWS account. The free plan is enough.
2. Turn on MFA for the root user, then stop using root.
3. In IAM, create a user for Terraform (here `multigres-terraform`), attach `AdministratorAccess`, and create an access key for "Command Line Interface".

   `AdministratorAccess` is broad on purpose: EKS creates IAM roles, so narrower managed policies are not enough. Use an account that holds nothing else. [`terraform/aws-setup.md`](../terraform/aws-setup.md) describes running Terraform from GitHub Actions with OIDC instead, with no long-lived keys.
4. Configure a profile in your own terminal (it asks for the key interactively):

   ```sh
   aws configure --profile multigres-lab          # region: ap-southeast-2 (or yours), output: json
   aws sts get-caller-identity --profile multigres-lab
   ```

   Do not paste the secret key into chat tools, issues or scripts. Delete the downloaded CSV afterwards.

```sh
export AWS_PROFILE=multigres-lab AWS_REGION=ap-southeast-2
```

## 2. Check the account can run this

```sh
# Kubernetes version in standard support (extended support costs about 6x per hour)
aws eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,versionStatus]' --output table

# Free-plan accounts can only launch some instance types; the default m7i-flex.large is one
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' --output table

# At least 3 availability zones
aws ec2 describe-availability-zones --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output table
```

## 3. Infrastructure (about 20 minutes)

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit: region, profile, owner, alert_email, admin_cidrs
curl -s https://checkip.amazonaws.com           # your IP, as <ip>/32 in admin_cidrs
terraform init
terraform plan -out tfplan                      # 76 resources
terraform apply tfplan
$(terraform output -raw kubeconfig_command)
kubectl get nodes -L topology.k8s.aws/zone-id   # one Ready node per zone
cd ..
```

## 4. Operator (about 1 minute)

```sh
kubectl apply --server-side -f failure-drill/results/_versions/operator-install.yaml
kubectl -n multigres-operator rollout status deploy/multigres-operator-controller-manager
```

`failure-drill/results/_versions/operator-install.yaml` is the exact manifest tested (SHA-256 in `operator-install.sha256`). To test a newer build, use `https://github.com/multigres/multigres-operator/releases/download/current/install.yaml` instead and record its digest.

## 5. Multigres cluster (about 5 minutes)

```sh
failure-drill/scripts/deploy.sh
```

It reads the zone IDs, backup bucket and backup role from the Terraform outputs, creates a random admin password as a Kubernetes Secret (never printed or written to disk), applies `failure-drill/manifests/cluster.yaml` and waits for `Healthy`. Then:

```sh
failure-drill/scripts/primary.sh                 # one pooler per zone, one of them primary
aws s3 ls "s3://$(terraform -chdir=terraform output -raw backup_bucket)/" --recursive | head   # backups through IRSA
```

## 6. Drills

Start the writer in a zone, then run drills one at a time or as a campaign:

```sh
failure-drill/scripts/writer.sh apse2-az1                     # builds the checker if needed
failure-drill/scripts/drill.sh pod-kill 1                     # about 10 minutes
failure-drill/scripts/campaign.sh "pod-kill:2 node-drain:1 node-terminate:1 az-down:1:apse2-az1"
```

Zone IDs differ by region; use the ones from `kubectl get nodes -L topology.k8s.aws/zone-id`. `campaign.sh` moves the writer out of the way of each drill. Each run writes `failure-drill/results/<drill>-<run>/`.

Before the zone drill against the zone holding two etcd members (if your cluster has one, see finding F3), run everything else first: it may leave the cluster needing manual repair.

## 7. Tables and charts

```sh
python3 failure-drill/analysis/collect.py        # -> results/runs.csv, results/series/
python3 failure-drill/analysis/plot.py           # -> results/charts/*.png (needs matplotlib)
failure-drill/scripts/scrub.sh                   # replaces the account ID before publishing
```

## 8. Tear down (do not skip)

```sh
kubectl -n multigres-demo delete multigrescluster demo --wait=true   # deletes its volumes (pvcDeletionPolicy: Delete)
kubectl get pv                                                       # should list nothing
aws s3 rm "s3://$(terraform -chdir=terraform output -raw backup_bucket)" --recursive
terraform -chdir=terraform destroy
aws ec2 describe-volumes --filters Name=tag:Project,Values=multigres-lab --query 'Volumes[].VolumeId'
```

Check the billing page the next day.

## Known problems and fixes

| Symptom | Cause | Fix |
|---|---|---|
| Node groups stay `CREATING` for more than 10 minutes; the Auto Scaling group's activity says `The specified instance type is not eligible for Free Tier` | free-plan accounts can only launch some instance types | use one from step 2 (the default `m7i-flex.large` is). If an apply is already stuck: `aws eks delete-nodegroup` for each, wait until they are gone (10 to 20 minutes), then `terraform plan` and `apply` again |
| The `MultigresCluster` is rejected: `no default StorageClass found in the cluster` | EKS 1.30 and later create no default StorageClass | `manifests/cluster.yaml` marks `multigres-gp3` as the default |
| Pool pods loop in `Init:CrashLoopBackOff` with `mkdir /var/lib/pooler/pgbackrest: permission denied` | finding F1 | `fsGroup: 999` on the pool (already in `cluster.yaml`); if the cluster was created without it, see finding F2 |
| A script prints nothing and hangs when run in the background | it is waiting for input | run it with `< /dev/null` |
| On Windows, `kubectl exec ... /ackcheck` fails with `C:/Program Files/Git/ackcheck` | Git Bash rewrites paths | the scripts set `MSYS_NO_PATHCONV=1`; do the same for commands you type |
