#!/usr/bin/env bash
# One snapshot of "does everything still work": shard phase, pods, a write and a read through
# the gateway, replication from the primary, the operator's recent errors, Prometheus scrape
# health, and ztunnel's view. Writes results/<label>/health.txt.
#   scripts/health.sh after-enroll
set -uo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
label="${1:?label}"; ns=multigres-demo
out="$here/results/$label"; mkdir -p "$out"
{
  echo "== $(date -u +%FT%TZ) $label"
  echo "-- shard"; kubectl -n $ns get shard -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers
  echo "-- multigres pods not fully ready"; kubectl -n $ns get pods --no-headers | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print}'
  echo "-- write and read through the gateway"
  kubectl -n $ns exec loadgen -- psql -Atc "create table if not exists mesh_probe (id bigserial primary key, label text, at timestamptz default now()); insert into mesh_probe (label) values ('$label') returning id, at" 2>&1 | head -2
  echo "-- replication seen from the primary"
  p="$("$here/../failure-drill/scripts/primary.sh" | awk '$4=="primary"{print $2}')"
  kubectl -n $ns exec "$p" -c postgres -- sh -c 'PGPASSWORD="$(cat /etc/postgres-password/* | head -1)" psql -h /var/lib/pooler/pg_sockets -U postgres -d postgres -Atc "select application_name, state, sync_state from pg_stat_replication"' 2>&1
  echo "-- operator errors in the last 3 min"
  kubectl -n multigres-operator logs deploy/multigres-operator-controller-manager --since=3m 2>&1 | grep -ciE '"level":"error"|error' 
  kubectl -n multigres-operator logs deploy/multigres-operator-controller-manager --since=3m 2>&1 | grep -iE '"level":"error"' | sed -E 's/"ts":[^,]*,//' | cut -c1-300 | sort | uniq -c | sort -rn | head -5
  echo "-- prometheus scrape targets (health: count)"
  kubectl -n multigres-operator exec prometheus-multigres-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null \
    | python3 -c 'import json,sys,collections; d=json.load(sys.stdin)["data"]["activeTargets"]; c=collections.Counter((t["labels"].get("job","?"),t["health"]) for t in d); [print(f"{n:4d} {j} {h}") for (j,h),n in sorted(c.items())]; errs={t["lastError"][:160] for t in d if t["health"]!="up"}; [print("     err:",e) for e in errs]' 2>&1
  if kubectl get ns istio-system >/dev/null 2>&1; then
    echo "-- ztunnel workloads (protocol per pod in $ns)"
    "${ISTIOCTL:-istioctl}" ztunnel-config workloads 2>/dev/null | awk -v ns=$ns 'NR==1 || $1==ns' | head -30
    echo "-- ztunnel errors/warnings in the last 3 min"
    kubectl -n istio-system logs ds/ztunnel --since=3m --all-containers 2>/dev/null | grep -E 'level=(error|warn)|\berror\b' | sed -E 's/^[^ ]+ //' | cut -c1-220 | sort | uniq -c | sort -rn | head -8
  fi
} > "$out/health.txt" 2>&1
cat "$out/health.txt"
