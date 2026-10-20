--!strict
-- AI Limits, host half: polls `omp usage --json` every five minutes, keeps the
-- normalized snapshot in `tern.kv` (the window half reads it there), and
-- draws the side panel (`cards`), the "Limites" tab (`dashboard`) and the
-- `omp usage` lens.
--
-- Block keys: r refreshes now (asks omp to drop its cache first), e shows or
-- hides account e-mails.

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end

local model = require("./model")
local prefs = require("./prefs")
local history = require("./history")
local view = require("./view")
local ui = tern.ui

-- kv `poll_minutes` (1 to 30, default 5).
local function poll_ms(): number
	local m = tonumber(tern.kv.get("poll_minutes"))
	return (if m and m >= 1 and m <= 30 then m else 5) * 60 * 1000
end
local TICK_MS = 5000
-- The cards' "resets in" texts move once a minute.
local RENDER_EVERY_MS = 60 * 1000
local OMP_TIMEOUT_MS = 90 * 1000

type Open = { cx: BlockCx, since: number }

-- `raw` is the last omp report as normalized; `snapshot` is it after the
-- user's filters and order, which is what every view and the window half see.
-- The window half lists `snapshot_all` in its filter pickers, so hidden
-- providers and accounts can be shown again.
local raw: model.Snapshot? = tern.kv.get("snapshot_all")
local snapshot: model.Snapshot? = tern.kv.get("snapshot")
if snapshot then
	tern.kv.set("snapshot_at", snapshot.at)
end
local prefs_seen = tern.kv.get("prefs_at")
local loading = false
local problem: string? = nil
local last_fetch = -math.huge -- tern.now() of the last fetch start
local last_render = 0
local handled_request = tern.kv.get("refresh_request") or 0
local blocks: { [number]: Open } = {}

-- Where omp lives: a daemon started at login may lack the shell's PATH, and
-- Tern ships its own copy under %LOCALAPPDATA%\Tern\omp.
local function omp_candidates(): { string }
	local list: { string } = {}
	local localappdata = tern.getenv("LOCALAPPDATA")
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	if localappdata then
		table.insert(list, localappdata .. "\\Tern\\omp\\bin\\omp.exe")
	end
	if home then
		table.insert(list, home .. "/.local/bin/omp")
		table.insert(list, home .. "/.bun/bin/omp")
	end
	table.insert(list, "/opt/homebrew/bin/omp")
	table.insert(list, "/usr/local/bin/omp")
	local found: { string } = {}
	for _, path in list do
		if tern.fs.exists(path) then
			table.insert(found, path)
		end
	end
	table.insert(found, "omp")
	return found
end

local function redacting(): boolean
	return tern.kv.get("redact") == true
end

local function live_panes(): { [number]: boolean }
	local live: { [number]: boolean } = {}
	for _, info in tern.pane.list() do
		live[info.pane] = true
	end
	return live
end

-- A block registers in `init`, which can run before the daemon lists its
-- pane, so young entries are kept.
local function prune()
	local live = live_panes()
	local now = tern.now()
	for pane, open in blocks do
		if not live[pane] and now - open.since > 2000 then
			blocks[pane] = nil
		end
	end
end

-- The window half closes blocks of ours missing from this list: a block that
-- restarted while the host half was reloading exits and never runs `init`.
-- nil until the first publish, so a host that came back with no blocks still
-- clears the ids the last one left in kv.
local published: string? = nil
local function publish()
	local ids: { number } = {}
	for pane in blocks do
		table.insert(ids, pane)
	end
	table.sort(ids)
	local text = table.concat(ids, ",")
	if text ~= published then
		published = text
		tern.kv.set("live", tern.json.array(ids))
	end
end

local function render_all()
	prune()
	publish()
	last_render = tern.now()
	for _, open in blocks do
		open.cx:render()
	end
end

local function first_lines(text: string, n: number): string
	local out = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		table.insert(out, line)
		if #out == n then
			break
		end
	end
	return table.concat(out, "\n")
end

-- omp prints only the document on stdout; tolerate a banner before it.
local function decode(stdout: string): any
	local ok, doc = pcall(tern.json.decode, stdout)
	if ok and type(doc) == "table" then
		return doc
	end
	local start = string.find(stdout, "{", 1, true)
	if start then
		ok, doc = pcall(tern.json.decode, string.sub(stdout, start))
		if ok and type(doc) == "table" then
			return doc
		end
	end
	return nil
end

local raw_changed = false

-- Publishes `raw` through the current filters.
local function apply_prefs()
	if raw == nil then
		return
	end
	local filtered = prefs.apply(raw :: model.Snapshot, prefs.read())
	snapshot = filtered
	-- Every kv.set rewrites the whole store: a filter change leaves raw alone.
	if raw_changed then
		raw_changed = false
		tern.kv.set("snapshot_all", raw)
	end
	tern.kv.set("snapshot", filtered)
	-- A revision, not the report's time: a filter change keeps `at` and must
	-- still reach the window's status line and title.
	tern.kv.set("snapshot_at", tern.now())
end

-- Providers omp does not report (Cursor, Grok) come from the plugin's own
-- PowerShell helpers, which print omp-shaped documents; their reports join
-- omp's before normalizing. A helper that fails keeps its last document.
-- Claude and Codex read the CLIs' own logins, for accounts omp does not have,
-- and keys-usage.ps1 the API keys saved in the plugin (Factory, OpenCode Go,
-- Command Code); their windows move fast, so they follow the poll. Cursor and
-- Grok poll at most every 15 minutes.
local HELPERS = { "claude-usage.ps1", "codex-usage.ps1", "cursor-usage.ps1", "grok-usage.ps1", "keys-usage.ps1" }
local SLOW_HELPERS: { [string]: boolean } = { ["cursor-usage.ps1"] = true, ["grok-usage.ps1"] = true }
local HELPER_TIMEOUT_MS = 45 * 1000
-- Each helper starts a PowerShell; their numbers move slowly, so poll them
-- less often than omp (a manual refresh still runs them).
local HELPER_MIN_MS = 15 * 60 * 1000
local helpers_at: { [string]: number } = {}
local omp_doc: any = nil
local helper_docs: { [string]: any } = {}

local function entries(value: any): { any }
	if type(value) ~= "table" then
		return {}
	end
	return if value.provider ~= nil then { value } else value
end

-- Normalizes omp's last document plus the helpers'; false when that fails.
local function rebuild(): boolean
	if omp_doc == nil then
		return false
	end
	-- Decoded JSON tables are read-only: copy into fresh lists.
	local reports: { any } = {}
	local disabled: { any } = {}
	local function add(doc: any)
		for _, r in entries(doc.reports) do
			table.insert(reports, r)
		end
		for _, d in entries(doc.disabledCredentials) do
			table.insert(disabled, d)
		end
	end
	add(omp_doc)
	for _, name in HELPERS do
		if helper_docs[name] then
			add(helper_docs[name])
		end
	end
	local merged = {
		reports = reports,
		disabledCredentials = disabled,
		accountsWithoutUsage = omp_doc.accountsWithoutUsage,
		generatedAt = omp_doc.generatedAt,
	}
	local ok, snap = pcall(model.from_omp, merged)
	if not ok then
		problem = t("could not read the report: ", "falha ao ler o relatório: ") .. tostring(snap)
		return false
	end
	local now = os.time() * 1000
	history.record(snap, now)
	history.annotate(snap, now)
	raw = snap
	raw_changed = true
	problem = nil
	apply_prefs()
	return true
end

-- omp and both helpers finish within moments of each other: normalize and
-- write kv once for the lot.
local rebuild_due = false
local function schedule_rebuild()
	if rebuild_due then
		return
	end
	rebuild_due = true
	tern.timer(300, function()
		rebuild_due = false
		if rebuild() then
			render_all()
		end
	end)
end

local function run_helpers(force: boolean)
	if tern.runtime.os ~= "windows" then
		return
	end
	for _, name in HELPERS do
		local every = if SLOW_HELPERS[name] then math.max(HELPER_MIN_MS, poll_ms()) else 0
		if not force and tern.now() - (helpers_at[name] or -math.huge) < every then
			continue
		end
		helpers_at[name] = tern.now()
		local argv = {
			"powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-File", tern.plugin.dir .. "\\" .. name,
		}
		local ok, err = pcall(function()
			local env = { AI_LIMITS_LANG = if PT then "pt" else "en" }
			tern.process.run(argv, { timeout_ms = HELPER_TIMEOUT_MS, env = env }, function(result, _)
				local doc = if result.status == 0 and not result.timed_out then decode(result.stdout) else nil
				if doc == nil then
					return
				end
				helper_docs[name] = doc
				schedule_rebuild()
			end)
		end)
		if not ok then
			tern.log.warn("ai-limits: helper did not start", name, err)
		end
	end
end

-- Stands in for omp's report when omp is off, missing or failing, so the
-- helpers' providers still show.
local EMPTY_DOC = { reports = {}, disabledCredentials = {} }

-- kv `use_omp`: false reads only the plugin's own helpers.
local function use_omp(): boolean
	return tern.kv.get("use_omp") ~= false
end

local function finish(result: ProcessResult)
	loading = false
	if result.timed_out then
		problem = t("omp usage did not answer in 90 s", "omp usage não respondeu em 90 s")
	elseif result.status ~= 0 then
		local err = first_lines(result.stderr, 2)
		problem = t("omp usage exited with ", "omp usage saiu com ") .. result.status .. (if err ~= "" then ": " .. err else "")
	else
		local doc = decode(result.stdout)
		if doc == nil or doc.reports == nil then
			problem = t("omp usage returned no JSON", "omp usage não devolveu JSON")
		else
			omp_doc = doc
		end
	end
	omp_doc = omp_doc or EMPTY_DOC
	rebuild()
	render_all()
end

-- Runs `omp <args>`, trying each install location until one spawns.
local function run_omp(args: { string }, done: (ProcessResult) -> ()): string?
	local last = t("omp is not on PATH", "omp não está no PATH")
	for _, omp in omp_candidates() do
		local argv: { string } = { omp }
		for _, a in args do
			table.insert(argv, a)
		end
		local ok, err = pcall(function()
			tern.process.run(argv, { timeout_ms = OMP_TIMEOUT_MS, env = { NO_COLOR = "1" } }, function(result, _)
				done(result)
			end)
		end)
		if ok then
			return nil
		end
		last = tostring(err)
	end
	return last
end

local function fetch(force: boolean)
	if loading then
		return
	end
	loading = true
	last_fetch = tern.now()
	render_all()
	run_helpers(force)
	if not use_omp() then
		loading = false
		problem = nil
		omp_doc = EMPTY_DOC
		schedule_rebuild()
		return
	end
	local function usage()
		local spawn_error = run_omp({ "usage", "--json" }, finish)
		if spawn_error then
			-- No omp on this machine: the helpers alone are the source.
			loading = false
			problem = nil
			omp_doc = EMPTY_DOC
			schedule_rebuild()
		end
	end
	if force then
		-- `invalidate` drops omp's cached reports so the next read is live.
		local spawn_error = run_omp({ "usage", "invalidate" }, function(_)
			usage()
		end)
		if spawn_error then
			usage()
		end
	else
		usage()
	end
end

-- The window half sizes the side column from these reports: the panel's
-- width and the measurement request (kv `width_req`) it answers.
local panel_cols: number? = nil
local answered_req: any = nil
-- A block made while its window is covered starts at the pty default 80×24
-- and keeps it until the window lays it out again; reporting that would
-- size the column from a width it never had.
local sized = false

local reported: string? = nil

local function report_size()
	if panel_cols == nil or not sized then
		return
	end
	answered_req = tern.kv.get("width_req")
	-- Every kv.set rewrites the whole store; a height-only resize changes nothing here.
	local key = tostring(panel_cols) .. ":" .. tostring(answered_req)
	if key == reported then
		return
	end
	reported = key
	tern.kv.set("panel_size", { cols = panel_cols, seq = answered_req or 0 })
end

-- A window half whose entry ran past its 50 ms budget (a cold start on a busy
-- machine) stays unloaded until the next reload, while this half keeps
-- drawing the column. The window half bumps `window_beat`; when a window lays
-- out our block and the beat stays still, ask for a reload, a few times at most.
local WINDOW_GRACE_MS = 25 * 1000
local MAX_RELOADS = 3
local beat_seen = tern.kv.get("window_beat")
local beat_changed_at = tern.now()
local reload_asked = false

local function watch_window()
	local beat = tern.kv.get("window_beat")
	if beat ~= beat_seen then
		beat_seen = beat
		beat_changed_at = tern.now()
		if tern.kv.get("window_reloads") ~= nil then
			tern.kv.set("window_reloads", nil)
		end
		return
	end
	if reload_asked or not sized or tern.now() - beat_changed_at < WINDOW_GRACE_MS then
		return
	end
	reload_asked = true
	local tries = tern.kv.get("window_reloads")
	tries = if type(tries) == "number" then tries else 0
	if tries >= MAX_RELOADS then
		return
	end
	tern.kv.set("window_reloads", tries + 1)
	pcall(function()
		tern.process.run({ "tern", "plugin", "reload" }, { timeout_ms = 30 * 1000 }, function(_result, _)
		end)
	end)
end

-- One loop for the whole host: polls on schedule, answers refresh requests-- the window half writes to kv, and moves the countdowns once a minute.
local mode_seen = tern.kv.get("mode")

local function tick()
	watch_window()
	local m = tern.kv.get("mode")
	if m ~= mode_seen then
		-- A resting floating card draws a different layout from the column.
		mode_seen = m
		render_all()
	end
	if tern.kv.get("width_req") ~= answered_req then
		report_size()
	end
	local prefs_at = tern.kv.get("prefs_at")
	if prefs_at ~= prefs_seen then
		prefs_seen = prefs_at
		apply_prefs()
		render_all()
	end
	local request = tern.kv.get("refresh_request")
	if type(request) == "number" and request > handled_request then
		handled_request = request
		fetch(true)
	elseif tern.now() - last_fetch >= poll_ms() then
		fetch(false)
	elseif next(blocks) ~= nil and tern.now() - last_render >= RENDER_EVERY_MS then
		render_all()
	end
	tern.timer(TICK_MS, tick)
end

-- Blocks.

-- Accounts the user put in front, per provider (kv `featured`).
local function featured(): { [string]: string }
	local out: { [string]: string } = {}
	local v = tern.kv.get("featured")
	if type(v) == "table" then
		for id, key in v do
			if type(id) == "string" and type(key) == "string" then
				out[id] = key
			end
		end
	end
	return out
end

local function set_featured(provider: string, key: string?)
	local map: { [string]: string? } = featured()
	map[provider] = key
	tern.kv.set("featured", if next(map) then map else nil)
	render_all()
end

-- The ↑/↓ buttons on a card: the same `provider_order` the order picker saves.
local function move_provider(id: string, delta: number)
	if snapshot == nil then
		return
	end
	local shown: { string } = {}
	for _, p in (snapshot :: model.Snapshot).providers do
		table.insert(shown, p.id)
	end
	local order = prefs.move(prefs.read().order, shown, id, delta)
	if order == nil then
		return
	end
	tern.kv.set("provider_order", tern.json.array(order))
	-- Marked seen so the tick does not filter a second time.
	prefs_seen = tern.now()
	tern.kv.set("prefs_at", prefs_seen)
	apply_prefs()
	render_all()
end

local function opts_for(layout: view.Layout): view.Opts
	local p = prefs.read()
	local empty: string? = nil
	if prefs.filtering(p) then
		empty = t("Everything is hidden by the filters. Adjust them in \"AI Limits: settings…\" (key c).", "Tudo oculto pelos filtros. Ajuste em \"Limites de IA: configurar…\" (tecla c).")
	end
	return {
		layout = layout,
		now_ms = os.time() * 1000,
		redact = redacting(),
		loading = loading,
		problem = problem,
		density = p.density,
		empty = empty,
		featured = featured(),
		stale_ms = 2 * poll_ms() + OMP_TIMEOUT_MS,
	}
end

local function toggle_redact()
	tern.kv.set("redact", not redacting())
	render_all()
end

local function on_key(key: Key): boolean?
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local k = key.text or key.name
	if k == "r" then
		fetch(true)
	elseif k == "e" then
		toggle_redact()
	elseif k == "c" then
		tern.kv.set("config_request", tern.now())
	else
		return false
	end
	return true
end

local function on_event(ev: UiEvent)
	if ev.ev ~= "action" then
		return
	end
	if ev.act == "refresh" then
		fetch(true)
	elseif ev.act == "redact" then
		toggle_redact()
	elseif ev.act == "configure" then
		tern.kv.set("config_request", tern.now())
	elseif type(ev.act) == "string" then
		local provider, key = string.match(ev.act, "^feature:([^|]+)|(.+)$")
		if provider then
			set_featured(provider, key)
			return
		end
		local cleared = string.match(ev.act, "^unfeature:(.+)$")
		if cleared then
			set_featured(cleared, nil)
			return
		end
		local moved, delta = string.match(ev.act, "^move:([^|]+)|(-?%d)$")
		if moved then
			move_provider(moved, tonumber(delta) :: number)
		end
	end
end

local function note_size(cols: number, rows: number, laid_out: boolean)
	if laid_out or cols ~= 80 or rows ~= 24 then
		sized = true
	end
	if cols ~= panel_cols then
		panel_cols = cols
		report_size()
	elseif laid_out then
		report_size()
	end
end

-- A floating card at rest shows what kv `pip_show` picks: the summary rows
-- (nil) or one provider's card. Focused, Tern grows it past this height, and
-- it shows every provider: the wheel does not reach a floating plugin block,
-- so the resting card has to fit.
local PIP_FULL_ROWS = 18
local NARROW_COLS = 30

local function cards_opts(cx: BlockCx): view.Opts
	note_size(cx.cols, cx.rows, false)
	local opts = opts_for("panel")
	-- Rings need room for their labels; a narrow column reads better as lines.
	if opts.density == "auto" and cx.cols < NARROW_COLS then
		opts.density = "lines"
	end
	if tern.kv.get("mode") ~= "pip" or cx.rows >= PIP_FULL_ROWS then
		return opts
	end
	opts.glance = true
	local pick = tern.kv.get("pip_show")
	if type(pick) == "string" and snapshot then
		for _, p in (snapshot :: model.Snapshot).providers do
			if p.id == pick then
				opts.only = pick
				return opts
			end
		end
	end
	opts.layout = "summary"
	return opts
end


tern.block.define("cards", {
	init = function(cx: BlockCx, _args: { string }, _saved: any): any
		blocks[cx.pane] = { cx = cx, since = tern.now() }
		publish()
		return { pane = cx.pane }
	end,
	title = function(_state: any): string?
		return t("AI Limits", "Limites de IA")
	end,
	view = function(_state: any, cx: BlockCx): BlockView
		return view.block(snapshot, cards_opts(cx))
	end,
	resize = function(_state: any, cols: number, rows: number, _cx: BlockCx)
		note_size(cols, rows, true)
	end,
	key = function(_state: any, key: Key, _cx: BlockCx): boolean?
		return on_key(key)
	end,
	event = function(_state: any, ev: UiEvent, _cx: BlockCx)
		on_event(ev)
	end,
})

tern.block.define("dashboard", {
	init = function(cx: BlockCx, _args: { string }, _saved: any): any
		blocks[cx.pane] = { cx = cx, since = tern.now() }
		publish()
		return { pane = cx.pane }
	end,
	title = function(_state: any): string?
		return t("Limits", "Limites")
	end,
	view = function(_state: any, _cx: BlockCx): BlockView
		return view.block(snapshot, opts_for("dashboard"))
	end,
	key = function(_state: any, key: Key, _cx: BlockCx): boolean?
		return on_key(key)
	end,
	event = function(_state: any, ev: UiEvent, _cx: BlockCx)
		on_event(ev)
	end,
})

-- Lens: `omp usage` drawn as cards. With --json the cards come from this
-- run's output; the plain table is omp's own text, so the cards show the
-- plugin's snapshot (Raw still shows what omp printed). Subcommands and
-- --history keep their raw output.

type LensState = {
	json: boolean,
	skip: boolean,
	only: string?,
	lines: { string },
	status: number?,
}

local SUBCOMMANDS: { [string]: boolean } = {
	invalidate = true,
	clients = true,
	accounts = true,
	reset = true,
}

local function lens_args(args: { string }): LensState
	local state: LensState = { json = false, skip = false, only = nil, lines = {}, status = nil }
	local i = 2 -- args[1] is "usage"
	while i <= #args do
		local a = args[i]
		if a == "--json" or a == "-j" then
			state.json = true
		elseif a == "--provider" or a == "-p" then
			state.only = args[i + 1]
			i += 1
		elseif string.sub(a, 1, 11) == "--provider=" then
			state.only = string.sub(a, 12)
		elseif a == "--history" or a == "--days" or a == "-d" or SUBCOMMANDS[a] then
			state.skip = true
		end
		i += 1
	end
	return state
end

tern.lens.define("usage", {
	open = function(run: LensRun, _cx: EffectCx): LensState
		local state = lens_args(run.args)
		if not state.skip and not state.json then
			-- The user's run refreshes omp's cache; pick it up for the cards.
			fetch(false)
		end
		return state
	end,
	line = function(state: LensState, l: LensLine)
		if state.json and not state.skip then
			table.insert(state.lines, l.text)
		end
	end,
	finish = function(state: LensState, status: number)
		state.status = status
	end,
	view = function(state: LensState): Node?
		if state.skip or state.status == nil or state.status ~= 0 then
			return nil
		end
		local opts = opts_for("lens")
		opts.loading = false
		opts.problem = nil
		opts.only = state.only
		local snap: model.Snapshot? = snapshot
		if state.json then
			local doc = decode(table.concat(state.lines, "\n"))
			if doc == nil or doc.reports == nil then
				return nil
			end
			local ok, parsed = pcall(model.from_omp, doc)
			if not ok then
				return nil
			end
			snap = prefs.apply(parsed, prefs.read())
		else
			if snap == nil then
				return nil
			end
			opts.note = t("Cards from the plugin's snapshot (", "Cartões do snapshot do plugin (")
				.. os.date("%H:%M", (snap :: model.Snapshot).at // 1000)
				.. t("). Raw shows omp's output.", "). Raw mostra a saída do omp.")
		end
		return ui.col({ view.body(snap, opts) })
	end,
	event = function(_state: LensState, ev: UiEvent, _cx: EffectCx)
		on_event(ev)
	end,
})

tick()
