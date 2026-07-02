#!/usr/bin/env node
// @ts-check
//
// viteenv probe — resident worker variant (spike, NOT the plugin).
//
// Same resolution as probe.mjs, but long-lived: node starts once, each
// project's vite is imported once and cached, then requests are answered over
// stdin/stdout. Purpose: measure the *warm* resolve cost (no node startup, no
// re-import) — the upper bound of method-A performance.
//
// Protocol: newline-delimited JSON.
//   in:  { "id": 1, "mode": "development", "root": "/abs/path" }
//   out: { "id": 1, ok, mode, root, envDir, envPrefix, viteVersion, env,
//          define, timings: { importMs, resolveMs, loadEnvMs, totalMs } }
//   err: { "id": 1, ok:false, error: { kind, message } }
//
// No extra npm deps; only the project's vite + Node stdlib.

import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { readFileSync, statSync, readdirSync } from "node:fs";
import { join, dirname, resolve as resolvePath, isAbsolute } from "node:path";
import { createInterface } from "node:readline";

// The cwd at startup. We resolve relative request roots against THIS, not
// process.cwd(), because we chdir(root) per request (see handle) — resolving a
// relative root against the mutated cwd would be non-idempotent.
const INITIAL_CWD = process.cwd();

/** root -> { vite, viteVersion, importMs } (or a rejected promise's reason) */
const viteCache = new Map();

/** `${root}\0${mode}` -> { result, snapshot } — last resolve + its watch set */
const resultCache = new Map();

/** @param {string} p @returns {number|null} mtimeMs, or null if missing */
function statMtime(p) {
  try {
    return statSync(p).mtimeMs;
  } catch {
    return null;
  }
}

/**
 * Files whose change must invalidate a cached resolve:
 *  - configFileDependencies: vite.config + everything it imports (vite tells us)
 *  - the config file itself (usually already in the deps, added defensively)
 *  - the env cascade in envDir (loadEnv reads these; not in config deps).
 *    Non-existent candidates are watched too, so creating .env.local later
 *    (mtime null -> number) counts as a change.
 * @param {any} resolved @param {string} root @param {string} mode @param {string} envDir
 * @returns {string[]}
 */
function buildWatchTargets(resolved, root, mode, envDir) {
  const t = new Set();
  for (const f of resolved.configFileDependencies ?? []) {
    t.add(isAbsolute(f) ? f : resolvePath(root, f));
  }
  if (resolved.configFile) t.add(resolved.configFile);
  for (const name of [".env", ".env.local", `.env.${mode}`, `.env.${mode}.local`]) {
    t.add(join(envDir, name));
  }
  return [...t];
}

/** @param {string[]} targets @returns {Record<string, number|null>} */
function snapshot(targets) {
  /** @type {Record<string, number|null>} */
  const m = {};
  for (const p of targets) m[p] = statMtime(p);
  return m;
}

/** True if any watched file's mtime/existence changed since the snapshot. */
function isStale(snap) {
  for (const p of Object.keys(snap)) {
    if (statMtime(p) !== snap[p]) return true;
  }
  return false;
}

/** @param {unknown} node @returns {string|null} */
function pickExport(node) {
  if (typeof node === "string") return node;
  if (node && typeof node === "object") {
    for (const cond of ["node", "import", "module", "default", "require"]) {
      if (cond in node) {
        const hit = pickExport(/** @type {any} */ (node)[cond]);
        if (hit) return hit;
      }
    }
  }
  return null;
}

const stderrLogger = {
  hasWarned: false,
  info: () => {},
  warn: () => { stderrLogger.hasWarned = true; },
  warnOnce: () => {},
  error: (m) => process.stderr.write(`[vite:error] ${m}\n`),
  clearScreen: () => {},
  hasErrorLogged: () => false,
};

/**
 * Import (and cache) the project's vite for a given root.
 * @param {string} root
 */
async function getVite(root) {
  const cached = viteCache.get(root);
  if (cached) return cached;

  const t0 = performance.now();
  const req = createRequire(join(root, "noop.js"));
  let pkgPath;
  try {
    pkgPath = req.resolve("vite/package.json");
  } catch (err) {
    const e = new Error(
      `could not resolve the project's vite from root=${root}: ${err?.message ?? String(err)}`,
    );
    // @ts-ignore
    e.kind = "vite-not-found";
    throw e;
  }
  const pkgDir = dirname(pkgPath);
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
  const viteVersion = pkg.version ?? null;
  const rel = pickExport(pkg.exports?.["."] ?? pkg.exports) ?? pkg.module ?? pkg.main;
  if (!rel) {
    const e = new Error(`resolved vite@${viteVersion} at ${pkgDir} but no ESM entry`);
    // @ts-ignore
    e.kind = "vite-not-found";
    throw e;
  }
  const url = pathToFileURL(resolvePath(pkgDir, rel)).href;

  let vite;
  try {
    vite = await import(url);
  } catch (err) {
    const e = new Error(`failed to import resolved vite (${url}): ${err?.message ?? String(err)}`);
    // @ts-ignore
    e.kind = "vite-not-found";
    throw e;
  }
  if (typeof vite.resolveConfig !== "function" || typeof vite.loadEnv !== "function") {
    const e = new Error(
      `vite@${viteVersion} missing expected API (resolveConfig=${typeof vite.resolveConfig}, loadEnv=${typeof vite.loadEnv})`,
    );
    // @ts-ignore
    e.kind = "bad-vite-api";
    throw e;
  }

  const entry = { vite, viteVersion, importMs: +(performance.now() - t0).toFixed(2) };
  viteCache.set(root, entry);
  return entry;
}

/**
 * Auto-discover which Vite modes this project has. Vite has no canonical mode
 * list (a mode is just a CLI string), so we infer it from consumer-authored
 * signals: `--mode <x>` in package.json scripts (and `vite`→development,
 * `vite build`→production) ∪ `.env.<mode>` files. Falls back to
 * development/production only if nothing is found.
 * @param {string} envDir
 * @param {string} root
 * @returns {string[]}
 */
function discoverModes(envDir, root) {
  const set = new Set();

  // 1. package.json scripts. Explicit `--mode <x>` / `-m x` wins per command;
  //    otherwise a vite invocation implies its default mode (`vite build` ->
  //    production, `vite`/`vite dev`/`vite serve` -> development).
  try {
    const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
    const modeRe = /(?:--mode|(?:^|\s)-m)[=\s]([\w.-]+)/g;
    for (const cmd of Object.values(pkg.scripts ?? {})) {
      if (typeof cmd !== "string") continue;
      let hadExplicit = false;
      modeRe.lastIndex = 0;
      let m;
      while ((m = modeRe.exec(cmd))) {
        set.add(m[1]);
        hadExplicit = true;
      }
      if (hadExplicit) continue;
      const tokens = cmd.split(/\s+/);
      for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (t === "vite" || t.endsWith("/vite")) {
          const next = tokens[i + 1];
          const sub = next && !next.startsWith("-") ? next : "dev";
          if (sub === "build") set.add("production");
          else if (sub === "preview") {
            // preview serves a prior build; not a mode of its own
          } else set.add("development"); // dev / serve / bare `vite`
        }
      }
    }
  } catch {
    // no/invalid package.json — skip this source
  }

  // 2. .env.<mode>[.local] files (exclude the base .env / .env.local)
  let entries = [];
  try {
    entries = readdirSync(envDir);
  } catch {
    // envDir may not exist
  }
  for (const name of entries) {
    const m = /^\.env\.(.+?)(?:\.local)?$/.exec(name);
    if (m && m[1] !== "local") set.add(m[1]);
  }

  // 3. last-resort fallback
  if (set.size === 0) {
    return ["development", "production"];
  }

  // order: development, production first (if present), then the rest sorted
  const pref = ["development", "production"].filter((m) => set.has(m));
  const rest = [...set].filter((m) => m !== "development" && m !== "production").sort();
  return [...pref, ...rest];
}

/**
 * Resolve env for EVERY mode at once. One resolveConfig (for envDir/envPrefix),
 * then a cheap loadEnv per mode. Returns { modeList, modes: { <mode>: env } }.
 * @param {{ root?: string, mode?: string, force?: boolean }} reqObj
 */
async function handleResolveAll(reqObj) {
  const baseMode = reqObj.mode ?? "development";
  let root = reqObj.root ?? INITIAL_CWD;
  root = isAbsolute(root) ? root : resolvePath(INITIAL_CWD, root);
  const key = `${root} *all`;
  const force = reqObj.force === true;

  const { vite, viteVersion, importMs } = await getVite(root);

  const tGate = performance.now();
  const cached = resultCache.get(key);
  const stale = force || !cached || isStale(cached.snapshot);
  const gateMs = +(performance.now() - tGate).toFixed(2);
  if (cached && !stale) {
    return {
      ...cached.result,
      cache: "hit",
      timings: { importMs: 0, gateMs, resolveMs: 0, loadEnvMs: 0, totalMs: gateMs },
    };
  }

  process.chdir(root);
  const tR = performance.now();
  let resolved;
  try {
    resolved = await vite.resolveConfig(
      { root, mode: baseMode, logLevel: "silent", customLogger: stderrLogger },
      "serve",
      baseMode,
      "development",
    );
  } catch (err) {
    const e = new Error(`resolveConfig threw: ${err?.message ?? String(err)}`);
    // @ts-ignore
    e.kind = "config-eval";
    throw e;
  }
  const resolveMs = +(performance.now() - tR).toFixed(2);

  const envDir = resolved.envDir ?? root;
  const envPrefix = resolved.envPrefix ?? "VITE_";
  const discovered = discoverModes(envDir, root);
  // `only` (optional) limits the result to that subset, in the caller's order.
  const only = Array.isArray(reqObj.only)
    ? reqObj.only.filter((m) => typeof m === "string" && m)
    : null;
  const modeList = only && only.length > 0 ? only.filter((m) => discovered.includes(m)) : discovered;

  const tE = performance.now();
  const modes = {};
  try {
    for (const m of modeList) {
      modes[m] = vite.loadEnv(m, envDir, envPrefix);
    }
  } catch (err) {
    const e = new Error(`loadEnv threw: ${err?.message ?? String(err)}`);
    // @ts-ignore
    e.kind = "config-eval";
    throw e;
  }
  const loadEnvMs = +(performance.now() - tE).toFixed(2);

  // watch set: config deps + base env files + every mode's env files + the dir
  // itself (so a brand-new .env.<mode> file invalidates the cache too).
  const t = new Set();
  for (const f of resolved.configFileDependencies ?? []) {
    t.add(isAbsolute(f) ? f : resolvePath(root, f));
  }
  if (resolved.configFile) t.add(resolved.configFile);
  t.add(envDir);
  t.add(join(envDir, ".env"));
  t.add(join(envDir, ".env.local"));
  for (const m of modeList) {
    t.add(join(envDir, `.env.${m}`));
    t.add(join(envDir, `.env.${m}.local`));
  }
  const targets = [...t];

  const result = {
    ok: true,
    root: resolved.root ?? root,
    envDir,
    envPrefix,
    viteVersion,
    modeList,
    modes,
    define: resolved.define ?? {},
    watching: targets.length,
  };
  resultCache.set(key, { result, snapshot: snapshot(targets) });

  return {
    ...result,
    cache: cached ? "stale-refresh" : "miss",
    timings: {
      importMs,
      gateMs,
      resolveMs,
      loadEnvMs,
      totalMs: +(gateMs + resolveMs + loadEnvMs).toFixed(2),
    },
  };
}

/**
 * @param {{ mode?: string, root?: string }} reqObj
 */
async function handle(reqObj) {
  // Cheap liveness/handshake probe: confirms the process is up and the JSON
  // line protocol works, WITHOUT triggering a vite resolve. Used by the caller
  // for a readiness handshake and periodic health checks.
  if (reqObj.op === "hello") {
    return { ok: true, hello: true, pid: process.pid, node: process.version };
  }

  if (reqObj.op === "resolve-all") {
    return handleResolveAll(reqObj);
  }

  const mode = reqObj.mode ?? "development";
  let root = reqObj.root ?? INITIAL_CWD;
  root = isAbsolute(root) ? root : resolvePath(INITIAL_CWD, root);
  const key = `${root}\0${mode}`;

  const { vite, viteVersion, importMs } = await getVite(root);

  // --- gate: stat the watch set; serve cache if nothing changed ---
  // `force: true` bypasses the gate and always re-resolves (manual refresh /
  // benchmarking the raw resolve cost).
  const force = reqObj.force === true;
  const tGate = performance.now();
  const cached = resultCache.get(key);
  const stale = force || !cached || isStale(cached.snapshot);
  const gateMs = +(performance.now() - tGate).toFixed(2);

  if (cached && !stale) {
    return {
      ...cached.result,
      cache: "hit",
      timings: { importMs: 0, gateMs, resolveMs: 0, loadEnvMs: 0, totalMs: gateMs },
    };
  }

  // --- miss / stale: resolve fresh ---
  // Real vite is launched from the project root, so plugins/config that read
  // process.cwd() assume cwd === root. The sidecar runs from elsewhere, so we
  // chdir here to emulate a real invocation. Safe because requests are
  // serialized (one resolve at a time via the tail promise).
  process.chdir(root);
  const tR = performance.now();
  let resolved;
  try {
    resolved = await vite.resolveConfig(
      { root, mode, logLevel: "silent", customLogger: stderrLogger },
      "serve",
      mode,
      "development",
    );
  } catch (err) {
    const e = new Error(
      `resolveConfig threw: ${err?.message ?? String(err)}`,
    );
    // @ts-ignore
    e.kind = "config-eval";
    throw e;
  }
  const resolveMs = +(performance.now() - tR).toFixed(2);

  const envDir = resolved.envDir ?? root;
  const envPrefix = resolved.envPrefix ?? "VITE_";

  const tE = performance.now();
  const env = vite.loadEnv(mode, envDir, envPrefix);
  const loadEnvMs = +(performance.now() - tE).toFixed(2);

  const targets = buildWatchTargets(resolved, root, mode, envDir);
  const result = {
    ok: true,
    mode,
    root: resolved.root ?? root,
    envDir,
    envPrefix,
    viteVersion,
    env,
    define: resolved.define ?? {},
    watching: targets.length,
  };
  resultCache.set(key, { result, snapshot: snapshot(targets) });

  return {
    ...result,
    cache: force ? "forced" : cached ? "stale-refresh" : "miss",
    timings: {
      importMs, // one-time import cost for this root (already paid after first request)
      gateMs,
      resolveMs,
      loadEnvMs,
      totalMs: +(gateMs + resolveMs + loadEnvMs).toFixed(2),
    },
  };
}

// --- line loop --------------------------------------------------------------
// Requests are processed sequentially via a tail promise so timings aren't
// skewed by concurrent resolves, and so stdin EOF can drain before exit.
const rl = createInterface({ input: process.stdin });
let tail = Promise.resolve();

rl.on("line", (line) => {
  const text = line.trim();
  if (!text) return;
  tail = tail.then(async () => {
    let reqObj;
    try {
      reqObj = JSON.parse(text);
    } catch {
      process.stdout.write(JSON.stringify({ ok: false, error: { kind: "unknown", message: "invalid JSON request" } }) + "\n");
      return;
    }
    const id = reqObj.id;
    try {
      const res = await handle(reqObj);
      process.stdout.write(JSON.stringify({ id, ...res }) + "\n");
    } catch (err) {
      const kind = /** @type {any} */ (err)?.kind ?? "unknown";
      process.stdout.write(
        JSON.stringify({ id, ok: false, error: { kind, message: err?.message ?? String(err) } }) + "\n",
      );
    }
  });
});
rl.on("close", () => {
  // wait for all queued requests to settle before exiting
  tail.then(() => process.exit(0));
});
process.stderr.write("[worker] ready\n");
