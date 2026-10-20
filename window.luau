--!strict
-- AI Limits, window half. The side panel (block `cards`) shows in one of four
-- modes: a fixed column at the edge of the active tab ("column"), the same
-- column opened and closed by a key ("drawer"), a floating card ("pip"), or
-- not at all ("off"). It follows you across tabs. This half also opens the
-- "Limites" tab, the palette peek, the status line and window title
-- summaries, and toasts when limits cross thresholds. The host half writes the
-- snapshot to `tern.kv`; this half only reads it.
--
-- The entry runs under a 50 ms budget, and Tern compiles every chunk to native
-- code first: the whole half in one file went past that at cold starts and
-- even on plain reloads. So this file only registers commands, chrome and
-- events. win_place and win_core (placement), win_alerts (peek, status line,
-- title) and win_toasts (threshold toasts) load from separate timer calls,
-- each with its own budget; win_settings and win_filters (the pickers) load
-- in the first command that needs them. Measured on an idle machine, each of
-- the old two modules took 10-20 ms to compile, and a busy one (Tern
-- reloading every plugin, git timing out) pushed that past 50 ms.

-- Focus, pane and tab events place the panel at once; the loop only catches
-- what no event reports (a parked panel dealt back, a host reload).
local LOOP_MS = 5000

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end
local BEAT_MS = 10 * 1000

local core: any = nil
local alerts: any = nil
local settings: any = nil

local function need_core(): any
	if core == nil then
		core = require("./win_core")
	end
	return core
end

local function need_alerts(): any
	if alerts == nil then
		alerts = require("./win_alerts")
	end
	return alerts
end

-- The pickers load on first use, in the hook that needs them.
local function need_settings(): any
	if settings == nil then
		settings = require("./win_settings")
	end
	return settings
end

local function in_filters(name: string): (WindowCx) -> ()
	return function(cx: WindowCx)
		(require("./win_filters") :: any)[name](cx)
	end
end

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	return if alerts then alerts.status() else nil
end)

tern.chrome.window_title(function(win: WindowInfo): string?
	return if alerts then alerts.title(win) else nil
end)

-- Commands.

type Command = { id: string, title: string, icon: string, run: (WindowCx) -> () }

local function in_core(name: string): (WindowCx) -> ()
	return function(cx: WindowCx)
		need_core()[name](cx)
	end
end

local function in_settings(name: string): (WindowCx) -> ()
	return function(cx: WindowCx)
		need_settings()[name](cx)
	end
end

local COMMANDS: { Command } = {
	{ id = "toggle", title = t("AI Limits: show/hide panel", "Limites de IA: mostrar/ocultar painel"), icon = "sidebar", run = in_core("toggle") },
	{
		id = "show",
		title = t("AI Limits: show panel", "Limites de IA: mostrar painel"),
		icon = "sidebar",
		run = function(cx: WindowCx)
			local c = need_core()
			c.show(cx, c.mode() == "drawer")
		end,
	},
	{ id = "hide", title = t("AI Limits: hide panel", "Limites de IA: ocultar painel"), icon = "eye-off", run = in_core("hide") },
	{ id = "dashboard", title = t("AI Limits: open the Limits tab", "Limites de IA: abrir aba Limites"), icon = "gauge", run = in_core("open_dashboard") },
	{
		id = "peek",
		title = t("AI Limits: peek", "Limites de IA: espiar"),
		icon = "eye",
		run = function(cx: WindowCx)
			need_alerts().peek(cx, need_core().open_dashboard)
		end,
	},
	{ id = "configure", title = t("AI Limits: settings…", "Limites de IA: configurar…"), icon = "sliders", run = in_settings("configure") },
	{ id = "refresh", title = t("AI Limits: refresh now", "Limites de IA: atualizar agora"), icon = "redo", run = in_settings("refresh") },
	{ id = "mode", title = t("AI Limits: panel mode", "Limites de IA: modo do painel"), icon = "sidebar", run = in_settings("mode") },
	{ id = "side", title = t("AI Limits: column side", "Limites de IA: lado da coluna"), icon = "columns", run = in_settings("side") },
	{ id = "width", title = t("AI Limits: column width", "Limites de IA: largura da coluna"), icon = "columns", run = in_settings("width") },
	{ id = "corner", title = t("AI Limits: floating card corner", "Limites de IA: canto do cartão flutuante"), icon = "pip", run = in_settings("corner") },
	{
		id = "pip_show",
		title = t("AI Limits: floating card content", "Limites de IA: conteúdo do cartão flutuante"),
		icon = "pip",
		run = in_settings("pip_show"),
	},
	{ id = "providers", title = t("AI Limits: choose providers", "Limites de IA: escolher providers"), icon = "eye", run = in_filters("providers") },
	{
		id = "windows",
		title = t("AI Limits: choose windows (5h, weekly, monthly…)", "Limites de IA: escolher janelas (5h, semanal, mensal…)"),
		icon = "clock",
		run = in_filters("windows"),
	},
	{ id = "accounts", title = t("AI Limits: choose accounts", "Limites de IA: escolher contas"), icon = "user", run = in_filters("accounts") },
	{ id = "order", title = t("AI Limits: provider order", "Limites de IA: ordem dos providers"), icon = "list", run = in_filters("order") },
	{ id = "density", title = t("AI Limits: card density", "Limites de IA: densidade dos cartões"), icon = "grid", run = in_filters("density") },
	{ id = "status", title = t("AI Limits: status bar", "Limites de IA: barra de status"), icon = "activity", run = in_settings("status") },
	{ id = "poll", title = t("AI Limits: refresh interval", "Limites de IA: frequência de atualização"), icon = "clock", run = in_settings("poll") },
	{ id = "sources", title = t("AI Limits: where limits come from", "Limites de IA: de onde vêm os limites"), icon = "plug", run = in_settings("sources") },
	{ id = "keys", title = t("AI Limits: API keys", "Limites de IA: chaves de API"), icon = "key", run = in_settings("keys") },
	{ id = "alerts", title = t("AI Limits: limit alerts", "Limites de IA: avisos de limite"), icon = "bell", run = in_settings("alerts") },
	{ id = "lang", title = t("AI Limits: language", "Limites de IA: idioma"), icon = "globe", run = in_settings("lang") },
}

for _, c in COMMANDS do
	tern.command({ id = c.id, title = c.title, icon = c.icon, group = t("AI Limits", "Limites de IA"), run = c.run })
end

local ctrl = if tern.runtime.os == "macos" then "cmd" else "ctrl"
tern.bind(ctrl .. "+alt+shift+u", "plugin.ai-limits.toggle")
tern.bind(ctrl .. "+alt+shift+i", "plugin.ai-limits.dashboard")
tern.bind(ctrl .. "+alt+shift+y", "plugin.ai-limits.peek")

-- Events.

tern.on("window_start", function(cx: WindowCx)
	if core then
		core.safe_ensure(cx)
	end
end)

tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	if core then
		core.safe_ensure(cx)
	end
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if core then
		core.pane_closed(ev, cx)
	end
end)

for _, name in { "pane_created", "tab_created", "tab_closed" } do
	tern.on(name, function(_ev: any, cx: WindowCx)
		if core then
			core.safe_ensure(cx)
		end
	end)
end

-- The panel's sliders button (a host block) can only write kv.
local config_seen = tern.kv.get("config_request")
local function watch_config(cx: WindowCx?)
	local req = tern.kv.get("config_request")
	if req ~= config_seen then
		config_seen = req
		if cx then
			need_settings().configure(cx :: WindowCx)
		end
	end
	tern.timer(300, watch_config)
end

local beat_at = -math.huge

local function loop(cx: WindowCx?)
	local now = tern.now()
	if now - beat_at >= BEAT_MS then
		-- The host half reloads the plugin when this stops moving.
		beat_at = now
		local beat = tern.kv.get("window_beat")
		tern.kv.set("window_beat", (if type(beat) == "number" then beat else 0) + 1)
	end
	alerts.reload_summary()
	if cx then
		-- Placement reads kv and walks the layout: its own budget, apart from
		-- the beat and the summary check above.
		tern.timer(0, function(later: WindowCx?)
			if later then
				core.tick(later :: WindowCx)
			end
		end)
	end
	tern.timer(LOOP_MS, loop)
end

-- One module per timer call, in order (win_core uses win_place, win_toasts
-- uses win_alerts, so each require finds the other already compiled); the loop
-- starts once they are all in. The pickers wait for their first use: a timer
-- that runs over its budget stops every timer of this half, the loop included.
local STEPS: { () -> () } = {
	function()
		require("./win_place")
	end,
	function()
		need_core()
	end,
	function()
		need_alerts()
	end,
	function()
		require("./win_toasts")
	end,
}

local function boot(i: number)
	tern.timer(0, function(_cx: WindowCx?)
		STEPS[i]()
		if i < #STEPS then
			boot(i + 1)
		else
			tern.timer(0, loop)
			tern.timer(300, watch_config)
		end
	end)
end
boot(1)
