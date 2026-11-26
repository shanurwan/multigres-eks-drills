#!/usr/bin/env bash
# Start the write checker pod in a given zone and copy the binary into it.
#   scripts/writer.sh apse2-az1
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: do not rewrite /paths passed to kubectl
here="$(cd "$(dirname "$0")/.." && pwd)"
zone="${1:?usage: writer.sh <zone-id>}"
ns=multigres-demo
bin="$here/tools/ackcheck/ackcheck"
if [ ! -x "$bin" ]; then
  (cd "$here/tools/ackcheck" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ackcheck .)
fi
kubectl -n "$ns" delete pod ackcheck --ignore-not-found --wait=true >/dev/null
sed "s|WRITER_ZONE|$zone|" "$here/manifests/writer.yaml" | kubectl apply -f -
kubectl -n "$ns" wait pod/ackcheck --for=condition=Ready --timeout=3m
# Relative path: kubectl cp reads "C:/..." as pod:path on Windows.
(cd "$here" && kubectl -n "$ns" cp tools/ackcheck/ackcheck ackcheck:/ackcheck)
kubectl -n "$ns" exec ackcheck -- chmod +x /ackcheck
echo "writer ready in $zone on $(kubectl -n "$ns" get pod ackcheck -o jsonpath='{.spec.nodeName}')"
