#!/usr/bin/env bash
# Run a sequence of drills unattended, keeping the writer out of harm's way.
#   scripts/campaign.sh "pod-kill:2 pod-kill:3 node-drain:1 az-down:1:apse2-az1"
# Each item is drill:run[:zone]. Stops at the first drill that fails to run.
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
ns=multigres-demo

zone_of_node() { kubectl get node "$1" -o jsonpath='{.metadata.labels.topology\.k8s\.aws/zone-id}'; }
writer_zone() { zone_of_node "$(kubectl -n $ns get pod ackcheck -o jsonpath='{.spec.nodeName}')"; }
all_zones() { kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.k8s\.aws/zone-id}{"\n"}{end}' | sort -u; }

for item in $1; do
  IFS=: read -r drill run zone <<<"$item"
  primary_zone="$("$here/scripts/primary.sh" | awk '$4=="primary"{print $1}')"
  # Zone to keep the writer out of: the zone being taken down, or the primary's zone.
  avoid="${zone:-$primary_zone}"
  [ "$drill" = pod-kill ] && avoid=""
  if [ -n "$avoid" ] && [ "$(writer_zone)" = "$avoid" ]; then
    new="$(all_zones | grep -v "^$avoid$" | head -1)"
    echo "$(date -u +%T) moving writer from $avoid to $new"
    "$here/scripts/writer.sh" "$new" >/dev/null
  fi
  echo "$(date -u +%T) === $drill run $run ${zone:-} (primary in $primary_zone, writer in $(writer_zone))"
  "$here/scripts/drill.sh" "$drill" "$run" ${zone:+"$zone"} < /dev/null
done
