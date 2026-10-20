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
-- code first, so the time grows with the code: a busy machine (Tern reloading
-- every plugin, settings reloading, git timing out) has pushed both this file
-- and the modules it once loaded in one go past it. So this file only
-- registers commands, keys, chrome and events, with as few functions as it
-- can. The rest loads one module per timer call, each with its own budget:
-- win_place and win_core (placement), win_alerts (peek, status line, title),
-- win_toasts (threshold toasts), win_cmds (what the commands do) and win_loop
-- (the main loop). win_settings and win_filters (the pickers) load in the
-- first command that needs them.

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end

-- Set by the boot timers below; until then events and chrome do nothing.
local core: any = nil
local alerts: any = nil

-- The hooks running now, one mark each (the title hook keeps running after
-- the status hook is stopped, so one shared mark would be cleared). Tern
-- stops a hook that runs over its budget midway and keeps it off until a
-- reload, which leaves its mark: win_loop reports it and the host reloads
-- the plugin, as it does when the loop stops.
local busy: { [string]: boolean } = {}

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	if alerts == nil then
		return nil
	end
	busy.status = true
	local segments = alerts.status()
	busy.status = nil
	return segments
end)

tern.chrome.window_title(function(win: WindowInfo): string?
	if alerts == nil then
		return nil
	end
	busy.title = true
	local title = alerts.title(win)
	busy.title = nil
	return title
end)

-- Commands: id, icon, title. What each does is in win_cmds.

local COMMANDS: { { string } } = {
	{ "toggle", "sidebar", t("AI Limits: show/hide panel", "Limites de IA: mostrar/ocultar painel") },
	{ "show", "sidebar", t("AI Limits: show panel", "Limites de IA: mostrar painel") },
	{ "hide", "eye-off", t("AI Limits: hide panel", "Limites de IA: ocultar painel") },
	{ "dashboard", "gauge", t("AI Limits: open the Limits tab", "Limites de IA: abrir aba Limites") },
	{ "peek", "eye", t("AI Limits: peek", "Limites de IA: espiar") },
	{ "configure", "sliders", t("AI Limits: settings…", "Limites de IA: configurar…") },
	{ "refresh", "redo", t("AI Limits: refresh now", "Limites de IA: atualizar agora") },
	{ "mode", "sidebar", t("AI Limits: panel mode", "Limites de IA: modo do painel") },
	{ "side", "columns", t("AI Limits: column side", "Limites de IA: lado da coluna") },
	{ "width", "columns", t("AI Limits: column width", "Limites de IA: largura da coluna") },
	{ "corner", "pip", t("AI Limits: floating card corner", "Limites de IA: canto do cartão flutuante") },
	{ "pip_show", "pip", t("AI Limits: floating card content", "Limites de IA: conteúdo do cartão flutuante") },
	{ "providers", "eye", t("AI Limits: choose providers", "Limites de IA: escolher providers") },
	{ "windows", "clock", t("AI Limits: choose windows (5h, weekly, monthly…)", "Limites de IA: escolher janelas (5h, semanal, mensal…)") },
	{ "accounts", "user", t("AI Limits: choose accounts", "Limites de IA: escolher contas") },
	{ "order", "list", t("AI Limits: provider order", "Limites de IA: ordem dos providers") },
	{ "density", "grid", t("AI Limits: card density", "Limites de IA: densidade dos cartões") },
	{ "status", "activity", t("AI Limits: status bar", "Limites de IA: barra de status") },
	{ "poll", "clock", t("AI Limits: refresh interval", "Limites de IA: frequência de atualização") },
	{ "sources", "plug", t("AI Limits: where limits come from", "Limites de IA: de onde vêm os limites") },
	{ "keys", "key", t("AI Limits: API keys", "Limites de IA: chaves de API") },
	{ "alerts", "bell", t("AI Limits: limit alerts", "Limites de IA: avisos de limite") },
	{ "lang", "globe", t("AI Limits: language", "Limites de IA: idioma") },
}

local group = t("AI Limits", "Limites de IA")
for _, c in COMMANDS do
	local id = c[1]
	tern.command({
		id = id,
		title = c[3],
		icon = c[2],
		group = group,
		run = function(cx: WindowCx)
			busy["command " .. id] = true;
			(require("./win_cmds") :: any)[id](cx)
			busy["command " .. id] = nil
		end,
	})
end

local ctrl = if tern.runtime.os == "macos" then "cmd" else "ctrl"
tern.bind(ctrl .. "+alt+shift+u", "plugin.ai-limits.toggle")
tern.bind(ctrl .. "+alt+shift+i", "plugin.ai-limits.dashboard")
tern.bind(ctrl .. "+alt+shift+y", "plugin.ai-limits.peek")

-- Events: focus, pane and tab changes place the panel at once.

local function ensure(_ev: any, cx: WindowCx)
	if core then
		core.safe_ensure(cx)
	end
end

tern.on("window_start", function(cx: WindowCx)
	ensure(nil, cx)
end)

for _, name in { "focus", "pane_created", "tab_created", "tab_closed" } do
	tern.on(name, ensure)
end

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if core then
		core.pane_closed(ev, cx)
	end
end)

-- Boot: one module per timer call, in order (each finds the ones it uses
-- already compiled); the loop starts last. A timer that runs over its budget
-- stops every timer of this half, the loop included. Every overrun in the log
-- landed 0.1-0.3 s after Tern reloaded its plugins (`settings loaded`), even
-- in hooks that do almost nothing, so the first module waits until that has
-- passed.
local BOOT_DELAY_MS = 1000
local config_at_load = tern.kv.get("config_request")
local BOOT = { "win_place", "win_core", "win_alerts", "win_toasts", "win_cmds", "win_loop" }

local function boot(i: number)
	tern.timer(if i == 1 then BOOT_DELAY_MS else 0, function(_cx: WindowCx?)
		local step = BOOT[i]
		if step == "win_place" then
			require("./win_place")
		elseif step == "win_core" then
			core = require("./win_core")
		elseif step == "win_alerts" then
			alerts = require("./win_alerts")
		elseif step == "win_toasts" then
			require("./win_toasts")
		elseif step == "win_cmds" then
			require("./win_cmds")
		else
			require("./win_loop").start(config_at_load, function(): string?
				local stuck = next(busy)
				if stuck then
					busy[stuck] = nil
				end
				return stuck
			end)
			return
		end
		boot(i + 1)
	end)
end
boot(1)
