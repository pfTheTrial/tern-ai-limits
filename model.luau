--!strict
-- Turns `omp usage --json` into the snapshot both halves share through
-- `tern.kv`: providers in a fixed order, their accounts, and each account's
-- limit windows grouped by family ("Standard credits", "Gemini", …).
-- Cursor and Grok come from the plugin's own helpers (cursor-usage.ps1,
-- grok-usage.ps1), which print documents of the same shape; the host merges
-- their reports into omp's before normalizing.

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end

local model = {}

export type Window = {
	key: string,
	short: string, -- "5h", "7d", "30d", "plano"
	used: number, -- 0..1
	text: string, -- "37%" or "120/2500"
	resets: number?, -- epoch ms
	exhausted: boolean,
	spark: { number }?, -- the last day's hourly readings (history.luau)
	eta: number?, -- epoch ms it runs out at the recent pace, when before resets
}

export type Family = {
	key: string,
	name: string, -- "" when the provider has a single family
	windows: { Window },
}

export type Account = {
	key: string,
	email: string?,
	plan: string?,
	blocked: boolean,
	worst: number, -- highest used fraction among its windows
	families: { Family },
}

export type Provider = {
	id: string,
	name: string,
	short: string,
	accounts: { Account },
	best: number, -- worst-window usage of the most available account
	blocked: boolean, -- every account is blocked
}

export type Problem = { provider: string, name: string, email: string?, cause: string }
export type Idle = { provider: string, name: string, kind: string }

export type Snapshot = {
	at: number, -- epoch ms of the report
	providers: { Provider },
	disabled: { Problem },
	idle: { Idle },
}

local NAMES: { [string]: string } = {
	["factory-droid"] = "Factory Droid",
	anthropic = "Claude",
	["openai-codex"] = "Codex",
	["opencode-go"] = "OpenCode Go",
	["opencode-zen"] = "OpenCode Zen",
	["google-antigravity"] = "Antigravity",
	["google-gemini-cli"] = "Gemini CLI",
	devin = "Devin",
	["github-copilot"] = "Copilot",
	cursor = "Cursor",
	grok = "Grok",
	commandcode = "Command Code",
	zai = "z.ai",
	minimax = "MiniMax",
	kimi = "Kimi",
}

local SHORT: { [string]: string } = {
	["factory-droid"] = "Droid",
	["google-antigravity"] = "AntiG",
	["google-gemini-cli"] = "Gemini",
	["opencode-go"] = "OCGo",
	["github-copilot"] = "Copilot",
}

-- The user's priority first; every other provider follows alphabetically.
local ORDER: { [string]: number } = {
	["factory-droid"] = 1,
	anthropic = 2,
	["openai-codex"] = 3,
	["opencode-go"] = 4,
}

local DURATIONS: { [number]: string } = {
	[3600000] = "1h",
	[18000000] = "5h",
	[86400000] = "1d",
	[604800000] = "7d",
	[2592000000] = "30d",
}

-- Window words omp appends to a limit's label; what is left names the family.
local WINDOW_WORDS = { "5 Hour", "Hourly", "Daily", "Weekly", "Monthly", "30 days", "7 days", "Plan Period" }

function model.name(provider: string): string
	return NAMES[provider] or provider
end

function model.short(provider: string): string
	return SHORT[provider] or NAMES[provider] or provider
end

local function short_window(w: any): string
	if type(w) ~= "table" then
		return "?"
	end
	local d = tonumber(w.durationMs)
	if d then
		if DURATIONS[d] then
			return DURATIONS[d]
		elseif d % 86400000 == 0 then
			return tostring(d // 86400000) .. "d"
		elseif d % 3600000 == 0 then
			return tostring(d // 3600000) .. "h"
		end
	end
	local label = tostring(w.label or w.id or "?")
	if string.find(label, "Plan Period", 1, true) then
		return "plano"
	end
	return label
end

-- A window's length in hours for ordering; "plano" and unknown ones go last.
local function window_hours(short: string): number
	local n, unit = string.match(short, "^(%d+)([hd])$")
	if n == nil then
		return math.huge
	end
	return tonumber(n) :: number * (if unit == "d" then 24 else 1)
end

local function family_of(label: string): string
	local name = string.gsub(label, "%s+window$", "")
	for _, word in WINDOW_WORDS do
		if name == word then
			return ""
		end
		local cut = #name - #word
		if cut > 0 and string.sub(name, cut + 1) == word then
			name = string.sub(name, 1, cut)
		end
	end
	name = string.gsub(name, "%s+$", "")
	return name
end

local function number_text(n: number): string
	if n == math.floor(n) then
		return string.format("%d", n)
	end
	return string.format("%.1f", n)
end

local function amount_of(a: any): (number, string)
	if type(a) ~= "table" then
		return 0, "?"
	end
	local used = tonumber(a.usedFraction)
	local u, l = tonumber(a.used), tonumber(a.limit)
	if used == nil and u and l and l > 0 then
		used = u / l
	end
	local fraction = math.clamp(used or 0, 0, 1)
	if a.unit == "percent" or u == nil or l == nil then
		return fraction, string.format("%d%%", math.floor(fraction * 100 + 0.5))
	end
	return fraction, number_text(u) .. "/" .. number_text(l)
end

-- What a refresh failure means to someone reading the card.
function model.cause(text: string): string
	if string.find(text, "invalid_grant", 1, true) or string.find(text, "refresh", 1, true) then
		return t("login expired: run omp login", "login expirado: rode omp login")
	end
	local first = string.match(text, "^[^\n]*") or text
	return if #first > 90 then string.sub(first, 1, 89) .. "…" else first
end

local function list_of(value: any): { any }
	if type(value) ~= "table" then
		return {}
	end
	-- A lone object (not an array) is one entry.
	if value.provider ~= nil then
		return { value }
	end
	return value
end

local function account_of(report: any, index: number): Account
	local meta = if type(report.metadata) == "table" then report.metadata else {}
	local limits = list_of(report.limits)
	local email = if type(meta.email) == "string" then meta.email else nil
	local plan = meta.planType
	local families: { Family } = {}
	local by_family: { [string]: Family } = {}
	local seen: { [string]: boolean } = {}
	local worst = 0
	local blocked = meta.allowed == false or meta.limitReached == true
	for _, limit in limits do
		if type(limit) ~= "table" then
			continue
		end
		local scope = if type(limit.scope) == "table" then limit.scope else {}
		if plan == nil and type(scope.tier) == "string" then
			plan = scope.tier
		end
		local name = family_of(tostring(limit.label or ""))
		-- omp labels Antigravity's separate Argon pool "Gemini" too; only its id tells.
		if name == "Gemini" and type(limit.id) == "string" and string.find(limit.id, "argon", 1, true) then
			name = "Gemini Argon"
		end
		local short = short_window(limit.window)
		local resets = if type(limit.window) == "table" then tonumber(limit.window.resetsAt) else nil
		-- Antigravity lists one shared pool once per model family (same
		-- sharedGroup); show it once. omp sends sharedGroup = "" for pools that
		-- are not shared, so those stay apart by id.
		local shared = if type(scope.sharedGroup) == "string" and scope.sharedGroup ~= "" then scope.sharedGroup else nil
		local dedupe = name .. "|" .. short .. "|" .. (shared or tostring(limit.id or resets or ""))
		if seen[dedupe] then
			continue
		end
		seen[dedupe] = true
		local used, text = amount_of(limit.amount)
		local exhausted = limit.status == "exhausted"
		if exhausted then
			used = math.max(used, 1)
		end
		worst = math.max(worst, used)
		local family = by_family[name]
		if family == nil then
			family = { key = if name == "" then "default" else name, name = name, windows = {} }
			by_family[name] = family
			table.insert(families, family)
		end
		table.insert(family.windows, {
			key = short .. ":" .. tostring(#family.windows + 1),
			short = short,
			used = used,
			text = text,
			resets = resets,
			exhausted = exhausted,
		})
	end
	if worst >= 1 then
		blocked = true
	end
	-- Shortest window first (5h before 7d), whatever order the source used.
	for _, family in families do
		table.sort(family.windows, function(a, b)
			return window_hours(a.short) < window_hours(b.short)
		end)
	end
	local id = meta.accountId or email or tostring(index)
	return {
		key = tostring(report.provider) .. ":" .. tostring(id),
		email = email,
		plan = if type(plan) == "string" then plan else nil,
		blocked = blocked,
		worst = worst,
		families = families,
	}
end

local function provider_order(a: Provider, b: Provider): boolean
	local ra, rb = ORDER[a.id] or 100, ORDER[b.id] or 100
	if ra ~= rb then
		return ra < rb
	end
	return a.name < b.name
end

-- Normalizes the decoded `omp usage --json` document.
function model.from_omp(doc: any): Snapshot
	local providers: { Provider } = {}
	local by_id: { [string]: Provider } = {}
	for index, report in list_of(doc.reports) do
		if type(report) ~= "table" or type(report.provider) ~= "string" then
			continue
		end
		local id = report.provider
		local provider = by_id[id]
		if provider == nil then
			provider = { id = id, name = model.name(id), short = model.short(id), accounts = {}, best = 1, blocked = true }
			by_id[id] = provider
			table.insert(providers, provider)
		end
		local account = account_of(report, index)
		-- omp and the plugin's own helpers can report the same login: keep the
		-- first (omp's), matched by account id or e-mail.
		local duplicate = false
		for _, other in provider.accounts do
			if other.key == account.key or (account.email ~= nil and other.email == account.email) then
				duplicate = true
				break
			end
		end
		if not duplicate then
			table.insert(provider.accounts, account)
		end
	end
	for _, provider in providers do
		table.sort(provider.accounts, function(a, b)
			if a.worst ~= b.worst then
				return a.worst < b.worst
			end
			return (a.email or a.key) < (b.email or b.key)
		end)
		local best = 1
		local blocked = true
		for _, account in provider.accounts do
			best = math.min(best, account.worst)
			blocked = blocked and account.blocked
		end
		provider.best = best
		provider.blocked = blocked
	end
	table.sort(providers, provider_order)

	-- A login one source reports as broken is not a problem while another
	-- source still reads it; and two sources may report the same breakage.
	local live: { [string]: boolean } = {}
	for _, provider in providers do
		for _, account in provider.accounts do
			if account.email then
				live[provider.id .. "|" .. account.email] = true
			end
		end
	end
	local disabled: { Problem } = {}
	for _, item in list_of(doc.disabledCredentials) do
		local who = if type(item) == "table" and type(item.email) == "string" then item.email else ""
		local seen_key = if type(item) == "table" then tostring(item.provider) .. "|" .. who else ""
		if type(item) == "table" and type(item.provider) == "string" and not live[seen_key] then
			live[seen_key] = true
			table.insert(disabled, {
				provider = item.provider,
				name = model.name(item.provider),
				email = if type(item.email) == "string" then item.email else nil,
				cause = model.cause(tostring(item.cause or "")),
			})
		end
	end

	local idle: { Idle } = {}
	for _, item in list_of(doc.accountsWithoutUsage) do
		if type(item) == "table" and type(item.provider) == "string" and by_id[item.provider] == nil then
			table.insert(idle, {
				provider = item.provider,
				name = model.name(item.provider),
				kind = tostring(item.type or "?"),
			})
		end
	end

	return {
		at = tonumber(doc.generatedAt) or os.time() * 1000,
		providers = providers,
		disabled = tern.json.array(disabled),
		idle = tern.json.array(idle),
	}
end

-- "ok" under 70% used, "warn" under 90%, else "bad".
function model.level(used: number, blocked: boolean?): string
	if blocked or used >= 0.9 then
		return "bad"
	elseif used >= 0.7 then
		return "warn"
	end
	return "ok"
end

-- `ada…@example.com` for `ada.lovelace@example.com`.
function model.redact(email: string): string
	local user, domain = string.match(email, "^([^@]+)@(.+)$")
	if user == nil or domain == nil then
		return string.sub(email, 1, 3) .. "…"
	end
	return string.sub(user, 1, 3) .. "…@" .. domain
end

-- Time left until `resets` (epoch ms): "42m", "3h05", "2d4h".
function model.until_text(resets: number, now_ms: number): string
	local s = math.max(0, (resets - now_ms) // 1000)
	if s < 3600 then
		return tostring(math.max(1, s // 60)) .. "m"
	elseif s < 86400 then
		return string.format("%dh%02d", s // 3600, (s % 3600) // 60)
	end
	return string.format("%dd%dh", s // 86400, (s % 86400) // 3600)
end

return model
