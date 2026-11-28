#!/usr/bin/env bash
# Run one failure drill and collect everything into results/<drill>-<run>/.
#
#   scripts/drill.sh pod-kill 1
#   scripts/drill.sh node-drain 1
#   scripts/drill.sh node-terminate 1
#   scripts/drill.sh az-down 1 apse2-az3      # zone to take down (default: the primary's zone)
#   scripts/drill.sh az-partition 1           # cut the zone off from the rest of the VPC (NACL), keep it running
#   scripts/drill.sh ng-upgrade 1             # rolling replacement of the zone's managed node group
#   scripts/drill.sh disk-full 1              # fill the primary's volume, then grow it through the MultigresCluster
#   MG_IMAGE=... PGCTLD_IMAGE=... MULTIADMIN_WEB_IMAGE=... scripts/drill.sh mg-upgrade 1   # newer Multigres images
#   scripts/drill.sh switchover 1             # a graceful switch-primary on its own
#
# The writer must already run in a zone the drill does not break (scripts/writer.sh).
# az-partition also starts a second writer inside the cut-off zone (pod ackcheck-iso), writing
# through that zone's own gateway, to see whether the isolated side acknowledges anything.
# Environment: WRITE_FOR (default 6m), FAULT_AT (default 60 s), AZ_HOLD (default 240 s),
# AWS_PROFILE / AWS_REGION for the node and zone drills, RESULTS_DIR (default results/;
# ../production-scenario uses its own).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: do not rewrite /paths passed to kubectl

here="$(cd "$(dirname "$0")/.." && pwd)"
drill="${1:?drill: pod-kill | node-drain | node-terminate | az-down | az-outage}"
n="${2:?run number}"
target_zone="${3:-}"
ns=multigres-demo
run="${RUN_NAME:-$drill-$n}"   # RUN_NAME: ../production-scenario names its own runs
results_dir="${RESULTS_DIR:-$here/results}"
out="$results_dir/$run"
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
# Only drills that take the primary's node away need the writer elsewhere.
if [[ "$drill" =~ ^(node-drain|node-terminate|ng-upgrade)$ ]] && [ "$primary_node" = "$(kubectl -n $ns get pod ackcheck -o jsonpath='{.spec.nodeName}')" ]; then
  echo "the writer shares the primary's node; move it to another zone first" >&2; exit 1
fi
kubectl -n $ns get pods -o wide > "$out/pods-before.txt"
{
  echo "drill=$drill run=$n writer_zone=$writer_zone target_zone=$target_zone"
  echo "primary_before=$primary_pod zone=$primary_zone node=$primary_node"
  echo "operator_image=$(kubectl -n multigres-operator get pods -l control-plane=controller-manager -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
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

if [ "$drill" = az-partition ]; then
  # A second writer inside the zone that will be cut off, through that zone's own gateway.
  cell_gw="$(kubectl -n $ns get svc --no-headers -o custom-columns=N:.metadata.name \
    | grep -E "^demo-$(kubectl -n $ns get multigrescluster demo -o jsonpath="{.spec.cells[?(@.zoneId=='$target_zone')].name}")-multigateway-")"
  kubectl -n $ns delete pod ackcheck-iso --ignore-not-found --wait=true >/dev/null
  sed -e "s|WRITER_ZONE|$target_zone|" -e "s|name: ackcheck$|name: ackcheck-iso|" -e "s|@demo-multigateway:|@$cell_gw:|" \
    "$here/manifests/writer.yaml" | kubectl apply -f - >/dev/null
  kubectl -n $ns wait pod/ackcheck-iso --for=condition=Ready --timeout=3m >/dev/null
  (cd "$here" && kubectl -n $ns cp tools/ackcheck/ackcheck ackcheck-iso:/ackcheck)
  kubectl -n $ns exec ackcheck-iso -- chmod +x /ackcheck
  echo "iso_writer=ackcheck-iso zone=$target_zone gateway=$cell_gw" >> "$out/run.txt"
fi

log "writer start ($write_for)"
kubectl -n $ns exec ackcheck -- sh -c "rm -rf /tmp/$run; mkdir -p /tmp/$run; /ackcheck run -run $run -workers 8 -rate 50 -timeout 2s -duration $write_for -out /tmp/$run > /tmp/$run/run.log 2>&1 &"
if [ "$drill" = az-partition ]; then
  log "isolated-zone writer start ($write_for, through $cell_gw)"
  kubectl -n $ns exec ackcheck-iso -- sh -c "rm -rf /tmp/$run-iso; mkdir -p /tmp/$run-iso; /ackcheck run -run $run-iso -workers 4 -rate 25 -timeout 2s -duration $write_for -out /tmp/$run-iso > /tmp/$run-iso/run.log 2>&1 &"
fi
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
  az-partition)
    # The zone keeps running but can't reach the rest of the VPC: its subnet gets a network ACL
    # that allows its own subnet and the internet and denies the VPC's other addresses, both ways.
    # NACLs are stateless, so open connections across the cut stop too.
    pnode="$(kubectl get nodes -l "topology.k8s.aws/zone-id=$target_zone" -o jsonpath='{.items[0].metadata.name}')"
    iid="$(kubectl get node "$pnode" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
    read -r subnet vpc <<<"$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].[SubnetId,VpcId]' --output text)"
    subnet_cidr="$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].CidrBlock' --output text)"
    vpc_cidr="$(aws ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[0].CidrBlock' --output text)"
    read -r orig_acl assoc <<<"$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values="$subnet" \
      --query "NetworkAcls[0].[NetworkAclId, Associations[?SubnetId=='$subnet'].NetworkAclAssociationId | [0]]" --output text)"
    acl="$(aws ec2 create-network-acl --vpc-id "$vpc" --query NetworkAcl.NetworkAclId --output text \
      --tag-specifications "ResourceType=network-acl,Tags=[{Key=Name,Value=$cluster-partition-$run}]")"
    for dir in --ingress --egress; do
      aws ec2 create-network-acl-entry --network-acl-id "$acl" $dir --rule-number 10 --protocol=-1 --cidr-block "$subnet_cidr" --rule-action allow
      aws ec2 create-network-acl-entry --network-acl-id "$acl" $dir --rule-number 20 --protocol=-1 --cidr-block "$vpc_cidr" --rule-action deny
      aws ec2 create-network-acl-entry --network-acl-id "$acl" $dir --rule-number 100 --protocol=-1 --cidr-block 0.0.0.0/0 --rule-action allow
    done
    # If this script dies mid-partition, this file says how to undo it by hand.
    echo "subnet=$subnet orig_acl=$orig_acl partition_acl=$acl (undo: replace the subnet's association back to orig_acl, delete partition_acl)" > "$out/partition-state.txt"
    heal_partition() {
      local a
      a="$(aws ec2 describe-network-acls --network-acl-ids "$acl" --query "NetworkAcls[0].Associations[?SubnetId=='$subnet'].NetworkAclAssociationId | [0]" --output text 2>/dev/null || true)"
      if [ -n "$a" ] && [ "$a" != None ]; then aws ec2 replace-network-acl-association --association-id "$a" --network-acl-id "$orig_acl" >/dev/null; fi
      aws ec2 delete-network-acl --network-acl-id "$acl" && acl=""
    }
    trap 'kill $observer 2>/dev/null || true; [ -n "${acl:-}" ] && heal_partition' EXIT
    log "fault: partition $target_zone (subnet $subnet_cidr cut off from $vpc_cidr) for ${az_hold}s"
    aws ec2 replace-network-acl-association --association-id "$assoc" --network-acl-id "$acl" --query NewAssociationId --output text >> "$out/fault.txt"
    echo "partitioned subnet=$subnet cidr=$subnet_cidr from=$vpc_cidr acl=$acl at $(now)" >> "$out/fault.txt"
    end=$(( $(date +%s) + az_hold ))
    while [ "$(date +%s)" -lt "$end" ]; do
      { echo "== $(now) node $pnode Ready=$(kubectl get node "$pnode" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
        "$here/scripts/primary.sh" 2>&1; } >> "$out/partition-observe.txt"
      sleep 10
    done
    log "heal: subnet back on $orig_acl"
    heal_partition
    echo "healed at $(now)" >> "$out/fault.txt"
    ;;
  ng-upgrade)
    # What an AMI or launch template rollout does: EKS starts a new node in the zone, cordons and
    # drains the old one (respecting PodDisruptionBudgets) and terminates it. The launch template
    # gets a new version with the same settings, so only the replacement itself is tested.
    ng="$(nodegroup_for_zone "$target_zone")"
    read -r lt_id lt_ver <<<"$(aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" --query 'nodegroup.launchTemplate.[id,version]' --output text)"
    new_ver="$(aws ec2 create-launch-template-version --launch-template-id "$lt_id" --source-version "$lt_ver" \
      --version-description "drill $run: unchanged settings" --launch-template-data '{}' --query LaunchTemplateVersion.VersionNumber --output text)"
    log "fault: node group $ng ($target_zone) rolling update, launch template version $lt_ver -> $new_ver (same settings)"
    uid="$(aws eks update-nodegroup-version --cluster-name "$cluster" --nodegroup-name "$ng" --launch-template "id=$lt_id,version=$new_ver" --query update.id --output text)"
    echo "nodegroup=$ng update=$uid launch_template=$lt_ver->$new_ver" >> "$out/fault.txt"
    while :; do
      st="$(aws eks describe-update --name "$cluster" --nodegroup-name "$ng" --update-id "$uid" --query update.status --output text)"
      echo "$(now) $st $(kubectl get nodes -l "topology.k8s.aws/zone-id=$target_zone" --no-headers 2>/dev/null | awk '{printf "%s:%s ", $1, $2}')" >> "$out/ng-update.txt"
      [ "$st" = InProgress ] || break
      sleep 15
    done
    log "node group update $uid: $st"
    aws eks describe-update --name "$cluster" --nodegroup-name "$ng" --update-id "$uid" --output json >> "$out/fault.txt"
    ;;
  disk-full)
    # The primary's data volume fills up (a file takes all but FILL_LEAVE_MB), stays full for
    # DISK_HOLD seconds, then gets the usual fix: a bigger volume through the MultigresCluster
    # (GROW_TO), which the EBS CSI driver expands online. The file is removed after the run.
    leave_mb="${FILL_LEAVE_MB:-64}"; hold="${DISK_HOLD:-180}"; grow_to="${GROW_TO:-15Gi}"
    size_path=/spec/databases/0/tablegroups/0/shards/0/spec/pools/default/storage/size
    pexec() { timeout 15 kubectl -n $ns exec "$primary_pod" -c multipooler -- "$@"; }
    avail_mb=$(( $(pexec df -k /var/lib/pooler | awk 'NR==2{print $4}') / 1024 ))
    fill_mb=$(( avail_mb - leave_mb ))
    log "fault: fill $primary_pod's data volume with $fill_mb MiB, leaving $leave_mb MiB"
    pexec fallocate -l "${fill_mb}M" /var/lib/pooler/drill-fill
    echo "filled pod=$primary_pod file=/var/lib/pooler/drill-fill mib=$fill_mb left_mib=$leave_mb at $(now)" >> "$out/fault.txt"
    disk_watch() {
      { echo "== $(now) $1"; pexec df -m /var/lib/pooler 2>&1 | tail -1
        kubectl -n $ns get pod "$primary_pod" --no-headers 2>&1
        "$here/scripts/primary.sh" 2>&1; } >> "$out/disk-observe.txt"
    }
    end=$(( $(date +%s) + hold ))
    while [ "$(date +%s)" -lt "$end" ]; do disk_watch full; sleep 10; done
    pvc="$(kubectl -n $ns get pod "$primary_pod" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' | tr ' ' '\n' | grep '^data-')"
    log "fix: grow the pool volumes to $grow_to through the MultigresCluster"
    kubectl -n $ns patch multigrescluster demo --type=json -p "[{\"op\":\"replace\",\"path\":\"$size_path\",\"value\":\"$grow_to\"}]" >> "$out/fault.txt"
    grow_deadline=$(( $(date +%s) + 900 ))
    until [ "$(kubectl -n $ns get pvc "$pvc" -o jsonpath='{.status.capacity.storage}')" = "$grow_to" ] || [ "$(date +%s)" -gt "$grow_deadline" ]; do
      disk_watch growing; sleep 10
    done
    log "pvc $pvc capacity: $(kubectl -n $ns get pvc "$pvc" -o jsonpath='{.status.capacity.storage}')"
    for i in 1 2 3 4 5 6; do disk_watch grown; sleep 10; done
    kubectl -n $ns get pvc "$pvc" -o yaml > "$out/pvc-after.yaml"
    kubectl -n $ns get events --field-selector "involvedObject.name=$pvc" > "$out/pvc-events.txt" 2>&1 || true
    ;;
  mg-upgrade)
    # A Multigres version upgrade: every component gets newer images (MG_IMAGE, PGCTLD_IMAGE,
    # MULTIADMIN_WEB_IMAGE) through spec.images, and the operator rolls the cluster.
    : "${MG_IMAGE:?MG_IMAGE (ghcr.io/multigres/multigres@sha256:...)}" "${PGCTLD_IMAGE:?PGCTLD_IMAGE}" "${MULTIADMIN_WEB_IMAGE:?MULTIADMIN_WEB_IMAGE}"
    log "fault: upgrade images to $MG_IMAGE and $PGCTLD_IMAGE"
    kubectl -n $ns patch multigrescluster demo --type=merge -p "{\"spec\":{\"images\":{\"multigateway\":\"$MG_IMAGE\",\"multiorch\":\"$MG_IMAGE\",\"multipooler\":\"$MG_IMAGE\",\"multiadmin\":\"$MG_IMAGE\",\"multiadminWeb\":\"$MULTIADMIN_WEB_IMAGE\",\"postgres\":\"$PGCTLD_IMAGE\"}}}" >> "$out/fault.txt"
    # Done when every pooler, gateway and orch pod runs the new image and the shard is Healthy.
    upg_deadline=$(( $(date +%s) + 1500 ))
    while [ "$(date +%s)" -lt "$upg_deadline" ]; do
      old="$(kubectl -n $ns get pods -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[*].image} {.spec.initContainers[*].image}{"\n"}{end}' \
        | grep -E 'multigateway|multiorch|pool-default' | grep -cvF "${MG_IMAGE#*@}" || true)"
      echo "$(now) pods_on_old_image=$old $(kubectl -n $ns get pods --no-headers | awk '/multigateway|multiorch|pool-default/{printf "%s:%s ", $1, $2}')" >> "$out/rollout.txt"
      [ "$old" = 0 ] && kubectl -n $ns get shard -o jsonpath='{.items[0].status.phase}' | grep -q Healthy && break
      sleep 10
    done
    log "rollout: $(tail -1 "$out/rollout.txt" | cut -d' ' -f2)"
    ;;
  switchover)
    # A planned switchover on its own: what a node drain or rolling restart asks multiorch for.
    log "fault: multigres cluster switch-primary (graceful)"
    echo 0-inf | kubectl -n $ns exec -i deploy/demo-multiadmin -- /multigres/bin/multigres cluster switch-primary \
      --admin-server localhost:18070 --reason "drill $run" >> "$out/fault.txt" 2>&1
    log "switch-primary returned"
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
# Relative path: kubectl cp reads "C:/..." as pod:path on Windows.
(cd "$results_dir" && kubectl -n $ns cp "ackcheck:/tmp/$run" "$run/ackcheck" >/dev/null)
if [ "$drill" = az-partition ]; then
  while kubectl -n $ns exec ackcheck-iso -- sh -c "pgrep -f 'ackcheck run -run $run-iso ' >/dev/null"; do sleep 5; done
  kubectl -n $ns exec ackcheck-iso -- /ackcheck verify -run "$run-iso" -out "/tmp/$run-iso" > "$out/verify-iso.json" 2> "$out/verify-iso.err" || log "isolated writer verify failed (see verify-iso.err)"
  (cd "$results_dir" && kubectl -n $ns cp "ackcheck-iso:/tmp/$run-iso" "$run/ackcheck-iso" >/dev/null)
fi
if [ "$drill" = disk-full ]; then
  kubectl -n $ns exec "$primary_pod" -c multipooler -- rm -f /var/lib/pooler/drill-fill && log "fill file removed"
fi
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
