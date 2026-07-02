# Design notes

Why viteenv.nvim resolves env the way it does. Condensed from a validation
spike (one-shot probe + a resident worker) run against real Vite projects
(Vite 8.1.1, Node 25). The code shows *what*; this is the *why*.

## Approach: delegate to the project's Vite

We do **not** reimplement env loading. The sidecar calls the project's own
`resolveConfig` + `loadEnv`, so the cascade, `dotenv-expand`, `envPrefix`, mode
files, and `define` always match what Vite actually produces — and stay correct
across Vite versions without us tracking spec changes.

Verified it correctly handles: `.env` / `.env.<mode>` precedence,
`${VAR}` expansion, custom `envPrefix` (incl. excluding non-prefixed keys),
user + plugin `define`, and async plugin `config`/`configResolved` hooks.

**All modes at once** (`resolve-all` op, for the inline all-modes lens):
one `resolveConfig` yields `envDir`/`envPrefix`, then a cheap `loadEnv` per mode
(~0.1 ms each) — no repeated `resolveConfig`. The gate additionally watches
`envDir` itself so a newly-added `.env.<mode>` invalidates the cache.

**Mode discovery.** Vite has no canonical mode list (a mode is just a CLI
`--mode` string), so modes are always auto-discovered from consumer-authored
signals: `--mode` flags in `package.json` scripts (plus `vite`→development,
`vite build`→production) ∪ `.env.<mode>` files; falling back to
development/production only if nothing is found. Only the fallback is imposed.
An optional `only` filter (from the plugin's `mode` config) narrows the result
to a subset. Value resolution per mode is always Vite's `loadEnv` — discovery
only decides *which* modes to load.

## Cost (measured)

| Path | Cost | Notes |
|---|---|---|
| One-shot `node` process | ~110 ms | dominated by node start + `import vite` |
| Resident worker: import | ~58 ms | **once** per project root |
| Resident worker: cold resolve | ~12 ms (light) / ~70 ms (heavy) | first resolve; esbuild warmup + TS-config bundle |
| Resident worker: **warm resolve** | p50 ~2.7 ms / p99 ~3.4 ms (light) | re-resolve after warmup |
| Heavy plugins (react+legacy+tsconfigPaths+300-file scan) | p50 ~6.7 ms / p99 ~9.8 ms | still single-digit ms |
| Network-I/O `config` hook | p50 = network latency (e.g. ~175 ms at 120 ms RTT), heavy jitter tail | dominates everything |
| mtime-gate **hit** (no change) | **~0.02 ms** | just `stat`s the watch set |

Takeaway: a **resident worker + an mtime gate** turns a ~110 ms/call cost into
~0.02 ms when nothing changed, and confines the real resolve cost to the moment
`vite.config`/`.env*` actually change.

## Three hard requirements

1. **Resolve the *project's* Vite from `root`** (monorepo-safe), never a global
   one. Vite is ESM-only, so `require.resolve('vite')` fails (no `require`
   export condition); instead resolve `vite/package.json`, read `exports['.']`,
   pick the ESM entry, and dynamic-`import` it.

2. **`chdir(root)` before resolving.** Real Vite is launched *from* the project
   root, so plugins/configs that read `process.cwd()` assume `cwd === root`. The
   sidecar starts elsewhere; without the chdir, such plugins break (we hit a real
   `ENOENT` from `@vitejs/plugin-legacy`-style cwd usage). Because `chdir` is
   process-global, requests must be processed **serially**.

3. **Gate + timeout.** The mtime gate (watch `configFileDependencies` +
   `configFile` + the `.env` cascade, including not-yet-existing candidates)
   keeps unchanged queries near-free. But `resolveConfig` re-runs `config` hooks
   every time, so a slow/hanging async hook (network I/O) head-of-line-blocks the
   serial queue — a worker-side resolve timeout is needed, and the Lua-side
   per-request timeout must be generous (~10 s) to not false-flag a healthy
   worker as wedged.

## Failure handling

Resolution failures are **structured, never thrown**: `{ ok:false, error:{ kind,
message } }`, and the worker stays alive. Distinguish:

- **per-request error** → degrade only, do NOT restart the worker.
- **process failure** (spawn/crash/no-response/garbage on stdout) → restart with
  exponential backoff + circuit breaker; protocol parser skips unparseable lines.

Display tiers (Lua keeps a last-good cache so it always has something to show):

| Tier | When | Render |
|---|---|---|
| 0 fresh | worker up, fresh value | the value |
| 1 stale | restarting / in-flight | last-good, dimmed |
| 2 degraded | no last-good + worker down | placeholder, quiet |
| 3 disabled | permanent (no Vite / bad API) | off for that root, one notice |

`error.kind` → action:

| kind | meaning | action |
|---|---|---|
| `vite-not-found` | no Vite in project (permanent) | Tier 3; do **not** restart worker |
| `config-eval` | config/plugin threw (often mid-edit) | Tier 1 stale; auto-recovers on next change |
| `bad-vite-api` | unsupported Vite | Tier 3 + notify |
| `unknown` | other / bad request | log; transient |

See `sidecar/PROTOCOL.md` for the wire format.
