# Multigres on EKS: failure drills

Goal: run Multigres across 3 availability zones on EKS, break it the way AWS breaks things, and measure what clients see.

Cost: about USD 0.50/hour while the cluster exists. Plan 4–6 hours, then destroy it.

## 0. Before you start

- Use a dedicated account or at least a dedicated, throwaway cluster, never a shared one.
- Choose a region with 3 AZs (for example `ap-southeast-1`).
- Find your public IP for `admin_cidrs` (for example `curl -s ifconfig.me`).
- Keep account IDs, cluster ARNs and company names out of anything you publish.

## 1. Create the cluster (about 15 min)

Check the Kubernetes version is in standard support (extended support costs about 6 times more per hour):

```sh
aws eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,versionStatus]' --output table
```

```sh
cd terraform
terraform plan -out tfplan \
  -var region=ap-southeast-1 -var profile=<aws-profile> -var owner=<you> \
  -var alert_email=<email> -var 'admin_cidrs=["<your-ip>/32"]'
terraform apply tfplan
terraform output            # note zone_ids, backup_bucket, backup_role_arn, node_groups
$(terraform output -raw kubeconfig_command)
```

Check: one node per AZ, and each node has its zone ID label.

```sh
kubectl get nodes -L topology.k8s.aws/zone-id,topology.kubernetes.io/zone
```

## 2. Install the operator

```sh
kubectl apply --server-side -f https://github.com/multigres/multigres-operator/releases/download/current/install.yaml
kubectl -n multigres-operator rollout status deploy/multigres-operator-controller-manager
```

## 3. Create the Multigres cluster

In `manifests/cluster.yaml`, replace `ZONE_ID_1..3` with the `zone_ids` output, `BACKUP_BUCKET`, `AWS_REGION` and `BACKUP_ROLE_ARN` with theirs, and `CHANGE_ME` with a password. Then:

```sh
kubectl apply -f manifests/cluster.yaml
kubectl -n multigres-demo get shards -w        # wait for Healthy
kubectl -n multigres-demo get pods -o wide     # one pooler per AZ, each on its own node
```

The layout is 3 cells (one per AZ), 1 pooler per cell, `MULTI_CELL_AT_LEAST_2`, gp3 volumes and S3 backups through IRSA.

Check backups reach S3:

```sh
aws s3 ls s3://<backup_bucket>/multigres-demo/ --recursive | head
```

## 4. Start the writer

Build the checker once (static Linux binary):

```sh
(cd tools/ackcheck && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../../ackcheck .)
```

Then copy it into a pod in the cluster:

```sh
kubectl -n multigres-demo run ackcheck --image=alpine:3.20 --restart=Never --command -- sleep 86400
kubectl -n multigres-demo cp ackcheck ackcheck:/ackcheck
kubectl -n multigres-demo exec ackcheck -- chmod +x /ackcheck
DSN='postgres://postgres:<password>@demo-multigateway:5432/postgres?sslmode=disable'
```

For each drill, start a 5-minute run, inject the fault at about 60 s, and verify afterwards:

```sh
RUN=az-1
kubectl -n multigres-demo exec ackcheck -- sh -c "nohup /ackcheck run -dsn '$DSN' -run $RUN -workers 8 -rate 50 -timeout 2s -duration 5m -out /tmp > /tmp/$RUN.log 2>&1 &"
# ... inject the fault ...
kubectl -n multigres-demo exec ackcheck -- /ackcheck verify -dsn "$DSN" -run $RUN -out /tmp
kubectl -n multigres-demo cp ackcheck:/tmp ./results-$RUN
```

Before a zone or node drill, check `kubectl get pod ackcheck -o wide` so the writer isn't running in the zone you are about to break.

Find the primary pooler:

```sh
for p in $(kubectl -n multigres-demo get pods -l app.kubernetes.io/component=shard-pool -o name); do
  echo "$p $(kubectl -n multigres-demo exec ${p#pod/} -c postgres -- env PGPASSWORD=<password> psql -h /var/lib/pooler/pg_sockets -U postgres -Atc 'select pg_is_in_recovery()')"
done   # f = primary
```

## 5. The drills (3 runs each)

| # | Fault | How |
|---|---|---|
| D1 | primary pod crash | `kubectl -n multigres-demo delete pod <primary> --grace-period=0 --force` |
| D2 | planned node maintenance | `kubectl drain <primary's node> --ignore-daemonsets --delete-emptydir-data`, then `kubectl uncordon` |
| D3 | sudden node loss | `aws ec2 terminate-instances --instance-ids <primary's node instance>` (the node group replaces it in the same AZ) |
| D4 | whole AZ down | `aws eks update-nodegroup-config --cluster-name multigres-lab --nodegroup-name <primary's AZ group> --scaling-config minSize=0,maxSize=2,desiredSize=0`, wait 5 min, then set it back to 1 |

For every run, record:

- from `verify`: acknowledged, lost (should be 0), failed, ambiguous, longest outage
- seconds until a new primary (writes resume)
- seconds until the Shard is `Healthy` again (`kubectl get shard -w` with timestamps)
- what happened to the pooler in the broken node/AZ: Pending? on which reason (`kubectl describe pod`)? Did its gp3 volume reattach after the node came back?

D4 is the one to watch closely. An EBS volume lives in one AZ, so the pooler there cannot move to another zone. Note how long that cell stays down, and whether the shard stays writable with 2 of 3 cells.

## 6. Tear down (do not skip)

```sh
kubectl -n multigres-demo delete multigrescluster demo     # PVCs are deleted with it
kubectl get pv                                             # should be empty
terraform destroy -var region=... (same -var flags as plan)
aws ec2 describe-volumes --filters Name=tag:Project,Values=multigres-lab --query 'Volumes[].VolumeId'
```

If anything is left over (volumes, load balancers), delete it by hand and check the bill the next day.
