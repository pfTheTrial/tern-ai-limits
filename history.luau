--!strict
-- Hourly usage samples per limit window, kept for a week in the plugin's data
-- directory (history.json). They come from whatever source fed the snapshot,
-- omp or the plugin's own helpers, so this works without omp. The dashboard
-- draws the last day as a sparkline, and a window whose recent pace would use
-- it up before its reset gets an `eta`.

local model = require("./model")

local history = {}

local HOUR = 3600 * 1000
local KEEP_MS = 7 * 24 * HOUR
local SAVE_EVERY_MS = 30 * 60 * 1000
-- How far back the pace is measured, and the least time it needs to mean
-- something.
local PACE_MS = 6 * HOUR
local MIN_PACE_MS = 45 * 60 * 1000
local SPARK_POINTS = 24

type Sample = { t: number, u: number, r: number? }

local path = tern.plugin.data .. "/history.json"
local series: { [string]: { Sample } } = {}
local saved_at = 0

do
	local ok, doc = pcall(function(): any
		if not tern.fs.exists(path) then
			return nil
		end
		return tern.json.decode(tern.fs.read(path, 4 * 1024 * 1024))
	end)
	-- Decoded tables are read-only: copy into our own.
	if ok and type(doc) == "table" then
		for key, list in doc do
			if type(key) == "string" and type(list) == "table" then
				local copy: { Sample } = {}
				for _, s in list do
					if type(s) == "table" and type(s.t) == "number" and type(s.u) == "number" then
						table.insert(copy, { t = s.t, u = s.u, r = if type(s.r) == "number" then s.r else nil })
					end
				end
				series[key] = copy
			end
		end
	end
end

local function key_of(provider: model.Provider, account: model.Account, family: model.Family, w: model.Window): string
	return provider.id .. "|" .. account.key .. "|" .. family.key .. "|" .. w.short
end

local function save(now: number)
	saved_at = now
	local ok, err = pcall(function()
		tern.fs.mkdir(tern.plugin.data)
		tern.fs.write(path, tern.json.encode(series))
	end)
	if not ok then
		tern.log.warn("ai-limits: history not saved", err)
	end
end

-- Adds this snapshot's readings: one sample per window and hour (a later
-- reading in the same hour replaces it), a week deep.
function history.record(snap: model.Snapshot, now: number)
	local appended = false
	local seen: { [string]: boolean } = {}
	for _, provider in snap.providers do
		for _, account in provider.accounts do
			for _, family in account.families do
				for _, w in family.windows do
					local key = key_of(provider, account, family, w)
					seen[key] = true
					local list = series[key]
					if list == nil then
						list = {}
						series[key] = list
					end
					local last = list[#list]
					if last and now - last.t < HOUR then
						last.u = w.used
						last.r = w.resets
					else
						table.insert(list, { t = now, u = w.used, r = w.resets })
						appended = true
					end
					while #list > 0 and list[1].t < now - KEEP_MS do
						table.remove(list, 1)
					end
				end
			end
		end
	end
	-- Windows that stopped being reported age out with the rest.
	for key, list in series do
		if not seen[key] and (#list == 0 or list[#list].t < now - KEEP_MS) then
			series[key] = nil
		end
	end
	if appended or now - saved_at >= SAVE_EVERY_MS then
		save(now)
	end
end

-- When `w` runs out at its pace over the last hours, if that comes before
-- its reset. Only samples from the same reset period count.
local function eta_of(list: { Sample }, w: model.Window, now: number): number?
	if w.used >= 1 or w.exhausted or w.resets == nil then
		return nil
	end
	local from: Sample? = nil
	for _, s in list do
		if s.t >= now - PACE_MS and (s.r == nil or s.r == w.resets) then
			from = s
			break
		end
	end
	if from == nil or now - from.t < MIN_PACE_MS then
		return nil
	end
	local rate = (w.used - from.u) / (now - from.t)
	if rate <= 0 then
		return nil
	end
	local eta = now + (1 - w.used) / rate
	return if eta < (w.resets :: number) then eta else nil
end

-- Puts the last day's samples (`spark`) and the run-out time (`eta`) on each
-- window of a freshly built snapshot.
function history.annotate(snap: model.Snapshot, now: number)
	for _, provider in snap.providers do
		for _, account in provider.accounts do
			for _, family in account.families do
				for _, w in family.windows do
					local list = series[key_of(provider, account, family, w)]
					if list and #list > 1 then
						local spark: { number } = {}
						for i = math.max(1, #list - SPARK_POINTS + 1), #list do
							table.insert(spark, math.floor(list[i].u * 1000 + 0.5) / 1000)
						end
						w.spark = spark
						w.eta = eta_of(list, w, now)
					end
				end
			end
		end
	end
end

return history
