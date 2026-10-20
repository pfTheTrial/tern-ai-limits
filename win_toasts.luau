--!strict
-- AI Limits, window half: toasts when limits cross thresholds, reset, run out
-- soon or lose their login. Split from win_alerts so each compiles in its own
-- timer call; window.luau loads win_alerts first.

local A = require("./win_alerts")

local t = A.t
local who = A.who
local until_text = A.until_text
local window_label = A.window_label

local M = {}

local MAX_TOASTS = 4

-- Which toasts are on (kv `alerts`, nil = the defaults): thresholds "50",
-- "70", "80", "90", "100" (ran out), plus "reset" and "login".
local DEFAULT_ALERTS = { "80", "90", "100", "reset", "login", "eta" }
local LEVELS = { 100, 90, 80, 70, 50 }

local function alerts_on(): { [string]: boolean }
	local on: { [string]: boolean } = {}
	local v = tern.kv.get("alerts")
	for _, id in (if type(v) == "table" then v else DEFAULT_ALERTS) do
		if type(id) == "string" then
			on[id] = true
		end
	end
	return on
end

-- The highest enabled threshold a window has reached, else 0.
local function bucket(used: number, exhausted: boolean, on: { [string]: boolean }): number
	for _, lvl in LEVELS do
		if on[tostring(lvl)] and (used >= lvl / 100 or (lvl == 100 and exhausted)) then
			return lvl
		end
	end
	return 0
end

-- Whether two flat maps of scalars hold the same entries.
local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function check_alerts(cx: WindowCx, snap: any)
	if type(snap) ~= "table" or type(snap.providers) ~= "table" then
		return
	end
	local on = alerts_on()
	local buckets: { [string]: number } = {}
	local labels: { [string]: string } = {}
	local etas: { [string]: number } = {}
	for _, provider in snap.providers do
		for _, account in provider.accounts do
			for _, family in account.families do
				for _, w in family.windows do
					local key = account.key .. "|" .. family.key .. "|" .. w.short
					buckets[key] = bucket(tonumber(w.used) or 0, w.exhausted == true, on)
					labels[key] = window_label(provider, account, family, w)
					if type(w.eta) == "number" then
						etas[key] = w.eta
					end
				end
			end
		end
	end
	local disabled: { [string]: string } = {}
	local disabled_names: { [string]: string } = {}
	for _, item in snap.disabled or {} do
		local key = tostring(item.provider) .. "|" .. tostring(item.email or "")
		disabled[key] = tostring(item.cause or "")
		disabled_names[key] = item.name .. (if item.email then " · " .. who(item.email) else "")
	end
	local prev = tern.kv.get("alert_state")
	-- Every kv write rewrites the whole store (snapshots included) and makes
	-- every other VM parse it again; most new snapshots change no bucket.
	local unchanged = type(prev) == "table" and same(prev.b, buckets) and same(prev.d, disabled) and same(prev.e, etas)
	if not unchanged then
		tern.kv.set("alert_state", { b = buckets, d = disabled, e = etas })
	end
	if type(prev) ~= "table" then
		return -- first snapshot: a baseline, not news
	end
	local pb = if type(prev.b) == "table" then prev.b else {}
	local pd = if type(prev.d) == "table" then prev.d else {}
	local pe = if type(prev.e) == "table" then prev.e else {}
	type Toast = { level: ToastLevel, text: string, sub: string? }
	local toasts: { Toast } = {}
	for key, b in buckets do
		local before = tonumber(pb[key]) or 0
		if b > before then
			if b == 100 then
				table.insert(toasts, {
					level = "error",
					text = labels[key] .. t(" ran out", " esgotou"),
					sub = t("Switch accounts or wait for the reset.", "Troque de conta ou espere o reset."),
				})
			else
				table.insert(toasts, {
					level = if b >= 90 then "error" else "info",
					text = labels[key] .. t(" passed ", " passou de ") .. b .. "%",
				})
			end
		elseif before > 0 and b == 0 and on.reset then
			table.insert(toasts, { level = "success", text = labels[key] .. t(" reset", " resetou") })
		end
	end
	-- A window starts heading to run out before its reset (history.luau's eta).
	local now_ms = os.time() * 1000
	for key, eta in etas do
		if pe[key] == nil and on.eta and (buckets[key] or 0) < 100 then
			table.insert(toasts, {
				level = "info",
				text = labels[key] .. t(" should run out in ", " deve esgotar em ") .. until_text(eta, now_ms),
				sub = t("At the pace of the last hours, before the reset.", "No ritmo das últimas horas, antes do reset."),
			})
		end
	end
	for key, cause in disabled do
		if pd[key] == nil and on.login then
			table.insert(toasts, { level = "error", text = t("Login problem: ", "Login com problema: ") .. disabled_names[key], sub = cause })
		end
	end
	for i, toast in toasts do
		if i > MAX_TOASTS then
			cx:toast("info", string.format(t("%d more limit alerts", "Mais %d avisos de limite"), #toasts - MAX_TOASTS), t("See the Limits tab.", "Veja a aba Limites."))
			break
		end
		cx:toast(toast.level, toast.text, toast.sub)
	end
end

M.check_alerts = check_alerts

return M
