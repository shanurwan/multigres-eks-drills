#!/usr/bin/env bash
# Prepare both scenarios on the cluster from ../failure-drill (Multigres already Healthy):
#   1. the loadgen pod in ZONE, with the binaries from scripts/build.sh
#   2. supafirehose's table (its own init.sql, 100,000 users) through the gateway
#   3. the roles Supabase Auth expects, then Auth itself, which runs its migrations through the gateway
#   4. USERS Auth users signed up through Auth
#
#   scripts/setup.sh apse2-az1
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
zone="${1:?usage: setup.sh <zone-id>}"
ns=multigres-demo
auth_version="${AUTH_VERSION:-v2.199.0}"
users="${USERS:-200}"
k() { kubectl -n "$ns" "$@"; }
lg() { k exec loadgen -- sh -c "$1"; }

if ! k get secret auth-secrets >/dev/null 2>&1; then
  k create secret generic auth-secrets \
    --from-literal=db-password="$(head -c 24 /dev/urandom | base64 | tr -dc A-Za-z0-9)" \
    --from-literal=jwt-secret="$(head -c 48 /dev/urandom | base64 | tr -dc A-Za-z0-9)" >/dev/null
fi

k delete pod loadgen --ignore-not-found --wait=true >/dev/null
sed "s|LOADGEN_ZONE|$zone|" "$here/manifests/loadgen.yaml" | kubectl apply -f - >/dev/null
k wait pod/loadgen --for=condition=Ready --timeout=3m >/dev/null
# Relative paths: kubectl cp reads "C:/..." as pod:path on Windows.
(cd "$here" && for b in supafirehose fhrec authload ackcheck; do k cp "bin/$b" "loadgen:/usr/local/bin/$b"; done
 k cp sql/supafirehose-init.sql loadgen:/tmp/supafirehose-init.sql
 k cp sql/auth-roles.sql loadgen:/tmp/auth-roles.sql)
lg 'chmod +x /usr/local/bin/supafirehose /usr/local/bin/fhrec /usr/local/bin/authload /usr/local/bin/ackcheck'
echo "loadgen ready in $zone on $(k get pod loadgen -o jsonpath='{.spec.nodeName}')"

lg 'psql -q -v ON_ERROR_STOP=1 -f /tmp/supafirehose-init.sql && psql -Atc "select count(*) from users"' | sed 's/^/supafirehose users: /'
lg 'psql -q -v ON_ERROR_STOP=1 -v auth_pw="$AUTH_DB_PASSWORD" -f /tmp/auth-roles.sql' && echo "auth roles ready"

sed -e "s|AUTH_ZONE|$zone|" -e "s|AUTH_VERSION|$auth_version|" "$here/manifests/auth.yaml" | kubectl apply -f - >/dev/null
k rollout status deploy/auth --timeout=5m
lg 'psql -Atc "select count(*) from auth.schema_migrations"' | sed 's/^/auth migrations applied: /'
lg "[ -s /tmp/users.json ] || authload seed -url http://auth:9999 -users $users -out /tmp/users.json"
