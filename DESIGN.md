# dbt-power-user.nvim — architecture spec

Internal build contract. Every module below MUST match its signatures exactly so
parallel implementation doesn't produce mismatched call sites. This file is the
single source of truth during the build; trim it down into README.md once the
plugin works end to end.

## Philosophy

Port the *value* of AltimateAI/vscode-dbt-power-user to Neovim, not its UI. CLI-only
architecture (no Python bridge, no cloud calls). Keyboard-first: every feature is a
command or a leader-key mapping, mouse always optional. Where a VSCode feature is
GUI-only (Perspective grid, embedded docs browser, notebooks, AI suite, collaboration
threads) it is skipped outright — see "Explicitly out of scope" below. Not everything
maps 1:1 and that's fine; the goal is that the plugin feels native to Neovim.

## Confirmed environment facts (do not re-derive, just use)

- Leader is `<leader>` (Space). Plugin's own prefix is `<leader>D` (config: `opts.prefix`,
  default `"<leader>D"`). Verified collision-free against LazyVim defaults and a real
  user config. ONE caveat: `extras/lang/sql.lua` (not currently enabled) maps `<leader>D`
  to `DBUIToggle` — if that extra is ever enabled, the user changes `opts.prefix` to
  `<leader>M` (verified free everywhere). Don't hardcode the prefix anywhere except
  `config.lua`'s default.
- `vim.system` for all async job execution (native in nvim 0.11.6, no plenary.job at
  runtime). **on_exit and on_stdout/on_stderr callbacks run in a fast-event context —
  ANY nvim API call inside them (buffer writes, vim.notify, diagnostics, picker calls)
  MUST be wrapped in `vim.schedule(function() ... end)`.** This is the single easiest
  bug to introduce; every module that touches vim.system must respect it.
- No treesitter for parsing dbt SQL (sql/jinja parsers aren't installed, and dbt SQL
  isn't valid SQL grammar anyway — see `extract.lua` spec below for the verified pure-Lua
  approach). Treesitter is still fine to *set* as a buffer's filetype (`sql`) purely for
  highlighting the compiled-SQL preview popup.
- Picker: **snacks.nvim** (`Snacks.picker.pick(opts)`), not telescope (not installed).
- Popups/trees: **nui.nvim** (`nui.popup`, `nui.tree`, `nui.line`).
- Completion: **blink.cmp** custom source (not nvim-cmp).
- Tests: **plenary.nvim** busted (`describe`/`it`), run via
  `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"`.
  `tests/minimal_init.lua` MUST be a minimal 4-line rtp setup — NEVER point it at a
  real, full `~/.config/nvim/init.lua`; that hangs for 120s+ per spec file (verified
  against a stock LazyVim config).
- Dev environment used to build this: dbt-core 1.9.6 + dbt-duckdb 1.9.6 under a pyenv
  Python 3.9.10 (any dbt-core 1.x + dbt-duckdb environment on `PATH` will do — this
  exact version isn't a hard requirement, just what was verified).

## Test fixture (already built and verified working — do not re-run dbt setup)

- `tests/fixtures/jaffle-shop/` — a real clone of dbt-labs/jaffle-shop, on branch
  `jaffle-shop-old` (the dbt 1.x-compatible line; `main` requires an unreleased dbt 2.0
  and will fail to parse — stay on `jaffle-shop-old`).
- `tests/fixtures/jaffle-shop/profiles.yml` — a project-local profile (duckdb, target
  `dev`, profile name `default`) pointing at `tests/fixtures/jaffle-shop/jaffle_shop.duckdb`.
  **This is intentionally separate from `~/.dbt/profiles.yml`**, which on a real dev
  machine will likely already have an unrelated `default` profile pointing at a real
  warehouse. Never touch `~/.dbt/profiles.yml`. Always invoke dbt with
  `--profiles-dir tests/fixtures/jaffle-shop`
  (or rely on the plugin's own `profiles_dir` config resolving to the project dir when set).
- `dbt deps && dbt seed --full-refresh --vars '{"load_source_data": true}' && dbt build && dbt docs generate`
  have already been run successfully against this fixture (52/52 pass) with
  `--no-version-check --project-dir tests/fixtures/jaffle-shop --profiles-dir tests/fixtures/jaffle-shop`.
  `target/manifest.json` (40 nodes, 6 sources), `target/catalog.json` (13 nodes),
  `target/run_results.json` and `target/compiled/**` all exist and are real. Use them
  directly in tests instead of hand-building fixture JSON.
- DAG shape (for anything that needs to assert against known lineage):
  `ecom.raw_items -> stg_order_items -> order_items -> orders -> customers` (5-level
  chain). `customers` has 2 parents (`stg_customers`, `orders`). `metricflow_time_spine`
  is a root node with no parents. Model names are globally unique in this fixture (no
  two-arg `ref('pkg','model')` calls anywhere), so name-based lookup is safe to test but
  the real implementation must still handle the two-arg form for other projects.

## Directory layout

```
dbt-power-user.nvim/
  lua/dbt-power-user/
    util.lua
    config.lua
    project.lua
    extract.lua
    manifest.lua
    job.lua
    selector.lua
    commands.lua
    quickfix.lua
    diagnostics.lua
    definition.lua
    hover.lua
    compile.lua
    show.lua
    lineage.lua
    picker.lua
    statusline.lua
    health.lua
    docs.lua
    create_model.lua
    defer.lua
    keymaps.lua
    init.lua
    completion/
      blink.lua
  plugin/
    dbt-power-user.lua
  doc/
    dbt-power-user.txt
  tests/
    minimal_init.lua
    fixtures/jaffle-shop/   -- already set up, see above
    extract_spec.lua
    project_spec.lua
    manifest_spec.lua
    selector_spec.lua
    quickfix_spec.lua
  README.md
  LICENSE
```

Module namespace uses the hyphen literally, e.g. `require("dbt-power-user.util")` —
this is valid Lua (require takes a string) and matches the `which-key` convention.

## Module contracts

### `util.lua` — no other module dependencies

```lua
M.notify(msg, level)              -- vim.notify wrapper, level default vim.log.levels.INFO,
                                   -- prefixes "[dbt] "
M.schedule(fn)                    -- if vim.in_fast_event() then vim.schedule(fn) else fn() end
M.json_decode(str) -> ok, data_or_err   -- pcall(vim.json.decode, str)
M.read_file(path) -> content_or_nil, err
M.file_mtime(path) -> mtime_or_nil      -- (vim.uv.fs_stat(path) or {}).mtime.sec
M.path_join(...) -> string              -- table.concat({...}, "/"), collapse "//"→"/"
```

### `config.lua` — depends on nothing

```lua
M.defaults = {
  prefix = "<leader>D",
  dbt_cmd = "dbt",              -- absolute path override allowed
  project_dir = nil,             -- nil = auto-detect (project.find_root)
  profiles_dir = nil,             -- nil = dbt's own default resolution
  target = nil,                    -- nil = profile's own default target
  query_limit = 500,
  lineage = { max_depth = 5 },
  picker = { preview = true },
}
M.options = vim.deepcopy(M.defaults)
M.setup(opts) -- M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
```

### `project.lua` — depends on `util`

```lua
M.find_root(start_path) -> root_dir_or_nil
  -- start_path defaults to current buffer's directory (vim.fn.expand("%:p:h")) or cwd.
  -- Walk upward until a directory containing "dbt_project.yml" is found, or filesystem root.
M.get_root(bufnr) -> root_dir_or_nil     -- memoized per-buffer-dir cache
M.parse_dbt_project_yml(root_dir) -> { name, profile, target_path } or nil
  -- dbt_project.yml has simple top-level scalar keys we need; extract with line-based
  -- Lua patterns, no full YAML parser needed: match `^name:%s*"?([%w_%-]+)"?`,
  -- `^profile:%s*"?([%w_%-]+)"?` (strip trailing "# comment"), `^target%-path:%s*"?([^"%s]+)"?`.
  -- Default target_path to "target" if the key is absent.
M.target_dir(root_dir) -> string          -- root_dir .. "/" .. (target_path or "target")
M.model_name_from_path(file_path, root_dir) -> name_or_nil
  -- basename of file_path minus ".sql", only if file_path is under root_dir/models/
  -- (or whatever model-paths resolves to — default "models" is fine for v1).
```

### `extract.lua` — PURE, no `vim.*` calls anywhere in this file. Must be testable
under bare luajit via plenary with zero editor state.

```lua
-- Verified-correct approach from research: balanced-paren matching then quote
-- extraction, operating on a whole buffer's text (not line-by-line, refs can span
-- multiple lines inside {{ }}).
M.find_refs(text) -> { {name=, pkg=nil_or_string, start_byte=, end_byte=}, ... }
  -- for inner in text:gmatch("{{%-?%s*ref%s*(%b())") do
  --   local args = {}
  --   for s in inner:gmatch("['\"]([^'\"]+)['\"]") do args[#args+1] = s end
  --   -- 1 arg: {name=args[1]}; 2 args: {pkg=args[1], name=args[2]}
  -- end
M.find_sources(text) -> { {source_name=, table_name=, start_byte=, end_byte=}, ... }
  -- same %b() approach on "source%s*%(%b()", first captured quoted string is
  -- source_name, second is table_name.
M.call_under_cursor(text, byte_offset) -> nil or { kind="ref"|"source", ... , start_byte=, end_byte=}
  -- run both find_refs/find_sources, return whichever span contains byte_offset.
M.completion_context(line_before_cursor) -> "ref_name" | "ref_pkg_name" | "source_name" | "source_table" | nil
  -- verbatim trigger regexes from research (adapt %-escaping for Lua patterns):
  --   ref_name:     line_before_cursor:match("ref%s*%(%s*['\"]?[%w_]*$")
  --   ref_pkg_name: line_before_cursor:match("ref%s*%(%s*'[^']*'%s*,%s*['\"]?[%w_]*$")  (2nd arg)
  --   source_name:  line_before_cursor:match("source%s*%(%s*['\"]?[%w_]*$")
  --   source_table: line_before_cursor:match("source%s*%(%s*'[^']*'%s*,%s*['\"]?[%w_]*$")
  -- Test against ALL these verified cases (put every one of these in extract_spec.lua):
  --   simple ref('customers'), double-quoted ref("stg_orders"), package-qualified
  --   ref('my_pkg','model_a'), multi-line "{{\n ref('multi_line')\n}}", whitespace
  --   control {{- ref('x') -}}, source('raw','jaffle_shop_customers'), two refs on one
  --   line, extra spaces ref ( 'x' ), and a comment "-- ref('not_real')" must yield
  --   NOTHING (no {{ }} braces present).
```

### `manifest.lua` — depends on `util`, `project`

```lua
-- Real fixture to test against: tests/fixtures/jaffle-shop/target/manifest.json (+ catalog.json,
-- run_results.json). Read the ACTUAL files, don't hand-write fixture JSON.
M.load(root_dir) -> manifest_or_nil       -- memoized per (root_dir, mtime of target/manifest.json)
M.load_catalog(root_dir) -> catalog_or_nil     -- same mtime-keyed cache; ABSENT node = "not built yet", not an error
M.load_run_results(root_dir) -> run_results_or_nil
M.invalidate(root_dir)
M.watch(root_dir, on_change)   -- vim.uv.new_fs_event on target/manifest.json; on_change wrapped via util.schedule

-- Graph projection filtered to resource_type in {model, seed, snapshot, source} —
-- manifest.parent_map/child_map include TEST unique_ids, which must be filtered out of
-- BOTH endpoints of every edge or every model gets phantom test children/parents.
M.graph(root_dir) -> {
  nodes = { [unique_id] = { name=, resource_type=, path=, original_file_path=,
                             package_name=, database=, schema=, materialized= } },
  parents = { [unique_id] = { unique_id, ... } },   -- never nil, empty table if none
  children = { [unique_id] = { unique_id, ... } },
}
  -- materialized defaults to "view" when config.materialized is absent, matching dbt's own default.
  -- Prefer manifest.parent_map/child_map (cheap, already transitive-safe for BFS) over
  -- node.depends_on.nodes; fall back to depends_on.nodes only if parent_map is null.

M.find_node_by_name(root_dir, name, resource_type_filter) -> unique_id_or_nil
  -- resource_type_filter optional ("model"|"source"|"seed"|nil for any).
M.find_node_by_path(root_dir, abs_or_relative_path) -> unique_id_or_nil
M.macro_lookup(root_dir, candidate) -> macro_node_or_nil
  -- candidate is either "pkg.name" or bare "name". Lookup order matters: try
  -- "<current_project_pkg>.<name>" is WRONG — actual dbt convention (verified in research):
  -- current-project macros are keyed bare in the manifest's macro unique_id
  -- ("macro.<project>.<name>"), installed-package macros as unique_id
  -- ("macro.<pkg>.<name>"). When resolving a call written as `pkg.name(...)` in SQL, try
  -- unique_id suffix "<pkg>.<name>" first, then bare "<name>" as fallback (self-prefixed
  -- calls must still resolve to the bare current-project macro).
M.sources(root_dir) -> { [source_name] = { [table_name] = unique_id } }
```

### `job.lua` — depends on `config`, `util`

```lua
M.run(argv, opts) -> handle
  -- opts: { cwd, env, on_stdout(line), on_stderr(line), on_exit(res) }
  -- wraps vim.system(argv, {text=true, cwd=opts.cwd, env=opts.env,
  --   stdout=function(err,data) if data then for line in data:gmatch("[^\n]+") do
  --     util.schedule(function() opts.on_stdout and opts.on_stdout(line) end) end end end,
  --   stderr=similar}, function(res) util.schedule(function() opts.on_exit and opts.on_exit(res) end) end)
M.run_dbt(subcmd_argv, opts) -> handle
  -- prepends config.options.dbt_cmd; appends "--project-dir" (config or project.find_root()),
  -- "--profiles-dir" (config.options.profiles_dir if set), "--target" (config.options.target if set).
  -- Does NOT add --no-version-check by default (that's a fixture-only workaround, not a
  -- general plugin behaviour) — expose it as an opt-in config flag `no_version_check = false`
  -- so users of a real (non-jaffle-shop) project aren't silently bypassing real version checks.
```

### `selector.lua` — depends on nothing

```lua
M.expand(selector_str, current_model_name) -> string
  -- Replace a bare "%" token with current_model_name. E.g. "%+" -> "customers+",
  -- "+%+" -> "+customers+", "%," -> "customers,". Use a simple global-substitute of
  -- the literal character "%" (careful: Lua string.gsub treats "%" as its own escape
  -- char, so escape it as "%%" in the pattern, or use plain string replace via
  -- table.concat(vim.split(s, "%", {plain=true}), current_model_name)).
```

### `commands.lua` — depends on `config`, `project`, `selector`, `job`, `quickfix`

```lua
M.setup()
  -- registers user commands, each nargs="?" accepting a selector string:
  --   :DbtRun [selector]     :DbtBuild [selector]   :DbtTest [selector]
  --   :DbtCompile [selector] :DbtSeed [selector]    :DbtDeps
  --   :DbtClean               :DbtParse              :DbtDocsGenerate
  -- default selector when omitted: "%" (current model). Every run/build/test finishing
  -- calls quickfix.populate_from_run_results(root_dir) and manifest.invalidate(root_dir).
M.run_model(direction)     -- direction one of "", "+", "%+"... convenience for keymaps:
                            -- "current" -> "%", "upstream" -> "+%", "downstream" -> "%+", "both" -> "+%+"
M.build_model(direction)
M.test_model()             -- always just "%", tests don't take graph operators the same way
M.compile_model(direction)
```

### `quickfix.lua` — depends on `manifest`, `util`

```lua
M.populate_from_run_results(root_dir)
  -- Read run_results.json. Failure set per dbt's OWN interpret_results logic (mirror
  -- exactly, don't invent): status in {"error","fail","runtime error","skipped","partial success"}
  -- counts as failure; "warn" does not. For each failing result, resolve its unique_id
  -- to a manifest node for original_file_path, build a qf entry:
  --   { filename = root_dir.."/"..original_file_path, lnum = 1, col = 1,
  --     text = (result.message or status), type = "E" }
  -- (bufnr-XOR-filename trick from neotest: prefer bufnr via vim.fn.bufnr(filename) if
  -- >0, else filename — never set both). Sort by (filename, lnum, col). vim.fn.setqflist(list, "r").
  -- vim.cmd("doautocmd QuickFixCmdPost") afterward — don't forget this, it's what lets
  -- other plugins react. Do NOT auto :copen; that's a user preference, leave it to them
  -- (document `vim.cmd.copen` in README as an optional autocmd users can add).
```

### `diagnostics.lua` — depends on `manifest`, `util`

```lua
-- The 4 LOCAL-only healthcheck messages from vscode-dbt-power-user, verbatim text so
-- behaviour is recognisable to anyone who's used the VSCode extension:
--   "Documentation missing for model: %s"          (node has no patch_path)
--   "Model %s does not exist in the database"       (model key absent from catalog)
--   "Column %s is undocumented in model: %s"
--   "Column %s listed in model %s is not found in the database."
M.check(root_dir) -> { {unique_id=, name=, message=, severity=vim.diagnostic.severity.HINT}, ... }
M.refresh_buffer(bufnr, root_dir)
  -- vim.diagnostic.set(ns, bufnr, diagnostics_for_this_buffers_model, {}) — resolve which
  -- model this buffer is via manifest.find_node_by_path, filter M.check() results to it.
```

### `definition.lua` — depends on `extract`, `manifest`, `project`, `util`

```lua
M.setup_buffer(bufnr)
  -- vim.bo[bufnr].tagfunc = "v:lua.require'dbt-power-user.definition'.tagfunc"
M.tagfunc(pattern, flags, info) -> tag_list
  -- Neovim tagfunc contract: return a list of {name=, filename=, cmd=} on match, {} if none.
  -- Resolve `pattern` (the word under cursor at tag-jump time) same way goto_under_cursor does.
M.goto_under_cursor()
  -- Read current buffer text + cursor byte offset, extract.call_under_cursor(...).
  -- ref -> manifest.find_node_by_name(root, name, "model") (2-arg form: filter also by package_name)
  -- source -> manifest.sources(root)[source_name][table_name]
  -- macro (bare word immediately followed by "(") -> manifest.macro_lookup
  -- On resolution: util.schedule(function() vim.cmd.edit(node.original_file_path) end)
  -- On failure: util.notify("No definition found", vim.log.levels.WARN)
```

### `hover.lua` — depends on `definition`'s resolution logic (refactor the "resolve node
under cursor" part out of `definition.lua` into a shared local function both call, or
just duplicate the ~10 lines — either is fine, don't over-engineer this)

```lua
M.show()
  -- resolve node under cursor, build a markdown string (name, resource_type, description,
  -- materialized, columns from catalog if present), vim.lsp.util.open_floating_preview(
  --   vim.split(md, "\n"), "markdown", { border = "rounded" })
```

### `compile.lua` — depends on `job`, `project`, `util`

```lua
M.preview(model_name)
  -- job.run_dbt({"compile","--select",model_name,"--output","json","--quiet","--no-use-colors"}, {
  --   on_exit = function(res)
  --     if res.code ~= 0 then return util.notify(res.stderr, ERROR) end
  --     local ok, data = util.json_decode(res.stdout)
  --     if not ok then return util.notify("could not parse dbt output", ERROR) end
  --     open_popup(data.compiled)   -- nui.popup, filetype=sql, readonly, title "Compiled SQL: "..model_name
  --   end })
  -- Popup mechanics (verified in research): buf_options={modifiable=false,readonly=true,
  -- filetype="sql"}; to fill, flip modifiable true, nvim_buf_set_lines, flip back false;
  -- map "q" and "<Esc>" (buffer-local via pop:map) to pop:unmount().
```

### `show.lua` — depends on `job`, `project`, `util`, visual-selection helper

```lua
M.preview_query(opts)
  -- opts.sql: if nil, use the whole current buffer's text (or visual selection range if
  -- opts.range is given, via ":'<,'>"-style extraction the caller already resolved).
  -- job.run_dbt({"show","--inline",opts.sql,"--output","json","--quiet","--limit",
  --   tostring(config.options.query_limit),"--no-use-colors"}, {on_exit=...})
  -- parse {"show": [ {col:val,...}, ... ]} (NOTE: numerics come back as floats from
  -- agate's to_json — format 1.0 as "1" when all values in a column are integral, don't
  -- just tostring() the float). Render as an aligned ASCII table in a scratch buffer
  -- (compute column widths from header+values, pad). Provide two buffer-local keymaps:
  -- "yc" yank the raw row data as CSV to the + register, "yj" yank as JSON.
M.preview_model(model_name) -- same but --select model_name instead of --inline
```

### `lineage.lua` — depends on `manifest`, `util`

```lua
M.ancestors(root_dir, unique_id, max_depth) -> nested tree table (own shape, own BFS —
  -- do not copy any code, this is a fresh implementation of a documented pattern, not a
  -- port): { unique_id=, name=, resource_type=, children={ ...same shape... } }
  -- (here "children" in the returned tree means "the next hop toward the root", i.e. for
  -- ancestors it walks manifest.graph(root_dir).parents; for descendants it walks .children)
M.descendants(root_dir, unique_id, max_depth) -> same shape, walks .children
M.show_tree(unique_id)
  -- nui.popup + nui.tree per the verified research snippet: NuiTree.Node({text=,path=,
  -- unique_id=}, children), get_node_id = node.unique_id (MUST be unique_id not name —
  -- name collisions across packages would throw nui's "duplicate node id"), prepare_node
  -- renders indentation + expand icon via NuiLine. Keymap vocabulary (fresh
  -- implementation of a documented pattern): <CR> open-or-toggle, o open-keep-focus,
  -- R refresh, q/<Esc> close.
M.show_picker(unique_id, direction) -- direction "ancestors"|"descendants", flattened
  -- list into Snacks.picker.pick with format showing indent-by-depth, confirm opens file.
```

### `picker.lua` — depends on `manifest`, `project`, `commands`

```lua
M.models()   -- Snacks.picker.pick{source="dbt_models", items=<all model nodes>, preview="file", confirm=open file}
M.sources()  -- same shape over source nodes (item.text = "source_name.table_name")
M.macros()   -- same shape over macro nodes
M.actions()  -- the master palette: static list of {label=, keymap_hint=, fn=} covering
             -- every command this plugin exposes, confirm calls item.fn(). This is the
             -- one command users are told to memorise (":DbtActions" / "<leader>Da").
M.run_history(root_dir) -- picker over the CURRENT run_results.json results[] (most
             -- recent invocation only for v1 — no rotating log), failures sorted first,
             -- confirm opens the failing model's file.
```

### `completion/blink.lua` — depends on `extract`, `manifest`, `project`

```lua
-- Must conform EXACTLY to the verified contract from research:
Source.new(opts, config) -> self   -- setmetatable pattern
Source:enabled() -> vim.bo.filetype == "sql"
Source:get_trigger_characters() -> { "'", '"', "(" }
Source:get_completions(ctx, callback) -> cancel_fn
  -- before = ctx.line:sub(1, ctx.cursor[2]); dispatch on extract.completion_context(before);
  -- build items from manifest.graph(root).nodes / manifest.sources(root) filtered by kind;
  -- ALWAYS call callback(...) at least once even when items is empty (blink requirement);
  -- return function() end as the cancel fn (no long-running lookup to cancel in v1).
```
Register in the user's own LazyVim spec (document in README, this repo does NOT modify
the user's own `~/.config/nvim` — see keymaps.lua note below for the same rule applied
to which-key):
```lua
{ "saghen/blink.cmp", opts = { sources = { providers = {
    dbt = { name = "dbt", module = "dbt-power-user.completion.blink" } },
    per_filetype = { sql = { inherit_defaults = true, "dbt" } } } } }
```

### `statusline.lua` — depends on `project`, `config`

```lua
M.status() -> string   -- "<project_name> 󰆼 <target>" or "" if no project detected
                         -- (lualine component usage documented in README, not wired
                         -- automatically into the user's own lualine.lua — see note below)
```

### `health.lua` — depends on `project`, `manifest`, `config`

```lua
-- require("dbt-power-user.health").check() is dispatched by :checkhealth dbt-power-user
-- via the standard convention: this module IS the vim.health checker (Neovim looks for
-- lua/dbt-power-user/health.lua's `check()` — or a health.lua at the plugin root; using
-- the in-namespace one keeps everything under lua/dbt-power-user/).
M.check()
  -- vim.health.start("dbt-power-user")
  -- dbt binary on PATH or config.options.dbt_cmd resolvable -> vim.health.ok/error
  -- project.find_root() succeeds from cwd -> ok/warn ("no dbt project found under cwd")
  -- manifest.load(root) succeeds and target/manifest.json exists -> ok, else warn
  --   ("run `dbt parse` to generate a manifest")
  -- profiles resolvable (best-effort: just check profiles_dir or ~/.dbt/profiles.yml exists)
  -- prefix collision check: vim.fn.maparg(config.options.prefix, "n") ~= "" -> warn
```

### `docs.lua` — depends on `job`, `manifest`, `util`

```lua
M.generate() -- job.run_dbt({"docs","generate"}, {on_exit = notify success/failure})
M.open()     -- vim.ui.open(project.target_dir(root).."/index.html") -- opens in real browser
M.generate_yaml_scaffold(model_name)
  -- read catalog.json columns for the model's unique_id, build a schema.yml-shaped
  -- `models: - name: <model> columns: - name: <col>` block, open in a scratch buffer for
  -- the user to review/merge (do NOT auto-write into their real schema.yml — merging
  -- YAML safely is out of scope for v1, scratch-buffer-then-manual-paste is the honest
  -- version of this feature).
```

### `create_model.lua` — depends on `manifest`, `util`

```lua
M.from_source(source_name, table_name)
  -- scaffold `select * from {{ source('source_name', 'table_name') }}` into a new buffer
  -- named "stg_<table_name>.sql" (or `base_` prefix per config, mirroring the VSCode
  -- setting names dbt.prefixGenerateModel/dbt.fileNameTemplateGenerateModel as config
  -- fields on config.lua: `create_model = { prefix = "stg", template = "{prefix}_{table}" }`),
  -- does NOT write to disk automatically — opens as an unsaved buffer for the user to
  -- place and save themselves (respect the user's directory structure, don't guess it).
```

### `defer.lua` — depends on `config`

```lua
M.enabled = false
M.toggle() -- flips M.enabled, util.notify current state
M.extra_args() -> {} or {"--defer","--state",config.options.defer_state_path}
  -- commands.lua must call this and append its result to every run/build/compile argv.
```

### `keymaps.lua` — depends on everything above; wires the leader-key surface

```lua
M.setup(prefix)
  -- require("which-key").add({ { prefix, group = "dbt", icon = {...} }, ... }) then every
  -- leaf mapping calling into the modules above. Full table below under "Keymap table".
  -- IMPORTANT: which-key.add must be called defensively — pcall it, since a user who
  -- doesn't have which-key installed should still get working keymaps (just no group
  -- label). Plain vim.keymap.set calls happen regardless of which-key's presence.
```

### `init.lua` — top-level `setup(opts)`

```lua
M.setup(opts)
  -- config.setup(opts)
  -- commands.setup()
  -- keymaps.setup(config.options.prefix)
  -- autocmd FileType {"sql","yaml"} -> if project.find_root() then definition.setup_buffer(bufnr);
  --   diagnostics.refresh_buffer(bufnr, root) end
  -- manifest.watch(root, function() diagnostics refresh + notify "manifest updated" end)
  --   (only start the watcher once per root_dir, guard against duplicate watches)
```

### `plugin/dbt-power-user.lua`

Thin bootstrap so the plugin also works for non-lazy.nvim users / bare `require`:
just enough to make `:checkhealth dbt-power-user` work without calling `setup()` first
(health.lua has no hard dependency on config having been set up — it should read
`config.options` which already has defaults even before `setup()` runs). Do NOT call
`M.setup()` automatically here — that's the user's job via their lazy.nvim spec `opts`.

## Keymap table (all under `config.options.prefix`, default `<leader>D`)

| Keys | Action |
|---|---|
| `Dr` | Run current model (`%`) |
| `DR` | Run downstream (`%+`) |
| `Du` | Run upstream (`+%`) |
| `Db` | Build current model |
| `Dt` | Test current model |
| `Dc` | Compile / preview current model (nui popup) |
| `Dp` | Preview query — normal mode: whole buffer; visual mode: selection |
| `Dl` | Lineage tree (nui.tree) for current model |
| `DL` | Lineage picker (snacks) for current model |
| `Dg` | Go to definition under cursor (also bound as buffer-local `gd` in dbt buffers) |
| `Dk` | Hover under cursor (also bound as buffer-local `K` in dbt buffers) |
| `Dm` | Models picker |
| `Ds` | Sources picker |
| `DM` | Macros picker |
| `Da` | Actions palette (`:DbtActions`) |
| `Dh` | Run history / latest run_results picker |
| `DD` | Defer-to-prod toggle |
| `Do` | Open dbt docs in browser |
| `DG` | `dbt docs generate` |

`gd`/`K` are set buffer-locally (not globally) inside `FileType sql` autocmd, only when
a dbt project root is detected — never override `gd`/`K` outside dbt buffers.

## Explicitly out of scope for v1 (document this in README, don't silently omit)

Column-level lineage (sqlglot), the Altimate AI suite (explain/optimise/review/etc,
all cloud-gated), SQL validation (cloud-gated), docs collaboration/comments,
Altimate notebooks, the Perspective pivot/filter/group grid (offer CSV/JSON yank
instead), embedded docs browser (opens real browser instead), CTE profiler, BigQuery
cost estimator, SQL formatting (document 3-line conform.nvim config instead — do not
reimplement, conform.nvim already does this better).

## Build order

1. `util.lua`, `config.lua`, `extract.lua` (+ full spec) — no cross-deps, build in parallel.
2. `project.lua` (+ spec) — depends only on util.
3. `manifest.lua` (+ spec, test against the REAL jaffle-shop manifest.json/catalog.json
   already on disk) — depends on util + project.
4. Parallel: {job, selector, commands, quickfix} | {definition, hover, completion/blink}
   | {compile, show, lineage, picker} | {diagnostics, statusline, health, docs,
   create_model, defer}.
5. `keymaps.lua`, `init.lua`, `plugin/dbt-power-user.lua` — integration, done last,
   after everything above exists and its real function signatures are known.
6. README.md, LICENSE (MIT).
7. End-to-end headless verification against the real jaffle-shop fixture; fix bugs found.
