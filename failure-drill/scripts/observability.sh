#!/usr/bin/env bash
# Install the operator's own monitoring stack (manifests/observability.yaml) into a zone
# the drills will not break, and point the operator and data plane at it.
#   scripts/observability.sh apse2-az1
# The operator's image does not change; adding OTEL_* variables to it makes the data-plane
# pods roll once to pick them up.
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
zone="${1:?usage: observability.sh <zone-id for the monitoring pods>}"
ns=multigres-operator
sel="{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"topology.k8s.aws/zone-id\":\"$zone\"}}}}}"

echo "== Prometheus Operator v0.80.0 (the version the operator's Makefile uses)"
kubectl apply --server-side -f https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.80.0/bundle.yaml >/dev/null
kubectl -n default patch deploy prometheus-operator -p "$sel" >/dev/null
kubectl -n default rollout status deploy/prometheus-operator --timeout=5m

echo "== monitoring stack"
(cd "$here" && kubectl apply --server-side -n "$ns" -f manifests/observability.yaml >/dev/null)
for d in otel-collector tempo grafana; do kubectl -n "$ns" patch deploy "$d" -p "$sel" >/dev/null; done
kubectl -n "$ns" patch prometheus multigres --type=merge -p "{\"spec\":{\"nodeSelector\":{\"topology.k8s.aws/zone-id\":\"$zone\"}}}" >/dev/null
for d in otel-collector tempo grafana; do kubectl -n "$ns" rollout status deploy/"$d" --timeout=5m; done
kubectl -n "$ns" wait pod -l prometheus=multigres --for=condition=Ready --timeout=5m

echo "== operator: OTEL_* settings from config/deploy-observability/manager-otel-patch.yaml"
kubectl -n "$ns" set env deploy/multigres-operator-controller-manager -c manager \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.multigres-operator.svc:4318 \
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
  OTEL_TRACES_EXPORTER=otlp \
  OTEL_METRICS_EXPORTER=otlp \
  OTEL_TRACES_SAMPLER=always_on \
  OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION=base2_exponential_bucket_histogram >/dev/null
kubectl -n "$ns" rollout status deploy/multigres-operator-controller-manager --timeout=5m
kubectl -n "$ns" get pods -o wide
echo "Grafana: kubectl -n $ns port-forward svc/grafana 3000:3000   (then http://localhost:3000)"
