#!/usr/bin/env bash
# Install Istio in ambient mode (istiod, istio-cni, ztunnel) with small requests, so it fits
# beside Multigres on 2-vCPU nodes. ISTIOCTL points at istioctl from the official release.
#   ISTIOCTL=~/istio-1.32.0/bin/istioctl scripts/install.sh
set -euo pipefail
istioctl="${ISTIOCTL:-istioctl}"
"$istioctl" install -y --set profile=ambient \
  --set values.pilot.resources.requests.cpu=100m --set values.pilot.resources.requests.memory=256Mi \
  --set values.ztunnel.resources.requests.cpu=50m --set values.ztunnel.resources.requests.memory=128Mi \
  --set values.cni.resources.requests.cpu=50m --set values.cni.resources.requests.memory=64Mi
kubectl -n istio-system rollout status ds/ztunnel --timeout=5m
kubectl -n istio-system rollout status ds/istio-cni-node --timeout=5m
"$istioctl" version
