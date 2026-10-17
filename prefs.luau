--!strict
-- User choices from the palette commands (the window half writes them to
-- `tern.kv`): which providers, accounts and limit windows show, in which
-- order, and how dense the cards are. The host applies them to every
-- snapshot before publishing, so the panel, the "Limites" tab, the status
-- line, the toasts, the peek and the lens all show the same things.

local model = require("./model")

export type Prefs = {
	hide_providers: { [string]: boolean },
	hide_accounts: { [string]: boolean },
	hide_windows: { [string]: boolean },
	order: { string },
	density: string, -- "auto" | "lines"
}

local prefs = {}

local function set_of(key: string): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local list = tern.kv.get(key)
	if type(list) == "table" then
		for _, id in list do
			if type(id) == "string" then
				out[id] = true
			end
		end
	end
	return out
end

function prefs.read(): Prefs
	local order: { string } = {}
	local raw_order = tern.kv.get("provider_order")
	if type(raw_order) == "table" then
		for _, id in raw_order do
			if type(id) == "string" then
				table.insert(order, id)
			end
		end
	end
	local density = tern.kv.get("density")
	if density ~= "lines" then
		density = "auto"
	end
	return {
		hide_providers = set_of("hide_providers"),
		hide_accounts = set_of("hide_accounts"),
		hide_windows = set_of("hide_windows"),
		order = order,
		density = density,
	}
end

-- Whether any filter hides something (for the "all hidden" empty state).
function prefs.filtering(p: Prefs): boolean
	return next(p.hide_providers) ~= nil
		or next(p.hide_accounts) ~= nil
		or next(p.hide_windows) ~= nil
end

local function apply_account(account: model.Account, p: Prefs): model.Account?
	local families: { model.Family } = {}
	local worst = 0
	for _, family in account.families do
		local windows: { model.Window } = {}
		for _, w in family.windows do
			if not p.hide_windows[w.short] then
				table.insert(windows, w)
				worst = math.max(worst, w.used)
			end
		end
		if #windows > 0 then
			table.insert(families, { key = family.key, name = family.name, windows = windows })
		end
	end
	if #families == 0 then
		return nil
	end
	return {
		key = account.key,
		email = account.email,
		plan = account.plan,
		blocked = account.blocked,
		worst = worst,
		families = families,
	}
end

-- The snapshot with the hidden providers, accounts and windows removed and
-- the providers in the user's order (unlisted ones keep their places after).
function prefs.apply(snap: model.Snapshot, p: Prefs): model.Snapshot
	local providers: { model.Provider } = {}
	local rank: { [string]: number } = {}
	for i, id in p.order do
		if rank[id] == nil then
			rank[id] = i
		end
	end
	for _, provider in snap.providers do
		if p.hide_providers[provider.id] then
			continue
		end
		local accounts: { model.Account } = {}
		local best = 1
		local blocked = true
		for _, account in provider.accounts do
			if p.hide_accounts[account.key] then
				continue
			end
			local filtered = apply_account(account, p)
			if filtered then
				table.insert(accounts, filtered)
				best = math.min(best, filtered.worst)
				blocked = blocked and filtered.blocked
			end
		end
		if #accounts > 0 then
			-- Hidden windows change each account's worst: feature the most available again.
			table.sort(accounts, function(a, b)
				if a.worst ~= b.worst then
					return a.worst < b.worst
				end
				return (a.email or a.key) < (b.email or b.key)
			end)
			table.insert(providers, {
				id = provider.id,
				name = provider.name,
				short = provider.short,
				accounts = accounts,
				best = best,
				blocked = blocked,
			})
		end
	end
	-- Stable re-sort: providers listed in `order` first, in that order.
	local index: { [string]: number } = {}
	for i, provider in providers do
		index[provider.id] = i
	end
	table.sort(providers, function(a, b)
		local ra = rank[a.id] or (#p.order + (index[a.id] or 0))
		local rb = rank[b.id] or (#p.order + (index[b.id] or 0))
		return ra < rb
	end)
	-- Logins and idle accounts of hidden providers go away too.
	local disabled: { model.Problem } = {}
	for _, item in snap.disabled do
		if not p.hide_providers[item.provider] then
			table.insert(disabled, item)
		end
	end
	local idle: { model.Idle } = {}
	for _, item in snap.idle do
		if not p.hide_providers[item.provider] then
			table.insert(idle, item)
		end
	end
	return {
		at = snap.at,
		providers = tern.json.array(providers),
		disabled = tern.json.array(disabled),
		idle = tern.json.array(idle),
	}
end

return prefs
