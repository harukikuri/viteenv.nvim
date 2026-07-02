# Tests

Dependency-free suite — no plenary/mini required, just headless Neovim.

```sh
make test
# or:
nvim --headless -u NONE -l tests/run.lua
```

Exits nonzero if any spec fails (CI-friendly).

## Layout

- `run.lua` — runner; discovers `*_spec.lua`, provides `describe/it/eq/ok/skip`
  and the `H` helpers global. Exits via `cquit` on failure.
- `helpers.lua` — buffer/tmp/path/wait utilities.
- `*_spec.lua` — one file per module.

## What's covered

| Spec | Kind | Needs |
|---|---|---|
| `config_spec` | unit | — |
| `scan_spec` | unit | comment/string test skips without a `typescript` parser |
| `project_spec` | unit | — |
| `lens_spec` | unit | — |
| `worker_spec` | integration | `node` + `npm install` in `examples/react-app` (else skipped) |

Integration specs auto-skip when the example app isn't installed, so the unit
suite always runs.
