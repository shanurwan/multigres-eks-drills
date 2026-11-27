#!/usr/bin/env bash
# Does a backup taken through Multigres push a quiet database's latest writes to the repository?
# Commit a marker, confirm its WAL segment is not archived, trigger one backup with the
# Multigres CLI (default: from a replica, as scheduled backups would), then check the archiver
# and restore to see whether the marker is there.
#
#   scripts/backup-wal-switch.sh 1            # TYPE (default incremental), WAIT (default 120 s)
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
n="${1:?run number}"; type="${TYPE:-incremental}"; wait_s="${WAIT:-120}"
ns=multigres-demo
out="$here/results/backup-wal-switch-$n"
[ -e "$out" ] && { echo "$out exists" >&2; exit 1; }
mkdir -p "$out"
now() { date -u +%FT%T.%3NZ; }
log() { echo "$(now) $*" | tee -a "$out/timeline.txt"; }
primary="$("$here/../failure-drill/scripts/primary.sh" | awk '$4=="primary"{print $2}')"
admin="$(kubectl -n "$ns" get pods --no-headers -o custom-columns=N:.metadata.name | grep -E 'multiadmin-[0-9a-f]+-' | grep -v web | head -1)"
pq() { kubectl -n "$ns" exec "$primary" -c postgres -- sh -c "PGPASSWORD=\"\$(cat /etc/postgres-password/* | head -1)\" psql -h /var/lib/pooler/pg_sockets -U postgres -d postgres -Atc \"$1\""; }
arch() { echo "$(now) | $(pq "select pg_walfile_name(pg_current_wal_lsn()) || ' | ' || coalesce(last_archived_wal,'') || ' | ' || coalesce(last_archived_time::text,'') from pg_stat_archiver")" | tee -a "$out/archiver.txt"; }
id=$((1000 + n))

echo "# time | current WAL file | last archived WAL | last archived at" > "$out/archiver.txt"
kubectl -n "$ns" exec loadgen -- psql -Atc "create table if not exists rpo_marker (id int primary key, at timestamptz not null default clock_timestamp())" >/dev/null
committed="$(kubectl -n "$ns" exec loadgen -- psql -Atc "insert into rpo_marker (id) values ($id) returning at" | head -1)"
seg="$(pq "select pg_walfile_name(pg_current_wal_lsn())")"
log "marker $id committed at $committed, in WAL segment $seg; primary $primary"
arch
sleep "$wait_s"
arch
log "waited ${wait_s}s; triggering a $type backup through multiadmin ($admin)"
kubectl -n "$ns" exec "$admin" -- /multigres/bin/multigres cluster backup --admin-server localhost:18070 --type "$type" --timeout 5m > "$out/backup.txt" 2>&1 || log "backup command failed (see backup.txt)"
log "backup command returned"
for _ in 1 2 3 4 5 6; do arch; sleep 10; done
kubectl -n "$ns" exec "$admin" -- /multigres/bin/multigres cluster list-backups --admin-server localhost:18070 > "$out/list-backups.txt" 2>&1 || true
last="$(tail -1 "$out/archiver.txt" | awk -F' [|] ' '{print $3}')"
if [[ "$last" > "$seg" || "$last" == "$seg" ]]; then log "segment $seg archived (last archived $last)"; else log "segment $seg NOT archived (last archived $last)"; fi
EXTRA_SQL="select id, at from rpo_marker order by id" "$here/scripts/restore.sh" "backup-wal-switch-$n-restore" | tail -2
cp "$here/results/backup-wal-switch-$n-restore/extra.txt" "$out/marker-in-restore.txt"
if grep -qE "^ *$id \|" "$out/marker-in-restore.txt"; then log "marker $id IS in the restored copy"; else log "marker $id is NOT in the restored copy"; fi
