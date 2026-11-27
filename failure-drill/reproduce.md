# Reproduce from a new AWS account

Everything here was run on an AWS free-plan account in `ap-southeast-2`. The cluster uses about USD 0.50 an hour of credit while it exists; a full round (deploy, all drills, teardown) takes about 4 hours. Destroy it at the end of every session (step 8).

Commands run from the repository root unless a step says otherwise. They work in bash on Linux and macOS, and in Git Bash on Windows.

## 1–3. Account, tools and cluster

Follow [`terraform/aws-setup.md`](../terraform/aws-setup.md). It goes from a new free-plan account to three Ready EKS nodes, one per zone, in about 45 minutes, with checks and fixes for the problems most likely to stop you. Come back here when `kubectl get nodes` shows three nodes.

Python 3.8+ (standard library) builds the tables in step 7, and `matplotlib` the charts. Go is needed only to rebuild the write checker: `go.mod` asks for 1.27.4, and Go fetches it.

In every new terminal:

```sh
export AWS_PROFILE=multigres-lab AWS_REGION=ap-southeast-2   # your profile and region
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
| Problems creating the account, the cluster or reaching it with kubectl | | see [`terraform/aws-setup.md`](../terraform/aws-setup.md#7-if-something-goes-wrong) |
| The `MultigresCluster` is rejected: `no default StorageClass found in the cluster` | EKS 1.30 and later create no default StorageClass | `manifests/cluster.yaml` marks `multigres-gp3` as the default |
| Pool pods loop in `Init:CrashLoopBackOff` with `mkdir /var/lib/pooler/pgbackrest: permission denied` | finding F1 | `fsGroup: 999` on the pool (already in `cluster.yaml`); if the cluster was created without it, see finding F2 |
| A script prints nothing and hangs when run in the background | it is waiting for input | run it with `< /dev/null` |
| On Windows, `kubectl exec ... /ackcheck` fails with `C:/Program Files/Git/ackcheck` | Git Bash rewrites paths | the scripts set `MSYS_NO_PATHCONV=1`; do the same for commands you type |
