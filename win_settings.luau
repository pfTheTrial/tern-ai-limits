--!strict
-- AI Limits, window half: the settings pickers and the "configurar…" list.
-- Loaded on first use; the filter pickers live in win_filters.

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end

local core = require("./win_core")

local M = {}

local MODES = core.MODES
local MODE_ORDER = core.MODE_ORDER
local CORNERS = core.CORNERS
local mode = core.mode
local side = core.side
local width = core.width
local corner = core.corner
local panel = core.panel
local neighbour = core.neighbour
local start_width = core.start_width
local show = core.show
local hide = core.hide
local safe_ensure = core.safe_ensure

-- Settings the host reads when it filters bump this so it republishes.
local function prefs_changed()
	tern.kv.set("prefs_at", tern.now())
end

-- Entries of the list below that win_filters handles.
local FILTERS: { [string]: boolean } = { providers = true, windows = true, accounts = true, order = true, density = true }

function M.refresh(cx: WindowCx)
	tern.kv.set("refresh_request", os.time())
	cx:toast("info", t("Refreshing limits", "Atualizando limites"), t("usage is read in the background", "omp usage roda em segundo plano"))
end

function M.mode(cx: WindowCx)
	local items: { PickItem } = {}
	for _, id in MODE_ORDER do
		table.insert(items, { label = MODES[id], id = id, current = id == mode() })
	end
	cx:pick({ items = items, placeholder = t("Limits panel mode", "Modo do painel de limites"), icon = "sidebar" })
		:next(function(choice, _err, later)
			if choice == nil or later == nil then
				return
			end
			local lcx = later :: WindowCx
			tern.kv.set("mode", choice.id)
			tern.kv.set("open", nil)
			if choice.id == "column" or choice.id == "pip" then
				show(lcx, false)
			else
				hide(lcx)
			end
		end)
end

function M.side(cx: WindowCx)
	local items: { PickItem } = {
		{ label = t("Right", "Direita"), id = "right", current = side() == "right", icon = "dock-right" },
		{ label = t("Left", "Esquerda"), id = "left", current = side() == "left", icon = "dock-left" },
	}
	cx:pick({ items = items, placeholder = t("Limits column side", "Lado da coluna de limites"), icon = "columns" })
		:next(function(choice, _err, later)
			if choice and later then
				tern.kv.set("side", choice.id)
				safe_ensure(later :: WindowCx)
			end
		end)
end

function M.width(cx: WindowCx)
	cx:prompt({ value = tostring(width()), placeholder = t("Width in columns (20 to 120)", "Largura em colunas (20 a 120)"), icon = "columns" })
		:next(function(text, _err, later)
			local n = tonumber(text)
			if n == nil or later == nil then
				return
			end
			tern.kv.set("width", math.clamp(math.floor(n), 20, 120))
			start_width()
			safe_ensure(later :: WindowCx)
		end)
end

function M.corner(cx: WindowCx)
	local keep = cx.session:focused()
	local items: { PickItem } = {}
	for _, id in { "tl", "tr", "bl", "br" } do
		table.insert(items, { label = CORNERS[id], id = id, current = id == corner(), icon = "pip-" .. id })
	end
	cx:pick({ items = items, placeholder = t("Limits card corner", "Canto do cartão de limites"), icon = "pip" })
		:next(function(choice, _err, later)
			if choice == nil or later == nil then
				return
			end
			tern.kv.set("corner", choice.id)
			local lcx = later :: WindowCx
			local info = panel(lcx)
			if info and info.floating then
				lcx.layout:float(info.pane, neighbour(lcx, info.pane, info.tab, keep), corner(), { focus = false })
			end
		end)
end


-- Where usage comes from: omp plus the plugin's helpers, or the helpers alone.
function M.sources(cx: WindowCx)
	local on = tern.kv.get("use_omp") ~= false
	local items: { PickItem } = {
		{ label = t("omp + direct reading (default)", "omp + leitura direta (padrão)"), id = "omp", current = on, detail = t("omp accounts and the tools' own logins", "contas do omp e logins das ferramentas") },
		{ label = t("Direct reading only, no omp", "Só leitura direta, sem omp"), id = "direct", current = not on, detail = t("Claude Code, Codex, Cursor, Grok and API keys", "Claude Code, Codex, Cursor, Grok e chaves de API") },
	}
	cx:pick({ items = items, placeholder = t("Where limits come from", "De onde vêm os limites"), icon = "plug" }):next(function(choice, _err, _later)
		if choice then
			tern.kv.set("use_omp", if choice.id == "direct" then false else nil)
			tern.kv.set("refresh_request", os.time())
		end
	end)
end

-- Providers read with an API key (keys-usage.ps1), kept in the system keychain
-- through tern.secrets.
local KEYS: { { id: string, label: string, hint: string } } = {
	{ id = "factory", label = "Factory (Droid)", hint = "app.factory.ai → Settings → API keys" },
	{ id = "opencode-go", label = "OpenCode Go", hint = "opencode.ai → Workspace → API keys" },
	{ id = "commandcode", label = "Command Code", hint = "commandcode.ai → Settings → API keys" },
}

function M.keys(cx: WindowCx)
	local items: { PickItem } = {}
	for _, k in KEYS do
		table.insert(items, { label = k.label, id = k.id, icon = "key", detail = k.hint })
	end
	cx:pick({ items = items, placeholder = t("API key for which provider?", "Chave de API de qual provider?"), icon = "key" }):next(function(choice, _err, later)
		if choice == nil or later == nil then
			return
		end
		local name = choice.id
		local label = choice.label
		;(later :: WindowCx)
			:prompt({ placeholder = t("Paste the ", "Cole a chave de ") .. label .. t(" key (empty deletes the saved one; the text shows while you type)", " (vazio apaga a salva; o texto aparece enquanto digita)"), icon = "key" })
			:next(function(text, _err2, later2)
				if text == nil or later2 == nil then
					return
				end
				local value = string.match(text, "^%s*(.-)%s*$")
				tern.secrets.set(name, if value == "" then nil else value):next(function(_ok, err3, later3)
					if later3 == nil then
						return
					end
					if err3 then
						(later3 :: WindowCx):toast("error", t("Could not save the key", "Não consegui salvar a chave"), err3)
						return
					end
					(later3 :: WindowCx):toast("success", if value == "" then t("", "Chave de ") .. label .. t(" key deleted", " apagada") else t("", "Chave de ") .. label .. t(" key saved", " salva"), t("Limits refresh in a moment.", "Os limites atualizam em instantes."))
					tern.kv.set("refresh_request", os.time())
				end)
			end)
	end)
end
-- kv `lang`: nil English, "pt" Portuguese. Every module reads it when it
-- loads, so a change reloads the plugin.
function M.lang(cx: WindowCx)
	local items: { PickItem } = {
		{ label = "English", id = "en", current = not PT },
		{ label = "Português (Brasil)", id = "pt", current = PT },
	}
	cx:pick({ items = items, placeholder = t("Language", "Idioma"), icon = "globe" }):next(function(choice, _err, _later)
		if choice == nil or (choice.id == "pt") == PT then
			return
		end
		tern.kv.set("lang", if choice.id == "pt" then "pt" else nil)
		tern.process.run({ "tern", "plugin", "reload" }, { timeout_ms = 30 * 1000 }, function(_result, _cx) end)
	end)
end

local POLLS = { 1, 2, 5, 10, 15, 30 }

function M.poll(cx: WindowCx)
	local now = tonumber(tern.kv.get("poll_minutes")) or 5
	local items: { PickItem } = {}
	for _, m in POLLS do
		local label = if m == 1 then t("Every minute", "A cada minuto") else t("Every ", "A cada ") .. m .. t(" minutes", " minutos")
		table.insert(items, { label = label .. (if m == 5 then t(" (default)", " (padrão)") else ""), id = tostring(m), current = m == now })
	end
	cx:pick({ items = items, placeholder = t("Refresh usage…", "Atualizar o uso…"), icon = "clock" }):next(function(choice, _err, _later)
		if choice then
			tern.kv.set("poll_minutes", if choice.id == "5" then nil else tonumber(choice.id))
		end
	end)
end

local ALERTS: { { id: string, label: string } } = {
	{ id = "50", label = t("Passed 50%", "Passou de 50%") },
	{ id = "70", label = t("Passed 70%", "Passou de 70%") },
	{ id = "80", label = t("Passed 80%", "Passou de 80%") },
	{ id = "90", label = t("Passed 90%", "Passou de 90%") },
	{ id = "100", label = t("Ran out", "Esgotou") },
	{ id = "reset", label = t("Reset after an alert", "Resetou depois de um aviso") },
	{ id = "login", label = t("Login problem", "Login com problema") },
	{ id = "eta", label = t("Will run out before the reset (by pace)", "Vai esgotar antes do reset (pelo ritmo)") },
}
local DEFAULT_ALERTS = { "80", "90", "100", "reset", "login", "eta" }

-- Toggles one toast kind per choice and reopens, like the filter pickers.
function M.alerts(cx: WindowCx)
	local function step(lcx: WindowCx)
		local v = tern.kv.get("alerts")
		local on: { [string]: boolean } = {}
		for _, id in (if type(v) == "table" then v else DEFAULT_ALERTS) do
			on[id] = true
		end
		local items: { PickItem } = {
			{ label = t("Done", "Concluir"), id = "__done", icon = "check" },
			{ label = t("Back to the default (80%, 90%, ran out, reset, login, pace)", "Voltar ao padrão (80%, 90%, esgotou, reset, login, ritmo)"), id = "__reset", icon = "undo" },
		}
		for _, a in ALERTS do
			table.insert(items, {
				label = a.label,
				id = a.id,
				current = on[a.id] == true,
				icon = if on[a.id] then "bell" else "slash",
				detail = if on[a.id] then t("alerts", "avisa") else t("silent", "não avisa"),
			})
		end
		lcx:pick({ items = items, placeholder = t("Limit alerts (↵ toggles)", "Avisos de limite (↵ liga/desliga)"), icon = "bell", action = t("toggle", "ligar/desligar") })
			:next(function(choice, _err, later)
				if choice == nil or later == nil or choice.id == "__done" then
					return
				end
				if choice.id == "__reset" then
					tern.kv.set("alerts", nil)
				else
					on[choice.id] = not on[choice.id]
					local list: { string } = {}
					for _, a in ALERTS do
						if on[a.id] then
							table.insert(list, a.id)
						end
					end
					tern.kv.set("alerts", tern.json.array(list))
				end
				step(later :: WindowCx)
			end)
	end
	step(cx)
end

local STATUS: { { id: string, label: string } } = {
	{ id = "", label = t("Every provider", "Todos os providers") },
	{ id = "alert", label = t("Only those past 70%", "Só os que passaram de 70%") },
	{ id = "top3", label = t("The first 3 in order", "Os 3 primeiros da ordem") },
}

function M.status(cx: WindowCx)
	local now = tern.kv.get("status_show")
	local items: { PickItem } = {}
	for _, s in STATUS do
		table.insert(items, { label = s.label, id = s.id, current = (now or "") == s.id })
	end
	cx:pick({ items = items, placeholder = t("Status bar shows…", "Barra de status mostra…"), icon = "activity" })
		:next(function(choice, _err, _later)
			if choice then
				tern.kv.set("status_show", if choice.id == "" then nil else choice.id)
				prefs_changed()
			end
		end)
end

-- What a resting floating card shows; focused, it shows every provider.
function M.pip_show(cx: WindowCx)
	local snap = tern.kv.get("snapshot")
	local now = tern.kv.get("pip_show")
	local items: { PickItem } = {
		{ label = t("Summary of every provider", "Resumo de todos os providers"), id = "", icon = "list", current = type(now) ~= "string" },
	}
	if type(snap) == "table" and type(snap.providers) == "table" then
		for _, p in snap.providers do
			table.insert(items, { label = t("Only ", "Só ") .. tostring(p.name), id = p.id, icon = "gauge", current = p.id == now })
		end
	end
	cx:pick({ items = items, placeholder = t("Resting floating card shows…", "Cartão flutuante em repouso mostra…"), icon = "pip" })
		:next(function(choice, _err, _later)
			if choice then
				tern.kv.set("pip_show", if choice.id == "" then nil else choice.id)
				prefs_changed()
			end
		end)
end

-- Every setting in one list, for the palette and the panel's sliders button.
local SETTINGS: { { id: string, label: string, icon: string } } = {
	{ id = "lang", label = t("Language", "Idioma"), icon = "globe" },
	{ id = "mode", label = t("Panel mode", "Modo do painel"), icon = "sidebar" },
	{ id = "providers", label = t("Providers shown", "Providers que aparecem"), icon = "eye" },
	{ id = "windows", label = t("Limit windows (5h, weekly, monthly…)", "Janelas de limite (5h, semanal, mensal…)"), icon = "clock" },
	{ id = "accounts", label = t("Accounts shown", "Contas que aparecem"), icon = "user" },
	{ id = "order", label = t("Provider order", "Ordem dos providers"), icon = "list" },
	{ id = "density", label = t("Card density", "Densidade dos cartões"), icon = "grid" },
	{ id = "status", label = t("Status bar", "Barra de status"), icon = "activity" },
	{ id = "poll", label = t("Refresh interval", "Frequência de atualização"), icon = "clock" },
	{ id = "sources", label = t("Where limits come from (with or without omp)", "De onde vêm os limites (com ou sem omp)"), icon = "plug" },
	{ id = "keys", label = t("API keys (Factory, OpenCode Go, Command Code)", "Chaves de API (Factory, OpenCode Go, Command Code)"), icon = "key" },
	{ id = "alerts", label = t("Limit alerts", "Avisos de limite"), icon = "bell" },
	{ id = "side", label = t("Column side", "Lado da coluna"), icon = "columns" },
	{ id = "width", label = t("Column width", "Largura da coluna"), icon = "columns" },
	{ id = "pip_show", label = t("Floating card content", "Conteúdo do cartão flutuante"), icon = "pip" },
	{ id = "corner", label = t("Floating card corner", "Canto do cartão flutuante"), icon = "pip" },
	{ id = "refresh", label = t("Refresh now", "Atualizar agora"), icon = "redo" },
	{ id = "dashboard", label = t("Open the Limits tab", "Abrir aba Limites"), icon = "gauge" },
}

local function configure(cx: WindowCx)
	local items: { PickItem } = {}
	for _, s in SETTINGS do
		local detail = if s.id == "mode" then MODES[mode()] else nil
		table.insert(items, { label = s.label, id = s.id, icon = s.icon, detail = detail })
	end
	cx:pick({ items = items, placeholder = t("AI Limits settings", "Configurar Limites de IA"), icon = "sliders" })
		:next(function(choice, _err, later)
			if choice == nil or later == nil then
				return
			end
			local lcx = later :: WindowCx
			if choice.id == "dashboard" then
				core.open_dashboard(lcx)
			elseif FILTERS[choice.id] then
				(require("./win_filters") :: any)[choice.id](lcx)
			else
				(M :: any)[choice.id](lcx)
			end
		end)
end

M.configure = configure

return M
