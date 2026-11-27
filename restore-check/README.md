# restore-check

Do Multigres's backups actually restore, with every acknowledged write in them? This restores the shard's pgBackRest backup from S3 into a throwaway pod and checks the result, row for row, against the live cluster.

Multigres has `multigres cluster verify-backups`, which runs `pgbackrest verify`. That checks the files in the repository are intact. It doesn't restore anything, so it can't say whether the data is complete, how long a restore takes, or how recent the restored data is. This answers those three, for the cluster in [`../failure-drill`](../failure-drill/failure-drill.md) after a day of failure drills.

## Summary

| Measure | Restore to the latest point | Point-in-time restore to 02:40:00 UTC |
|---|---|---|
| **Acknowledged writes checked against the live cluster** (count and checksum, per drill run) | **3,033,361 of 3,033,361** present, across 25 runs | **2,671,802 of 2,671,802** present up to the target |
| Writes after the target in the restored copy | – | **0** |
| supafirehose users, Auth users, sessions and refresh tokens | all equal to live | all equal to live at the target |
| Base backup restored | one full backup, taken at cluster bootstrap 15 hours earlier (55 MB) | the same |
| WAL replayed | 115 segments (1.8 GB) across **19 failover timelines** | 103 segments across 17 timelines |
| Copy the backup from S3 | 14.9 s | 14.9 s |
| Replay WAL and promote | 41.9 s (WAL replay itself 34 s) | 41.6 s |
| **Total, until the copy accepts connections** | **under 1 minute** for a 543 MiB database | under 1 minute |

**Every acknowledged write came back**, including through 19 failovers' worth of timeline switches, and **point-in-time restore works to the second** on these backups. Multigres doesn't expose point-in-time restore yet. Its own design notes say restores always use `--type=standby`, the latest state. So this shows the data needed for it is already in the repository.

### How recent is the restored data? (RPO on a quiet database)

`archive_timeout` is `0` on the cluster, which is Postgres's default, and Multigres's generated configuration keeps it. With it at 0, a WAL segment is archived only when it fills (16 MB) or something forces a switch. In the deployed build the only forced switch is `pgbackrest check` at the first backup. So on a quiet database, a committed write can stay out of the repository for hours. `scripts/rpo-marker.sh` measures that:

| Step | Result |
|---|---|
| Marker row committed and **acknowledged through the gateway** | 03:58:24 UTC, in WAL segment `…75`, 4.0 MB into it |
| Last segment archived before it | `…74`, at 03:35:05 |
| WAL written while the database was quiet | about 400 bytes/s (352 KB in 14.6 min), from background activity alone |
| Segment `…75` archived during the 15-minute hold | **no** (polled every 30 s, [`archiver.txt`](results/rpo-marker-1/archiver.txt)) |
| Restore of the latest backup state at 04:13 | replay ended at the end of `…74`. **The marker row and even its table are missing** |
| Time for `…75` to fill at that rate | about **8.7 hours**, during which every write since 03:35 exists only on the cluster's own disks |

On a busy database segments fill in seconds, and the gap is small. The risk is the quiet one, such as overnight, a staging project, or a small tenant. There, losing the cluster and restoring from S3 would lose hours of acknowledged writes, and nothing reports it. `pg_stat_archiver` shows no failure, because nothing failed.

The fix is one setting, for example `archive_timeout = 60s`. That caps the gap at about a minute for the cost of mostly empty segments on idle databases, which compress to almost nothing with `compress-type=zst`, already set here. Archiving health is open work in [#654](https://github.com/multigres/multigres/issues/654).

## What it means for running Multigres

- **Backups restore and are complete,** but only one base backup exists, taken at bootstrap. Restore time grows with the WAL since then. Here a day of drills meant 1.8 GB of WAL and about 35 s of replay, which is fine. At production write rates, without scheduled base backups, it's hours. Scheduled backups are open work: [#525](https://github.com/multigres/multigres-operator/issues/525) and the scheduling proof of concept [#811](https://github.com/multigres/multigres-operator/pull/811). The design notes recommend them "to keep restore times predictable".
- **A quiet database can be hours behind its backup** (above). Set `archive_timeout`, and alert on the age of the newest restorable write, not only on archiver errors.
- **Test restores, not only `verify`.** A restore of the latest backup, plus a count and checksum against live, is about a minute of compute here, and it's the only check that proves the data is there.

## How it works

`scripts/restore.sh <name> [target time]`:

1. **Before.** On the live primary, record `pg_stat_archiver` (last archived WAL and when) and `pgbackrest info`.
2. **Restore pod.** It uses the same `pgctld` image the cluster runs (Postgres 17 + pgBackRest 2.60.1) and the `multigres-backup` ServiceAccount, whose IRSA role can read the bucket. Its gp3 volume is created and deleted with the pod. The repository settings are copied from the live pooler's own `pgbackrest.conf`.
3. **Copy.** `pgbackrest restore --archive-mode=off`, with `--type=time --target=…` for point-in-time.
4. **Replay.** Start Postgres with archiving off, no replication, no synchronous standbys and a socket only, so the copy can never write WAL into the live repository or join the cluster. Wait until it has promoted.
5. **Compare.** The same queries ([`sql/snapshot.sql`](sql/snapshot.sql)) run on the restored copy and, through the gateway, on the live cluster:
   - for every drill run in the `ackcheck` table, the row count and a checksum of every key written up to the target minus 1 s
   - any rows after the target plus 1 s
   - supafirehose's `users`, and Auth's users, sessions and refresh tokens
6. **Verdict.** `analysis/compare.py` reports PASS only if every run matches and nothing after the target is present. Then the pod and its volume are deleted.

The 1 s margins exist because a row's `at` is the transaction's start, a few ms before its commit, and point-in-time recovery stops at a commit.

**Validation.**
- Each restore's `postgres.log` shows the backup set, every WAL segment fetched, each timeline switch, `recovery stopping before commit … 02:40:00.000084` for the point-in-time run, and the promotion.
- `live.txt` and `restored.txt` hold the raw query output behind every number.
- The comparison first reported FAIL for the point-in-time run, because it counted two drill runs that started after the target as missing. It now treats a run with no rows up to the target as empty on both sides.

## Reproduce

With the cluster from `../failure-drill` and the `loadgen` pod from `../production-scenario/scripts/setup.sh`:

```sh
restore-check/scripts/restore.sh latest-1
restore-check/scripts/restore.sh pitr-1 "2026-11-27 02:40:00+00"    # any time inside your WAL range
restore-check/scripts/rpo-marker.sh 1                               # 15 min hold, then a restore
```

`rpo-marker.sh` also writes `results/rpo-marker-<n>/` (`marker.txt`, `archiver.txt`, `marker-in-restore.txt`) and its restore as `results/rpo-marker-<n>-restore/`.

Each restore writes `results/<name>/`: `timeline.txt`, `pgbackrest-info.txt`, `live-archiver.txt`, `pgbackrest-restore.log`, `postgres.log`, `live.txt`, `restored.txt` and `summary.txt`.
