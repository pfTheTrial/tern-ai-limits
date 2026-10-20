-- Fixture tests for model.luau and prefs.luau. Run tests/run.ps1: plain Luau
-- has no way to give a required module the `tern` global, so the script
-- bundles both modules after a stub and runs this file in the same chunk,
-- where `model`, `prefs` and `store` already exist.

local failures = 0
local count = 0
local function check(name: string, cond: boolean, detail: string?)
	count += 1
	if not cond then
		failures += 1
		print("FAIL " .. name .. (if detail then ": " .. detail else ""))
	end
end

local function provider(snap, id: string)
	for _, p in snap.providers do
		if p.id == id then
			return p
		end
	end
	return nil
end

local function windows(account): { [string]: any }
	local out = {}
	for _, f in account.families do
		for _, w in f.windows do
			out[(if f.name == "" then "" else f.name .. "/") .. w.short] = w
		end
	end
	return out
end

local H5, D7 = 18000000, 604800000
local function limit(id, label, duration, used, extra)
	local l = {
		id = id,
		label = label,
		window = { durationMs = duration, resetsAt = 1792800000000 },
		amount = { usedFraction = used, unit = "percent" },
		scope = { sharedGroup = "" },
	}
	for k, v in extra or {} do
		l[k] = v
	end
	return l
end

-- Antigravity: the Argon pool shares omp's "Gemini" label; the shared
-- Claude & GPT pool is listed once per model family.
do
	local snap = model.from_omp({
		reports = {
			{
				provider = "google-antigravity",
				metadata = { email = "a@x.com" },
				limits = {
					limit("google-antigravity:google:default:gemini-weekly", "Gemini", D7, 0.08),
					limit("google-antigravity:google:default:gemini-argon-wtu-weekly", "Gemini", D7, 0.2),
					limit("google-antigravity:anthropic:default:3p-weekly", "Claude & GPT (shared)", D7, 0.68,
						{ scope = { sharedGroup = "3p-weekly:weekly" } }),
					limit("google-antigravity:openai:default:3p-weekly", "Claude & GPT (shared)", D7, 0.68,
						{ scope = { sharedGroup = "3p-weekly:weekly" } }),
				},
			},
		},
	})
	local w = windows(provider(snap, "google-antigravity").accounts[1])
	local gem = nil
	for _, f in provider(snap, "google-antigravity").accounts[1].families do
		if f.name == "Gemini" then
			gem = f
		end
	end
	check("windows shortest first", gem ~= nil and #gem.windows == 1)
	check("argon kept apart", w["Gemini Argon/7d"] ~= nil and w["Gemini Argon/7d"].used == 0.2)
	check("gemini kept", w["Gemini/7d"] ~= nil and w["Gemini/7d"].used == 0.08)
	local shared = 0
	for _, f in provider(snap, "google-antigravity").accounts[1].families do
		if f.name == "Claude & GPT (shared)" then
			shared += #f.windows
		end
	end
	check("shared pool once", shared == 1, tostring(shared))
end

-- Labels the helpers send: omp's window words name no family; a prefix does.
do
	local snap = model.from_omp({
		reports = {
			{
				provider = "anthropic",
				metadata = { email = "c@x.com", planType = "max" },
				limits = {
					limit("seven_day", "Weekly", D7, 0.1),
					limit("five_hour", "5 Hour", H5, 0.42),
					limit("seven_day_sonnet", "Sonnet Weekly", D7, 0.3),
				},
			},
			{
				provider = "cursor",
				metadata = { email = "u@x.com" },
				limits = {
					{ label = "Total", window = { label = "Plan Period", resetsAt = 1 }, amount = { usedFraction = 0.617, unit = "percent" } },
					{ label = "On-demand (US$)", window = { label = "Plan Period" }, amount = { used = 3.5, limit = 20 } },
				},
			},
			{
				provider = "grok",
				metadata = {},
				limits = { limit("period", "Credits", D7, 0.375) },
			},
		},
	})
	local c = windows(provider(snap, "anthropic").accounts[1])
	check("claude 5h", c["5h"] ~= nil and c["5h"].used == 0.42)
	check("5h before 7d", provider(snap, "anthropic").accounts[1].families[1].windows[1].short == "5h")
	check("claude weekly", c["7d"] ~= nil)
	check("claude sonnet family", c["Sonnet/7d"] ~= nil)
	local cu = windows(provider(snap, "cursor").accounts[1])
	check("cursor plan window", cu["Total/plano"] ~= nil and cu["Total/plano"].text == "62%", cu["Total/plano"] and cu["Total/plano"].text)
	check("cursor on-demand text", cu["On-demand (US$)/plano"] ~= nil and cu["On-demand (US$)/plano"].text == "3.5/20")
	check("grok weekly", windows(provider(snap, "grok").accounts[1])["Credits/7d"] ~= nil)
	check("names", provider(snap, "grok").name == "Grok" and provider(snap, "anthropic").name == "Claude")
end

-- The same Codex login from omp and from codex-usage.ps1 shows once, omp's
-- first; a helper's "expired" for a login omp still reads is no problem.
do
	local snap = model.from_omp({
		reports = {
			{ provider = "openai-codex", metadata = { email = "o@x.com", accountId = "acc-1" }, limits = { limit("p", "5 Hour", H5, 0.5) } },
			{ provider = "openai-codex", metadata = { email = "o@x.com", accountId = "acc-1" }, limits = { limit("p", "5 Hour", H5, 0.9) } },
			{ provider = "openai-codex", metadata = { email = "p@x.com", accountId = "acc-2" }, limits = { limit("p", "5 Hour", H5, 0.1) } },
		},
		disabledCredentials = {
			{ provider = "openai-codex", email = "o@x.com", cause = "login do Codex expirado" },
			{ provider = "anthropic", email = "c@x.com", cause = "invalid_grant" },
			{ provider = "anthropic", email = "c@x.com", cause = "login do Claude Code expirado" },
		},
	})
	local codex = provider(snap, "openai-codex")
	check("codex deduped", #codex.accounts == 2, tostring(#codex.accounts))
	local o = nil
	for _, a in codex.accounts do
		if a.email == "o@x.com" then
			o = a
		end
	end
	check("omp copy kept", o ~= nil and o.worst == 0.5)
	check("most available first", codex.accounts[1].email == "p@x.com")
	check("disabled deduped and live dropped", #snap.disabled == 1 and snap.disabled[1].provider == "anthropic", tostring(#snap.disabled))
	check("cause translated", snap.disabled[1].cause == "login expired: run omp login")
end

-- Exhausted windows count as full and block the account.
do
	local snap = model.from_omp({
		reports = {
			{ provider = "factory-droid", metadata = {}, limits = { limit("x", "Weekly", D7, 0.4, { status = "exhausted" }) } },
		},
	})
	local a = provider(snap, "factory-droid").accounts[1]
	check("exhausted", a.worst == 1 and a.blocked == true)
end

-- prefs: hiding a window re-ranks accounts; hidden providers go; order applies.
do
	local snap = model.from_omp({
		reports = {
			{ provider = "openai-codex", metadata = { email = "a@x.com", accountId = "a" },
				limits = { limit("p", "5 Hour", H5, 0.8), limit("s", "Weekly", D7, 0.1) } },
			{ provider = "openai-codex", metadata = { email = "b@x.com", accountId = "b" },
				limits = { limit("p", "5 Hour", H5, 0.2), limit("s", "Weekly", D7, 0.9) } },
			{ provider = "devin", metadata = {}, limits = { limit("d", "Daily", 86400000, 0.1) } },
			{ provider = "grok", metadata = {}, limits = { limit("g", "Credits", D7, 0.1) } },
		},
	})
	check("before: a first", provider(snap, "openai-codex").accounts[1].email == "a@x.com")
	store = { hide_windows = { "7d" } }
	local f = prefs.apply(snap, prefs.read())
	local codex = provider(f, "openai-codex")
	check("after hiding 7d: b first", codex.accounts[1].email == "b@x.com")
	check("best follows", codex.best == 0.2, tostring(codex.best))
	store = { hide_providers = { "devin" }, provider_order = { "grok" } }
	f = prefs.apply(snap, prefs.read())
	check("hidden provider gone", provider(f, "devin") == nil)
	check("order applied", f.providers[1].id == "grok", f.providers[1].id)
	store = {}
end

-- history: hourly samples, a pace that runs out before the reset gives an eta.
do
	local H = 3600000
	local t0 = 1792000000000
	local function snap_at(used: number)
		return model.from_omp({
			reports = { { provider = "openai-codex", metadata = { accountId = "h" },
				limits = { { id = "p", label = "5 Hour", window = { durationMs = H5, resetsAt = t0 + 24 * H },
					amount = { usedFraction = used, unit = "percent" } } } } },
		})
	end
	history.record(snap_at(0.2), t0)
	history.record(snap_at(0.25), t0 + 10 * 60000) -- same hour: replaces
	local s = snap_at(0.4)
	history.record(s, t0 + 2 * H)
	history.annotate(s, t0 + 2 * H)
	local w = s.providers[1].accounts[1].families[1].windows[1]
	check("spark two hourly points", w.spark ~= nil and #w.spark == 2 and w.spark[1] == 0.25, w.spark and tostring(#w.spark))
	-- The hour's sample keeps its first time: 0.25 to 0.4 in 2h leaves 0.6 for
	-- 8h more, at 10h, before the reset at 24h.
	check("eta before reset", w.eta ~= nil and math.abs(w.eta - (t0 + 10 * H)) < 60000, tostring(w.eta and (w.eta - t0) / H))
	local flat = snap_at(0.4)
	history.record(flat, t0 + 2 * H + 30 * 60000)
	history.annotate(flat, t0 + 2 * H + 30 * 60000)
	check("eta keeps the pace from the window's start", flat.providers[1].accounts[1].families[1].windows[1].eta ~= nil)
	local late = snap_at(0.42)
	history.record(late, t0 + 20 * H)
	history.annotate(late, t0 + 20 * H)
	check("no eta when the pace finishes after the reset", late.providers[1].accounts[1].families[1].windows[1].eta == nil)
end

-- until_text and level thresholds.
do
	check("until minutes", model.until_text(42 * 60000, 0) == "42m")
	check("until hours", model.until_text((3 * 3600 + 5 * 60) * 1000, 0) == "3h05")
	check("until days", model.until_text((2 * 86400 + 4 * 3600) * 1000, 0) == "2d4h")
	check("levels", model.level(0.69) == "ok" and model.level(0.7) == "warn" and model.level(0.9) == "bad" and model.level(0.1, true) == "bad")
end

-- Moving a card with its ↑/↓ buttons.
do
	local shown = { "a", "b", "c" }
	local down = prefs.move({ "x", "c" }, shown, "a", 1)
	check("move down swaps and keeps hidden after", down ~= nil and table.concat(down, ",") == "b,a,c,x", if down then table.concat(down, ",") else "nil")
	local up = prefs.move({}, shown, "c", -1)
	check("move up", up ~= nil and table.concat(up, ",") == "a,c,b")
	check("no move past the top", prefs.move({}, shown, "a", -1) == nil)
	check("no move past the bottom", prefs.move({}, shown, "c", 1) == nil)
	check("unknown id", prefs.move({}, shown, "z", 1) == nil)
end

print(string.format("%d checks, %d failed", count, failures))
if failures > 0 then
	error("tests failed")
end
