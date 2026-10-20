--!strict
-- AI Limits, window half: the palette peek and the status line and window
-- title summaries. Threshold toasts live in win_toasts, which uses the text
-- helpers exported here.

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end

local M = {}

local TOGGLE = "plugin.ai-limits.toggle"

local segments: { StatusSegment } = {}
local title_alert: string? = nil
local seen_at: number? = nil

-- Copies of model.luau's level, redact and until_text.

local function level(used: number, blocked: boolean?): string
	if blocked or used >= 0.9 then
		return "bad"
	elseif used >= 0.7 then
		return "warn"
	end
	return "ok"
end

local function redact(email: string): string
	local user, domain = string.match(email, "^([^@]+)@(.+)$")
	if user == nil or domain == nil then
		return string.sub(email, 1, 3) .. "…"
	end
	return string.sub(user, 1, 3) .. "…@" .. domain
end

local function until_text(resets: number, now_ms: number): string
	local s = math.max(0, (resets - now_ms) // 1000)
	if s < 3600 then
		return tostring(math.max(1, s // 60)) .. "m"
	elseif s < 86400 then
		return string.format("%dh%02d", s // 3600, (s % 3600) // 60)
	end
	return string.format("%dd%dh", s // 86400, (s % 86400) // 3600)
end

-- Text helpers for the peek, toasts and title.

local function who(email: string?): string
	if email == nil then
		return ""
	end
	return if tern.kv.get("redact") == true then redact(email) else email
end

local function window_label(provider: any, account: any, family: any, w: any): string
	local label = provider.name
	if #provider.accounts > 1 and account.email then
		label ..= " · " .. who(account.email)
	end
	if family.name ~= "" and #account.families > 1 then
		label ..= " · " .. family.name
	end
	return label .. " · " .. (if w.short == "plano" then t("plan", "plano") else w.short)
end

-- Palette peek; `open_dashboard` comes from win_core.
function M.peek(cx: WindowCx, open_dashboard: (WindowCx) -> ())
	local snap = tern.kv.get("snapshot")
	if type(snap) ~= "table" or type(snap.providers) ~= "table" then
		cx:toast("info", t("No limits data yet", "Ainda sem dados de limites"), t("Usage is being read in the background.", "O omp usage roda em segundo plano."))
		return
	end
	local now_ms = os.time() * 1000
	local items: { PickItem } = {}
	for _, provider in snap.providers do
		for _, account in provider.accounts do
			local parts: { string } = {}
			for _, family in account.families do
				for _, w in family.windows do
					local text = (if w.short == "plano" then t("plan", "plano") else w.short) .. " " .. w.text
					if family.name ~= "" and #account.families > 1 then
						text = family.name .. " " .. text
					end
					if w.resets then
						text ..= " ↻" .. until_text(w.resets, now_ms)
					end
					table.insert(parts, text)
				end
			end
			table.insert(items, {
				label = if account.email then who(account.email) else provider.name,
				detail = table.concat(parts, "  ·  "),
				group = provider.name,
				icon = if account.blocked then "warn" else "gauge",
				dashboard = true,
			})
		end
	end
	for _, item in snap.disabled or {} do
		table.insert(items, {
			label = item.name .. (if item.email then " · " .. who(item.email) else ""),
			detail = item.cause,
			group = t("Logins with problems", "Logins com problema"),
			icon = "warn",
			dashboard = true,
		})
	end
	cx:pick({ items = items, placeholder = t("AI Limits", "Limites de IA"), icon = "gauge", action = t("open the Limits tab", "abrir aba Limites") })
		:next(function(choice, _err, later)
			if choice and later then
				open_dashboard(later :: WindowCx)
			end
		end)
end

-- Toasts when a window crosses 80%, 90% or runs out, when it resets, and when
-- a login expires. The last seen state lives in kv, so reloads stay quiet.

-- Status line and window title.

local TONES: { [string]: string } = { ok = "ok", warn = "warn", bad = "error" }

local function build(snap: any)
	segments = {}
	title_alert = nil
	if type(snap) ~= "table" or type(snap.providers) ~= "table" then
		return
	end
	-- kv `status_show`: nil every provider, "alert" only those past 70%,
	-- "top3" the first three in the user's order.
	local show = tern.kv.get("status_show")
	local alerting: { string } = {}
	for _, provider in snap.providers do
		local best = tonumber(provider.best) or 0
		local lv = level(best, provider.blocked == true)
		local name = tostring(provider.short or provider.name or provider.id)
		local text = string.format("%s %d%%", name, math.floor(best * 100 + 0.5))
		local wanted = if show == "alert" then lv ~= "ok" elseif show == "top3" then #segments < 3 else true
		if wanted then
			table.insert(segments, {
				text = text,
				icon = if #segments == 0 then "gauge" else nil,
				tone = TONES[lv],
				command = TOGGLE,
			})
		end
		if lv ~= "ok" then
			table.insert(alerting, text)
		end
	end
	if #segments == 0 and #snap.providers > 0 then
		-- Nothing in alert: keep one quiet segment as the way into the panel.
		table.insert(segments, { text = t("AI ok", "IA ok"), icon = "gauge", tone = "ok", command = TOGGLE })
	end
	if #alerting > 0 then
		title_alert = table.concat(alerting, " · ")
	end
end

local function reload_summary()
	local stamp = tern.kv.get("snapshot_at")
	if stamp ~= nil and stamp == seen_at then
		return
	end
	-- Decoding the snapshot gets its own timer budget, and comparing alerts
	-- (which rewrites kv and raises toasts) another one.
	tern.timer(0, function(_cx: WindowCx?)
		if stamp ~= nil and stamp == seen_at then
			return
		end
		local ok, snap = pcall(tern.kv.get, "snapshot")
		if not ok then
			return
		end
		seen_at = stamp
		build(snap)
		tern.chrome.refresh()
		tern.timer(0, function(cx: WindowCx?)
			if cx then
				require("./win_toasts").check_alerts(cx :: WindowCx, snap)
			end
		end)
	end)
end

function M.status(): { StatusSegment }?
	if #segments == 0 then
		return nil
	end
	return segments
end

function M.title(win: WindowInfo): string?
	if title_alert == nil then
		return nil
	end
	local base = if type(win.space) == "string" and win.space ~= "" then win.space else "Tern"
	return base .. " · " .. (title_alert :: string)
end

M.reload_summary = reload_summary
M.t = t
M.who = who
M.until_text = until_text
M.window_label = window_label

return M
