# Monitoring gaps seen during the zone outage

The operator's own monitoring stack was installed for the zone outage drill (`az-outage-1`): Prometheus with its PrometheusRule alerts, Grafana with its three dashboards, the OpenTelemetry Collector and Tempo, rendered from `config/monitoring` and `config/deploy-observability` at the tested commit (`manifests/observability.yaml`, `scripts/observability.sh`). The monitoring pods ran in `apse2-az1`, outside the zone taken down.

Screenshots and alert snapshots are in `results/az-outage-1-dashboards/`.

## What worked

- The critical `MultigresCellGatewayUnavailable` and `MultigresClusterReconcileErrors` **fired**; `MultigresClusterDegraded` and `MultigresPoolPodsStuck` went to pending (their `for:` windows are 10 and 15 minutes). See `alerts-1533.json`.
- The Data Plane dashboard showed what the application saw: the query rate stayed at about 400 a second through the outage, and p95 latency rose briefly to about 6.8 ms when the zone came back (`4-after-data-plane.jpg`).

## Gaps

| ID | Gap | Evidence | Suggested change |
|---|---|---|---|
| O1 | No alert covers the global topology or its etcd. All 11 rules are built on operator metrics (cluster phase, gateways, pools, reconcile errors, webhooks, backups, rollouts, drains). During the outage etcd was down to 1 of 3 members and nothing alerted on that. | the rule list in this file's section below | an alert on topology server members not ready, or on etcd quorum (etcd exposes `etcd_server_has_leader`) |
| O2 | With a zone gone and etcd quorum lost, Cluster Health showed the cluster as `Progressing` and "Clusters in Error: 0". The top-level view reads like a rollout in progress. | `3-during-cluster-health.jpg` | count `Degraded` (and long `Progressing`) clusters as needing attention, or show topology health on the same row |
| O3 | Data-plane metrics are pushed about every 60 seconds (the OpenTelemetry SDK default; the overlay sets no export interval). In a 5-minute window Prometheus held 2 samples per series, so the SQL panels were blank for the first couple of minutes and a 20-second failover is a single point. The operator's docs example uses 30 seconds. | `count_over_time(mg_gateway_query_duration_seconds[5m]) = 2` | set `OTEL_METRIC_EXPORT_INTERVAL` (or `spec.observability.metricExportInterval`) to 10 to 15 seconds in the overlay |
| O4 | Cluster Health lists the `demo` cluster under namespace `multigres-operator`; the cluster is in `multigres-demo`. Probably the scrape target's namespace label shown instead of the cluster's. | `1-before-cluster-health.jpg` | use the cluster's namespace label in that panel |

## Alert rules loaded (11)

`MultigresClusterReconcileErrors`, `MultigresClusterDegraded`, `MultigresCellGatewayUnavailable`, `MultigresShardPoolDegraded`, `MultigresWebhookErrors`, `MultigresBackupStale`, `MultigresRollingUpdateStuck`, `MultigresPoolPodsStuck`, `MultigresDrainTimeout`, `MultigresReconcileSlow`, `MultigresControllerSaturated`.
