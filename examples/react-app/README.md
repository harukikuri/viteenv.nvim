# viteenv example: React + Vite + TS

A small but real Vite app used to exercise viteenv.nvim against actual
`import.meta.env.VITE_*` references.

## What it demonstrates

- `src/config.ts` and `src/App.tsx` reference several env vars (dot + bracket).
- `.env` / `.env.development` / `.env.production` show:
  - mode-specific overrides (`VITE_API_BASE`, `VITE_DEBUG`, `VITE_FEATURE_FLAGS`)
  - variable expansion (`VITE_API_URL=${VITE_API_BASE}/v1`)
  - a non-`VITE_` secret (`SECRET_DB_PASSWORD`) that is correctly NOT exposed
- `vite.config.ts` adds a user `define` (`__BUILD_MODE__`).

## Setup

```sh
npm install
```

## See it in Neovim

With the plugin on your runtimepath:

```lua
require("viteenv").setup({})
```

Open `src/config.ts`. Each `import.meta.env.VITE_*` gets inline end-of-line text
showing every mode (`development`, `production`, and the custom `staging` from
`.env.staging`). Keys that are the same in all modes collapse to one value;
keys that differ fan out:

```
appName:  import.meta.env.VITE_APP_NAME    = viteenv demo
apiUrl:   import.meta.env.VITE_API_URL     development = http://localhost:3000/v1 │ production = https://api.prod… │ staging = https://api.staging…
debug:    import.meta.env.VITE_DEBUG       development = true │ production = false │ staging = true
```

Limit which modes show with `:ViteEnvMode development production`, or
`setup({ mode = { "development", "production" } })`.

## Confirm the sidecar resolves it directly

The resolver the lens uses can also be driven by hand. From the plugin repo root:

```sh
# development
echo '{"id":1,"mode":"development","root":"'"$PWD"'/examples/react-app"}' \
  | node sidecar/worker.mjs

# production
echo '{"id":1,"mode":"production","root":"'"$PWD"'/examples/react-app"}' \
  | node sidecar/worker.mjs
```

You should see `VITE_API_URL` expanded differently per mode and the secret absent.

## Run the app (optional)

```sh
npm run dev      # http://localhost:5173
npm run build
```
