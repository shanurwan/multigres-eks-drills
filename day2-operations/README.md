# day2-operations

Planned operations and slow problems on a busy Multigres cluster: a zone cut off from the network, a managed node group upgrade, a full primary volume grown online, a rolling Multigres upgrade and graceful switchovers. **Results: [`blog.md`](blog.md).**

This builds on [`../production-scenario`](../production-scenario/README.md): same EKS cluster, same load (supafirehose with 500 connections plus the drill writer), same collection. What's new is the operations, added to [`../failure-drill/scripts/drill.sh`](../failure-drill/scripts/drill.sh).

## The operations

| Drill | What `drill.sh` does | Settings |
|---|---|---|
| `az-partition` | gives the primary zone's subnet a new network ACL that allows its own subnet and the internet and denies the rest of the VPC, both ways. Starts a second writer (`ackcheck-iso`) inside that zone, through the zone's own gateway. Puts the original ACL back after `AZ_HOLD`, also on exit | `AZ_HOLD` (default 240 s) |
| `ng-upgrade` | creates a launch template version with the same settings for the primary zone's node group and starts the managed node group update. Polls it until it ends | |
| `disk-full` | `fallocate`s a file in the primary's `/var/lib/pooler` that leaves `FILL_LEAVE_MB` free, holds for `DISK_HOLD`, then patches the pool storage size in the `MultigresCluster` to `GROW_TO` and waits for the PVC. Removes the file after the run | `FILL_LEAVE_MB` (64), `DISK_HOLD` (180 s), `GROW_TO` (15Gi) |
| `mg-upgrade` | merge-patches `spec.images` of the `MultigresCluster` and waits until no pod runs an old image | `MG_IMAGE`, `PGCTLD_IMAGE`, `MULTIADMIN_WEB_IMAGE` |
| `switchover` | runs `multigres cluster switch-primary` in the multiadmin pod | |

Every drill records `timeline.txt`, the Shard's phase every few seconds, which pooler is primary before and after, events, pods and every component's log. The drill writer runs 8 connections × 50 inserts/s through the gateway and checks every acknowledged write afterwards.

## Run it

You need the cluster from [`../terraform/aws-setup.md`](../terraform/aws-setup.md), Multigres deployed as in [`../failure-drill/reproduce.md`](../failure-drill/reproduce.md), and the load tools from [`../production-scenario`](../production-scenario/README.md).

```bash
export AWS_PROFILE=multigres-lab AWS_REGION=ap-southeast-2 CONNS=500

WRITE_FOR=8m scripts/day2.sh az-partition 1
WRITE_FOR=12m scripts/day2.sh ng-upgrade 1
WRITE_FOR=12m FILL_LEAVE_MB=1 GROW_TO=20Gi scripts/day2.sh disk-full 1
WRITE_FOR=25m MG_IMAGE=ghcr.io/multigres/multigres@sha256:... \
  PGCTLD_IMAGE=ghcr.io/multigres/pgctld@sha256:... \
  MULTIADMIN_WEB_IMAGE=ghcr.io/multigres/multiadmin-web@sha256:... scripts/day2.sh mg-upgrade 1
WRITE_FOR=4m scripts/day2.sh switchover 1
```

Wait for the shard to be `Healthy` between runs. `TAG=<name>` adds a tag to the run name, as the runs on the new image do here (`storm-switchover-c500-a7e06a8-3`).

Then, from this folder:

```bash
python3 ../production-scenario/analysis/collect.py results   # runs.csv, series/, errors/
python3 analysis/day2.py                                     # day2.csv
python3 analysis/plot.py                                     # charts/ (needs matplotlib)
../failure-drill/scripts/scrub.sh                            # replaces the AWS account ID before publishing
```

## What `day2.py` adds

| Column | Definition |
|---|---|
| `shard_not_healthy_s` | seconds after the fault where `shard-timeline.txt` shows a phase other than `Healthy` |
| `cut_after_fault_line_s` | when the ACL swap returned, after the `fault:` line. The cut is measured from here |
| `iso_acked_1s_after_cut_or_later` | writes the inside writer had acknowledged 1 s or more after the cut. Earlier ones were in flight |
| `iso_first_ack_after_heal_s` | how long after the heal the inside writer could write again |
| `ng_update_s`, `ng_update_result` | from `describe-update` |
| `pooler_longest_not_ready_s` | longest time a pool showed fewer than all containers ready |
| `full_for_s`, `grow_took_s` | from filling the volume to the grow, and from the grow to the PVC reporting the new size |
| `rollout_s` | from the image patch to no pod on an old image |

## Validation

- **The fault happened.** Partition: `fault.txt` has the ACL and the swap time, and the inside writer stops within 67 ms. Node group: `ng-update.txt` ends `Successful` and the pooler's node changes. Disk: `disk-observe.txt` shows 0 bytes free. Upgrade: `rollout.txt` ends with 0 pods on old images, and `run.txt` of later runs shows the new digests. Switchover: `primary-before.txt` and `primary-after.txt` differ.
- **Everything was put back.** The partition ACL is restored and deleted, the fill file is removed, and the shard is `Healthy` before the next run.
- **The first disk-full run didn't fill the disk.** It left 64 MiB and Postgres used 25 MiB of it. It is kept and reported as such, and run 2 used 1 MiB.
- **Gateway log lines are not client errors.** "portal query execution failed" is logged for each internal retry. Client errors come only from supafirehose and the drill writer.
