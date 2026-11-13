-- Run from the repository root: luajit -joff tools/benchmark_sync.lua FIXTURE [REPEATS]
local fixture = dofile(assert(arg[1], "QuestieDB fixture path required"))
local repeats = tonumber(arg[2]) or 3
local bitMode = arg[3] or "native"
local linkLatency = tonumber(arg[5]) or 0
assert(linkLatency >= 0, "one-way latency cannot be negative")
assert(repeats >= 1 and repeats == math.floor(repeats), "repeats must be a positive integer")
assert(bitMode == "native" or bitMode == "portable", "bit mode must be native or portable")
local network = require("tests.support.sync_network")
local clock = os.clock
local profiler = { active = false, stack = {} }
local function wrap(client, stage, fn)
	return function(...)
		if not profiler.active then
			return fn(...)
		end
		local frame = { children = 0 }
		local stack = profiler.stack
		stack[#stack + 1] = frame
		local started = clock()
		local a, b, c, d = fn(...)
		local elapsed = clock() - started
		stack[#stack] = nil
		if stack[#stack] then
			stack[#stack].children = stack[#stack].children + elapsed
		end
		local row = client.cpu[stage] or { seconds = 0, calls = 0 }
		client.cpu[stage] = row
		local exclusive = elapsed - frame.children
		row.seconds, row.calls = row.seconds + exclusive, row.calls + 1
		if stage ~= "transport_mock" then
			local time = client.env.GetTime()
			client.cpuAt[time] = (client.cpuAt[time] or 0) + exclusive * 1000
		end
		return a, b, c, d
	end
end
local privateStages = {
	collectQuests = "quest_scan",
	render = "render_preparation",
	scanQuests = "activity_and_scan_glue",
	recordActivity = "activity",
	broadcast = "sender_queue",
	pump = "sender_queue",
	send = "send_glue",
}
local function instrument(c, env)
	c.cpu, c.cpuAt, c.scope = {}, {}, {}
	local visited, wrapped = {}, {}
	local function measured(fn, stage)
		if not wrapped[fn] then
			wrapped[fn] = wrap(c, stage, fn)
		end
		return wrapped[fn]
	end
	for _, entry in ipairs({
		{
			env.QuestWithFriends.Core,
			{ encode = "encode", decode = "decode", compare = "comparison", sortGroups = "comparison" },
		},
		{
			env.QuestWithFriends.Sync,
			{
				digest = "digest",
				snapshot = "sync_state",
				readSnapshot = "sync_state",
				patch = "patch_build",
				apply = "patch_apply",
			},
		},
		{ env.QuestWithFriends.ItemStock, { annotate = "item_stock" } },
	}) do
		for name, stage in pairs(entry[2]) do
			entry[1][name] = measured(entry[1][name], stage)
		end
	end
	local function visit(fn)
		if visited[fn] then
			return
		end
		visited[fn] = true
		for i = 1, 100 do
			local name, value = debug.getupvalue(fn, i)
			if not name then
				break
			end
			if not c.scope[name] then
				local position = i
				c.scope[name] = function()
					local _, current = debug.getupvalue(fn, position)
					return current
				end
			end
			if type(value) == "function" and debug.getinfo(value, "S").source:match("^@src/") then
				visit(value)
				if privateStages[name] then
					debug.setupvalue(fn, i, measured(value, privateStages[name]))
				end
			elseif name == "delta" and type(value) == "table" then
				for key, method in pairs(value) do
					if type(method) == "function" then
						visit(method)
						if key == "materialize" then
							value[key] = measured(method, "fragmentation")
						end
					end
				end
			end
		end
	end
	visit(c.event)
	visit(env.SlashCmdList.QUESTWITHFRIENDS)
	c.event = wrap(c, "runtime_other", c.event)
	env.C_ChatInfo.SendAddonMessage = wrap(c, "transport_mock", env.C_ChatInfo.SendAddonMessage)
end
local function clone(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = clone(v)
	end
	return copy
end
local function count(values)
	local n = 0
	for _ in pairs(values) do
		n = n + 1
	end
	return n
end
local function configure(c, env, index)
	env.bit = bitMode == "native" and require("bit") or false
	env.bit32 = false
	-- Fixed offsets avoid machine addresses/clock time changing heartbeat phases between runs.
	env.tostring = function(value)
		return type(value) == "table" and "benchmark-client-" .. index or tostring(value)
	end
	env.math = setmetatable({
		random = function()
			return index
		end,
	}, { __index = math })
	env.GetQuestUiMapID = function(id)
		return fixture.quests[id].zoneID
	end
	env.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 4
	local bags, byID = {}, {}
	env.C_Container = {
		GetContainerNumSlots = function(bag)
			if bag == 0 then
				bags, byID = {}, {}
				for _, quest in pairs(c.quests) do
					for _, objective in ipairs(quest.objectives) do
						if objective.type == "item" and objective.numFulfilled > 0 and not byID[objective.targetID] then
							local item = {
								itemID = objective.targetID,
								itemName = objective.text,
								stackCount = objective.numFulfilled,
								isBound = false,
								isLocked = false,
							}
							bags[#bags + 1] = item
							byID[item.itemID] = item
						end
					end
				end
			end
			return 16
		end,
		GetContainerItemInfo = function(bag, slot)
			return bags[bag * 16 + slot]
		end,
	}
	local tradeable = { [814] = true, [729] = true, [730] = true, [731] = true, [1080] = true, [1081] = true }
	env.C_Item = {
		GetItemInfo = function(id)
			return byID[id] and byID[id].itemName,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				tradeable[id] and 0 or 1
		end,
	}
end
local function setup(minor, mixed)
	local n = network(
		"forever",
		4,
		mixed and { 2, 2, 2, 1 } or { minor, minor, minor, minor },
		{ debug = false, wrap = wrap, instrument = instrument, configure = configure, latency = linkLatency }
	)
	for index, c in ipairs(n.clients) do
		c.party = false
		for _, id in ipairs(fixture.history) do
			local q = clone(fixture.quests[id])
			q.state = "ready"
			for _, o in ipairs(q.objectives) do
				o.numFulfilled = o.numRequired
			end
			c.quests = { [id] = q }
			c:fire("QUEST_LOG_UPDATE")
			c:fire("QUEST_TURNED_IN", id)
		end
		c.quests = {}
		for position, id in ipairs(fixture.active) do
			local q = clone(fixture.quests[id])
			q.state = "active"
			for slot, o in ipairs(q.objectives) do
				o.numFulfilled = (index + position + slot) % o.numRequired
			end
			c.quests[id] = q
		end
		c.party = true
	end
	return n
end
local function ready(n)
	for _, c in ipairs(n.clients) do
		for _, name in ipairs({ "outgoing", "queuedSnapshot", "requestPending", "scheduled" }) do
			if c.scope[name]() then
				return false
			end
		end
		local delta = c.scope.delta()
		if delta.suspended or delta.capabilityPending or delta.heartbeatPending then
			return false
		end
		local peers = c.scope.peers()
		if count(peers) ~= 3 then
			return false
		end
		for _, peer in pairs(peers) do
			if not peer.quests or peer.status or peer.pending or peer.partialPending then
				return false
			end
			assert(count(peer.quests) == 50, "expected 20 active + 30 retained completed records")
		end
	end
	return true
end
local function untilReady(n, limit, predicate)
	local deadline = n.time + (limit or 180)
	while n.time < deadline do
		if predicate() then
			return
		end
		n:advance(0.05)
	end
	error("benchmark did not converge at " .. n.time)
end
local function reset(n)
	for _, c in ipairs(n.clients) do
		c.cpu, c.cpuAt, c.attempts = {}, {}, {}
	end
end
local function update(n, players, quests, monotonic)
	local expected = {}
	for i = 1, players do
		local c = n.clients[i]
		expected[c.sender] = {}
		for slot = 1, quests do
			local id = ({ 9, 38, 152, 116 })[slot]
			local objectiveIndex = 1
			if monotonic then
				local found = false
				for _, candidate in ipairs(fixture.active) do
					for j, objective in ipairs(c.quests[candidate].objectives) do
						if not found and objective.numFulfilled < objective.numRequired then
							id, objectiveIndex, found = candidate, j, true
						end
					end
				end
				assert(found, "workload exhausted active objectives")
			end
			local o = c.quests[id].objectives[objectiveIndex]
			if monotonic then
				o.numFulfilled = o.numFulfilled + 1
			elseif o.numRequired == 1 then
				o.numFulfilled = 1 - o.numFulfilled
			else
				o.numFulfilled = (o.numFulfilled + 1) % o.numRequired
			end
			local complete = true
			for _, objective in ipairs(c.quests[id].objectives) do
				if objective.numFulfilled < objective.numRequired then
					complete = false
				end
			end
			c.quests[id].state = complete and "ready" or "active"
			expected[c.sender][id] = { have = o.numFulfilled, state = c.quests[id].state, objective = objectiveIndex }
		end
		c:fire("QUEST_LOG_UPDATE")
	end
	return expected
end
local function matches(n, expected)
	for _, c in ipairs(n.clients) do
		local peers = c.scope.peers()
		for sender, changes in pairs(expected) do
			if c.sender ~= sender then
				local peer = peers[sender]
				for id, want in pairs(changes) do
					local q = peer and peer.quests and peer.quests[id]
					if not q or q.objectives[want.objective].have ~= want.have or q.state ~= want.state then
						return false
					end
				end
			end
		end
	end
	return true
end
local function summarize(n, start, finish)
	local result = {
		duration_s = finish - start,
		cpu_ms = {},
		calls = {},
		messages = {},
		bytes = 0,
		sender_last_data_s = {},
		client_cpu_ms = {},
		peak_same_time_ms = {},
	}
	local first, last
	for _, c in ipairs(n.clients) do
		result.client_cpu_ms[c.sender] = 0
		for _, ms in pairs(c.cpuAt) do
			result.peak_same_time_ms[c.sender] = math.max(result.peak_same_time_ms[c.sender] or 0, ms)
		end
		for stage, row in pairs(c.cpu) do
			if stage ~= "transport_mock" then
				result.client_cpu_ms[c.sender] = result.client_cpu_ms[c.sender] + row.seconds * 1000
				result.cpu_ms[stage] = (result.cpu_ms[stage] or 0) + row.seconds * 1000
				result.calls[stage] = (result.calls[stage] or 0) + row.calls
			end
		end
		for _, attempt in ipairs(c.attempts) do
			local kind = assert(attempt.message:match("^%d+%.%d+:([A-Z])"))
			result.messages[kind] = (result.messages[kind] or 0) + 1
			result.bytes = result.bytes + #attempt.message
			if kind == "D" or kind == "P" then
				first = math.min(first or attempt.time, attempt.time)
				last = math.max(last or attempt.time, attempt.time)
				result.sender_last_data_s[c.sender] = attempt.time - start
			end
		end
	end
	result.total_cpu_ms = 0
	for _, ms in pairs(result.cpu_ms) do
		result.total_cpu_ms = result.total_cpu_ms + ms
	end
	result.first_data_s = first and first - start or nil
	result.data_span_s = last and last - first or nil
	return result
end
local function run(minor, scenario, mixed)
	local n = setup(minor, mixed)
	if scenario ~= "cold_party" then
		n:join()
		untilReady(n, 180, function()
			return ready(n)
		end)
		n:advance(1)
	end
	reset(n)
	profiler.active = true
	local start = n.time
	local finish
	if scenario == "cold_party" then
		n:join()
		untilReady(n, 180, function()
			return ready(n)
		end)
		finish = n.time
	elseif scenario == "idle_300s" then
		n:advance(300)
		finish = n.time
	elseif scenario == "adventure_300s" or scenario == "rapid_61s" then
		local interval, duration = scenario == "rapid_61s" and 1 or 10, scenario == "rapid_61s" and 61 or 300
		local expected
		local latencies = {}
		for _ = 1, duration / interval do
			local eventAt = n.time
			expected = update(n, 4, 1, scenario == "adventure_300s")
			local observed = false
			n.afterTimer = function()
				if not observed and matches(n, expected) then
					latencies[#latencies + 1] = n.time - eventAt
					observed = true
				end
			end
			n:advance(interval)
		end
		n.afterTimer = nil
		untilReady(n, 180, function()
			return matches(n, expected) and ready(n)
		end)
		finish = n.time
		local result = summarize(n, start, finish)
		result.event_batches = duration / interval
		result.cached_state_matched_before_next_batch = #latencies
		result.data_messages_during_workload = 0
		for _, client in ipairs(n.clients) do
			for _, attempt in ipairs(client.attempts) do
				if attempt.time < start + duration and attempt.message:match("^%d+%.%d+:[DP]:") then
					result.data_messages_during_workload = result.data_messages_during_workload + 1
				end
			end
		end
		result.latencies_s = latencies
		result.workload_s = duration
		profiler.active = false
		return result
	else
		if scenario == "during_checkpoint" then
			n.clients[1].env.SlashCmdList.QUESTWITHFRIENDS("")
			n:advance(2.5)
			reset(n)
			start = n.time
		end
		local expected = update(
			n,
			(scenario == "single_player" or scenario == "during_checkpoint") and 1 or 4,
			scenario == "four_quests" and 4 or 1
		)
		local observed
		n.afterTimer = function()
			if not observed and matches(n, expected) then
				observed = n.time
			end
		end
		untilReady(n, 180, function()
			return observed ~= nil
		end)
		n.afterTimer = nil
		finish = assert(observed)
	end
	profiler.active = false
	local result = summarize(n, start, finish)
	result.local_payload_bytes = {}
	for _, client in ipairs(n.clients) do
		result.local_payload_bytes[client.sender] = #client.env.QuestWithFriends.Core.encode(client.scope.localQuests())
	end
	return result
end
local function json(value)
	local t = type(value)
	if t == "nil" then
		return "null"
	end
	if t == "boolean" or t == "number" then
		return tostring(value)
	end
	if t == "string" then
		return '"'
			.. value:gsub('[%z\1-\31\\"]', function(c)
				return c == '"' and '\\"' or c == "\\" and "\\\\" or string.format("\\u%04x", c:byte())
			end)
			.. '"'
	end
	local keys, parts = {}, {}
	for k in pairs(value) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, k in ipairs(keys) do
		parts[#parts + 1] = json(tostring(k)) .. ":" .. json(value[k])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end
local jitRuntime = rawget(_G, "jit")
local output = {
	source = fixture.source,
	revision = fixture.revision,
	interpreter = _VERSION,
	jit = jitRuntime and jitRuntime.status() or false,
	jit_version = jitRuntime and jitRuntime.version,
	repeats = repeats,
	bit_mode = bitMode,
	one_way_latency_s = linkLatency,
	results = {},
}
for _, minor in ipairs({ 1, 2 }) do
	local cases = {}
	output.results["1." .. minor] = cases
	for _, scenario in
		ipairs(arg[4] and { arg[4] } or {
			"cold_party",
			"single_player",
			"all_players",
			"four_quests",
			"during_checkpoint",
			"idle_300s",
			"adventure_300s",
			"rapid_61s",
		})
	do
		local runs = {}
		for i = 1, repeats do
			io.stderr:write("1.", minor, " ", scenario, " ", i, "/", repeats, "\n")
			runs[i] = run(minor, scenario, false)
		end
		cases[scenario] = runs
	end
end
output.mixed = run(2, "all_players", true)
print(json(output))
