# viteenv.nvim

Inline lens for Vite environment variables. Shows the **effective value** of
`import.meta.env.VITE_X` (per mode) right next to the reference in your source,
resolved by your project's own Vite — so cascade, `dotenv-expand`, `envPrefix`,
mode files, and `define` all match what Vite actually produces.

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
- **Live** — a filesystem watcher refreshes the lens when `.env*` /
  `vite.config` change, no keypress needed.

## Requirements

- Neovim 0.10+ (extmarks / `vim.system`)
- Node.js 18+ available on `PATH`
- A project where **Vite is resolvable from the project root** via Node's module
  resolution — i.e. reachable in `node_modules` from the root upward (the
  project's own install, or a hoisted one in a monorepo). The sidecar uses that
  Vite; nothing is bundled, and a global Vite is never used.

## Installation

```lua
{ "harukikuri/viteenv.nvim", opts = {} }
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
