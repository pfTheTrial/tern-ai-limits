--!strict
-- Views shared by the side panel, the "Limites" tab and the `omp usage` lens.
-- Layout follows CodexBar's menu card: a header with the provider's logo,
-- name and account, then one ring per limit window. Every tree hangs under an
-- `.ail-root` element so ai-limits.css styles it wherever it is drawn.

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end

local model = require("./model")
local ui = tern.ui
local el = ui.el

local view = {}

-- "summary": one row per provider (a resting floating card). "panel": stacked
-- cards (side column). "dashboard": a grid of large cards (its own tab).
-- "lens": cards under a command's output.
export type Layout = "summary" | "panel" | "dashboard" | "lens"

export type Opts = {
	layout: Layout,
	now_ms: number,
	redact: boolean,
	loading: boolean?,
	problem: string?,
	note: string?, -- a muted line under the cards
	only: string?, -- show this provider only
	density: string?, -- "lines" draws one row per limit instead of rings
	empty: string?, -- what to say when no provider is left to show
	featured: { [string]: string }?, -- provider id → account key the user put in front
	stale_ms: number?, -- data older than this reads as old (two missed polls)
	glance: boolean?, -- a resting floating card: no bottom bar, it cannot be clicked
}


local function pct(used: number): string
	return tostring(math.floor(used * 100 + 0.5)) .. "%"
end

local function ring_tone(level: string): string
	if level == "bad" then
		return "error"
	elseif level == "warn" then
		return "warning"
	end
	return "accent"
end

local function who(email: string?, redact: boolean): string
	if email == nil then
		return t("account", "conta")
	end
	return if redact then model.redact(email) else email
end

local function ring(used: number, level: string, size: string): Node
	return ui.node("meter", { value = used, style = "ring", size = size, tone = ring_tone(level) })
end

-- A window's length as shown: "plano" is also an id, kept as is in data.
local function short_of(w: model.Window): string
	return if w.short == "plano" then t("plan", "plano") else w.short
end

local function root(layout: Layout, kids: { Node }): Node
	return el("div", { class = "ail-root ail-" .. layout, key = "root" }, kids)
end

-- The account a card puts in front: the one the user picked, else the most
-- available (accounts come sorted that way).
local function front(provider: model.Provider, opts: Opts): (model.Account?, boolean)
	local pick = if opts.featured then opts.featured[provider.id] else nil
	if pick then
		for _, account in provider.accounts do
			if account.key == pick then
				return account, true
			end
		end
	end
	return provider.accounts[1], false
end

-- The most used window of an account: what limits it next.
function view.tightest(account: model.Account): model.Window?
	local found: model.Window? = nil
	for _, family in account.families do
		for _, w in family.windows do
			if found == nil or w.used > (found :: model.Window).used then
				found = w
			end
		end
	end
	return found
end

-- "esgota em 3h" when the recent pace runs the window out before its reset.
local function eta_text(w: model.Window, now_ms: number): string?
	if w.eta == nil then
		return nil
	end
	return t("runs out in ", "esgota em ") .. model.until_text(w.eta :: number, now_ms)
end

local function window_title(label: string, w: model.Window, now_ms: number): string
	local title = label .. ": " .. w.text .. t(" used", " usado")
	if w.resets then
		title ..= t(" · resets in ", " · reseta em ") .. model.until_text(w.resets, now_ms)
	end
	local eta = eta_text(w, now_ms)
	if eta then
		title ..= t(" · at the pace of the last hours, ", " · no ritmo das últimas horas, ") .. eta
	end
	return title
end

-- The last day's hourly readings as a one-line chart.
local function spark(w: model.Window, level: string): Node?
	if w.spark == nil or #(w.spark :: { number }) < 2 then
		return nil
	end
	local series: { any } = {}
	for _, u in w.spark :: { number } do
		table.insert(series, { value = math.max(u, 0.001), title = pct(u) })
	end
	return ui.node("chart", { kind = "spark", token = ring_tone(level), series = series })
end

-- `label` names the ring; the window's length by default. `key` must be
-- unique among its siblings.
local function tile(w: model.Window, opts: Opts, label: string?, key: string?): Node
	local level = model.level(w.used, w.exhausted)
	local reset = if w.resets then model.until_text(w.resets, opts.now_ms) else "—"
	local kids: { Node } = {
		el("div", { class = "ail-ring" }, {
			ring(w.used, level, "lg"),
			el("span", { class = "ail-pct", text = pct(w.used) }),
		}),
		el("span", { class = "ail-win", text = label or short_of(w) }),
		el("span", { class = "ail-reset", text = reset }),
	}
	local eta = eta_text(w, opts.now_ms)
	if eta then
		table.insert(kids, el("span", { class = "ail-eta", text = eta }))
	end
	if opts.layout == "dashboard" then
		local chart = spark(w, level)
		if chart then
			table.insert(kids, el("div", { class = "ail-spark" }, { chart }))
		end
	end
	return el("div", {
		class = "ail-tile",
		key = key or w.key,
		title = window_title(if label then label .. " · " .. short_of(w) else short_of(w), w, opts.now_ms),
		attrs = { ["data-level"] = level },
	}, kids)
end

local function rings_of(account: model.Account, opts: Opts): { Node }
	local out: { Node } = {}
	-- Several families of one window each (Cursor's Total/Auto/API): one row,
	-- each ring named by its family, instead of a header and a lone ring apiece.
	local singles = #account.families > 1
	for _, family in account.families do
		if #family.windows ~= 1 then
			singles = false
		end
	end
	if singles then
		local tiles: { Node } = {}
		for _, family in account.families do
			local w = family.windows[1]
			table.insert(tiles, tile(w, opts, if family.name ~= "" then family.name else nil, family.key .. ":" .. w.key))
		end
		return { el("div", { class = "ail-group", key = "singles" }, { el("div", { class = "ail-rings" }, tiles) }) }
	end
	for _, family in account.families do
		local tiles: { Node } = {}
		for _, w in family.windows do
			table.insert(tiles, tile(w, opts))
		end
		local kids: { Node } = {}
		if family.name ~= "" and #account.families > 1 then
			table.insert(kids, el("span", { class = "ail-family", text = family.name }))
		end
		table.insert(kids, el("div", { class = "ail-rings" }, tiles))
		table.insert(out, el("div", { class = "ail-group", key = family.key }, kids))
	end
	return out
end

-- The dense alternative to the rings: one row per limit window.
local function limit_line(family: model.Family, w: model.Window, account: model.Account, now_ms: number): Node
	local level = model.level(w.used, w.exhausted)
	local label = short_of(w)
	if family.name ~= "" and #account.families > 1 then
		label = family.name .. " · " .. short_of(w)
	end
	local reset = if w.resets then model.until_text(w.resets, now_ms) else "—"
	local eta = if w.eta then "!" .. model.until_text(w.eta :: number, now_ms) else nil
	return el("div", {
		class = "ail-line",
		key = family.key .. ":" .. w.key,
		title = window_title(label, w, now_ms),
		attrs = { ["data-level"] = level, ["data-eta"] = if eta then "true" else "false" },
	}, {
		ring(w.used, level, "sm"),
		el("span", { class = "ail-line-name", text = label }),
		el("span", { class = "ail-line-pct", text = pct(w.used) }),
		el("span", { class = "ail-line-reset", text = eta or reset }),
	})
end

local function limits_of(account: model.Account, opts: Opts): { Node }
	if opts.density ~= "lines" then
		return rings_of(account, opts)
	end
	local rows: { Node } = {}
	for _, family in account.families do
		for _, w in family.windows do
			table.insert(rows, limit_line(family, w, account, opts.now_ms))
		end
	end
	return { el("div", { class = "ail-lines", key = "lines" }, rows) }
end

-- One line per extra account: name, its tightest window as a small ring.
-- Clicking it puts that account in front.
local function account_row(provider: model.Provider, account: model.Account, now_ms: number, redact: boolean): Node
	local w = view.tightest(account)
	local kids: { Node } = { el("span", { class = "ail-acct-name", text = who(account.email, redact) }) }
	if w then
		local level = model.level(w.used, account.blocked)
		table.insert(kids, ring(w.used, level, "md"))
		table.insert(kids, el("span", { class = "ail-acct-pct", text = pct(w.used) }))
		table.insert(kids, el("span", {
			class = "ail-acct-reset",
			text = if w.resets then model.until_text(w.resets, now_ms) else short_of(w),
		}))
	end
	return el("button", {
		class = "ail-acct",
		key = account.key,
		title = t("Put this account in front", "Mostrar esta conta em destaque"),
		actions = { click = "feature:" .. provider.id .. "|" .. account.key },
		attrs = { ["data-blocked"] = if account.blocked then "true" else "false" },
	}, kids)
end

-- The dashboard shows every account with its rings; the panel shows the
-- account in front with rings and the rest as rows.
-- Tern blocks get no drag events, so a card moves by these buttons; they
-- show while the card is hovered or one of them has focus.
local function move_buttons(provider: model.Provider, index: number, count: number): Node
	local function button(delta: number, glyph: string, title: string): Node
		return el("button", {
			class = "ail-move",
			key = "move" .. delta,
			text = glyph,
			title = title,
			disabled = (delta < 0 and index == 1) or (delta > 0 and index == count),
			actions = { click = "move:" .. provider.id .. "|" .. delta },
		})
	end
	return el("div", { class = "ail-moves" }, {
		button(-1, "↑", t("Move up", "Mover para cima")),
		button(1, "↓", t("Move down", "Mover para baixo")),
	})
end

local function provider_card(provider: model.Provider, opts: Opts, index: number, count: number): Node
	local main, pinned = front(provider, opts)
	if opts.layout == "dashboard" then
		main, pinned = provider.accounts[1], false
	end
	local level = model.level(provider.best, provider.blocked)
	local head_right: { Node } = {}
	if main and main.plan then
		table.insert(head_right, el("span", { class = "ail-plan", text = main.plan }))
	end
	if #provider.accounts > 1 then
		local free = 0
		for _, a in provider.accounts do
			if not a.blocked then
				free += 1
			end
		end
		-- A person icon, not the word "free": next to a plan pill that read as
		-- the Free tier, and a word crowded the provider's name.
		table.insert(head_right, el("span", {
			class = "ail-count",
			title = string.format(t("%d of %d accounts with limit left", "%d de %d contas com limite livre"), free, #provider.accounts),
		}, {
			ui.node("icon", { name = "user" }),
			el("span", { text = string.format("%d/%d", free, #provider.accounts) }),
		}))
	end
	if pinned then
		table.insert(head_right, el("button", {
			class = "ail-unpin",
			title = t("Back to the most available account", "Voltar para a conta mais livre"),
			actions = { click = "unfeature:" .. provider.id },
		}, { ui.node("icon", { name = "pin" }) }))
	end
	if count > 1 and opts.only == nil and (opts.layout == "panel" or opts.layout == "dashboard") then
		table.insert(head_right, move_buttons(provider, index, count))
	end
	local kids: { Node } = {
		el("div", { class = "ail-head" }, {
			el("span", { class = "ail-logo", attrs = { ["data-provider"] = provider.id } }),
			el("div", { class = "ail-title" }, {
				el("span", { class = "ail-name", text = provider.name }),
				el("span", { class = "ail-sub", text = if main then who(main.email, opts.redact) else "" }),
			}),
			el("div", { class = "ail-meta" }, head_right),
		}),
	}
	if opts.layout == "dashboard" then
		for i, account in provider.accounts do
			local block: { Node } = {}
			if i > 1 then
				table.insert(block, el("div", { class = "ail-acct-head" }, {
					el("span", { class = "ail-acct-name", text = who(account.email, opts.redact) }),
					el("span", { class = "ail-plan", text = account.plan or "", hidden = account.plan == nil }),
				}))
			end
			for _, node in limits_of(account, opts) do
				table.insert(block, node)
			end
			table.insert(kids, el("div", { class = "ail-acct-block", key = account.key }, block))
		end
	else
		if main then
			-- Keyed by account: putting another account in front mounts a new
			-- block, which eases in (ai-limits.css) instead of swapping at once.
			table.insert(kids, el("div", { class = "ail-front", key = "front:" .. main.key }, limits_of(main, opts)))
		end
		if #provider.accounts > 1 then
			local rows: { Node } = {}
			for _, account in provider.accounts do
				if account ~= main then
					table.insert(rows, account_row(provider, account, opts.now_ms, opts.redact))
				end
			end
			table.insert(kids, el("div", { class = "ail-accts" }, rows))
		end
	end
	return el("div", {
		class = "ail-card",
		key = provider.id,
		attrs = { ["data-level"] = level, ["data-provider"] = provider.id },
	}, kids)
end

local function alerts(snap: model.Snapshot, opts: Opts): Node?
	if #snap.disabled == 0 and #snap.idle == 0 then
		return nil
	end
	local rows: { Node } = {}
	for i, item in snap.disabled do
		table.insert(rows, el("div", { class = "ail-alert", key = "d" .. i }, {
			ui.node("icon", { name = "warn", tone = "warning" }),
			el("span", { class = "ail-alert-name", text = item.name }),
			el("span", { class = "ail-alert-text", text = item.cause }),
			el("span", { class = "ail-alert-who", text = if item.email then who(item.email, opts.redact) else "" }),
		}))
	end
	if #snap.idle > 0 then
		local names = {}
		for _, item in snap.idle do
			table.insert(names, item.name)
		end
		table.insert(rows, el("div", { class = "ail-alert ail-idle", key = "idle" }, {
			ui.node("icon", { name = "minus", tone = "muted" }),
			el("span", { class = "ail-alert-text", text = t("no usage data: ", "sem dados de uso: ") .. table.concat(names, ", ") }),
		}))
	end
	return el("div", { class = "ail-alerts", key = "alerts" }, rows)
end

local function icon_button(icon: string, act: string, title: string): Node
	return el("button", { class = "ail-btn", title = title, actions = { click = act } }, {
		ui.node("icon", { name = icon }),
	})
end

-- One row per provider: logo, name, and the tightest window of its most
-- available account.
local function summary(snap: model.Snapshot, opts: Opts): Node
	local rows: { Node } = {}
	for _, provider in snap.providers do
		local main = front(provider, opts)
		local w = if main then view.tightest(main) else nil
		local level = model.level(if w then w.used else provider.best, provider.blocked)
		local reset = if w and w.resets then model.until_text(w.resets, opts.now_ms) else "—"
		if w and w.eta then
			reset = "!" .. model.until_text(w.eta :: number, opts.now_ms)
		end
		local title = if w then window_title(provider.name .. " · " .. short_of(w), w, opts.now_ms) else provider.name
		table.insert(rows, el("div", {
			class = "ail-sum",
			key = provider.id,
			title = title,
			attrs = { ["data-level"] = level, ["data-eta"] = if w and w.eta then "true" else "false" },
		}, {
			el("span", { class = "ail-logo", attrs = { ["data-provider"] = provider.id } }),
			el("span", { class = "ail-sum-name", text = provider.name }),
			el("span", { class = "ail-sum-win", text = if w then short_of(w) else "" }),
			ring(if w then w.used else 0, level, "sm"),
			el("span", { class = "ail-sum-pct", text = if w then pct(w.used) else "—" }),
			el("span", { class = "ail-sum-reset", text = reset }),
		}))
	end
	if #snap.disabled > 0 then
		table.insert(rows, el("div", { class = "ail-sum ail-sum-alert", key = "alerts" }, {
			ui.node("icon", { name = "warn", tone = "warning" }),
			el("span", { class = "ail-sum-name", text = #snap.disabled .. t(" login(s) with problems", " login(s) com problema") }),
		}))
	end
	return el("div", { class = "ail-summary-rows", key = "summary" }, rows)
end

local function updated_text(snap: model.Snapshot?, opts: Opts): Node
	if opts.loading then
		return ui.node("spinner", { style = "dots", label = "atualizando" })
	elseif opts.problem and snap then
		return el("span", { class = "ail-updated ail-warn", text = opts.problem :: string, title = opts.problem })
	elseif snap then
		local at = (snap :: model.Snapshot).at
		local text = t("updated at ", "atualizado às ") .. os.date("%H:%M", at // 1000)
		-- Two missed polls: say so instead of passing old numbers off as current.
		if opts.stale_ms and opts.now_ms - at > opts.stale_ms then
			return el("span", {
				class = "ail-updated ail-warn",
				text = text .. t(" (old)", " (antigo)"),
				title = t("The last reads failed; press r to try again.", "O omp não respondeu nas últimas consultas; pressione r para tentar de novo."),
			})
		end
		return el("span", { class = "ail-updated", text = text })
	end
	return el("span", { class = "ail-updated", text = "" })
end

local function actions(opts: Opts): Node
	return el("div", { class = "ail-actions" }, {
		icon_button(if opts.redact then "eye" else "eye-off", "redact", if opts.redact
			then t("Show e-mails (e)", "Mostrar e-mails (e)")
			else t("Hide e-mails (e)", "Ocultar e-mails (e)")),
		icon_button("redo", "refresh", t("Refresh now (r)", "Atualizar agora (r)")),
		icon_button("sliders", "configure", t("Settings (c)", "Configurar (c)")),
	})
end

local function filtered(snap: model.Snapshot, only: string?): model.Snapshot
	if only == nil then
		return snap
	end
	local providers: { model.Provider } = {}
	for _, p in snap.providers do
		if p.id == only then
			table.insert(providers, p)
		end
	end
	return { at = snap.at, providers = providers, disabled = snap.disabled, idle = snap.idle }
end

-- The cards (or the summary rows) for `snap`, or the loading/error state.
function view.body(snap: model.Snapshot?, opts: Opts): Node
	if snap == nil then
		if opts.problem then
			return root(opts.layout, {
				el("div", { class = "ail-empty", key = "error" }, {
					ui.node("icon", { name = "error", tone = "error" }),
					el("span", { class = "ail-empty-title", text = t("Could not read the limits", "Não consegui ler os limites") }),
					el("span", { class = "ail-empty-text", text = opts.problem :: string }),
					el("span", {
						class = "ail-empty-text",
						text = t("Check that omp is installed and logged in (omp login), or that a direct source is set up, then press r.", "Confira se o omp está instalado e logado (omp login), depois pressione r."),
					}),
				}),
			})
		end
		return root(opts.layout, {
			el("div", { class = "ail-empty", key = "loading" }, {
				ui.node("spinner", { style = "dots", label = t("Reading limits…", "Lendo limites do omp…") }),
			}),
		})
	end
	local s = filtered(snap :: model.Snapshot, opts.only)
	if opts.layout == "summary" then
		return root("summary", { summary(s, opts) })
	end
	local kids: { Node } = {}
	if opts.layout == "dashboard" then
		table.insert(kids, el("div", { class = "ail-dash-head", key = "head" }, {
			el("div", { class = "ail-title" }, {
				el("span", { class = "ail-dash-title", text = t("AI Limits", "Limites de IA") }),
				updated_text(s, opts),
			}),
			actions(opts),
		}))
	end
	local cards: { Node } = {}
	for i, provider in s.providers do
		table.insert(cards, provider_card(provider, opts, i, #s.providers))
	end
	if #cards == 0 then
		table.insert(cards, el("div", {
			class = "ail-empty",
			key = "none",
			text = opts.empty or t("No logged-in account has limits to show.", "Nenhuma conta logada no omp tem limites para mostrar."),
		}))
	end
	table.insert(kids, el("div", { class = "ail-grid", key = "grid" }, cards))
	local extra = if opts.only then nil else alerts(s, opts)
	if extra then
		table.insert(kids, extra)
	end
	if opts.note then
		table.insert(kids, el("span", { class = "ail-note", key = "note", text = opts.note }))
	end
	return root(opts.layout, kids)
end

-- The panel's bottom bar: when the data is from, and the actions.
function view.dock(snap: model.Snapshot?, opts: Opts): Node
	return root(opts.layout, {
		el("div", { class = "ail-dock" }, { updated_text(snap, opts), actions(opts) }),
	})
end

-- A block's regions: the region roots are containers, as Tern requires.
function view.block(snap: model.Snapshot?, opts: Opts): BlockView
	local main = ui.col({ view.body(snap, opts) })
	if opts.layout == "dashboard" or (opts.glance and snap ~= nil) then
		return { main = main }
	end
	return { main = main, dock = ui.col({ view.dock(snap, opts) }) }
end

return view
