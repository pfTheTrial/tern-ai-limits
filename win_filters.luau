--!strict
-- AI Limits, window half: what to show, in which order and how dense. Loaded
-- on first use, apart from win_settings, so neither file's compile nears the
-- 50 ms a window hook gets.

-- Loaded at startup by window.luau, so requiring it here costs nothing.
local who = require("./win_alerts").who

local M = {}

-- The window only writes the choices to kv and bumps `prefs_at`; the host
-- re-filters and republishes.

local WINDOW_NAMES: { [string]: string } = {
	["1h"] = "1 hora",
	["5h"] = "5 horas",
	["1d"] = "Diária",
	["7d"] = "Semanal",
	["30d"] = "Mensal",
	plano = "Período do plano",
}
local WINDOW_ORDER = { "1h", "5h", "1d", "7d", "30d", "plano" }

local DENSITIES: { [string]: string } = {
	auto = "Anéis (padrão)",
	lines = "Lista compacta (uma linha por cota)",
}
local DENSITY_ORDER = { "auto", "lines" }

local function kv_list(key: string): { string }
	local out: { string } = {}
	local v = tern.kv.get(key)
	if type(v) == "table" then
		for _, item in v do
			if type(item) == "string" then
				table.insert(out, item)
			end
		end
	end
	return out
end

local function kv_set(key: string): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, item in kv_list(key) do
		out[item] = true
	end
	return out
end

local function prefs_changed()
	tern.kv.set("prefs_at", tern.now())
end

local function kv_toggle(key: string, id: string)
	local list = kv_list(key)
	for i, item in list do
		if item == id then
			table.remove(list, i)
			tern.kv.set(key, if #list > 0 then tern.json.array(list) else nil)
			return
		end
	end
	table.insert(list, id)
	tern.kv.set(key, tern.json.array(list))
end

-- Every provider and account omp reported, hidden ones included.
local function all_snapshot(cx: WindowCx): any
	local snap = tern.kv.get("snapshot_all")
	if type(snap) ~= "table" or type(snap.providers) ~= "table" then
		snap = tern.kv.get("snapshot")
	end
	if type(snap) ~= "table" or type(snap.providers) ~= "table" then
		cx:toast("info", "Ainda sem dados de limites", "O omp usage roda em segundo plano.")
		return nil
	end
	return snap
end

-- A picker where each choice flips one item and the picker opens again, so
-- several can be changed in a row; Esc or "Concluir" closes it.
local function toggle_pick(cx: WindowCx, title: string, icon: string, key: string, items: () -> { PickItem })
	local function step(lcx: WindowCx)
		local list: { PickItem } = {
			{ label = "Concluir", id = "__done", icon = "check" },
			{ label = "Mostrar todos", id = "__reset", icon = "eye" },
		}
		for _, item in items() do
			table.insert(list, item)
		end
		lcx:pick({ items = list, placeholder = title, icon = icon, action = "mostrar/ocultar" })
			:next(function(choice, _err, later)
				if choice == nil or later == nil or choice.id == "__done" then
					return
				end
				if choice.id == "__reset" then
					tern.kv.set(key, nil)
				else
					kv_toggle(key, choice.id)
				end
				prefs_changed()
				step(later :: WindowCx)
			end)
	end
	step(cx)
end

local function visibility(item: PickItem, hidden: boolean): PickItem
	item.current = not hidden
	item.icon = if hidden then "eye-off" else "eye"
	item.detail = if hidden then "oculto" else item.detail
	return item
end

function M.providers(cx: WindowCx)
	local snap = all_snapshot(cx)
	if snap == nil then
		return
	end
	toggle_pick(cx, "Providers mostrados (↵ alterna)", "eye", "hide_providers", function()
		local hidden = kv_set("hide_providers")
		local items: { PickItem } = {}
		for _, p in snap.providers do
			local n = #p.accounts
			table.insert(items, visibility({
				label = tostring(p.name),
				id = p.id,
				detail = if n == 1 then "1 conta" else n .. " contas",
			}, hidden[p.id] == true))
		end
		return items
	end)
end

function M.windows(cx: WindowCx)
	local snap = all_snapshot(cx)
	if snap == nil then
		return
	end
	local count: { [string]: number } = {}
	for _, p in snap.providers do
		for _, a in p.accounts do
			for _, family in a.families do
				for _, w in family.windows do
					count[w.short] = (count[w.short] or 0) + 1
				end
			end
		end
	end
	local shorts: { string } = {}
	for _, s in WINDOW_ORDER do
		if count[s] then
			table.insert(shorts, s)
		end
	end
	for s in count do
		if WINDOW_NAMES[s] == nil then
			table.insert(shorts, s)
		end
	end
	toggle_pick(cx, "Janelas mostradas (↵ alterna)", "clock", "hide_windows", function()
		local hidden = kv_set("hide_windows")
		local items: { PickItem } = {}
		for _, s in shorts do
			table.insert(items, visibility({
				label = (WINDOW_NAMES[s] or s) .. " (" .. s .. ")",
				id = s,
				detail = count[s] .. (if count[s] == 1 then " cota" else " cotas"),
			}, hidden[s] == true))
		end
		return items
	end)
end

function M.accounts(cx: WindowCx)
	local snap = all_snapshot(cx)
	if snap == nil then
		return
	end
	toggle_pick(cx, "Contas mostradas (↵ alterna)", "user", "hide_accounts", function()
		local hidden = kv_set("hide_accounts")
		local items: { PickItem } = {}
		for _, p in snap.providers do
			for _, a in p.accounts do
				table.insert(items, visibility({
					label = if a.email then who(a.email) else tostring(p.name),
					id = a.key,
					group = tostring(p.name),
					detail = a.plan,
				}, hidden[a.key] == true))
			end
		end
		return items
	end)
end

function M.order(cx: WindowCx)
	local snap = all_snapshot(cx)
	if snap == nil then
		return
	end
	-- The current order: saved ids first, then the rest as omp sorts them.
	local names: { [string]: string } = {}
	local current: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, p in snap.providers do
		names[p.id] = tostring(p.name)
	end
	for _, id in kv_list("provider_order") do
		if names[id] and not seen[id] then
			seen[id] = true
			table.insert(current, id)
		end
	end
	for _, p in snap.providers do
		if not seen[p.id] then
			seen[p.id] = true
			table.insert(current, p.id)
		end
	end
	local picked: { string } = {}
	local function save(lcx: WindowCx)
		if #picked == 0 then
			return
		end
		local order: { string } = table.clone(picked)
		local taken: { [string]: boolean } = {}
		for _, id in picked do
			taken[id] = true
		end
		for _, id in current do
			if not taken[id] then
				table.insert(order, id)
			end
		end
		tern.kv.set("provider_order", tern.json.array(order))
		prefs_changed()
		local shown: { string } = {}
		for _, id in order do
			table.insert(shown, names[id])
		end
		lcx:toast("success", "Ordem dos providers salva", table.concat(shown, " › "))
	end
	local function step(lcx: WindowCx)
		local taken: { [string]: boolean } = {}
		local chosen: { string } = {}
		for _, id in picked do
			taken[id] = true
			table.insert(chosen, names[id])
		end
		local items: { PickItem } = {}
		for i, id in current do
			if not taken[id] then
				table.insert(items, { label = names[id], id = id, detail = "hoje em " .. i .. "º" })
			end
		end
		if #items == 0 then
			save(lcx)
			return
		end
		local placeholder = if #chosen == 0
			then "Escolha o 1º provider (Esc salva a ordem escolhida até aqui)"
			else table.concat(chosen, " › ") .. " › escolha o " .. (#chosen + 1) .. "º"
		lcx:pick({ items = items, placeholder = placeholder, icon = "list", action = "colocar aqui" })
			:next(function(choice, _err, later)
				if later == nil then
					return
				end
				if choice == nil then
					save(later :: WindowCx)
					return
				end
				table.insert(picked, choice.id)
				step(later :: WindowCx)
			end)
	end
	step(cx)
end

function M.density(cx: WindowCx)
	local now = tern.kv.get("density")
	if type(now) ~= "string" or DENSITIES[now] == nil then
		now = "auto"
	end
	local items: { PickItem } = {}
	for _, id in DENSITY_ORDER do
		table.insert(items, { label = DENSITIES[id], id = id, current = id == now })
	end
	cx:pick({ items = items, placeholder = "Densidade dos cartões de limites", icon = "grid" })
		:next(function(choice, _err, _later)
			if choice then
				tern.kv.set("density", if choice.id == "auto" then nil else choice.id)
				prefs_changed()
			end
		end)
end

return M
