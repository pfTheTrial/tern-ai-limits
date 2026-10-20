--!strict
-- AI Limits, window half: what each palette command does. window.luau
-- registers the commands (titles, icons, keys) at load and calls in here by
-- id, so the entry chunk stays small enough to compile under its 50 ms
-- budget. Loaded from a boot timer; the pickers (win_settings, win_filters)
-- still load in the first command that needs them.

local M: { [string]: (WindowCx) -> () } = {}

local function core(): any
	return require("./win_core")
end

local function settings(): any
	return require("./win_settings")
end

local function filters(): any
	return require("./win_filters")
end

function M.toggle(cx: WindowCx)
	core().toggle(cx)
end

function M.show(cx: WindowCx)
	local c = core()
	c.show(cx, c.mode() == "drawer")
end

function M.hide(cx: WindowCx)
	core().hide(cx)
end

function M.dashboard(cx: WindowCx)
	core().open_dashboard(cx)
end

function M.peek(cx: WindowCx)
	require("./win_alerts").peek(cx, core().open_dashboard)
end

for _, id in { "configure", "refresh", "mode", "side", "width", "corner", "pip_show", "status", "poll", "sources", "keys", "alerts", "lang" } do
	M[id] = function(cx: WindowCx)
		settings()[id](cx)
	end
end

for _, id in { "providers", "windows", "accounts", "order", "density" } do
	M[id] = function(cx: WindowCx)
		filters()[id](cx)
	end
end

return M
