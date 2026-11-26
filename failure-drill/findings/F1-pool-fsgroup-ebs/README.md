# F1: on EBS the pooler cannot write to its own volume

## Symptom

A new `MultigresCluster` on EKS never becomes ready. Every pool pod loops in `Init:CrashLoopBackOff`, and the gateways restart because no primary exists. The `postgres` init container exits with:

```
Error: failed to create pgbackrest directory: mkdir /var/lib/pooler/pgbackrest: permission denied
```

## Evidence (in this folder)

| File | Shows |
|---|---|
| `postgres-init.log` | the error above, from the pool pod's `postgres` container |
| `security-context.txt` | pod security context `{}`; container runs as uid 999, gid 999, `runAsNonRoot` |
| `pods.txt` | all three pool pods in `Init:CrashLoopBackOff`, gateways restarting |
| `shard-conditions.txt` | the Shard's conditions at the time |

## Cause

- The pool's containers run as uid/gid 999 (`postgres`).
- A new EBS volume is formatted by the CSI driver and its root directory is owned by `root`.
- Kubernetes changes a volume's group ownership only when the pod sets `fsGroup`. The operator sets the pod security context only when the pool spec has `fsGroup` (`buildPoolPodSecurityContext` in `pkg/resource-handler/controller/shard/pool_pod.go`), and the field has no default.
- On kind, the local-path provisioner creates world-writable directories, so the same spec works there. That is why the project's tests, which all run on kind, do not see this.

History: PR #452 removed hard-coded UIDs and made the pool's `fsGroup` explicit; later PRs (#453, #528, #542) reworked the container identity defaults. None of the samples or docs set `fsGroup`.

## Workaround

Set `fsGroup` on every pool, matching the postgres group:

```yaml
pools:
  default:
    fsGroup: 999
```

`manifests/cluster.yaml` here does this.

## Suggested fix

Either default `fsGroup` to the postgres GID (999) when it is unset, matching the container identity the operator already defaults, or set it in the samples and document it as required on any CSI driver that creates root-owned volumes (EBS, GCE PD, Azure Disk).

## Reproduce

1. EKS with the EBS CSI driver and a gp3 StorageClass.
2. Any `MultigresCluster` whose pools do not set `fsGroup`.
3. `kubectl logs <pool-pod> -c postgres` shows the error within a minute.
