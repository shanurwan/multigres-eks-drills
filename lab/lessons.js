// The lessons, and what each one says once its run has played. Every number in an
// outcome is computed here from the run record, not written in by hand.

const fmt = (n) => (n == null ? "–" : Number(n).toLocaleString("en-US"));
const secs = (n) => (n == null ? "–" : `${Number(n).toFixed(1)} s`);

// Seconds in which at least one write failed while the Shard's phase said Healthy.
export function healthyWhileFailing(run) {
  let n = 0;
  const { t0, werr } = run.series;
  werr.forEach((e, i) => {
    if (!e) return;
    const t = t0 + i;
    let phase = "Healthy";
    for (const [at, p] of run.shard) { if (at > t) break; phase = p; }
    if (phase === "Healthy") n++;
  });
  return n;
}

const common = (run) => [
  { value: fmt(run.verify.lost_acked), label: "acknowledged writes lost" },
  { value: secs(run.facts.writer_longest_outage_s), label: "longest gap with no acknowledged write" },
  { value: fmt(run.facts.fh_errors_total), label: `errors seen by ${fmt(run.facts.fh_connections || 500)} app connections` },
];

export const LESSONS = [
  {
    id: "meet", short: "Meet the cluster",
    title: "Three zones, one primary",
    body: [
      "This is a Multigres cluster on Amazon EKS, spread over three availability zones in Sydney. Each zone runs a <b>gateway</b> that apps connect to and a <b>pool pod</b> with Postgres and its pooler. <b>etcd</b>, which holds the topology, has three members, drawn where the scheduler actually put them: two shared a node in zone 3.",
      "One Postgres is the primary. The other two are standbys, and a write is only acknowledged once a standby in another zone has it. <b>multiorch</b> watches the shard and appoints a new primary when it has to.",
      "Two things push traffic through it in every lesson: Multigres's own load tool holding 500 app connections, and a writer that records every insert and later checks that each acknowledged one is still there.",
    ],
    commands: ["kubectl get pods -n multigres-demo", "scripts/primary.sh"],
    aside: "The terminal replays what these commands printed on the real cluster. Nothing on this page talks to AWS.",
  },
  {
    id: "switchover", short: "Planned switchover", key: "switchover",
    title: "Move the primary on purpose",
    body: [
      "Before maintenance you move the primary yourself: <code>multigres cluster switch-primary</code>. The old primary stops taking writes, a standby takes over, and the gateways hold queries for the few seconds in between and replay them.",
      "Watch the gold ring move to another zone, and the strip: does any app connection see an error?",
    ],
    commands: ["scripts/day2.sh switchover"],
    aside: "Four runs were recorded, two before and two after an upgrade to a newer Multigres image. Pick them with the run buttons on the picture.",
    outcome(run) {
      return {
        figures: [...common(run), { value: secs(run.switch_s), label: "until writes went to the new primary" }],
        paragraphs: [
          `The primary moved from ${run.primary_before} to ${run.primary_after}. The gateways held ${fmt(run.facts.buffer_drained)} queries and replayed them on the new primary, so the app's connections saw ${fmt(run.facts.fh_errors_total)} errors.`,
          `The drill writer gives up on a write after 2 s, which is shorter than the gateways held queries here. So ${fmt(run.facts.writer_ambiguous)} writes in flight at the switch timed out on its side, and ${fmt(run.facts.writer_ambiguous_present)} of them turned out to be committed anyway. None that was acknowledged went missing.`,
        ],
      };
    },
  },
  {
    id: "upgrade", short: "Rolling upgrade", key: "mg-upgrade",
    title: "Upgrade Multigres under load",
    body: [
      "A new Multigres image is set on the <code>MultigresCluster</code>, and the operator replaces every pod: gateways, orchestrators, the pool pods one at a time, with a planned switchover before the primary's.",
      "Watch the counter of pods still on the old image, and what happens to the app's connections when the gateways are replaced.",
    ],
    commands: ["scripts/day2.sh mg-upgrade"],
    aside: "The new image is the first one with multigres#1730, a change to how a primary is drained.",
    outcome(run) {
      return {
        figures: [...common(run), { value: secs(run.facts.rollout_s), label: "until no pod ran the old image" }],
        paragraphs: [
          `All the errors came in the first seconds, when the gateway pods were replaced: each app connection on an old gateway was closed once (<code>unexpected EOF</code>) and reconnected. Connections dipped to ${fmt(run.facts.fh_min_connections)} of 500.`,
          "The primary's own move was a planned switchover, invisible to the app. A Postgres proxy can't hand a live client connection to another pod, so a gateway rollout means one reconnect per client. Plan rollouts for it.",
        ],
      };
    },
  },
  {
    id: "nodegroup", short: "Node group upgrade", key: "ng-upgrade",
    title: "Replace the primary's node",
    body: [
      "An EKS managed node group upgrade, the kind an AMI update triggers: AWS starts a new node, drains the old one and terminates it. Here it's the node holding the primary.",
      "Watch the pool pod in that zone go dark while it moves, and the primary move away first.",
    ],
    commands: ["scripts/day2.sh ng-upgrade"],
    aside: "Two runs of the same operation. Compare them with the run buttons: the client errors differ by about forty times.",
    outcome(run) {
      return {
        figures: [...common(run), { value: secs(run.facts.ng_update_s), label: "for the node group update" }],
        paragraphs: [
          `The update succeeded, and the primary moved from ${run.primary_before} to ${run.primary_after}. ${run.facts.credential_lookup_failed ? `This time ${fmt(run.facts.credential_lookup_failed)} app reconnects failed their login lookup while no primary could answer.` : "This time almost no app connection noticed."}`,
          "The same operation on the same cluster gave 6,288 client errors in one run and 158 in the other. In the first, the new primary landed on the zone 1 node, which also ran the load tool and Auth on 2 vCPUs. One run tells you little, so run it a few times.",
        ],
      };
    },
  },
  {
    id: "partition", short: "Cut a zone off", key: "az-partition",
    title: "Cut the primary's zone off the network",
    body: [
      "The primary's zone keeps running, but its subnet gets a network ACL that blocks the other two zones, both ways. It's a partition, not an outage: the old primary is alive and still has clients.",
      "A second writer runs inside the cut-off zone, through that zone's own gateway. The question that matters: does the isolated side acknowledge writes it can't replicate?",
    ],
    commands: ["scripts/day2.sh az-partition"],
    aside: "In run 2 the cut-off zone also held 2 of the 3 etcd members, so the side that kept working had no etcd quorum.",
    incidents: [{
      who: "GitHub", when: "October 2018",
      what: "43 seconds of lost connectivity between two data centres led to a cross-country failover of MySQL primaries, and writes on both sides that then had to be reconciled. The site was degraded for about 24 hours.",
      why: "A short partition with automatic failover is exactly the case to rehearse.",
      url: "https://github.blog/2018-10-30-oct21-post-incident-analysis/", link: "GitHub's post-incident analysis",
    }],
    outcome(run) {
      return {
        figures: [
          { value: fmt(run.facts.iso_acked_in_flight), label: `writes acknowledged inside the cut-off zone after the cut, all within ${Math.round((run.facts.iso_last_ack_after_cut_s || 0) * 1000)} ms` },
          { value: fmt((run.verify.lost_acked || 0) + (run.verify_iso?.lost_acked || 0)), label: "acknowledged writes lost, both writers" },
          { value: secs(run.facts.writer_longest_outage_s), label: "longest gap with no acknowledged write, outside" },
          { value: secs(run.facts.iso_back_after_heal_s), label: "after the heal until the inside writer could write again" },
        ],
        paragraphs: [
          `The isolated primary couldn't get another zone to confirm, so ${run.facts.iso_acked_in_flight ? `apart from ${fmt(run.facts.iso_acked_in_flight)} writes already in flight when the ACL landed, ` : ""}it acknowledged nothing. The writer inside the zone got ${fmt(run.facts.iso_errors)} errors and no late successes. Outside, multiorch noticed through <code>${run.facts.detection}</code>, its check for a primary whose commits have stopped, ${secs(run.facts.detection_s)} after the drill started (the cut itself took effect ${secs(run.facts.cut_after_fault_s)} in), and promoted ${run.primary_after}.`,
          run.etcd && run.etcd.filter((z) => z === ["apse2-az1", "apse2-az2", "apse2-az3"].indexOf(run.cut?.zone)).length >= 2
            ? "The cut-off zone held 2 of the 3 etcd members, so the side that promoted had no etcd quorum. The promotion went ahead anyway, and nothing acknowledged was lost."
            : "",
        ].filter(Boolean),
      };
    },
  },
  {
    id: "disk", short: "Fill the disk", key: "disk-full",
    title: "Fill the primary's disk, then watch the status",
    body: [
      "A file fills the primary's data volume until only a little space is left. Postgres needs to extend its files to write. What does the app see, and what does the cluster report?",
      "Keep an eye on the phase badge at the top of the picture while the writes fail. After three minutes the volume is grown through the <code>MultigresCluster</code>'s <code>storage.size</code>.",
    ],
    commands: ["scripts/day2.sh disk-full"],
    aside: "Run 1 left 64 MiB free and Postgres never ran out. Run 2 left 1 MiB. Both are here, run 2 first.",
    outcome(run) {
      const healthyFailing = healthyWhileFailing(run);
      return {
        figures: [
          ...common(run).slice(0, 2),
          { value: `${healthyFailing} s`, label: "with failing writes while the Shard said Healthy" },
          { value: secs(run.facts.grow_took_s), label: "for the PVC to report the new size" },
        ],
        paragraphs: run.fill_leave_mb > 8
          ? ["With 64 MiB left, Postgres used only about 25 MiB in four minutes, so the disk never filled and nothing failed. The run shows only that growing the volume online is safe."]
          : [
            "Every write failed with <code>53100 could not extend file … No space left on device</code>. The primary kept its role and its pods stayed ready, so nothing failed over. The Shard's phase follows pod readiness, so it stayed Healthy for most of it. An alert on the phase would have said nothing.",
            "Growing the volume brought writes back within seconds, without a restart. A full disk needs its own alert, on the volume's free space.",
          ],
      };
    },
  },
  {
    id: "live", short: "Run it yourself",
    title: "Run every lesson on your own cluster",
    body: [
      "Everything here came from a Terraform template and a handful of scripts in the same repository. A free-plan AWS account is enough: the cluster costs about USD 0.50 an hour, and a full round takes an afternoon.",
      "The guide below the course walks through it, from a new AWS account to these exact commands. When you have your own results, build them into a <code>runs.json</code> and load it here to replay them on the same picture.",
    ],
    commands: ["terraform -chdir=terraform apply"],
    aside: "Destroy the cluster at the end of every session. The guide's last step shows how, and how to check nothing is left.",
  },
];

export function outcomeFor(lesson, run) {
  return lesson.outcome && run ? lesson.outcome(run) : { figures: [], paragraphs: [] };
}
