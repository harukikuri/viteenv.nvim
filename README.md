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
  stays correct across Vite versions.
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
