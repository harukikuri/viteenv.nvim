# Sidecar protocol

`sidecar/worker.mjs` is a long-lived Node process. The Lua side talks to it over
**newline-delimited JSON** on stdin/stdout. stderr carries human logs only
(never part of the protocol). stdout carries **one JSON object per line**.

Started with no arguments:

```
node sidecar/worker.mjs
```

## Requests (stdin, one JSON per line)

### `hello` — liveness / handshake (no Vite resolve)
```json
{ "id": 0, "op": "hello" }
```
→ `{ "id": 0, "ok": true, "hello": true, "pid": 12345, "node": "v20.x" }`

Used for the startup handshake and periodic health checks. Cheap; does not
touch Vite.

### resolve (default op)
```json
{ "id": 1, "mode": "development", "root": "/abs/project/root", "force": false }
```
- `mode` — Vite mode (default `"development"`)
- `root` — absolute project root (default the sidecar's initial cwd)
- `force` — bypass the mtime gate and always re-resolve (manual refresh)

### resolve-all — every mode at once
```json
{ "id": 2, "op": "resolve-all", "root": "/abs/project/root", "force": false,
  "only": ["development", "production"] }
```
One `resolveConfig` (for `envDir`/`envPrefix`) then a cheap `loadEnv` per mode.
Modes are auto-discovered: `--mode` flags in `package.json` scripts (and
`vite`→development, `vite build`→production) ∪ `.env.<mode>` files, falling back
to `development`/`production` if none are found.
- `only` (optional) — limit the result to this subset of the discovered modes,
  in the given order.

Response adds `modeList` and `modes`:
```json
{
  "id": 2, "ok": true, "root": "…", "envDir": "…", "envPrefix": ["VITE_"],
  "modeList": ["development", "production", "staging"],
  "modes": {
    "development": { "VITE_API_URL": "http://localhost:3000/v1" },
    "production":  { "VITE_API_URL": "https://api.prod.example.com/v1" },
    "staging":     { "VITE_API_URL": "https://api.staging.example.com/v1" }
  },
  "define": { "…": "…" }, "watching": 9, "cache": "miss", "timings": { … }
}
```

## Responses (stdout, one JSON per line)

### success
```json
{
  "id": 1,
  "ok": true,
  "mode": "development",
  "root": "/abs/project/root",
  "envDir": "/abs/project/root",
  "envPrefix": ["VITE_"],
  "viteVersion": "8.1.1",
  "env": { "VITE_API_URL": "https://api.dev.example" },
  "define": { "__APP_MODE__": "\"development\"" },
  "watching": 5,
  "cache": "hit | miss | stale-refresh | forced",
  "timings": { "importMs": 0, "gateMs": 0.02, "resolveMs": 0, "loadEnvMs": 0, "totalMs": 0.02 }
}
```

### failure (worker stays alive)
```json
{ "id": 1, "ok": false, "error": { "kind": "...", "message": "..." } }
```

`error.kind`:
| kind | meaning | Lua action (see docs/DESIGN.md) |
|---|---|---|
| `vite-not-found` | no Vite resolvable from `root` (permanent) | disable lens for this root; do **not** restart worker |
| `config-eval` | `vite.config` / a plugin threw (often transient, mid-edit) | show last-good as stale; auto-recovers on next change |
| `bad-vite-api` | resolved Vite lacks expected API | disable + notify (upgrade) |
| `unknown` | anything else / bad request JSON | log; treat as transient |

## Behavior notes (validated; see `docs/DESIGN.md`)

- The worker resolves the **project's** Vite from `root` (monorepo-safe), not a
  global one.
- It `chdir(root)` before resolving so `process.cwd()`-dependent plugins behave
  as under real Vite. **Required.**
- Requests are processed **serially** (a tail promise) — needed because `chdir`
  is process-global. A slow/hanging async `config` hook head-of-line-blocks the
  queue, so a worker-side resolve timeout is planned.
- The mtime gate watches `configFileDependencies` + `configFile` + the env
  cascade (`.env`, `.env.local`, `.env.<mode>`, `.env.<mode>.local`), including
  not-yet-existing candidates.
