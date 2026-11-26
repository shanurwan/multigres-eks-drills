# F3: by default the global etcd is not spread across zones

## Symptom

In a 3-zone cluster, two of the three members of the operator-managed global topology etcd were scheduled into the same zone:

```
demo-global-topo-0 apse2-az3
demo-global-topo-1 apse2-az2
demo-global-topo-2 apse2-az3
```

Their EBS volumes were created in that zone too (`WaitForFirstConsumer`), so the placement is permanent: a restarted member can only run in the zone that holds its volume.

## Evidence (in this folder)

| File | Shows |
|---|---|
| `placement.txt` | each member's zone, each volume's zone, and the StatefulSet's affinity and topology spread constraints (both empty) |
| `etcd-spec-fields.txt` | `kubectl explain multigrescluster.spec.globalTopoServer.etcd`: the etcd settings themselves (image, maintenance, pvcDeletionPolicy, replicas, resources, rootPath, storage) |
| `placement-spec-field.txt` | `kubectl explain multigrescluster.spec.globalTopoServer.placement`: affinity, nodeSelector, tolerations and topologySpreadConstraints for the etcd pods |

The spec can spread etcd (`globalTopoServer.placement.topologySpreadConstraints`), but the operator sets no default, and neither the docs nor the samples mention it for the global topology (checked: README, `docs/configuration.md`, `docs/storage.md`, `docs/topology-maintenance.md`, `config/samples/`).

## Impact

Losing the zone that holds two members leaves one of three: etcd loses quorum. What that does to a running shard is measured by the zone drill against `apse2-az3` (see the summary).

Placement is decided by the scheduler at creation time, so whether a given cluster is exposed depends on chance.

## Workaround

Set a zone spread when the cluster is created:

```yaml
spec:
  globalTopoServer:
    placement:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:                          # the etcd pods' labels
              app.kubernetes.io/component: toposerver
              multigres.com/cluster: <cluster name>
```

It only helps at creation. Once a member's EBS volume exists, that member can only run in the volume's zone, so moving it means deleting its PersistentVolumeClaim and letting etcd re-sync the member. An external etcd that is already spread across zones (`globalTopoServer.external`) avoids the problem too.

## Suggested fix

Default the managed etcd to a zone spread (`maxSkew: 1` on `topology.kubernetes.io/zone`, with `whenUnsatisfiable: ScheduleAnyway` so single-zone clusters still schedule), and mention `placement` in the docs for multi-zone clusters. The pool pods are pinned per cell already; the global topology is the one component that spans zones and has no default rule.
