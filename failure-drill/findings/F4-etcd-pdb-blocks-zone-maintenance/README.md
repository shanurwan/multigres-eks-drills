# F4: with etcd packed into one zone, that zone's nodes cannot be drained

## Symptom

Draining the node in `apse2-az3`, the zone holding two of the three global etcd members (F3), never completes. In this round it happened twice with `kubectl drain` and once with EKS itself:

- **`kubectl drain`** (drills `node-drain-1` and `node-drain-3`): one etcd member is evicted, then every attempt to evict the second fails for 10 minutes until the drain times out:

  ```
  error when evicting pods/"demo-global-topo-2" -n "multigres-demo" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
  ```

  115 retries in one run. The Shard reported `Progressing` for the whole time and `Healthy` about 700 seconds after the drain started, against 43 seconds when draining a node in another zone.

- **EKS scale-in** (the first attempt at a zone drill): scaling the zone's managed node group to 0 left the instance in `Terminating:Wait` (`MidTerminatingLifecycleAction`) for more than 6 minutes, with the same two etcd pods, one `Pending` and one un-evictable, until the node group was scaled back.

## Evidence (in this folder)

| File | Shows |
|---|---|
| `node-drain-1-timeline.txt`, `node-drain-1-fault.txt` | the drain's start, its 10-minute timeout, and every eviction attempt |
| `eks-scale-in-stuck.txt` | nodes, the etcd and pool pods, both PodDisruptionBudgets (0 allowed disruptions), the Auto Scaling activity and the instance's lifecycle state |

The full runs are in `results/node-drain-1/` and `results/node-drain-3/`.

## Cause

Three things together:

1. Two etcd members, and their EBS volumes, are in the same zone (F3).
2. The etcd PodDisruptionBudget allows one member to be unavailable (`maxUnavailable: 1`), which is right for a 3-member etcd.
3. The zone has one node. The evicted member cannot start anywhere else, because its volume can only attach in its own zone, and that zone's only node is cordoned.

So the first eviction uses the budget, the evicted member never comes back, and the second can never be evicted. With more than one node in the zone the first member would move and the drain would continue, but the window in which the zone is down to one etcd member would still exist.

## Impact

- Routine node maintenance in that zone stalls: `kubectl drain`, EKS managed node group upgrades (which wait for disruption budgets for a limited time, then fail or force the eviction), and Karpenter consolidation.
- While stuck, one etcd member is down and a second is the next to go; the cluster is one failure from losing the global topology's quorum.

## Workaround

- Spread etcd across zones at creation (see F3).
- Or run at least two nodes per zone, so an evicted member can restart in its own zone.

## Suggested fix

The fix for F3 (a default zone spread for the managed etcd) removes this. A cheaper complement: a status condition or warning when two etcd members share a zone, since that is the state in which ordinary maintenance can deadlock.
