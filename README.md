# viteenv.nvim

Inline lens for Vite environment variables. Shows the **effective value** of
`import.meta.env.VITE_X` (per mode) right next to the reference in your source,
resolved by your project's own Vite — so cascade, `dotenv-expand`, `envPrefix`,
mode files, and `define` all match what Vite actually produces.

> Status: **working.** Inline end-of-line text shows every Vite mode —
> collapsed to one value when all modes agree, fanned out per-mode only for keys
> that differ. Backed by the resident sidecar; Treesitter-accurate. Approach
> validated — see [`docs/DESIGN.md`](docs/DESIGN.md). Tests: `make test`.
> Still TODO: `.env` watching beyond the sidecar gate.

## How it works

```
 ┌────────────┐   import.meta.env.VITE_X spotted   ┌─────────────────┐
 │  Neovim    │ ────────────────────────────────▶ │  Node sidecar    │
 │  (Lua)     │   {root, mode} request (JSON)      │  (sidecar/       │
 │            │ ◀──────────────────────────────── │   worker.mjs)    │
 │  renders   │   {env, define, ...} response      │  uses PROJECT's  │
 │  virt_text │                                    │  vite, mtime gate│
 └────────────┘                                    └─────────────────┘
```

- **Resolution is delegated to the project's Vite** (not reimplemented), so it
  stays correct across Vite versions. (`docs/DESIGN.md`)
- A **resident worker** keeps Vite imported once; warm resolves cost ~2–7 ms.
- An **mtime gate** re-resolves only when `vite.config` / `.env*` actually
  change; unchanged queries cost ~0.02 ms.
- **Failures are structured**, and the plugin degrades gracefully (stale / off)
  instead of erroring.

## Architecture / layout

See [`doc/viteenv.txt`](doc/viteenv.txt) for the full map. In short:

| Path | Role |
|---|---|
| `lua/viteenv/` | the plugin (config, inline lens, worker client, scan, cache) |
| `plugin/viteenv.lua` | load guard, commands, autocmds |
| `sidecar/worker.mjs` | the validated Node resolver (resident worker + gate) |
| `sidecar/PROTOCOL.md` | the JSON line protocol between Lua and the sidecar |
| `docs/DESIGN.md` | design rationale + measured costs (not shipped at runtime) |

## Requirements

- Neovim 0.10+ (extmarks / `vim.system`)
- Node.js 18+ available on `PATH`
- A project where **Vite is resolvable from the project root** via Node's module
  resolution — i.e. reachable in `node_modules` from the root upward (the
  project's own install, or a hoisted one in a monorepo). The sidecar uses that
  Vite; nothing is bundled, and a global Vite is never used.

## Install (lazy.nvim) — placeholder

```lua
{ "kuri-sun/viteenv.nvim", opts = {} }
```

## Configuration

```lua
require("viteenv").setup({
  mode = nil,   -- nil = show all discovered modes; a list limits them,
                --   e.g. { "development", "production" }
  lens = {
    collapse = true, -- one value when all modes agree; per-mode when they differ
    -- mode_labels = { development = "dev", production = "prod" }, -- optional
  },
})
```

### Which modes are shown?

Vite has no canonical mode list (a mode is just a `--mode` string), so modes are
**always auto-discovered**:

- `--mode` flags in your `package.json` scripts (and `vite`→`development`,
  `vite build`→`production`) **∪** your `.env.<mode>` files.
- fallback to `development` / `production` only if nothing is found.

Set `mode` to a list to **limit** the lens to a subset of those (or use
`:ViteEnvMode development production`); leave it `nil` to show them all.

Inline output (only differing keys fan out per mode):

```
const name   = import.meta.env.VITE_APP_NAME;          = viteenv demo
const apiUrl = import.meta.env.VITE_API_URL;           development = http://localhost:3000/v1 │ production = https://api.prod… │ staging = …
```
(annotations start at the same column regardless of line length)

Annotations are **aligned to a uniform column** — `lens.padding` spaces
(default 8) past the longest annotated line — and use their own highlight
groups, which you can override:

```vim
hi ViteEnvValue     guifg=...   " the value (default: Comment)
hi ViteEnvMode      guifg=...   " the mode label (Type)
hi ViteEnvSeparator guifg=...   " the │ divider (NonText)
hi ViteEnvStale     guifg=...   " last-good shown while refreshing
hi ViteEnvMissing   guifg=...   " referenced VITE_X not set
```

Labels are the real mode names by default; set `lens.mode_labels` to abbreviate
(e.g. `{ development = "dev", production = "prod" }`).

See `lua/viteenv/config.lua` for all defaults.
