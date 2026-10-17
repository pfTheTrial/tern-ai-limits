--!strict
-- AI Limits, window half: the side panel's placement. Loaded by window.luau
-- from a timer, so compiling it gets its own 50 ms budget.

local M = {}

local KIND = "ai-limits.cards"
local DASH = "ai-limits.dashboard"
local DEFAULT_WIDTH = 34

type Mode = "column" | "drawer" | "pip" | "off"

local MODES: { [string]: string } = {
	column = "Coluna fixa (sempre aberta)",
	drawer = "Gaveta (abre e fecha no atalho)",
	pip = "Cartão flutuante",
	off = "Desligado (só barra de status)",
}
local MODE_ORDER = { "column", "drawer", "pip", "off" }
local CORNERS: { [string]: string } = {
	tl = "superior esquerdo",
	tr = "superior direito",
	bl = "inferior esquerdo",
	br = "inferior direito",
}

-- The panel this window last found, so pane_closed can tell a user close.
local card_pane: number? = nil
-- Where focus goes back to when the drawer closes.
local drawer_return: number? = nil
-- Width fixing after a move: the measurement asked for, and the report last
-- acted on.
local width_due: number? = nil
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
			if pane.pane == card_pane then
				card_pane = nil
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
		card_pane = info.pane
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
	if width_due == nil then
		return false
	end
	local info = panel(cx)
	if info == nil or info.floating or info.parked then
		width_due = nil
		return false
	end
	local report = tern.kv.get("panel_size")
	if type(report) ~= "table" or report.seq ~= width_due then
		return true
	end
	local cols = tonumber(report.cols)
	if cols == nil then
		return true
	end
	local want = width()
	if math.abs(cols - want) <= 1 then
		width_due = nil
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
	width_due = seq
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

-- When this window last floated the panel itself.
local floated_at = -math.huge

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
		floated_at = tern.now()
		local ok, err = cx.layout:float(pane, over, corner(), { focus = false })
		if not ok then
			tern.log.warn("ai-limits: float failed", err)
		end
	end
	refocus(cx, pane, keep)
end

-- Whether the panel floated when this window last placed or saw it; nil while
-- parked or unknown.
local was_floating: boolean? = nil

local function place(cx: WindowCx, info: PaneInfo, tab: number?, keep: number?, focus_panel: boolean)
	if mode() == "pip" then
		place_pip(cx, info, tab, if focus_panel then nil else keep)
	else
		place_column(cx, info, tab, if focus_panel then nil else keep)
	end
	was_floating = mode() == "pip"
	if focus_panel then
		cx.layout:focus(info.pane)
	end
end

local function show(cx: WindowCx, focus_panel: boolean)
	tern.kv.set("open", true)
	if mode() == "off" then
		return
	end
	-- The "Limites" tab already shows everything; the panel comes back on
	-- the next tab (ensure places it there).
	local dash = find_kind(cx, DASH)
	if dash and dash.tab ~= nil and dash.tab == active_tab(cx) then
		return
	end
	local keep = cx.session:focused()
	local info = panel(cx)
	if info then
		if keep == info.pane then
			keep = nil
		end
		if focus_panel then
			drawer_return = keep
		end
		place(cx, info, active_tab(cx), keep, focus_panel)
		return
	end
	local tab = active_tab(cx)
	local target = if tab then edge_leaf(cx, tab, side(), nil) else keep
	if target == nil then
		return
	end
	local pane = cx.layout:split(target, side(), { block = KIND }, { focus = false })
	if pane == nil then
		cx:toast("error", "AI Limits não carregou neste host", "Rode `tern plugin list` para ver o erro.")
		return
	end
	card_pane = pane
	if focus_panel then
		drawer_return = keep
	end
	start_width()
	-- The new pane reaches this window's replica after the call returns.
	tern.timer(200, function(later: WindowCx?)
		local lcx = later :: WindowCx
		local found = panel(lcx)
		if found then
			place(lcx, found, active_tab(lcx), keep, focus_panel)
		end
	end)
end

local function hide(cx: WindowCx)
	tern.kv.set("open", false)
	local info = panel(cx)
	if info and not info.parked then
		local back = drawer_return
		drawer_return = nil
		cx.layout:park(info.pane)
		if back and cx.session:pane(back) then
			cx.layout:focus(back)
		end
	end
end

local function shown_here(cx: WindowCx, info: PaneInfo?): boolean
	return info ~= nil and not info.parked and info.tab == active_tab(cx)
end

local function toggle(cx: WindowCx)
	if mode() == "off" then
		tern.kv.set("mode", "drawer")
	end
	local info = panel(cx)
	if is_open() and shown_here(cx, info) then
		hide(cx)
	else
		show(cx, mode() == "drawer")
	end
end

-- Keeps the panel where the mode says: recreated when missing, in the active
-- tab, at its edge (or floating in its corner).
-- nil until this window has seen the panel once.
local was_parked: boolean? = nil
-- Until when a closed panel is left alone (see M.pane_closed).
local closing_until = -math.huge

local function ensure(cx: WindowCx)
	local m = mode()
	local info = panel(cx)
	-- Tern shows a parked panel as a chip at the bottom of the window; clicking
	-- it unparks the pane, which means "open", not something to park again.
	local unparked = was_parked == true and info ~= nil and not info.parked
	-- Parking it from Tern's own pane menu means "hide": do not deal it back.
	local parked_by_user = was_parked == false and info ~= nil and info.parked == true and is_open()
	was_parked = if info then info.parked == true else nil
	if parked_by_user then
		tern.kv.set("open", false)
	end
	if unparked and not is_open() then
		if m == "off" then
			tern.kv.set("mode", "drawer")
			m = "drawer"
		end
		tern.kv.set("open", true)
	end
	-- The pane header's float and dock buttons pick the mode, so the next
	-- placement does not undo them.
	if info and not info.parked and not unparked and was_floating ~= nil and m ~= "off" and is_open() then
		local floating = info.floating == true
		if floating ~= was_floating and floating ~= (m == "pip") then
			m = if floating then "pip" else "column"
			tern.kv.set("mode", m)
			local layout = if floating and info.tab then cx.session:layout(info.tab) else nil
			if layout then
				for _, float in layout.floats do
					if float.pane == info.pane then
						tern.kv.set("corner", float.corner)
					end
				end
			end
		end
	end
	if info then
		was_floating = if info.parked then nil else info.floating == true
	end
	if m == "off" or not is_open() then
		if info and not info.parked then
			cx.layout:park(info.pane)
		end
		return
	end
	if info == nil then
		-- pane_closed is still deciding whether the user closed it.
		if tern.now() < closing_until then
			return
		end
		show(cx, false)
		return
	end
	local tab = active_tab(cx)
	if tab == nil then
		return
	end
	-- The "Limites" tab already shows everything.
	local dash = find_kind(cx, DASH)
	if dash and dash.tab == tab then
		return
	end
	local focused = cx.session:focused()
	local keep = focused
	if keep == info.pane then
		keep = neighbour(cx, info.pane, info.tab, nil)
	end
	if m == "pip" then
		if info.parked or info.tab ~= tab or not info.floating then
			place(cx, info, tab, keep, false)
			return
		end
		-- Right after this window floats the panel, Tern may land it in another
		-- corner: move it to ours. Later, another corner means the user dragged
		-- it there, and that becomes the saved corner.
		local layout = cx.session:layout(tab)
		if layout then
			for _, float in layout.floats do
				if float.pane == info.pane and float.corner ~= corner() then
					if tern.now() - floated_at < 3000 then
						cx.layout:float(info.pane, float.over, corner(), { focus = false })
					else
						tern.kv.set("corner", float.corner)
					end
				end
			end
		end
		return
	end
	if info.parked or info.floating or info.tab ~= tab or edge_leaf(cx, tab, side(), nil) ~= info.pane then
		place(cx, info, tab, keep, false)
	end
end

local function safe_ensure(cx: WindowCx)
	local ok, err = pcall(function(): any
		ensure(cx)
		return nil
	end)
	if not ok then
		tern.log.warn("ai-limits: ensure failed", err)
	end
end

-- The "Limites" tab.

local function open_dashboard(cx: WindowCx)
	local dash = find_kind(cx, DASH)
	if dash then
		if dash.parked then
			cx.layout:unpark(dash.pane)
		end
		cx.layout:focus(dash.pane)
		return
	end
	local tab, err = cx.layout:tab({ name = "Limites", launch = { block = DASH } })
	if tab == nil then
		cx:toast("error", "Não consegui abrir a aba Limites", err)
	end
end

-- Closing the panel by hand hides it until the next show or toggle. A window
-- that is going down (Tern quitting or crashing) also reports its panes
-- closed, so decide a moment later, when no panel of ours is left.
function M.pane_closed(ev: PaneEvent, cx: WindowCx)
	if card_pane == nil or ev.pane ~= card_pane or cx.session:pane(ev.pane) ~= nil then
		return
	end
	card_pane = nil
	closing_until = tern.now() + 1500
	tern.timer(1500, function(later: WindowCx?)
		if later and find_kind(later :: WindowCx, KIND) == nil then
			tern.kv.set("open", false)
		end
	end)
end

local width_checked = false

function M.tick(cx: WindowCx)
	safe_ensure(cx)
	if not width_checked then
		-- Check a column left from before a reload once.
		width_checked = true
		if mode() == "column" or mode() == "drawer" then
			start_width()
		end
	end
	fix_width(cx)
end

M.MODES = MODES
M.MODE_ORDER = MODE_ORDER
M.CORNERS = CORNERS
M.mode = mode
M.side = side
M.width = width
M.corner = corner
M.panel = panel
M.neighbour = neighbour
M.start_width = start_width
M.show = show
M.hide = hide
M.toggle = toggle
M.safe_ensure = safe_ensure
M.open_dashboard = open_dashboard

return M
