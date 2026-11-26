# F2: fixing the spec does not repair a cluster that never started

## Symptom

After F1, adding `fsGroup: 999` to the pool spec is accepted, reaches the Shard, and nothing happens. The pool pods keep crashing with the old security context. The Shard reports:

```
RollingUpdate=True RolloutBlocked: not replacing pod demo-postgres-default-0-inf-pool-default-az1-4b646709-0:
awaiting a registered target and a committed primary
PostureConsistent=Unknown AwaitingPoolerRegistration: Waiting for multipoolers to register in topology
```

## Evidence (in this folder)

`state-before-manual-delete.txt`: the Shard's `fsGroup` (999), its conditions, and the pods still in `Init:CrashLoopBackOff`, followed by the recovery time after the manual step.

## Cause

The rolling update protects availability by replacing a pod only once there is a committed primary and a registered target to hand over to. A cluster that has never had a primary can never meet that condition, so the safety check blocks the only change that would let it get a primary.

## Workaround

Delete the pool pods once. The operator recreates them from the current spec:

```sh
kubectl -n <ns> delete pod -l <pool pods>      # here: the three *-pool-default-* pods
```

Here the cluster reported `Healthy` 268 seconds after the delete.

## Suggested fix

Skip the "committed primary" precondition when no pod of the pool has ever been ready (or the shard has never had a primary), since there is no availability left to protect. Alternatively, surface this state as its own condition, so the operator tells the user that a manual pod delete is required.
