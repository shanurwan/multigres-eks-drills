#!/usr/bin/env bash
# How far behind can a restore be on a quiet database? Commit one marker row through the
# gateway, then watch whether the WAL segment holding it reaches the backup repository,
# and restore after HOLD to see whether the marker is there.
#
#   scripts/rpo-marker.sh 1            # HOLD (default 15m), POLL (default 30 s)
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
n="${1:?run number}"
hold="${HOLD:-15m}"; poll="${POLL:-30}"
ns=multigres-demo
out="$here/results/rpo-marker-$n"
[ -e "$out" ] && { echo "$out exists" >&2; exit 1; }
mkdir -p "$out"
now() { date -u +%FT%T.%3NZ; }
log() { echo "$(now) $*" | tee -a "$out/timeline.txt"; }
primary="$("$here/../failure-drill/scripts/primary.sh" | awk '$4=="primary"{print $2}')"
pq() { kubectl -n "$ns" exec "$primary" -c postgres -- sh -c "PGPASSWORD=\"\$(cat /etc/postgres-password/* | head -1)\" psql -h /var/lib/pooler/pg_sockets -U postgres -d postgres -Atc \"$1\""; }

kubectl -n "$ns" exec loadgen -- psql -Atc "create table if not exists rpo_marker (id int primary key, at timestamptz not null default clock_timestamp())" >/dev/null
committed="$(kubectl -n "$ns" exec loadgen -- psql -Atc "insert into rpo_marker (id) values ($n) returning at")"
wal="$(pq "select pg_walfile_name(pg_current_wal_lsn()) || ' ' || pg_current_wal_lsn()")"
log "marker $n committed at $committed (acknowledged through the gateway); primary $primary at WAL $wal"
echo "marker_committed=$committed marker_wal_file=${wal%% *} marker_lsn=${wal##* }" > "$out/marker.txt"

end=$(( $(date +%s) + ${hold%m} * 60 ))
echo "# time | current WAL file | current LSN | last archived WAL | last archived at | archive_timeout" > "$out/archiver.txt"
while [ "$(date +%s)" -lt "$end" ]; do
  echo "$(now) | $(pq "select pg_walfile_name(pg_current_wal_lsn()) || ' | ' || pg_current_wal_lsn() || ' | ' || coalesce(last_archived_wal,'') || ' | ' || coalesce(last_archived_time::text,'') || ' | ' || current_setting('archive_timeout') from pg_stat_archiver")" >> "$out/archiver.txt"
  sleep "$poll"
done
log "held $hold; restoring the latest backup state"
EXTRA_SQL="select id, at from rpo_marker order by id" "$here/scripts/restore.sh" "rpo-marker-$n-restore" | tail -3
cp "$here/results/rpo-marker-$n-restore/extra.txt" "$out/marker-in-restore.txt"
if grep -qE "^ *$n \|" "$out/marker-in-restore.txt"; then log "marker $n IS in the restored copy"; else log "marker $n is NOT in the restored copy"; fi
