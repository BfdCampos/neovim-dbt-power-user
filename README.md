# dbt-power-user.nvim

A keyboard-first Neovim port of the useful parts of [AltimateAI/vscode-dbt-power-user](https://github.com/AltimateAI/vscode-dbt-power-user). CLI-only, no Python bridge, no cloud account, no telemetry. Everything shells out to the real `dbt` binary already on your machine and reads its own artifacts (`manifest.json`, `catalog.json`, `run_results.json`).

Not everything from the VSCode extension made the trip across, on purpose. Here's the shape of it at a glance:

## At a glance: this vs. the VSCode extension

**✅ What made the trip:**
- 🏃 Run / build / test / compile, with dbt's own `+model` / `model+` / `+model+` selectors
- 👁️ Compiled SQL preview
- 📊 Query preview (`dbt show`), with CSV/JSON yank
- 🕸️ Lineage as a real ASCII flowchart (horizontal or vertical, not an indented tree)
- 🎯 Go to definition + hover for `ref()` / `source()` / macros
- ⌨️ `ref()` / `source()` autocomplete
- 🩺 Local health diagnostics as real Neovim diagnostics
- 🚦 Quickfix integration on a failed run/build/test
- 🔎 Pickers for models, sources, macros, run history, plus an action palette
- 📖 Docs generate/open, defer to prod, create-model-from-source scaffolder

**🚫 What deliberately didn't** (see [Out of scope](#out-of-scope) below for why each one):
- 🧬 Column-level lineage
- 🤖 The AI suite (explain/optimise/review/translate/fix)
- ✅ SQL validation & the deeper healthcheck
- 🖼️ The Perspective results grid, embedded docs browser, notebooks, collaboration threads
- 🎨 SQL formatting
- 💸 The CTE profiler and BigQuery cost estimator

Smaller on purpose, not unfinished: everything cut was either commercial-cloud-gated, GUI-only with no honest terminal equivalent, or already solved better by another plugin you'd have installed anyway.

## Features

- **Run / build / test / compile** the current model, with dbt's own selector operators (`+model`, `model+`, `+model+`) mapped to convenient keymaps, and full selector syntax available via the `:Dbt*` commands.
- **Compiled SQL preview** — a read-only floating window showing the real, Jinja-rendered SQL for the model under your cursor.
- **Query preview** — run the current buffer, a visual selection, or the compiled model itself against your warehouse via `dbt show`, rendered as an aligned table with CSV/JSON yank.
- **Lineage** — a real flowchart, left to right by default (raw sources on the left flowing through to the model in question, its downstream consumers further right; set `opts.lineage.direction = "vertical"` for top-to-bottom instead), with proper box-drawing connectors including merges/splits, not an indented tree — `<CR>`/`o` jump to a file under the cursor, `/` searches it like any other buffer. A flat picker is also available if you'd rather fuzzy-find than read the diagram.
- **Go to definition** (`gd`) and **hover** (`<leader>Dk`) for `ref()`, `source()` and macro calls, wired through Neovim's native `tagfunc` so `<C-]>`/`<C-t>` work too. `K` is left alone deliberately — it's `keywordprg` by default and often already rebound by an LSP, so it never gets fought over.
- **Autocomplete** for `ref()`/`source()` arguments via a `blink.cmp` source.
- **Local health diagnostics** — the same four checks the VSCode extension runs without a cloud account (missing docs, model not yet built, undocumented column, column missing from the warehouse), surfaced as real Neovim diagnostics.
- **Quickfix integration** — a failing `run`/`build`/`test` populates the quickfix list from `run_results.json`, so `]q`/`[q` just works.
- **Pickers** for models, sources, macros, run history, and a `:DbtActions` palette that lists every action with its keymap.
- **Defer to prod**, **docs generate/open**, and a **create-model-from-source** scaffolder.
- `:checkhealth dbt-power-user`.

## Requirements

- Neovim ≥ 0.10 (built and tested on 0.11.6). Only `vim.system` is used for process execution — no `plenary.job` dependency at runtime.
- [dbt-core](https://github.com/dbt-labs/dbt-core) on your `PATH` (or point `opts.dbt_cmd` at it).
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) — popups, including the lineage flowchart.
- [snacks.nvim](https://github.com/folke/snacks.nvim) with the picker enabled — models/sources/macros/actions pickers. (If you use telescope instead of snacks, the pickers won't work; everything else will.)
- [blink.cmp](https://github.com/Saghen/blink.cmp) — only needed for `ref()`/`source()` autocomplete.
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) — dev/test dependency only, not required at runtime.

All five are already part of a stock LazyVim install.

## Installation

Create `~/.config/nvim/lua/plugins/dbt-power-user.lua`:

```lua
return {
  {
    "BfdCampos/neovim-dbt-power-user",
    name = "dbt-power-user.nvim",
    ft = { "sql", "yaml" },
    dependencies = { "MunifTanjim/nui.nvim" },
    config = function(_, opts)
      require("dbt-power-user").setup(opts)
    end,
    opts = {
      -- prefix = "<leader>D",   -- change to "<leader>M" if you ever enable
                                  -- LazyVim's extras.lang.sql (it also claims <leader>D)
    },
  },
}
```

Restart Neovim (or `:Lazy sync`), then open any `.sql` file inside a dbt project and run `:checkhealth dbt-power-user` to confirm everything is wired up.

If you turn on blink.cmp completion, add this to whatever spec you already configure `saghen/blink.cmp` in:

```lua
opts = {
  sources = {
    providers = {
      dbt = { name = "dbt", module = "dbt-power-user.completion.blink" },
    },
    per_filetype = { sql = { inherit_defaults = true, "dbt" } },
  },
}
```

## Getting started — testing it right now, with no dbt project of your own

This repo includes what you need to build a real, working test project so you can try every feature without touching your own dbt setup: a small setup script that clones [dbt-labs/jaffle-shop](https://github.com/dbt-labs/jaffle-shop) (the `jaffle-shop-old` branch — the current `main` requires an unreleased dbt 2.0) into `tests/fixtures/jaffle-shop/` and builds it against a local DuckDB file. That directory is gitignored — it's its own nested git clone with generated artifacts, not checked in as plugin source — so build it once yourself, then reuse it for as long as you like.

1. **Clone this repo** somewhere on disk, separate from wherever your plugin manager ends up installing it, since you'll run `nvim` directly against files inside this clone:
   ```bash
   git clone https://github.com/BfdCampos/neovim-dbt-power-user.git
   cd neovim-dbt-power-user
   ```
2. **Install the plugin.** Create `~/.config/nvim/lua/plugins/dbt-power-user.lua`:
   ```lua
   return {
     {
       "BfdCampos/neovim-dbt-power-user",
       name = "dbt-power-user.nvim",
       ft = { "sql", "yaml" },
       dependencies = { "MunifTanjim/nui.nvim" },
       config = function(_, opts)
         require("dbt-power-user").setup(opts)
       end,
       opts = {
         -- prefix = "<leader>D",   -- change to "<leader>M" if you ever enable
                                     -- LazyVim's extras.lang.sql (it also claims <leader>D)
       },
     },
   }
   ```
   Restart Neovim (or `:Lazy sync`).
3. **Build the fixture.** Needs `dbt` on `PATH` (`pip install dbt-duckdb` pulls in dbt-core automatically) — any way you manage that (pyenv, a venv, whatever you already use) is fine:
   ```bash
   git clone --branch jaffle-shop-old https://github.com/dbt-labs/jaffle-shop.git tests/fixtures/jaffle-shop
   cd tests/fixtures/jaffle-shop

   # If you use pyenv and your active Python doesn't have dbt-core + dbt-duckdb, pin
   # one that does for just this directory (skip this line otherwise):
   pyenv local 3.9.10

   cat > profiles.yml <<'EOF'
   default:
     target: dev
     outputs:
       dev:
         type: duckdb
         path: jaffle_shop.duckdb
         schema: main
         threads: 4
   EOF

   dbt deps  --no-version-check
   dbt seed  --full-refresh --vars '{"load_source_data": true}' --no-version-check
   dbt build --vars '{"load_source_data": true}' --no-version-check
   dbt docs generate --no-version-check
   cd ../../..
   ```
   (`--no-version-check` is only needed because jaffle-shop's `main` branch — not `jaffle-shop-old` — pins a `require-dbt-version` ahead of any released dbt-core. It isn't something the plugin itself adds to your own commands; see `opts.no_version_check` below if you ever need it for your own project.)
4. **Open a model file in the fixture** (from inside your clone of this repo):
   ```
   nvim tests/fixtures/jaffle-shop/models/marts/customers.sql
   ```
5. **Run the health check**: `:checkhealth dbt-power-user`. You should see the dbt executable, the detected project (`jaffle_shop`), a real manifest and catalog, and a free `<leader>D` prefix, all green.
6. **Try the actions palette**: `<leader>Da` opens a picker listing every action next to its keymap. Confirming any entry runs it — this is the one thing worth memorising, everything else is discoverable from here.
7. A few specific things to try on `customers.sql`:
   - `<leader>Dc` — compiled SQL preview. You'll see the real rendered SQL, `ref()` calls replaced with quoted relation names.
   - Put your cursor inside `ref('stg_customers')` on line 5 and press `gd` — jumps straight to `stg_customers.sql`. Press `<leader>Dk` instead for a hover card with columns and types.
   - `<leader>Dl` — a lineage flowchart for `customers`: `raw_items` and friends on the left, flowing right through `stg_order_items`/`order_items`/`orders` into `customers`. `<CR>` opens the file under the cursor, `o` opens it without leaving the popup, `q` closes it, `/` searches it like any buffer.
   - `<leader>Dp` — previews the whole buffer's query result as a table (yank with `yc`/`yj`). Visually select a few lines first and press `<leader>Dp` again to preview just the selection.
   - `<leader>Dr` — runs just this model; `<leader>DR` — this model and everything downstream. Watch the notification, then check `:copen` if anything failed (nothing will, the fixture is a clean build).
   - `<leader>Dm` / `<leader>Ds` / `<leader>DM` — pickers over every model / source / macro in the project.

If you ever want a fresh DuckDB file, delete `tests/fixtures/jaffle-shop/` and repeat step 3.

## Running it against your own project

Point `opts.project_dir`/`opts.profiles_dir`/`opts.dbt_cmd`/`opts.target` at whatever makes `dbt <anything>` work from your terminal today — the plugin doesn't need a real dbt project to be anything special, it just shells out the same commands you'd type yourself.

One thing worth flagging: some organisations wrap `dbt` in their own script rather than exposing it directly on `PATH` (a shell function, a task runner, whatever). If a plain `dbt compile`/`dbt run` doesn't already work for you outside this plugin (try it in a terminal first), set `opts.dbt_cmd` to whatever wrapper does — this plugin hasn't been tested against every such setup, so treat it as a starting point to adjust rather than something guaranteed to work first try.

## Configuration

All defaults, in `lua/dbt-power-user/config.lua`:

```lua
require("dbt-power-user").setup({
  prefix = "<leader>D",       -- leader-key prefix for every mapping below
  dbt_cmd = "dbt",             -- absolute path override allowed
  project_dir = nil,            -- nil = auto-detect by walking up for dbt_project.yml
  profiles_dir = nil,             -- nil = dbt's own default resolution (~/.dbt)
  target = nil,                    -- nil = the profile's own default target
  no_version_check = false,         -- adds --no-version-check to every dbt invocation
  query_limit = 500,                 -- row limit for `dbt show`
  lineage = { max_depth = 5, direction = "horizontal" }, -- or "vertical"
  picker = { preview = true },
  create_model = { prefix = "stg", template = "{prefix}_{table}" },
  defer_state_path = nil,       -- nil = --defer/--state unavailable until you set this
})
```

## Keymaps

Everything below is under `opts.prefix` (default `<leader>D`); `<leader>Da` opens a palette listing all of them plus a few extras that don't have a dedicated keymap.

| Keys | Action |
|---|---|
| `<leader>Dr` | Run current model |
| `<leader>DR` | Run current model and downstream |
| `<leader>Du` | Run upstream and current model |
| `<leader>Db` | Build current model |
| `<leader>Dt` | Test current model |
| `<leader>Dc` | Compile and preview current model |
| `<leader>Dp` | Preview query results (whole buffer in normal mode, selection in visual mode) |
| `<leader>Dl` | Lineage tree |
| `<leader>DL` | Lineage picker (upstream) |
| `<leader>Dg` | Go to definition under cursor |
| `<leader>Dk` | Hover under cursor |
| `<leader>Dm` | Models picker |
| `<leader>Ds` | Sources picker |
| `<leader>DM` | Macros picker |
| `<leader>Dh` | Run history (latest run results) |
| `<leader>DD` | Toggle defer to prod |
| `<leader>Do` | Open dbt docs in browser |
| `<leader>DG` | Generate dbt docs |
| `<leader>Da` | Action palette (everything above, plus the downstream lineage picker) |

Inside any `.sql` buffer belonging to a detected dbt project, plain `gd` is also bound (buffer-local, so it never affects non-dbt files). `K` is never touched — hover lives at `<leader>Dk` instead.

## Commands

`:DbtRun`, `:DbtBuild`, `:DbtTest`, `:DbtCompile` and `:DbtSeed` each take an optional dbt selector, with `%` expanding to the current buffer's model name — so `:DbtBuild %+` builds the current model and everything downstream, and `:DbtBuild orders+,@customers` works exactly as it would on the command line. `:DbtDeps`, `:DbtClean`, `:DbtParse` and `:DbtDocsGenerate` take no arguments.

## Out of scope

Deliberately not built, all for the same reason: no honest Neovim equivalent, or already solved better by something else.

- **Column-level lineage.** The VSCode extension leans on a bundled `sqlglot` plus, failing that, a paid cloud API. A local, `sqlglot`-backed version is a plausible future extension but wasn't built for v1.
- **The AI assistance suite** (explain/optimise/review/translate/fix, all cloud-gated). You already have `avante.nvim`/`copilot.lua`/`codecompanion.nvim`/Claude Code for that.
- **SQL validation and the deeper healthcheck** — both call Altimate's paid backend.
- **The Perspective results grid, the embedded docs browser, notebooks, and docs collaboration threads** — all GUI-only or hosted-service features with no editor-native equivalent worth faking. Query results get CSV/JSON yank instead of a pivot table; docs open in your real browser; there's no in-editor comment thread.
- **SQL formatting.** Already solved better by [conform.nvim](https://github.com/stevearc/conform.nvim), which ships a `sqlfmt` formatter — three lines of config, not reimplemented here.
- **The CTE profiler and the BigQuery cost estimator** — narrow, warehouse-cost-incurring features, worth adding later only if you actually want them.

## Architecture

`DESIGN.md` has the full module-by-module breakdown (exact function contracts, the research this was built from, and why several early instincts — treesitter parsing, `plenary.job`, telescope — were deliberately not used). Useful if you're extending this yourself, or handing it to an AI agent to do so.

The command grammar (`%` selector expansion) follows [EloiSanchez/dbt.nvim](https://github.com/EloiSanchez/dbt.nvim) (MIT); the quickfix/diagnostics patterns (bufnr-XOR-filename, `QuickFixCmdPost`, extmark-tracked diagnostics) follow [nvim-neotest/neotest](https://github.com/nvim-neotest/neotest) (MIT). No code was copied from either — both are credited here because the *patterns* were worth reusing deliberately rather than reinventing. [gbakes/dbt-forge](https://github.com/gbakes/dbt-forge) is the closest prior art in spirit but ships with no licence file, so nothing from it — code or otherwise — went into this repo.

## Testing

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

175 specs, all passing, most of them asserting against the real jaffle-shop fixture's actual `manifest.json`/`catalog.json`/`run_results.json` rather than hand-built mocks.

## Licence

MIT, see `LICENSE`.
