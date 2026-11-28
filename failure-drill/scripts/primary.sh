#!/usr/bin/env bash
# Print "<zone-id> <pod> <node> primary|standby" for each pooler.
# The password is read inside the pod from the mounted Secret, never on this machine.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ns=multigres-demo
for p in $(kubectl -n "$ns" get pods --no-headers -o custom-columns=N:.metadata.name | grep pool-default); do
  node="$(kubectl -n "$ns" get pod "$p" -o jsonpath='{.spec.nodeName}')"
  zone="$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.k8s\.aws/zone-id}')"
  # timeout: during a partition a pod can be unreachable, and exec would hang
  r="$(timeout 8 kubectl -n "$ns" exec "$p" -c postgres -- sh -c \
      'PGPASSWORD="$(cat /etc/postgres-password/* | head -1)" psql -h /var/lib/pooler/pg_sockets -U postgres -d postgres -Atc "select pg_is_in_recovery()"' 2>/dev/null || echo "?")"
  case "$r" in f) role=primary ;; t) role=standby ;; *) role=unknown ;; esac
  echo "$zone $p $node $role"
done | sort
