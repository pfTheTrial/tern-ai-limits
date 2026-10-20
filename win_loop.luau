--!strict
-- AI Limits, window half: the main loop (heartbeat for the host, summary
-- refresh, panel placement) and the watch on the panel's sliders button.
-- Loaded by window.luau's last boot timer, after win_core and win_alerts.

local core = require("./win_core")
local alerts = require("./win_alerts")

local M = {}

-- Focus, pane and tab events place the panel at once; the loop only catches
-- what no event reports (a parked panel dealt back, a host reload).
local LOOP_MS = 5000
local BEAT_MS = 10 * 1000

-- The panel's sliders button (a host block) can only write kv.
local config_seen: any = nil
local function watch_config(cx: WindowCx?)
	local req = tern.kv.get("config_request")
	if req ~= config_seen then
		config_seen = req
		if cx then
			require("./win_settings").configure(cx :: WindowCx)
		end
	end
	tern.timer(300, watch_config)
end

local beat_at = -math.huge
-- window.luau's: the hook a budget overrun left unfinished, if any.
local stuck_hook: () -> string? = function(): string?
	return nil
end

local function loop(cx: WindowCx?)
	local now = tern.now()
	local stuck = stuck_hook()
	if stuck then
		-- Tern keeps that hook off until a reload; the host half does it.
		tern.kv.set("window_stuck", { hook = stuck, at = now })
	end
	if now - beat_at >= BEAT_MS then
		-- The host half reloads the plugin when this stops moving.
		beat_at = now
		local beat = tern.kv.get("window_beat")
		tern.kv.set("window_beat", (if type(beat) == "number" then beat else 0) + 1)
	end
	alerts.reload_summary()
	if cx then
		-- Placement reads kv and walks the layout: its own budget, apart from
		-- the beat and the summary check above.
		tern.timer(0, function(later: WindowCx?)
			if later then
				core.tick(later :: WindowCx)
			end
		end)
	end
	tern.timer(LOOP_MS, loop)
end

-- `config_at_load` is the sliders request window.luau saw at load, so a
-- press made while the modules were loading still opens the settings.
function M.start(config_at_load: any, stuck: () -> string?)
	config_seen = config_at_load
	stuck_hook = stuck
	tern.timer(0, loop)
	tern.timer(300, watch_config)
end

return M
