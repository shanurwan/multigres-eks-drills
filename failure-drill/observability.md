# Observability

What is recorded for every run, and how to read it to explain a result.

## Per run: `results/<drill>-<run>/`

| File | What it holds | Read it to answer |
|---|---|---|
| `run.txt` | drill, zones, the primary before, every container's image digest, Kubernetes version, timings used | exactly what was tested |
| `timeline.txt` | the harness's own steps with timestamps: writer start, fault, proof points, writer end, Healthy | when the fault happened, to the millisecond |
| `shard-timeline.txt` | Shard phase and each pooler's readiness, sampled every 6 to 9 seconds | when the operator noticed, and when it reported recovery |
| `ackcheck/<run>.events.jsonl` | every write attempt: time (µs), writer, sequence, outcome, latency, error | what the application saw, second by second |
| `verify.json` | acknowledged, failed, ambiguous, lost, outages, error kinds, latency percentiles | the headline numbers |
| `primary-before.txt`, `primary-after.txt` | which pooler was primary, by zone | where the failover went |
| `pods-before.txt`, `pods-after.txt`, `pods-zone-down.txt` | pods, nodes and restarts | what moved and what was stuck |
| `events.txt` | Kubernetes events in the namespace | scheduling failures, volume attach and detach, evictions |
| `fault.txt` | the fault command's output and its proof | that the fault happened (see [validation.md](validation.md)) |
| `logs/operator.log` | the operator, from a minute before the run | what the operator decided and why |
| `logs/<pod>.<container>.log` | every multiorch, gateway and pooler container (`postgres`, `multipooler`, `postgres-exporter`) | the failover from the inside: elections, promotions, refused connections |
| `logs/<pod>.<container>.previous.log` | the previous container's log, where one restarted | why a container died |

## Reading a failover

A typical sequence for a primary failure, in order of where to look:

1. `timeline.txt`: the fault time.
2. `ackcheck/*.events.jsonl`: the last acknowledged write before the fault, the first error, and the first acknowledged write after. The gap between them is the outage.
3. `logs/*multiorch*.log`: when multiorch noticed the primary was gone and which standby it chose.
4. `logs/*pool-default*.multipooler.log` on the new primary: the promotion.
5. `logs/*multigateway*.log`: when the gateway learned the new primary and stopped returning errors.
6. `shard-timeline.txt`: when the Shard left `Healthy`, and when it returned.

The gap between step 5 and step 6 is the time during which the application is fine but the operator still reports a problem, or the reverse. That is the "what clients see vs what the operator reports" chart in the summary.

## The operator's own monitoring stack

The operator ships Prometheus alert rules and three Grafana dashboards (`config/monitoring/` in its repository), and a development overlay that installs an OpenTelemetry Collector, Prometheus, Tempo and Grafana. This round did not install them: the drills' numbers come from the client's side and from logs, which do not depend on a monitoring stack being up during the fault. Running the operator's own stack through the same drills, to check whether its alerts fire and its dashboards show the failover, is the next step.
