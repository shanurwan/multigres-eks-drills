#!/usr/bin/env bash
# Run one failure drill and collect everything into results/<drill>-<run>/.
#
#   scripts/drill.sh pod-kill 1
#   scripts/drill.sh node-drain 1
#   scripts/drill.sh node-terminate 1
#   scripts/drill.sh az-down 1 apse2-az3      # zone to take down (default: the primary's zone)
#
# The writer must already run in a zone the drill does not break (scripts/writer.sh).
# Environment: WRITE_FOR (default 6m), FAULT_AT (default 60 s), AZ_HOLD (default 240 s),
# AWS_PROFILE / AWS_REGION for the node and zone drills.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: do not rewrite /paths passed to kubectl

here="$(cd "$(dirname "$0")/.." && pwd)"
drill="${1:?drill: pod-kill | node-drain | node-terminate | az-down | az-outage}"
n="${2:?run number}"
target_zone="${3:-}"
ns=multigres-demo
run="$drill-$n"
out="$here/results/$run"
write_for="${WRITE_FOR:-6m}"
fault_at="${FAULT_AT:-60}"
az_hold="${AZ_HOLD:-240}"
cluster="multigres-lab"

[ -e "$out" ] && { echo "$out exists; use another run number" >&2; exit 1; }
mkdir -p "$out"
now() { date -u +%FT%T.%3NZ; }
log() { echo "$(now) $*" | tee -a "$out/timeline.txt"; }

# ---- before -----------------------------------------------------------------
writer_zone="$(kubectl get node "$(kubectl -n $ns get pod ackcheck -o jsonpath='{.spec.nodeName}')" \
  -o jsonpath='{.metadata.labels.topology\.k8s\.aws/zone-id}')"
"$here/scripts/primary.sh" > "$out/primary-before.txt"
primary_line="$(grep ' primary$' "$out/primary-before.txt" || true)"
[ -n "$primary_line" ] || { echo "no primary found" >&2; cat "$out/primary-before.txt" >&2; exit 1; }
read -r primary_zone primary_pod primary_node _ <<<"$primary_line"
[ -n "$target_zone" ] || target_zone="$primary_zone"
if [[ "$drill" == az-* ]] && [ "$target_zone" = "$writer_zone" ]; then
  echo "the writer runs in $writer_zone, the zone this drill breaks; move it first" >&2; exit 1
fi
if [[ "$drill" != az-* ]] && [ "$primary_node" = "$(kubectl -n $ns get pod ackcheck -o jsonpath='{.spec.nodeName}')" ] && [ "$drill" != pod-kill ]; then
  echo "the writer shares the primary's node; move it to another zone first" >&2; exit 1
fi
kubectl -n $ns get pods -o wide > "$out/pods-before.txt"
{
  echo "drill=$drill run=$n writer_zone=$writer_zone target_zone=$target_zone"
  echo "primary_before=$primary_pod zone=$primary_zone node=$primary_node"
  echo "operator_image=$(kubectl -n multigres-operator get pods -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
  kubectl -n $ns get pod "$primary_pod" -o jsonpath='{range .status.containerStatuses[*]}{.name}={.imageID}{"\n"}{end}{range .status.initContainerStatuses[*]}{.name}={.imageID}{"\n"}{end}'
  echo "kubernetes=$(kubectl version -o json 2>/dev/null | grep -m1 gitVersion | tr -d ' ",' | cut -d: -f2)"
  echo "write_for=$write_for fault_at=${fault_at}s az_hold=${az_hold}s"
} > "$out/run.txt"

# ---- observers --------------------------------------------------------------
start_epoch=$(date +%s)
(
  while :; do
    phase="$(kubectl -n $ns get shard -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo '?')"
    ready="$(kubectl -n $ns get pods --no-headers 2>/dev/null | awk '/pool-default/{printf "%s ", $2}')"
    echo "$(now) shard=$phase pools_ready=[${ready% }]"
    sleep 2
  done
) > "$out/shard-timeline.txt" 2>&1 &
observer=$!
trap 'kill $observer 2>/dev/null || true' EXIT

log "writer start ($write_for)"
kubectl -n $ns exec ackcheck -- sh -c "rm -rf /tmp/$run; mkdir -p /tmp/$run; /ackcheck run -run $run -workers 8 -rate 50 -timeout 2s -duration $write_for -out /tmp/$run > /tmp/$run/run.log 2>&1 &"
sleep "$fault_at"

# ---- fault ------------------------------------------------------------------
nodegroup_for_zone() {
  kubectl get nodes -l "topology.k8s.aws/zone-id=$1" -o jsonpath='{.items[0].metadata.labels.eks\.amazonaws\.com/nodegroup}'
}
case "$drill" in
  pod-kill)
    uid="$(kubectl -n $ns get pod "$primary_pod" -o jsonpath='{.metadata.uid}')"
    log "fault: force-delete primary pod $primary_pod (uid $uid)"
    kubectl -n $ns delete pod "$primary_pod" --grace-period=0 --force --wait=false 2>&1 | tee -a "$out/fault.txt"
    echo "deleted uid=$uid" >> "$out/fault.txt"
    ;;
  node-drain)
    log "fault: drain $primary_node"
    kubectl drain "$primary_node" --ignore-daemonsets --delete-emptydir-data --timeout=10m >> "$out/fault.txt" 2>&1 || log "drain did not finish (see fault.txt)"
    log "drain returned; uncordon"
    kubectl uncordon "$primary_node" >> "$out/fault.txt" 2>&1
    ;;
  node-terminate)
    iid="$(kubectl get node "$primary_node" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
    log "fault: terminate instance $iid ($primary_node)"
    aws ec2 terminate-instances --instance-ids "$iid" --query 'TerminatingInstances[0].CurrentState.Name' --output text >> "$out/fault.txt"
    aws ec2 wait instance-terminated --instance-ids "$iid"
    log "instance $iid terminated"
    echo "instance=$iid state=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].State.Name' --output text)" >> "$out/fault.txt"
    ;;
  az-down)
    ng="$(nodegroup_for_zone "$target_zone")"
    log "fault: scale node group $ng ($target_zone) to 0"
    aws eks update-nodegroup-config --cluster-name "$cluster" --nodegroup-name "$ng" \
      --scaling-config minSize=0,maxSize=2,desiredSize=0 --query 'update.id' --output text >> "$out/fault.txt"
    until [ "$(kubectl get nodes -l "topology.k8s.aws/zone-id=$target_zone" --no-headers 2>/dev/null | wc -l)" -eq 0 ]; do sleep 5; done
    log "zone $target_zone has 0 nodes"
    echo "nodes_in_zone_after_scale_down=0 at $(now)" >> "$out/fault.txt"
    kubectl -n $ns get pods -o wide > "$out/pods-zone-down.txt"
    sleep "$az_hold"
    log "restore: scale node group $ng back to 1"
    aws eks update-nodegroup-config --cluster-name "$cluster" --nodegroup-name "$ng" \
      --scaling-config minSize=1,maxSize=2,desiredSize=1 --query 'update.id' --output text >> "$out/fault.txt"
    until kubectl get nodes -l "topology.k8s.aws/zone-id=$target_zone" --no-headers 2>/dev/null | grep -q ' Ready'; do sleep 5; done
    log "zone $target_zone has a Ready node again"
    ;;
  az-outage)
    # An abrupt zone outage: nothing is drained. The node group goes to 0 so nothing replaces
    # the instances, and every instance in the zone is terminated at once.
    ng="$(nodegroup_for_zone "$target_zone")"
    iids="$(kubectl get nodes -l "topology.k8s.aws/zone-id=$target_zone" -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | awk -F/ 'NF{print $NF}' | tr '\n' ' ')"
    log "fault: node group $ng ($target_zone) to 0 and terminate $iids"
    aws eks update-nodegroup-config --cluster-name "$cluster" --nodegroup-name "$ng" \
      --scaling-config minSize=0,maxSize=2,desiredSize=0 --query 'update.id' --output text >> "$out/fault.txt"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $iids --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text >> "$out/fault.txt"
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $iids
    log "instances terminated: $iids"
    for i in $iids; do echo "instance=$i state=$(aws ec2 describe-instances --instance-ids "$i" --query 'Reservations[0].Instances[0].State.Name' --output text)" >> "$out/fault.txt"; done
    kubectl -n $ns get pods -o wide > "$out/pods-zone-down.txt"
    sleep "$az_hold"
    log "restore: scale node group $ng back to 1"
    aws eks update-nodegroup-config --cluster-name "$cluster" --nodegroup-name "$ng" \
      --scaling-config minSize=1,maxSize=2,desiredSize=1 --query 'update.id' --output text >> "$out/fault.txt"
    until kubectl get nodes -l "topology.k8s.aws/zone-id=$target_zone" --no-headers 2>/dev/null | grep -q ' Ready '; do sleep 5; done
    log "zone $target_zone has a Ready node again"
    ;;
  *) echo "unknown drill $drill" >&2; exit 2 ;;
esac

# ---- after --------------------------------------------------------------------
log "waiting for the writer to finish"
while kubectl -n $ns exec ackcheck -- sh -c "pgrep -f 'ackcheck run -run $run ' >/dev/null"; do sleep 5; done
log "writer finished; waiting for the shard to be Healthy (up to 15 min)"
kubectl -n $ns wait shard --all --for=jsonpath='{.status.phase}'=Healthy --timeout=15m >/dev/null 2>&1 \
  && log "shard Healthy" || log "shard NOT Healthy after 15 min"
kubectl -n $ns exec ackcheck -- /ackcheck verify -run "$run" -out "/tmp/$run" > "$out/verify.json" 2> "$out/verify.err" || log "verify failed (see verify.err)"
(cd "$here" && kubectl -n $ns cp "ackcheck:/tmp/$run" "results/$run/ackcheck" >/dev/null)
"$here/scripts/primary.sh" > "$out/primary-after.txt" || true
kubectl -n $ns get pods -o wide > "$out/pods-after.txt"
kubectl -n $ns get events --sort-by=.lastTimestamp > "$out/events.txt" 2>&1 || true
since="$(( $(date +%s) - start_epoch + 60 ))s"
mkdir -p "$out/logs"
kubectl -n multigres-operator logs deploy/multigres-operator-controller-manager --since="$since" > "$out/logs/operator.log" 2>&1 || true
for p in $(kubectl -n $ns get pods --no-headers -o custom-columns=N:.metadata.name | grep -E 'multiorch|multigateway|pool-default'); do
  for c in $(kubectl -n $ns get pod "$p" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}'); do
    kubectl -n $ns logs "$p" -c "$c" --since="$since" > "$out/logs/$p.$c.log" 2>/dev/null || true
    kubectl -n $ns logs "$p" -c "$c" --previous > "$out/logs/$p.$c.previous.log" 2>/dev/null || rm -f "$out/logs/$p.$c.previous.log"
  done
done
log "done: $out"
grep -E '"(acked|failed|ambiguous|lost_acked)"' "$out/verify.json" || true
