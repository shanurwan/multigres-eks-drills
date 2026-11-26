#!/usr/bin/env bash
# Deploy the 3-cell Multigres cluster onto the EKS cluster created by terraform/.
# Fills manifests/cluster.yaml from the Terraform outputs, creates the admin
# password Secret once (random, never printed or written to disk) and applies.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tf() { terraform -chdir="$here/terraform" output -raw "$1"; }
list() { terraform -chdir="$here/terraform" output -json "$1" | tr -d '[]" \r\n' | tr ',' '\n'; }

for bin in terraform kubectl openssl; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done

ns=multigres-demo
first_az="$(list azs | head -1)"; region="${first_az%?}"
bucket="$(tf backup_bucket)"
role="$(tf backup_role_arn)"
mapfile -t zones < <(list zone_ids | sort)
[ "${#zones[@]}" -eq 3 ] || { echo "expected 3 zone IDs, got ${#zones[@]}" >&2; exit 1; }

# The nodes must carry the zone IDs the cells are pinned to.
for z in "${zones[@]}"; do
  n="$(kubectl get nodes -l "topology.k8s.aws/zone-id=$z" --no-headers 2>/dev/null | wc -l)"
  [ "$n" -ge 1 ] || { echo "no node labelled topology.k8s.aws/zone-id=$z" >&2; exit 1; }
done

kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
if ! kubectl -n "$ns" get secret multigres-admin-password >/dev/null 2>&1; then
  kubectl -n "$ns" create secret generic multigres-admin-password \
    --from-literal=password="$(openssl rand -hex 24)" >/dev/null
  echo "created secret $ns/multigres-admin-password"
fi

sed -e "s|ZONE_ID_1|${zones[0]}|" -e "s|ZONE_ID_2|${zones[1]}|" -e "s|ZONE_ID_3|${zones[2]}|" \
    -e "s|BACKUP_BUCKET|$bucket|" -e "s|AWS_REGION|$region|" -e "s|BACKUP_ROLE_ARN|$role|" \
    "$here/manifests/cluster.yaml" |
  awk 'BEGIN{RS="---\n"; ORS="---\n"} !/kind: Secret/' |
  kubectl apply --server-side -f -

echo "waiting for the cluster to be Healthy (up to ${WAIT:-15m})"
kubectl -n "$ns" wait multigrescluster/demo --for=jsonpath='{.status.phase}'=Healthy --timeout="${WAIT:-15m}"
kubectl -n "$ns" get pods -o wide
