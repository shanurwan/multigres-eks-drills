// Multigres day-2 lab.
//
// A replay, not a simulation and not a live cluster. The terminal prints the run's own
// timeline and checks, and the picture is driven by the same record: which zone held the
// primary, which zone was cut off, the Shard's phase and which pool pods were ready, how
// full the primary's disk was, and how many writes and app requests succeeded or failed
// in each second. Two things are drawn only to make the picture readable and are not
// measured: the individual dots (the record keeps counts per second, not paths), and
// which gateway a dot passes through. The role change is drawn when the writer's writes
// came back, the first moment the record shows clients reaching the new primary.

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { LESSONS, outcomeFor, healthyWhileFailing } from "./lessons.js";

const $ = (id) => document.getElementById(id);
const Q = new URLSearchParams(location.search);
const TT = Q.has("tiktok");          // the scripted vertical video
const CAPTURE = Q.has("capture");    // frames are stepped by a script, not by the browser
const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const store = {
  get(k, f) { try { return JSON.parse(localStorage.getItem(k)) ?? f; } catch { return f; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private window */ } },
};

const S = {
  bundle: null, byKey: new Map(), lesson: 0,
  done: new Set(store.get("mglab.done", [])), pick: {},
  run: null, t: 0, playing: false, speed: 8, finished: false,
  printed: 0, lines: [], block: null, own: false,
};

// ---------- data ---------------------------------------------------------------------

function index(bundle) {
  S.bundle = bundle;
  S.byKey = new Map();
  for (const run of bundle.runs) {
    if (!S.byKey.has(run.drill)) S.byKey.set(run.drill, []);
    S.byKey.get(run.drill).push(run);
  }
  // A disk that really filled comes first; then by run number.
  for (const runs of S.byKey.values()) runs.sort((a, b) => (a.fill_leave_mb ?? 0) - (b.fill_leave_mb ?? 0) || a.n - b.n);
  const first = bundle.runs[0];
  const day = first ? new Date(first.started).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }) : "";
  const lost = bundle.runs.reduce((a, r) => a + (r.verify.lost_acked || 0) + (r.verify_iso?.lost_acked || 0), 0);
  const writes = bundle.runs.reduce((a, r) => a + (r.verify.acked || 0) + (r.verify_iso?.acked || 0), 0);
  $("provenance").textContent = S.own
    ? `Your ${bundle.runs.length} runs, loaded from your file. They stay in this browser tab.`
    : `${bundle.runs.length} runs recorded on ${day} on a 3-zone EKS cluster: ${writes.toLocaleString("en-US")} acknowledged writes checked, ${lost} lost. Nothing on this page talks to a cluster.`;
}

async function load() {
  const res = await fetch("data/runs.json");
  if (!res.ok) throw new Error(`data/runs.json: ${res.status}`);
  index(await res.json());
}

const at = (run, arr, t) => {
  const i = Math.floor(t) - run.series.t0;
  return i >= 0 && i < arr.length ? arr[i] : 0;
};

// What the cluster looked like at t, rebuilt from the record.
function stateAt(run, t) {
  const primary = run.switch_s != null && t >= run.switch_s ? run.primary_after : run.primary_before;
  let phase = "Healthy", ready = [true, true, true];
  for (const [s, p, r] of run.shard) { if (s > t) break; phase = p; ready = r; }
  const cut = run.cut && t >= run.cut.from_s && t < run.cut.heal_s ? run.cut.zone : null;
  let disk = null;
  if (run.disk?.length) {
    const pts = run.disk;
    const before = [...pts].reverse().find((p) => p[0] <= t);
    if (t >= pts[0][0] - 2 && before) disk = { used: before[2] / before[1], availMb: before[3], sizeMb: before[1] };
  }
  let oldPods = null;
  if (run.rollout?.length && t >= 0) { oldPods = 9; for (const [s, n] of run.rollout) { if (s > t) break; oldPods = n; } }
  let ng = null;
  if (run.ng_update?.length && t >= 0) { for (const [s, x] of run.ng_update) { if (s > t) break; ng = x; } ng ??= "InProgress"; }
  return {
    primary, phase, ready, cut, disk, oldPods, ng,
    ok: at(run, run.series.ok, t), werr: at(run, run.series.werr, t), ferr: at(run, run.series.ferr, t),
    conns: at(run, run.series.conns, t),
    isoOk: run.iso ? at(run, run.iso.ok, t) : 0, isoErr: run.iso ? at(run, run.iso.err, t) : 0,
  };
}

// ---------- lessons ------------------------------------------------------------------

function renderLessons() {
  const list = $("lessons");
  list.innerHTML = "";
  LESSONS.forEach((lesson, i) => {
    const li = document.createElement("li");
    const b = document.createElement("button");
    b.type = "button";
    b.innerHTML = `<span class="num">${S.done.has(lesson.id) ? "✓" : i + 1}</span>${lesson.short}`;
    if (S.done.has(lesson.id)) b.classList.add("done");
    if (i === S.lesson) b.setAttribute("aria-current", "step");
    b.addEventListener("click", () => openLesson(i));
    li.append(b);
    list.append(li);
  });
}

function fieldNotes(lesson) {
  if (!lesson.incidents?.length) return "";
  return `<aside class="field"><h3>It has happened for real</h3>${lesson.incidents.map((i) => `
    <div class="incident"><p class="who">${i.who} <span>${i.when}</span></p><p>${i.what}</p>
    <p class="lesson-link">${i.why}</p><p><a href="${i.url}" target="_blank" rel="noopener">${i.link} ↗</a></p></div>`).join("")}
    <p class="aside">The summary is ours; the report is theirs. Read it in full.</p></aside>`;
}

function openLesson(i, { focus = true } = {}) {
  S.lesson = i;
  store.set("mglab.lesson", i);
  const lesson = LESSONS[i];
  $("lesson").innerHTML = `
    <p class="kicker">Lesson ${i + 1} of ${LESSONS.length}</p>
    <h2>${lesson.title}</h2>
    ${lesson.body.map((p) => `<p>${p}</p>`).join("")}
    <h3>Type this in the terminal</h3>
    ${lesson.commands.map((c) => `<code class="type">${c}</code>`).join("")}
    <p class="aside">${lesson.aside}</p>
    <div class="outcome" id="outcome" hidden></div>
    ${fieldNotes(lesson)}`;
  renderLessons();
  if (S.done.has(lesson.id)) showOutcome(lesson, lastRunFor(lesson));
  if (focus && matchMedia("(min-width: 900px)").matches) $("term-in").focus({ preventScroll: true });
  if (!S.playing) idleScene(lesson);
}

function lastRunFor(lesson) {
  if (!lesson.key) return null;
  const runs = S.byKey.get(lesson.key) || [];
  return runs[S.pick[lesson.key] || 0] || null;
}

function showOutcome(lesson, run) {
  const box = $("outcome");
  if (!box) return;
  const { figures, paragraphs } = outcomeFor(lesson, run);
  const next = S.lesson < LESSONS.length - 1
    ? `<div class="next"><button type="button" id="next">Next: ${LESSONS[S.lesson + 1].short}</button></div>`
    : `<div class="next"><a class="button" href="#live" style="margin-top:0">Set it up yourself</a></div>`;
  box.innerHTML = `<h3>${lesson.id === "meet" || lesson.id === "live" ? "Next" : "What just happened"}</h3>
    ${figures.length ? `<div class="figures">${figures.map((f) => `<div class="figure"><b>${f.value}</b><span>${f.label}</span></div>`).join("")}</div>` : ""}
    ${paragraphs.map((p) => `<p>${p}</p>`).join("")}${next}`;
  box.hidden = false;
  const btn = $("next");
  if (btn) btn.addEventListener("click", () => { openLesson(S.lesson + 1); $("course").scrollIntoView({ block: "start" }); });
}

function markDone(lesson, run) {
  S.done.add(lesson.id);
  store.set("mglab.done", [...S.done]);
  renderLessons();
  showOutcome(lesson, run);
}

// ---------- terminal -----------------------------------------------------------------

const out = $("term-out");
const input = $("term-in");
const history = [];
let historyAt = 0;

function print(text, cls) {
  const div = document.createElement("div");
  if (cls) div.className = cls;
  div.textContent = text === "" ? " " : text;
  out.append(div);
  $("term-body").scrollTop = $("term-body").scrollHeight;
  return div;
}

function classify(line) {
  if (/fault:|partition |could not|fill |not Healthy|NOT/.test(line)) return "fault";
  if (/heal:|fix:|capacity:|shard Healthy|rollout:|node group update|switch-primary returned/.test(line)) return "good";
  if (/verify/.test(line)) return "note";
  return "";
}

const DRILLS = ["switchover", "mg-upgrade", "ng-upgrade", "az-partition", "disk-full"];
const HELP = [
  "This terminal replays recorded runs. Commands it knows:",
  "",
  "  kubectl get pods -n multigres-demo",
  "  scripts/primary.sh",
  ...DRILLS.map((d) => `  scripts/day2.sh ${d}`),
  "  terraform -chdir=terraform apply",
  "  clear, help",
  "",
  "Tab completes the current lesson's command. Up and down walk your history.",
];

function execute(raw) {
  const line = raw.trim();
  print(line, "cmd");
  if (!line) return;
  history.push(line); historyAt = history.length;
  const w = line.split(/\s+/);
  if (S.playing) stopReplay();
  if (line === "help") return HELP.forEach((l) => print(l, "note"));
  if (line === "clear") { out.innerHTML = ""; return; }

  if (w[0] === "kubectl") {
    if (w[1] === "get" && /^pods?$/.test(w[2] || "")) { S.bundle.pods.split("\n").forEach((l) => print(l)); return; }
    return print("This replay only recorded: kubectl get pods -n multigres-demo", "note");
  }
  if (/primary\.sh$/.test(w[0])) {
    (S.bundle.primary || "").split("\n").forEach((l) => print(l));
    print("(zone, pool pod, node, role: read inside each pod with pg_is_in_recovery())", "note");
    if (LESSONS[S.lesson].id === "meet") markDone(LESSONS[S.lesson], null);
    return;
  }
  if (w[0] === "terraform" || (w[0] === "terraform" && w.includes("apply"))) {
    ["This page can't create AWS resources. On your own machine this command builds the",
      "VPC, the 3-zone EKS cluster, the backup bucket and the IAM roles, in about 20 minutes.",
      "", "The full guide is below the course, under \"Run it yourself\"."].forEach((l) => print(l, "note"));
    const lesson = LESSONS.find((l) => l.id === "live");
    if (lesson) { if (LESSONS[S.lesson] !== lesson) openLesson(LESSONS.indexOf(lesson), { focus: false }); markDone(lesson, null); }
    return;
  }
  if (!/day2\.sh$/.test(w[0])) return print(`${w[0]}: not part of this replay. Type help to see what is.`, "note");
  const drill = w[1];
  const runs = S.byKey.get(drill);
  if (!runs) return print(`day2.sh: unknown drill "${drill || ""}": use ${DRILLS.join(", ")}`, "warn");
  let pick = S.pick[drill] || 0;
  if (w[2] && /^\d+$/.test(w[2])) pick = clamp(runs.findIndex((r) => r.n === Number(w[2])), 0, runs.length - 1);
  S.pick[drill] = pick;
  startReplay(runs[pick]);
}

input.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { const v = input.value; input.value = ""; execute(v); }
  else if (e.key === "Tab") {
    e.preventDefault();
    const cmds = LESSONS[S.lesson].commands;
    input.value = cmds.find((c) => c.startsWith(input.value) && c !== input.value) || cmds.at(-1);
  }
  else if (e.key === "ArrowUp") { if (historyAt > 0) input.value = history[--historyAt]; e.preventDefault(); }
  else if (e.key === "ArrowDown") { input.value = historyAt < history.length - 1 ? history[++historyAt] : ((historyAt = history.length), ""); e.preventDefault(); }
  else if (e.key === "l" && e.ctrlKey) { e.preventDefault(); out.innerHTML = ""; }
});
$("term-body").addEventListener("click", () => { if (!getSelection().toString()) input.focus({ preventScroll: true }); });

function typeFor(command) {
  input.focus({ preventScroll: true });
  if (reducedMotion) { input.value = ""; execute(command); return; }
  let i = 0;
  input.value = "";
  const tick = () => {
    input.value = command.slice(0, ++i);
    if (i < command.length) setTimeout(tick, 22 + Math.random() * 38);
    else setTimeout(() => { input.value = ""; execute(command); }, 260);
  };
  tick();
}
$("hint").addEventListener("click", () => {
  const cmds = LESSONS[S.lesson].commands;
  // Lesson 1 has two commands: type whichever has not been typed yet.
  typeFor(cmds.find((c) => !history.includes(c)) || cmds.at(-1));
});

// ---------- replay engine ------------------------------------------------------------

function parseOutput(run) {
  let at = -Infinity;
  // The typed command is already echoed by the terminal; skip the record's copy of it.
  return run.output.split("\n").filter((text) => !text.startsWith("$ ")).map((text) => {
    const m = text.match(/^\s+([+-]\d+\.\d)s\s/);
    if (m) at = parseFloat(m[1]);
    else if (/^\s+verify/.test(text)) at = run.observe_s;
    return { text, at };
  });
}

function startReplay(run) {
  S.run = run;
  S.lines = parseOutput(run);
  S.printed = 0;
  S.block = document.createElement("div");
  out.append(S.block);
  S.t = -run.baseline_s;
  S.finished = false;
  S.playing = true;
  renderRunPick();
  drawStrip();
  scene.reset();
}

function stopReplay() {
  if (S.playing && S.block) {
    const div = document.createElement("div");
    div.className = "note";
    div.textContent = "(replay stopped)";
    S.block.append(div);
  }
  S.playing = false;
}

function printUpTo(t) {
  while (S.printed < S.lines.length && S.lines[S.printed].at <= t) {
    const { text } = S.lines[S.printed++];
    const div = document.createElement("div");
    const cls = classify(text);
    if (cls) div.className = cls;
    div.textContent = text;
    S.block.append(div);
  }
  $("term-body").scrollTop = $("term-body").scrollHeight;
}

function seek(t) {
  if (!S.run) return;
  S.t = clamp(t, -S.run.baseline_s, S.run.observe_s);
  S.block.innerHTML = "";
  S.printed = 0;
  S.finished = false;
  S.playing = true;
  printUpTo(S.t);
  scene.reset();
}

// Slow to near real time wherever something is happening.
function busyAt(run, t) {
  const st = stateAt(run, t);
  if (st.werr > 0 || st.ferr > 0 || st.isoErr > 0) return true;
  if (run.switch_s != null && Math.abs(t - run.switch_s) < 3) return true;
  return run.events.some((e) => Math.abs(e.t - t) < 1.5);
}

function advance(dt) {
  if (!S.playing || !S.run) return;
  const run = S.run;
  const speed = S.fixedSpeed || !busyAt(run, S.t) ? S.speed : Math.min(S.speed, 3);
  S.t += dt * speed;
  if (S.t >= run.observe_s) {
    S.t = run.observe_s;
    printUpTo(Infinity);
    S.playing = false;
    S.finished = true;
    const lesson = LESSONS.find((l) => l.key === run.drill);
    if (lesson) {
      if (LESSONS[S.lesson] !== lesson) openLesson(LESSONS.indexOf(lesson), { focus: false });
      markDone(lesson, run);
    }
  } else printUpTo(S.t);
  const chip = $("clock");
  const sign = S.t < 0 ? "−" : "+";
  chip.textContent = S.finished ? "run complete" : `${S.t < 0 ? "before" : "operation"}  ${sign}${Math.abs(S.t).toFixed(0)} s`;
  chip.classList.toggle("fault", S.t >= 0 && !S.finished);
  drawStrip();
}

function renderRunPick() {
  const el = $("runpick");
  el.innerHTML = "";
  el.hidden = !S.run;
  if (!S.run) return;
  const runs = S.byKey.get(S.run.drill);
  el.append("run ");
  runs.forEach((run, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = String(run.n) + (run.tag ? "*" : "");
    b.setAttribute("aria-pressed", String(run === S.run));
    b.title = `Run ${run.n}${run.tag ? ` on image ${run.tag}` : ""}, ${new Date(run.started).toISOString().slice(11, 19)} UTC`;
    b.addEventListener("click", () => { S.pick[run.drill] = i; print(`(switching to run ${run.n})`, "note"); startReplay(run); });
    el.append(b);
  });
}

function renderSpeeds() {
  const el = $("speeds");
  el.innerHTML = "";
  for (const speed of [2, 8, 30]) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = `${speed}×`;
    b.setAttribute("aria-pressed", String(speed === S.speed));
    b.addEventListener("click", () => { S.speed = speed; renderSpeeds(); });
    el.append(b);
  }
}

// ---------- the strip under the scene ------------------------------------------------

const strip = $("strip");
function drawStrip() {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const w = strip.clientWidth, h = strip.clientHeight;
  if (strip.width !== w * dpr) { strip.width = w * dpr; strip.height = h * dpr; }
  const c = strip.getContext("2d");
  c.setTransform(dpr, 0, 0, dpr, 0, 0);
  c.clearRect(0, 0, w, h);
  const run = S.run;
  if (!run) {
    c.fillStyle = "#8494a0"; c.font = "12px 'IBM Plex Sans', sans-serif";
    c.fillText("Run a drill in the terminal and its timeline appears here.", 2, h / 2 + 4);
    return;
  }
  const from = -run.baseline_s, to = run.observe_s, span = to - from;
  const x = (t) => ((t - from) / span) * w;
  const barW = Math.max(1, w / span);
  const top = 7, base = h - 1, plot = base - top;
  const okMax = Math.max(400, ...run.series.ok);
  const failMax = Math.max(1, ...run.series.ferr.map((f, i) => f + run.series.werr[i]));

  // Shard phase not Healthy: an amber band along the top.
  let phase = "Healthy", since = from;
  const band = (a, b) => { c.fillStyle = "#d9a441"; c.fillRect(x(a), 0, Math.max(1, x(b) - x(a)), 4); };
  for (const [s, p] of run.shard) { if (phase !== "Healthy") band(since, s); phase = p; since = s; }
  if (phase !== "Healthy") band(since, to);
  if (run.cut) { c.fillStyle = "rgba(226,103,74,0.16)"; c.fillRect(x(run.cut.from_s), top, x(run.cut.heal_s) - x(run.cut.from_s), plot); }

  for (let s = Math.ceil(from); s < to; s++) {
    const i = s - run.series.t0;
    const okH = clamp(run.series.ok[i] / okMax, 0, 1) * plot;
    c.fillStyle = s < S.t ? "#3fa798" : "rgba(63,167,152,0.28)";
    c.fillRect(x(s), base - okH, barW, okH);
    const fail = run.series.ferr[i] + run.series.werr[i];
    if (fail > 0) {
      const fH = Math.max(3, Math.sqrt(fail / failMax) * plot * 0.9);
      c.fillStyle = s < S.t ? "#e2674a" : "rgba(226,103,74,0.4)";
      c.fillRect(x(s), top, barW, fH);
    }
  }
  if (run.iso) {
    c.strokeStyle = "#e9c46a"; c.lineWidth = 1.4; c.beginPath();
    const isoMax = Math.max(1, ...run.iso.ok);
    run.iso.ok.forEach((v, i) => {
      const px = x(run.series.t0 + i), py = base - (v / isoMax) * plot * 0.35;
      i ? c.lineTo(px, py) : c.moveTo(px, py);
    });
    c.stroke();
  }
  c.fillStyle = "#f2a48d"; c.fillRect(x(0), 0, 1, h);
  c.font = "10.5px 'IBM Plex Sans', sans-serif"; c.fillText("start", x(0) + 4, 17);
  c.fillStyle = "#fff"; c.fillRect(x(S.t), 0, 1.5, h);
}
strip.addEventListener("click", (e) => {
  if (!S.run) return;
  const r = strip.getBoundingClientRect();
  seek(-S.run.baseline_s + ((e.clientX - r.left) / r.width) * (S.run.baseline_s + S.run.observe_s));
});
new ResizeObserver(drawStrip).observe(strip);

// ---------- the scene ----------------------------------------------------------------

const COLOR = {
  ok: new THREE.Color("#58c2b2"), bad: new THREE.Color("#ee6a4b"), iso: new THREE.Color("#e9c46a"),
  body: new THREE.Color("#5d7688"), bodyHi: new THREE.Color("#8fb0c6"), dark: new THREE.Color("#2f3a42"),
  primary: new THREE.Color("#e9c46a"), cut: new THREE.Color("#ee6a4b"), plate: new THREE.Color("#1b252d"),
  repl: new THREE.Color("#58c2b2"), fill: new THREE.Color("#3fa798"), full: new THREE.Color("#ee6a4b"),
};
const ZX = [-6.6, 0, 6.6];
const P = {
  clients: new THREE.Vector3(0, 0.7, 8.4),
  gw: (i) => new THREE.Vector3(ZX[i], 0.55, 2.6),
  pool: (i) => new THREE.Vector3(ZX[i], 0.8, -0.8),
  etcd: (i) => new THREE.Vector3(ZX[i] - 1.6, 0.45, -3.2),
  gauge: (i) => new THREE.Vector3(ZX[i] + 1.55, 0, -0.8),
  iso: (i) => new THREE.Vector3(ZX[i] + 1.7, 0.5, 4.4),
};

const scene = (() => {
  const canvas = $("scene");
  const flat = (why) => {
    document.querySelector(".stage").classList.add("flat");
    $("labels").innerHTML = `<p class="no3d">The 3D view could not start in this browser (${why}). The terminal and the timeline still replay the run.</p>`;
    return { frame() {}, reset() {} };
  };
  let renderer;
  try { renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true }); }
  catch { return flat("WebGL is not available"); }
  let lost = false;
  canvas.addEventListener("webglcontextlost", (e) => { e.preventDefault(); lost = true; flat("the graphics context was lost"); });
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
  const world = new THREE.Scene();
  world.fog = new THREE.Fog(0x10161b, 26, 52);
  const camera = new THREE.PerspectiveCamera(36, 2, 0.1, 120);
  camera.position.set(0, 13.5, 17.5);
  const controls = new OrbitControls(camera, canvas);
  controls.target.set(0, 0.6, 1.4);
  controls.enablePan = false; controls.enableDamping = true;
  controls.minDistance = 12; controls.maxDistance = 64;
  controls.minPolarAngle = 0.45; controls.maxPolarAngle = 1.42;
  controls.update();
  world.add(new THREE.HemisphereLight(0xe6f0f6, 0x1c2831, 1.5));
  const sun = new THREE.DirectionalLight(0xffffff, 2.2);
  sun.position.set(-6, 14, 9);
  world.add(sun);
  const grid = new THREE.GridHelper(48, 48, 0x24313b, 0x1a242c);
  grid.position.y = -0.24;
  world.add(grid);

  const labels = $("labels");
  const tracked = [];
  const label = (object, dy = 1.1) => {
    const el = document.createElement("div");
    el.className = "label3d";
    labels.append(el);
    const e = { object, el, dy };
    tracked.push(e);
    return e;
  };
  const setLabel = (e, title, sub = "", tone = "") => {
    const html = `${title}${sub ? `<small>${sub}</small>` : ""}`;
    if (e.html !== html) { e.el.innerHTML = html; e.html = html; }
    e.el.className = `label3d ${tone}`;
  };
  const mat = (color = COLOR.body) => new THREE.MeshStandardMaterial({ color: color.clone(), roughness: 0.5, metalness: 0.05, transparent: true });

  // Zones: a plate each, with a gateway, a pool pod (Postgres) and an etcd member.
  const zones = [0, 1, 2].map((i) => {
    const plate = new THREE.Mesh(new RoundedBoxGeometry(5.4, 0.3, 9.2, 3, 0.12), mat(COLOR.plate));
    plate.position.set(ZX[i], -0.15, -0.3);
    world.add(plate);
    const zoneTag = new THREE.Object3D(); zoneTag.position.set(ZX[i], -0.6, 4.3); world.add(zoneTag);
    const gw = new THREE.Mesh(new RoundedBoxGeometry(1.5, 0.9, 1.2, 3, 0.14), mat());
    gw.position.copy(P.gw(i)); world.add(gw);
    const pool = new THREE.Mesh(new THREE.CylinderGeometry(0.85, 0.85, 1.5, 40), mat());
    pool.position.copy(P.pool(i)); world.add(pool);
    const ring = new THREE.Mesh(new THREE.TorusGeometry(1.1, 0.08, 12, 60), new THREE.MeshBasicMaterial({ color: COLOR.primary, transparent: true, opacity: 0 }));
    ring.rotation.x = Math.PI / 2; ring.position.set(P.pool(i).x, P.pool(i).y + 0.95, P.pool(i).z); world.add(ring);
    const etcd = new THREE.Mesh(new THREE.OctahedronGeometry(0.42), new THREE.MeshStandardMaterial({ color: 0xc3d2dc, roughness: 0.35, metalness: 0.2, transparent: true }));
    etcd.position.copy(P.etcd(i)); world.add(etcd);
    // Disk gauge, shown only for runs that record the disk.
    const shell = new THREE.Mesh(new THREE.BoxGeometry(0.34, 1.8, 0.34), new THREE.MeshBasicMaterial({ color: 0x9fb2c0, wireframe: true, transparent: true, opacity: 0 }));
    shell.position.set(P.gauge(i).x, 0.9, P.gauge(i).z); world.add(shell);
    const fill = new THREE.Mesh(new THREE.BoxGeometry(0.3, 1, 0.3), new THREE.MeshBasicMaterial({ color: COLOR.fill.clone(), transparent: true, opacity: 0 }));
    fill.position.set(P.gauge(i).x, 0, P.gauge(i).z); world.add(fill);
    // The cut: a red glass box around the zone.
    const wall = new THREE.Mesh(new THREE.BoxGeometry(5.9, 3.2, 9.7), new THREE.MeshBasicMaterial({ color: COLOR.cut, transparent: true, opacity: 0, depthWrite: false, side: THREE.DoubleSide }));
    wall.position.set(ZX[i], 1.45, -0.3); world.add(wall);
    const iso = new THREE.Mesh(new THREE.SphereGeometry(0.34, 24, 16), new THREE.MeshStandardMaterial({ color: COLOR.iso, roughness: 0.4, transparent: true, opacity: 0 }));
    iso.position.copy(P.iso(i)); world.add(iso);
    return {
      plate, gw, pool, ring, etcd, shell, fill, wall, iso,
      zoneLabel: label(zoneTag, 0.2), gwLabel: label(gw, 1.0), poolLabel: label(pool, 2.05), isoLabel: label(iso, 0.6),
    };
  });
  const clients = new THREE.Mesh(new THREE.SphereGeometry(0.62, 32, 20), new THREE.MeshStandardMaterial({ color: COLOR.ok, roughness: 0.4 }));
  clients.position.copy(P.clients); world.add(clients);
  const clientLabel = label(clients, 1.1);

  // Synchronous replication from the primary to the standbys.
  const replGeo = new THREE.BufferGeometry();
  replGeo.setAttribute("position", new THREE.BufferAttribute(new Float32Array(12), 3));
  replGeo.setAttribute("color", new THREE.BufferAttribute(new Float32Array(12), 3));
  const repl = new THREE.LineSegments(replGeo, new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.8 }));
  world.add(repl);

  // Dots.
  const MAX = 520;
  const dots = new THREE.InstancedMesh(new THREE.SphereGeometry(TT ? 0.15 : 0.11, 10, 8), new THREE.MeshBasicMaterial(), MAX);
  dots.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  dots.count = 0;
  world.add(dots);
  const live = [];
  let debt = { main: 0, iso: 0 };
  const m4 = new THREE.Matrix4();
  const tmp = new THREE.Vector3(), a = new THREE.Vector3(), b = new THREE.Vector3();
  const zi = (zone) => Math.max(0, ["apse2-az1", "apse2-az2", "apse2-az3"].indexOf(zone));
  let state = null;

  function reset() { live.length = 0; debt = { main: 0, iso: 0 }; }

  function spawn(kind, st) {
    if (live.length >= MAX) return;
    const p = zi(st.primary), cutI = st.cut ? zi(st.cut) : -1;
    if (kind === "main") {
      const total = st.ok + st.werr + st.ferr;
      if (!total) return;
      const fail = Math.random() < (st.werr + st.ferr) / total;
      // The load enters through any gateway outside a cut-off zone.
      const open = [0, 1, 2].filter((i) => i !== cutI);
      const g = open[Math.floor(Math.random() * open.length)];
      live.push({ kind, fail, from: P.clients, gw: g, pool: p, leg: 0, p: 0, jitter: (Math.random() - 0.5) * 0.7 });
    } else {
      const total = st.isoOk + st.isoErr;
      if (!total) return;
      const i = zi(S.run.cut.zone);
      const fail = Math.random() < st.isoErr / total;
      live.push({ kind, fail, from: P.iso(i), gw: i, pool: i, leg: 0, p: 0, jitter: (Math.random() - 0.5) * 0.4 });
    }
  }

  function legPoints(d, leg) {
    const gw = P.gw(d.gw), pool = P.pool(d.pool);
    switch (leg) {
      case 0: return [d.from, gw];
      case 1: return [gw, pool];
      case 2: return [pool, gw];
      case 3: return [gw, d.from];
      default: return null;
    }
  }

  function frame(dt, run, st) {
    if (lost) return;
    state = st;
    const ease = Math.min(1, dt * 5);
    const p = zi(st.primary), cutI = st.cut ? zi(st.cut) : -1;
    const healthy = st.phase === "Healthy";

    zones.forEach((z, i) => {
      const isPrimary = i === p, ready = st.ready[i] !== false, cut = i === cutI;
      z.pool.material.color.lerp(!ready ? COLOR.dark : isPrimary ? COLOR.bodyHi : COLOR.body, ease);
      z.pool.material.opacity += ((ready ? 1 : 0.45) - z.pool.material.opacity) * ease;
      z.ring.material.opacity += ((isPrimary ? 1 : 0) - z.ring.material.opacity) * Math.min(1, dt * 6);
      z.ring.rotation.z += dt * 0.6;
      z.wall.material.opacity += ((cut ? 0.16 + 0.05 * Math.sin(performance.now() / 260) : 0) - z.wall.material.opacity) * ease;
      z.plate.material.color.lerp(cut ? new THREE.Color("#3a1f1b") : COLOR.plate, ease);
      z.iso.material.opacity += ((run?.cut && i === zi(run.cut.zone) ? 1 : 0) - z.iso.material.opacity) * ease;
      z.isoLabel.el.style.opacity = z.iso.material.opacity > 0.4 ? 1 : 0;
      if (run?.cut) setLabel(z.isoLabel, "writer inside", st.isoOk ? `${st.isoOk} acked/s` : st.isoErr ? "every write fails" : "", st.isoErr && !st.isoOk ? "bad" : "");

      // Disk: the primary's gauge.
      const showDisk = st.disk && isPrimary;
      const used = showDisk ? st.disk.used : 0;
      z.shell.material.opacity += ((showDisk ? 0.6 : 0) - z.shell.material.opacity) * ease;
      z.fill.material.opacity += ((showDisk ? 0.95 : 0) - z.fill.material.opacity) * ease;
      z.fill.scale.y = Math.max(0.001, 1.8 * used);
      z.fill.position.y = (1.8 * used) / 2;
      z.fill.material.color.lerp(used > 0.97 ? COLOR.full : COLOR.fill, ease);

      setLabel(z.zoneLabel, `zone ${["1", "2", "3"][i]}`, run ? run.zones[i] : "", cut ? "bad" : "");
      let sub = isPrimary ? "Postgres primary" : "standby", tone = isPrimary ? "good" : "";
      if (!ready) { sub = isPrimary ? "primary, pod not ready" : "pod not ready, moving"; tone = "bad"; }
      if (cut) { sub = isPrimary ? "primary, cut off" : "cut off"; tone = "bad"; }
      if (showDisk && st.disk.availMb <= 2) { sub = `primary, disk full (${st.disk.availMb} MB free)`; tone = "bad"; }
      else if (showDisk) sub = `primary, disk ${Math.round(used * 100)}% used`;
      setLabel(z.poolLabel, "pool pod", sub, tone);
      setLabel(z.gwLabel, "gateway", cut ? "cut off" : "", cut ? "bad" : "");
    });

    // Replication lines: primary to each standby; red where the cut breaks them.
    const pos = replGeo.attributes.position, col = replGeo.attributes.color;
    let k = 0;
    for (const i of [0, 1, 2]) {
      if (i === p) continue;
      const from = P.pool(p), to = P.pool(i);
      pos.setXYZ(k * 2, from.x, 1.2, from.z); pos.setXYZ(k * 2 + 1, to.x, 1.2, to.z);
      const broken = i === cutI || p === cutI;
      const c = broken ? COLOR.cut : COLOR.repl;
      col.setXYZ(k * 2, c.r, c.g, c.b); col.setXYZ(k * 2 + 1, c.r, c.g, c.b);
      k++;
    }
    pos.needsUpdate = true; col.needsUpdate = true;

    const conns = st.conns || (run ? run.facts.fh_connections : 500) || 500;
    setLabel(clientLabel, "app connections", run ? `${conns} open · ${st.ok} writes acked/s` : "500 connections + the writer", st.werr || st.ferr ? "bad" : "");

    // HUD: what the cluster reported, next to what the clients saw.
    const failing = st.werr + st.ferr + st.isoErr;
    const hud = $("hud");
    if (run) {
      const lie = healthy && st.werr > 0;
      hud.hidden = false;
      hud.className = `hud ${healthy ? (lie ? "lie" : "ok") : "warn"}`;
      hud.innerHTML = `<span>Shard phase <b>${st.phase}</b></span><span>${failing ? `<b class="bad">${failing.toLocaleString("en-US")}</b> failed/s` : "no failures"}</span>`
        + (st.oldPods != null ? `<span>pods on old image <b>${st.oldPods}</b> of 9</span>` : "")
        + (st.ng ? `<span>node group update <b>${st.ng}</b></span>` : "")
        + (lie ? `<span class="liebadge">status says Healthy, writes are failing</span>` : "");
    } else hud.hidden = true;

    // Spawn a sample of the real traffic.
    if (run && S.playing && !reducedMotion) {
      debt.main += dt * (TT ? 30 : 14);
      while (debt.main >= 1) { debt.main -= 1; spawn("main", st); }
      if (run.cut) { debt.iso += dt * 4; while (debt.iso >= 1) { debt.iso -= 1; spawn("iso", st); } }
    }
    let n = 0;
    for (let i = live.length - 1; i >= 0; i--) {
      const d = live[i];
      d.p += dt * 1.8;
      if (d.p >= 1) {
        d.p = 0; d.leg++;
        if (d.leg === 1 && d.fail && (d.kind === "iso" || st.ferr > st.werr)) d.leg = 3;   // turned back at the gateway
      }
      const pts = legPoints(d, d.leg);
      if (!pts) { live.splice(i, 1); continue; }
      a.copy(pts[0]); b.copy(pts[1]);
      tmp.lerpVectors(a, b, d.p);
      tmp.y += Math.sin(d.p * Math.PI) * (d.leg === 1 || d.leg === 2 ? 0.8 : 0.45) + 0.05;
      tmp.x += d.jitter * Math.sin(d.p * Math.PI);
      if (n < MAX) {
        m4.makeTranslation(tmp.x, tmp.y, tmp.z);
        dots.setMatrixAt(n, m4);
        const failingNow = d.fail && d.leg >= 2;
        dots.setColorAt(n, failingNow ? COLOR.bad : d.kind === "iso" ? COLOR.iso : COLOR.ok);
        n++;
      }
    }
    dots.count = n;
    dots.instanceMatrix.needsUpdate = true;
    if (dots.instanceColor) dots.instanceColor.needsUpdate = true;

    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== Math.floor(w * renderer.getPixelRatio()) || canvas.height !== Math.floor(h * renderer.getPixelRatio())) {
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      // A narrow stage (a phone, a vertical video) moves the camera back so all three zones fit.
      const dist = 22.1 * clamp((TT ? 1.42 : 1.75) / camera.aspect, 1, 2.7);
      camera.position.sub(controls.target).setLength(dist).add(controls.target);
      world.fog.near = dist + 4; world.fog.far = dist + 30;
      camera.updateProjectionMatrix();
    }
    controls.update();
    renderer.render(world, camera);
    for (const e of tracked) {
      tmp.copy(e.object.position); tmp.y += e.dy;
      tmp.project(camera);
      e.el.style.left = `${(tmp.x * 0.5 + 0.5) * w}px`;
      e.el.style.top = `${(-tmp.y * 0.5 + 0.5) * h}px`;
      e.el.style.display = tmp.z < 1 ? "" : "none";
    }
  }
  return { frame, reset, get state() { return state; } };
})();

let idle = null;
function idleScene(lesson) {
  const runs = lesson.key ? S.byKey.get(lesson.key) : null;
  const run = runs ? runs[S.pick[lesson.key] || 0] : S.bundle.runs[0];
  if (!run) return;
  idle = stateAt(run, -run.baseline_s);
  idle.ok = 0; idle.werr = 0; idle.ferr = 0;
  if (!S.run || !S.playing) { $("clock").textContent = "the cluster at rest"; $("clock").classList.remove("fault"); }
}

function step(dt) {
  if (TT) tiktok.step(dt);
  advance(dt);
  const showRun = S.run && (S.playing || S.finished);
  const st = showRun ? stateAt(S.run, S.t) : idle;
  if (st) scene.frame(dt, showRun ? S.run : null, st);
}
let last = performance.now();
function loop(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  step(dt);
  requestAnimationFrame(loop);
}

// ---------- results table ------------------------------------------------------------

const range = (vals, digits = 0, unit = "") => {
  const v = vals.filter((x) => x != null);
  if (!v.length) return "–";
  const lo = Math.min(...v), hi = Math.max(...v);
  const f = (x) => x.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits });
  return `${lo === hi ? f(lo) : `${f(lo)}–${f(hi)}`}${unit}`;
};

function renderResults() {
  const names = {
    switchover: "Planned switchover", "mg-upgrade": "Rolling Multigres upgrade", "ng-upgrade": "EKS node group upgrade",
    "az-partition": "Primary's zone cut off", "disk-full": "Primary's disk filled, then grown",
  };
  const rows = [];
  for (const [key, name] of Object.entries(names)) {
    const runs = S.byKey.get(key);
    if (!runs) continue;
    rows.push(`<tr>
      <td>${name}</td><td>${runs.length}</td>
      <td>${range(runs.map((r) => (r.verify.lost_acked || 0) + (r.verify_iso?.lost_acked || 0)))}</td>
      <td>${range(runs.map((r) => r.facts.writer_longest_outage_s), 1, " s")}</td>
      <td class="${Math.max(...runs.map((r) => r.facts.fh_errors_total || 0)) > 0 ? "hot" : ""}">${range(runs.map((r) => r.facts.fh_errors_total))}</td>
      <td>${range(runs.map((r) => r.facts.shard_not_healthy_s), 0, " s")}</td>
      <td>${range(runs.map((r) => healthyWhileFailing(r)), 0, " s")}</td></tr>`);
  }
  $("results-table").innerHTML = `
    <thead><tr><th>Operation</th><th>Runs</th><th>Acked writes lost</th><th>Longest gap</th><th>App errors</th><th>Not Healthy</th><th>Writes failing, phase Healthy</th></tr></thead>
    <tbody>${rows.join("")}</tbody>`;
}

// ---------- your own runs ------------------------------------------------------------

$("own-file")?.addEventListener("change", async (e) => {
  const file = e.target.files?.[0];
  if (!file) return;
  try {
    const bundle = JSON.parse(await file.text());
    if (!Array.isArray(bundle.runs)) throw new Error("no runs in this file");
    S.own = true;
    stopReplay();
    S.run = null; S.pick = {};
    index(bundle);
    renderResults(); renderRunPick(); drawStrip();
    openLesson(1, { focus: false });
    print(`Loaded ${bundle.runs.length} of your runs from ${file.name}. Every lesson now replays them.`, "note");
    $("own-status").textContent = `Loaded ${bundle.runs.length} runs from ${file.name}.`;
    $("course").scrollIntoView();
  } catch (err) {
    $("own-status").textContent = `Could not read ${file.name}: ${err.message}`;
  }
});

// ---------- links to a moment --------------------------------------------------------

// ?drill=disk-full&run=2&at=60 opens that run at that second; &play=1&speed=30 for a recording.
function openLink() {
  const q = new URLSearchParams(location.search);
  const runs = S.byKey.get(q.get("drill"));
  if (!runs) return;
  const run = runs.find((r) => r.n === Number(q.get("run"))) || runs[0];
  S.pick[run.drill] = runs.indexOf(run);
  const lesson = LESSONS.findIndex((l) => l.key === run.drill);
  if (lesson >= 0) openLesson(lesson, { focus: false });
  if (q.has("speed")) { S.speed = Number(q.get("speed")); renderSpeeds(); }
  print(`scripts/day2.sh ${run.drill} ${run.n}`, "cmd");
  startReplay(run);
  if (q.has("at")) seek(Number(q.get("at")));
  if (!q.has("video")) $("course").scrollIntoView();
}

// ---------- start --------------------------------------------------------------------

// ---------- vertical video (?tiktok=1, and &capture=1 to step frames from a script) --
//
// A scripted tour for a short vertical video: the zone cut-off, then the full disk, with
// captions. It replays the same records as the lab; only the order and the speed are set.

if (Q.has("video") || TT) document.body.classList.add("video");
if (TT) document.body.classList.add("tiktok");

const tiktok = (() => {
  let clock = 0, seg = -1, segStart = 0;
  const cap = document.createElement("div"), foot = document.createElement("div");
  cap.className = "tt-cap"; foot.className = "tt-foot";
  if (TT) document.body.append(cap, foot);
  const fixAt = (run) => (run.events.find((e) => e.text.startsWith("fix:")) || { t: 222 }).t;
  const backAt = (run) => {
    const f = fixAt(run);
    const i = run.series.ok.findIndex((v, k) => run.series.t0 + k > f && v > 0);
    return i < 0 ? f + 13 : run.series.t0 + i;
  };
  const SEGS = [
    { dur: 3.4, run: () => S.byKey.get("az-partition")?.find((r) => r.n === 2), idle: true,
      text: () => ["We broke a Postgres cluster on purpose", "Multigres on AWS · three zones · real recorded runs"] },
    { run: () => S.byKey.get("az-partition")?.find((r) => r.n === 2), from: -7, to: 78, speed: 6,
      text: (t) => t < 0 ? ["1 · Cut the primary's zone off the network", "It keeps running. It just can't reach the other two zones."]
        : t < 21 ? ["Writes pause while the cluster decides", "The cut-off zone can't get a second zone to confirm"]
          : ["New primary in another zone after 20 s", "The cut-off side acknowledged 0 writes · 0 lost"] },
    { run: () => S.byKey.get("disk-full")?.find((r) => r.n === 2), from: -6, to: 250, speed: 12.5,
      // Follows the recorded phase, so a caption never says Healthy while the record doesn't.
      text: (t, run) => {
        if (t < 0) return ["2 · Fill the primary's disk", "Leave 1 MB free"];
        if (t >= backAt(run) + 4) return ["Alert on free space, not on “Healthy”", ""];
        if (t >= fixAt(run)) return ["Grow the volume", "Writes back 13 s later, no restart"];
        if (t < 32) return ["Every write fails", "53100 · No space left on device"];
        const st = stateAt(run, t);
        const leftHealthy = run.shard.find(([s, p]) => p !== "Healthy" && s >= 0)?.[0] ?? Infinity;
        if (st.phase !== "Healthy") return [`The shard says ${st.phase} for ${Math.round(run.facts.shard_not_healthy_s)} s`, "The only part of the outage the status showed"];
        if (t < leftHealthy) return ["…and the cluster still says Healthy", "Every write failing, for minutes"];
        return ["…then Healthy again", "Writes still failing"];
      } },
    { dur: 4.2, hold: true,
      text: () => ["0 of 2.7 million acknowledged writes lost", "Interactive lab + every script · github.com/shanurwan/multigres-eks-drills"] },
  ];
  const durOf = (s) => s.dur ?? (s.to - s.from) / s.speed;
  function enter(i) {
    seg = i; segStart = clock;
    const s = SEGS[i];
    if (!s || s.hold) return;
    const run = s.run();
    if (!run) return;
    S.speed = s.speed || 1; S.fixedSpeed = true;
    if (s.idle) { S.run = null; S.playing = false; idle = stateAt(run, -run.baseline_s); idle.ok = 0; idle.werr = 0; idle.ferr = 0; return; }
    S.pick[run.drill] = S.byKey.get(run.drill).indexOf(run);
    startReplay(run);
    seek(s.from);
  }
  function step(dt) {
    if (!S.bundle) return;
    if (seg < 0) enter(0);
    clock += dt;
    while (seg < SEGS.length && clock - segStart >= durOf(SEGS[seg])) {
      if (seg === SEGS.length - 1) { window.__done = true; break; }
      enter(seg + 1);
    }
    const s = SEGS[seg];
    if (S.run && s?.to != null && S.t >= s.to) { S.playing = false; S.finished = true; }
    const [title, sub] = s.text(S.t, S.run);
    const html = `<b>${title}</b>${sub ? `<span>${sub}</span>` : ""}`;
    if (cap.dataset.html !== html) { cap.innerHTML = html; cap.dataset.html = html; cap.classList.remove("in"); void cap.offsetWidth; cap.classList.add("in"); }
    foot.innerHTML = s.hold ? `<span class="tt-big">multigres-eks-drills</span>` : `<span>replay of a recorded run · 0 acknowledged writes lost</span>`;
    document.body.classList.toggle("tt-end", !!s.hold);
  }
  return { step, get total() { return SEGS.reduce((a, s) => a + durOf(s), 0); } };
})();
window.__frame = (dt) => step(dt);
window.__videoLength = () => tiktok.total;

load().then(() => {
  renderSpeeds();
  renderRunPick();
  renderResults();
  openLesson(clamp(store.get("mglab.lesson", 0), 0, LESSONS.length - 1), { focus: false });
  print("This terminal replays real runs recorded on a 3-zone EKS cluster.", "note");
  print("Type the lesson's command, or press Tab to complete it. Type help for the list.", "note");
  print("");
  drawStrip();
  openLink();
  if (!CAPTURE) requestAnimationFrame(loop);
  window.__ready = true;
}).catch((err) => {
  $("provenance").textContent = `The recorded runs could not be loaded (${err.message}).`;
  print(`could not load the recorded runs: ${err.message}`, "warn");
});
