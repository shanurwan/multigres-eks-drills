#!/usr/bin/env bash
# Run one production scenario around one failure drill from ../failure-drill.
#
#   scripts/scenario.sh storm 1            # supafirehose holding CONNS connections, then the fault
#   scripts/scenario.sh auth 1             # Supabase Auth logins, then the fault
#   scripts/scenario.sh storm 0 none       # the same load with no fault (baseline)
#
# The third argument is the drill (default pod-kill; anything drill.sh accepts, or "none").
# resources.txt has "<unix time> <pod> <memory bytes> <cpu usage_usec>" from each pod's cgroup.
# Environment: CONNS (default 500), READ_QPS (2000), WRITE_QPS (200), AUTH_RATE (20 ops/s),
# WRITE_FOR (6m), FAULT_AT (60 s), SCENARIO_RESULTS (default results/), TAG (added to the run name, e.g. buf30 for a changed buffer). Results land in results/<scenario>-<drill>-<conns|rate>-<n>/.
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
scenario="${1:?scenario: storm | auth}"
n="${2:?run number}"
drill="${3:-pod-kill}"
ns=multigres-demo
conns="${CONNS:-500}"
read_qps="${READ_QPS:-2000}"
write_qps="${WRITE_QPS:-200}"
auth_rate="${AUTH_RATE:-20}"
export WRITE_FOR="${WRITE_FOR:-6m}" FAULT_AT="${FAULT_AT:-60}"
secs=$(( ${WRITE_FOR%m} * 60 ))
case "$scenario" in
  storm) run="storm-$drill-c$conns${TAG:+-$TAG}-$n" ;;
  auth)  run="auth-$drill-r$auth_rate${TAG:+-$TAG}-$n" ;;
  *) echo "unknown scenario $scenario" >&2; exit 2 ;;
esac
results="${SCENARIO_RESULTS:-$here/results}"   # ../day2-operations keeps its runs in its own results/
out="$results/$run"
[ -e "$out" ] && { echo "$out exists; use another run number" >&2; exit 1; }
lg() { kubectl -n "$ns" exec loadgen -- sh -c "$1"; }
# The writer keys rows by run name, so a reused name would collide with an earlier run's rows.
if [ -n "$(lg "psql -Atc \"select 1 from ackcheck where run = '$run' limit 1\"" 2>/dev/null)" ]; then
  echo "run $run already has rows in the ackcheck table; use another run number" >&2; exit 1
fi
now() { date -u +%FT%T.%3NZ; }

# ---- load ---------------------------------------------------------------------
lg "rm -rf /tmp/$run; mkdir -p /tmp/$run"
if [ "$scenario" = storm ]; then
  lg "pkill -x supafirehose; sleep 1; nohup supafirehose > /tmp/$run/supafirehose.log 2>&1 &
      sleep 2
      post() { wget -qO- --header 'Content-Type: application/json' --post-data \"\$2\" http://localhost:8080/api/\$1 >/dev/null; }
      post config '{\"connections\":$conns,\"read_qps\":$read_qps,\"write_qps\":$write_qps,\"churn_rate\":0}'
      post start '{}'
      nohup fhrec -out /tmp/$run/metrics.jsonl -duration $((secs + 30))s > /tmp/$run/fhrec.log 2>&1 &
      nohup sh -c 'sleep $((secs + 25)); wget -qO- --post-data {} http://localhost:8080/api/stop' >/dev/null 2>&1 &"
  echo "$(now) supafirehose: $conns connections, $read_qps reads/s, $write_qps writes/s"
  sleep 25   # let every connection open before the drill's own writer starts
else
  lg "nohup authload run -url http://auth:9999 -users-file /tmp/users.json -rate $auth_rate -duration $((secs + 30))s -out /tmp/$run/auth.jsonl > /tmp/$run/authload.log 2>&1 &"
  echo "$(now) authload: $auth_rate ops/s"
  sleep 5
fi

# ---- gateway and client resources, one sampler per pod (kubectl exec takes ~1-4 s) ----
mkdir -p "$results"
pat='multigateway|^loadgen$'; [ "$scenario" = auth ] && pat='multigateway|^loadgen$|^auth-'
samplers=""
for p in $(kubectl -n "$ns" get pods --no-headers -o custom-columns=N:.metadata.name | grep -E "$pat"); do
  (
    while :; do
      v="$(kubectl -n "$ns" exec "$p" -- cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/cpu.stat 2>/dev/null | awk 'NR==1{m=$1} /usage_usec/{u=$2} END{print m, u}')"
      [ -n "$v" ] && echo "$(date +%s.%N | cut -c1-14) $p $v"
      sleep 1
    done
  ) > "$out.resources.$p.tmp" 2>/dev/null &
  samplers="$samplers $!"
done
# shellcheck disable=SC2086
trap 'kill $samplers 2>/dev/null || true' EXIT

# ---- the fault ----------------------------------------------------------------
if [ "$drill" = none ]; then
  mkdir -p "$out"
  echo "$(now) no fault; writer for $WRITE_FOR" | tee "$out/timeline.txt"
  kubectl -n "$ns" exec ackcheck -- sh -c "rm -rf /tmp/$run; mkdir -p /tmp/$run; /ackcheck run -run $run -workers 8 -rate 50 -timeout 2s -duration $WRITE_FOR -out /tmp/$run > /tmp/$run/run.log 2>&1"
  kubectl -n "$ns" exec ackcheck -- /ackcheck verify -run "$run" -out "/tmp/$run" > "$out/verify.json"
  (cd "$results" && kubectl -n "$ns" cp "ackcheck:/tmp/$run" "$run/ackcheck" >/dev/null)
else
  RESULTS_DIR="$results" RUN_NAME="$run" "$here/../failure-drill/scripts/drill.sh" "$drill" "$n" | sed "s/^/  /"
  # With RUN_NAME, drill.sh writes to $out and names the writer run the same.
fi

# ---- collect ------------------------------------------------------------------
# shellcheck disable=SC2086
kill $samplers 2>/dev/null || true
sort -n "$out".resources.*.tmp > "$out/resources.txt" && rm -f "$out".resources.*.tmp
# Nothing in the pod reaps finished processes, so skip zombies (state Z) when waiting.
# The [a]/[f] keep grep from matching its own command line.
while lg "ps -o stat,args | grep -v '^ *Z' | grep -qE '[a]uthload run|[f]hrec -out /tmp/$run '" 2>/dev/null; do sleep 5; done
(cd "$results" && kubectl -n "$ns" cp "loadgen:/tmp/$run" "$run/load" >/dev/null)
kubectl -n "$ns" logs deploy/auth --since=15m > "$out/load/auth-server.log" 2>/dev/null || true
for p in $(kubectl -n "$ns" get pods --no-headers -o custom-columns=N:.metadata.name | grep multigateway); do
  echo "$p restarts=$(kubectl -n "$ns" get pod "$p" -o jsonpath='{.status.containerStatuses[0].restartCount}') last=$(kubectl -n "$ns" get pod "$p" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}') peak_bytes=$(kubectl -n "$ns" exec "$p" -- cat /sys/fs/cgroup/memory.peak 2>/dev/null)"
done > "$out/gateways-after.txt"
echo "$(now) done: $out"
