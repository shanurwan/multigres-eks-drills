#!/usr/bin/env bash
# Restore the shard's pgBackRest backup from S3 into a throwaway pod, then check the data
# against the live cluster.
#
#   scripts/restore.sh latest-1                             # to the end of the archived WAL
#   scripts/restore.sh pitr-1 "2026-11-27 02:40:00+00"      # point-in-time
#
# Needs the cluster from ../failure-drill and the loadgen pod from ../production-scenario
# (its psql reaches the live cluster through the gateway). Results: results/<name>/.
# EXTRA_SQL: one more query to run on the restored copy (saved as extra.txt).
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: restore.sh <name> [target time]}"
target="${2:-}"
ns=multigres-demo
pod="restore-$name"
out="$here/results/$name"
[ -e "$out" ] && { echo "$out exists" >&2; exit 1; }
mkdir -p "$out"
k() { kubectl -n "$ns" "$@"; }
rx() { k exec "$pod" -- sh -c "$1"; }
now() { date -u +%FT%T.%3NZ; }
log() { echo "$(now) $*" | tee -a "$out/timeline.txt"; }

# ---- before: what the live primary has archived -----------------------------------
primary="$("$here/../failure-drill/scripts/primary.sh" | awk '$4=="primary"{print $2}')"
k exec "$primary" -c postgres -- sh -c 'PGPASSWORD="$(cat /etc/postgres-password/* | head -1)" psql -h /var/lib/pooler/pg_sockets -U postgres -d postgres -Atc "
  select now(), pg_walfile_name(pg_current_wal_lsn()), archived_count, last_archived_wal, last_archived_time, failed_count,
         current_setting(\$\$archive_timeout\$\$) from pg_stat_archiver"' > "$out/live-archiver.txt"
k exec "$primary" -c postgres -- pgbackrest --config=/var/lib/pooler/pgbackrest/pgbackrest.conf --stanza=multigres info > "$out/pgbackrest-info.txt"
image="$(k get pod "$primary" -o jsonpath='{.spec.initContainers[?(@.name=="postgres")].image}')"
# The repository settings, copied from the live pooler's own pgBackRest configuration.
repo="$(k exec "$primary" -c postgres -- cat /var/lib/pooler/pgbackrest/pgbackrest.conf | grep -E '^repo1-')"
log "primary $primary; image $image; target ${target:-end of archive}"

# ---- restore pod ----------------------------------------------------------------------
sed -e "s|RESTORE_NAME|$pod|" -e "s|IMAGE|$image|" "$here/manifests/restore-pod.yaml" | kubectl apply -f - >/dev/null
k wait "pod/$pod" --for=condition=Ready --timeout=5m >/dev/null
log "restore pod ready on $(k get pod "$pod" -o jsonpath='{.spec.nodeName}')"
k exec -i "$pod" -- sh -c "mkdir -p /restore/log /restore/spool /restore/lock && cat > /restore/pgbackrest.conf" <<EOF
[global]
log-path=/restore/log
spool-path=/restore/spool
lock-path=/restore/lock
log-level-console=info
process-max=4

[multigres]
$repo
pg1-path=/restore/pg_data
EOF
(cd "$here" && k cp sql/snapshot.sql "$pod:/restore/snapshot.sql")

# ---- 1. copy the backup (pgbackrest restore) ------------------------------------------
type_args=""
[ -n "$target" ] && type_args="--type=time --target='$target' --target-action=promote"
log "pgbackrest restore start"
rx "pgbackrest --config=/restore/pgbackrest.conf --stanza=multigres restore --archive-mode=off $type_args" > "$out/pgbackrest-restore.log" 2>&1
log "pgbackrest restore done"

# ---- 2. replay WAL and promote ----------------------------------------------------------
# Archiving off, no replication, no synchronous standbys, socket only: the copy can't touch the live cluster.
rx "nohup postgres -D /restore/pg_data -c archive_mode=off -c archive_command=/bin/true \
      -c restore_command='pgbackrest --config=/restore/pgbackrest.conf --stanza=multigres archive-get %f \"%p\"' \
      -c synchronous_standby_names='' -c primary_conninfo='' -c listen_addresses='' \
      -c unix_socket_directories=/restore -c port=5432 -c logging_collector=off \
      > /restore/postgres.log 2>&1 &"
log "postgres started (recovery)"
until [ "$(rx "psql -h /restore -U postgres -d postgres -Atc 'select pg_is_in_recovery()'" 2>/dev/null)" = f ]; do
  rx "pgrep -x postgres >/dev/null" || { log "postgres exited during recovery"; k cp "$pod:/restore/postgres.log" "$out/postgres.log" >/dev/null 2>&1 || true; exit 1; }
  sleep 5
done
log "recovery done, promoted"

# ---- 3. compare with the live cluster -----------------------------------------------------
newest="$(rx "psql -h /restore -U postgres -d postgres -Atc 'select max(at) from ackcheck'")"
check_at="${target:-$newest}"
log "newest restored write $newest; comparing at $check_at"
rx "psql -h /restore -U postgres -d postgres -v target='$check_at' -f /restore/snapshot.sql" > "$out/restored.txt"
k exec -i loadgen -- psql -v target="$check_at" -f - < "$here/sql/snapshot.sql" > "$out/live.txt"
log "snapshots taken"
# Optional extra check on the restored copy, e.g. EXTRA_SQL="select * from rpo_marker"
if [ -n "${EXTRA_SQL:-}" ]; then
  rx "psql -h /restore -U postgres -d postgres -c \"$EXTRA_SQL\"" > "$out/extra.txt" 2>&1 || true
fi

(cd "$out" && k cp "$pod:/restore/postgres.log" postgres.log >/dev/null && k cp "$pod:/restore/log" pgbackrest-logs >/dev/null) || true
k delete pod "$pod" --wait=false >/dev/null
log "done: $out"
python3 "$here/analysis/compare.py" "$out" | tee "$out/summary.txt"
