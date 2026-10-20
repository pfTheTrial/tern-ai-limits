--!strict
-- AI Limits, window half: showing, hiding and keeping the side panel in place,
-- and the "Limites" tab. The helpers it uses live in win_place, which
-- window.luau loads in an earlier timer call, so compiling each file gets its
-- own 50 ms budget.

local P = require("./win_place")

local M = {}

local KIND = P.KIND
local DASH = P.DASH
local S = P.S
local t = P.t
local mode = P.mode
local side = P.side
local corner = P.corner
local is_open = P.is_open
local find_kind = P.find_kind
local panel = P.panel
local active_tab = P.active_tab
local edge_leaf = P.edge_leaf
local neighbour = P.neighbour
local fix_width = P.fix_width
local start_width = P.start_width
local place = P.place

-- Where focus goes back to when the drawer closes.
local drawer_return: number? = nil

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
		cx:toast("error", t("AI Limits did not load on this host", "AI Limits não carregou neste host"), t("Run `tern plugin list` to see the error.", "Rode `tern plugin list` para ver o erro."))
		return
	end
	S.card_pane = pane
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

-- Rebuilding a tab's splits (another plugin regrouping its panes, a pane
-- opened or closed) hands the column a new share; measure it again when the
-- tab's panes change. Ratios are left out of the key, so a column the user
-- dragged wider stays that way.
local trees_seen: { [number]: string } = {}

local function tree_key(tree: TabTree): string
	if tree.pane then
		return tostring(tree.pane)
	end
	local a, b = tree[1], tree[2]
	return "(" .. (tree.split or "") .. " " .. (if a then tree_key(a) else "") .. " " .. (if b then tree_key(b) else "") .. ")"
end

local function watch_tree(cx: WindowCx, tab: number)
	local layout = cx.session:layout(tab)
	if layout == nil then
		return
	end
	local key = tree_key(layout.root)
	local seen = trees_seen[tab]
	trees_seen[tab] = key
	if seen ~= nil and seen ~= key and S.width_due == nil then
		start_width()
	end
end

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
	if info and not info.parked and not unparked and S.was_floating ~= nil and m ~= "off" and is_open() then
		local floating = info.floating == true
		if floating ~= S.was_floating and floating ~= (m == "pip") then
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
		S.was_floating = if info.parked then nil else info.floating == true
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
					if tern.now() - S.floated_at < 3000 then
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
	else
		watch_tree(cx, tab)
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
	local tab, err = cx.layout:tab({ name = t("Limits", "Limites"), launch = { block = DASH } })
	if tab == nil then
		cx:toast("error", t("Could not open the Limits tab", "Não consegui abrir a aba Limites"), err)
	end
end

-- Closing the panel by hand hides it until the next show or toggle. A window
-- that is going down (Tern quitting or crashing) also reports its panes
-- closed, so decide a moment later, when no panel of ours is left.
function M.pane_closed(ev: PaneEvent, cx: WindowCx)
	if S.card_pane == nil or ev.pane ~= S.card_pane or cx.session:pane(ev.pane) ~= nil then
		return
	end
	S.card_pane = nil
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

M.MODES = P.MODES
M.MODE_ORDER = P.MODE_ORDER
M.CORNERS = P.CORNERS
M.mode = mode
M.side = side
M.width = P.width
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
