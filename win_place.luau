--!strict
-- AI Limits, window half: settings, pane lookup, column width and placement
-- of the side panel. Split from win_core so each file compiles in its own
-- timer call: one 600-line chunk took 12-17 ms on an idle machine and went
-- past the 50 ms budget on a busy one. window.luau loads this one first.

local PT = tern.kv.get("lang") == "pt"
local function t(en: string, pt: string): string
	return if PT then pt else en
end

local M = {}

local KIND = "ai-limits.cards"
local DASH = "ai-limits.dashboard"
local DEFAULT_WIDTH = 34

type Mode = "column" | "drawer" | "pip" | "off"

local MODES: { [string]: string } = {
	column = t("Fixed column (always open)", "Coluna fixa (sempre aberta)"),
	drawer = t("Drawer (opens and closes on the shortcut)", "Gaveta (abre e fecha no atalho)"),
	pip = t("Floating card", "Cartão flutuante"),
	off = t("Off (status bar only)", "Desligado (só barra de status)"),
}
local MODE_ORDER = { "column", "drawer", "pip", "off" }
local CORNERS: { [string]: string } = {
	tl = t("top left", "superior esquerdo"),
	tr = t("top right", "superior direito"),
	bl = t("bottom left", "inferior esquerdo"),
	br = t("bottom right", "inferior direito"),
}

-- State shared with win_core.
type State = {
	-- The panel this window last found, so pane_closed can tell a user close.
	card_pane: number?,
	-- The measurement asked for after a move (see fix_width).
	width_due: number?,
	-- When this window last floated the panel itself.
	floated_at: number,
	-- Whether the panel floated when this window last placed or saw it; nil
	-- while parked or unknown.
	was_floating: boolean?,
}
local S: State = { card_pane = nil, width_due = nil, floated_at = -math.huge, was_floating = nil }

-- The width report last acted on.
local resized_from: string? = nil

-- Settings, all in kv so every window shares them.

local function mode(): Mode
	local m = tern.kv.get("mode")
	if type(m) == "string" and MODES[m] then
		return m :: Mode
	end
	return "column"
end

local function side(): Dir
	local s: Dir = if tern.kv.get("side") == "left" then "left" else "right"
	return s
end

local function width(): number
	local w = tonumber(tern.kv.get("width"))
	return if w and w >= 20 and w <= 120 then w else DEFAULT_WIDTH
end

local function corner(): Corner
	local c = tern.kv.get("corner")
	if type(c) == "string" and CORNERS[c] then
		return c :: Corner
	end
	return "br"
end

-- Whether the panel should be showing; the drawer starts closed.
local function is_open(): boolean
	local v = tern.kv.get("open")
	if type(v) == "boolean" then
		return v
	end
	return mode() ~= "drawer"
end

-- Panes and tabs.

-- Since when each block of ours has been missing from the host's live list.
local missing_since: { [number]: number } = {}

-- Whether the host half runs `pane`: a block that restarted while the host
-- half was reloading exits without running `init`, and Tern reports no exit
-- status for plugin blocks, so the host publishes its live blocks in kv.
local function alive(pane: PaneInfo): boolean
	if pane.exited ~= nil then
		return false
	end
	local live = tern.kv.get("live")
	if type(live) == "table" then
		for _, id in live do
			if id == pane.pane then
				missing_since[pane.pane] = nil
				return true
			end
		end
	end
	-- A reloading host lists nothing for a moment, and a new block registers
	-- a little after it appears: only a lasting absence means dead.
	local since = missing_since[pane.pane]
	if since == nil then
		missing_since[pane.pane] = tern.now()
		return true
	end
	return tern.now() - since < 4000
end

-- A live block of `kind`; dead ones are closed so the caller recreates them.
local function find_kind(cx: WindowCx, kind: string): PaneInfo?
	for _, pane in cx.session:panes() do
		if pane.block == kind then
			if alive(pane) then
				return pane
			end
			if pane.pane == S.card_pane then
				S.card_pane = nil
			end
			missing_since[pane.pane] = nil
			cx.layout:close(pane.pane)
		end
	end
	return nil
end

local function panel(cx: WindowCx): PaneInfo?
	local info = find_kind(cx, KIND)
	if info then
		S.card_pane = info.pane
	end
	return info
end

local function active_tab(cx: WindowCx): number?
	local focused = cx.session:focused()
	if focused == nil then
		return nil
	end
	return cx.session:tab_of(focused)
end

-- The leaf at the panel's edge of `tab`: the right- (or left-) most branch of
-- side-by-side splits, the top branch of stacked ones.
local function edge_leaf(cx: WindowCx, tab: number, s: Dir, exclude: number?): number?
	local layout = cx.session:layout(tab)
	if layout == nil then
		return nil
	end
	local function walk(t: TabTree): number?
		if t.pane ~= nil then
			return if t.pane == exclude then nil else t.pane
		end
		local first, second = t[1], t[2]
		if t.split == "right" and s == "right" then
			first, second = second, first
		end
		local found = if first then walk(first) else nil
		if found == nil and second then
			found = walk(second)
		end
		return found
	end
	return walk(layout.root)
end

-- A tiled pane of `tab` other than the panel, preferring `keep`.
local function neighbour(cx: WindowCx, card: number, tab: number?, keep: number?): number?
	if tab == nil then
		return keep
	end
	local first: number? = nil
	for _, p in cx.session:panes() do
		if p.tab == tab and p.pane ~= card and not p.floating then
			if p.pane == keep then
				return keep
			end
			if p.focused and first == nil then
				first = p.pane
			end
			first = first or p.pane
		end
	end
	return first
end

local function refocus(cx: WindowCx, pane: number, keep: number?)
	if keep ~= nil and keep ~= pane and cx.session:focused() ~= keep then
		cx.layout:focus(keep)
	end
end

-- Column width. Pane sizes reach Lua only through the block itself, and a
-- window that is covered stops reporting them, so a size read right after a
-- move can be stale. The window asks for a measurement (kv `width_req`); the
-- host answers in `panel_size` with the request it saw; only an answer to the
-- current request moves the divider.

local function fix_width(cx: WindowCx): boolean
	if S.width_due == nil then
		return false
	end
	local info = panel(cx)
	if info == nil or info.floating or info.parked then
		S.width_due = nil
		return false
	end
	local report = tern.kv.get("panel_size")
	if type(report) ~= "table" or report.seq ~= S.width_due then
		return true
	end
	local cols = tonumber(report.cols)
	if cols == nil then
		return true
	end
	local want = width()
	if math.abs(cols - want) <= 1 then
		S.width_due = nil
		return false
	end
	local key = tostring(report.seq) .. ":" .. tostring(cols)
	if resized_from ~= key then
		resized_from = key
		local inward: Dir = if side() == "right" then "left" else "right"
		cx.layout:resize(info.pane, inward, want - cols)
	end
	return true
end

local function schedule_width(left: number)
	tern.timer(400, function(later: WindowCx?)
		if later and fix_width(later :: WindowCx) and left > 1 then
			schedule_width(left - 1)
		end
	end)
end

local function start_width()
	local seq = (tonumber(tern.kv.get("width_req")) or 0) + 1
	tern.kv.set("width_req", seq)
	S.width_due = seq
	resized_from = nil
	-- A quick follow-up for the common case; the main loop keeps trying.
	schedule_width(15)
end

-- Placement.

local function place_column(cx: WindowCx, info: PaneInfo, tab: number?, keep: number?)
	local pane = info.pane
	if info.parked then
		cx.layout:unpark(pane, { focus = false })
	end
	local now = cx.session:pane(pane)
	if now and now.floating then
		cx.layout:dock(pane)
		now = cx.session:pane(pane)
	end
	if tab == nil then
		return
	end
	local s: Dir = side()
	local at_edge = now ~= nil and now.tab == tab and edge_leaf(cx, tab, s, nil) == pane
	if not at_edge then
		local target = edge_leaf(cx, tab, s, pane)
		if target then
			if not cx.layout:move(pane, target, s, { focus = false }) then
				cx.layout:move_to_tab(pane, tab, { focus = false })
				cx.layout:move(pane, target, s, { focus = false })
			end
			start_width()
		end
	end
	refocus(cx, pane, keep)
end

local function place_pip(cx: WindowCx, info: PaneInfo, tab: number?, keep: number?)
	local pane = info.pane
	if info.parked then
		cx.layout:unpark(pane, { focus = false })
	elseif tab ~= nil and info.tab ~= tab then
		cx.layout:move_to_tab(pane, tab, { focus = false })
	end
	local now = cx.session:pane(pane)
	if now == nil or not now.floating then
		-- Without an explicit owner Tern ignores the corner and picks the one
		-- nearest the block's old area.
		local over = neighbour(cx, pane, if now then now.tab else tab, keep)
		S.floated_at = tern.now()
		local ok, err = cx.layout:float(pane, over, corner(), { focus = false })
		if not ok then
			tern.log.warn("ai-limits: float failed", err)
		end
	end
	refocus(cx, pane, keep)
end

local function place(cx: WindowCx, info: PaneInfo, tab: number?, keep: number?, focus_panel: boolean)
	if mode() == "pip" then
		place_pip(cx, info, tab, if focus_panel then nil else keep)
	else
		place_column(cx, info, tab, if focus_panel then nil else keep)
	end
	S.was_floating = mode() == "pip"
	if focus_panel then
		cx.layout:focus(info.pane)
	end
end

M.KIND = KIND
M.DASH = DASH
M.MODES = MODES
M.MODE_ORDER = MODE_ORDER
M.CORNERS = CORNERS
M.S = S
M.t = t
M.mode = mode
M.side = side
M.width = width
M.corner = corner
M.is_open = is_open
M.find_kind = find_kind
M.panel = panel
M.active_tab = active_tab
M.edge_leaf = edge_leaf
M.neighbour = neighbour
M.fix_width = fix_width
M.start_width = start_width
M.place = place

return M
