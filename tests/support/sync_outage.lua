local network = require("tests.support.sync_network")
local hasNativeBits, nativeBits = pcall(require, "bit")

local function run(variant)
	assert(variant == "disconnect" or variant == "throttle" or variant == "combined", "unknown outage variant")
	local disconnect = variant ~= "throttle"
	local throttling = variant ~= "disconnect"
	local n = network("forever", 4, { 3, 3, 3, 3 }, {
		configure = function(c, env, index)
			env.bit = hasNativeBits and nativeBits or false
			env.bit32 = false
			env.tostring = function(value)
				return type(value) == "table" and ("outage-" .. index .. "-" .. c.incarnation) or tostring(value)
			end
			env.math = setmetatable({
				random = function()
					return index
				end,
			}, { __index = math })
		end,
	})
	local result = { variant = variant, phases = {}, converged = false }
	local expected = {}
	local function current()
		for _, c in ipairs(n.clients) do
			if not c.view.complete or c.view.updating then
				return false
			end
			local seen = {}
			for _, group in ipairs(c.view.groups) do
				if expected[group.questID] == group.title then
					seen[group.questID] = true
				end
			end
			for id in pairs(expected) do
				if not seen[id] then
					return false
				end
			end
		end
		return true
	end
	local function measure(name, action)
		local phase = { name = name, started = n.time, clients = {} }
		local before = {}
		for i, c in ipairs(n.clients) do
			before[i] = { attempts = #c.attempts, logs = #c.logs }
		end
		action()
		phase.duration = n.time - phase.started
		for i, c in ipairs(n.clients) do
			local row = {
				full = 0,
				partial = 0,
				unchanged = 0,
				requests = 0,
				repairs = 0,
				rejected = 0,
				refreshing = 0,
				timeouts = 0,
			}
			for j = before[i].attempts + 1, #c.attempts do
				local attempt = c.attempts[j]
				if attempt.result ~= 0 then
					row.rejected = row.rejected + 1
				elseif attempt.message == "1.3:H" then
					row.requests = row.requests + 1
				elseif attempt.message:match("^1%.3:R:") then
					row.repairs = row.repairs + 1
				end
			end
			for j = before[i].logs + 1, #c.logs do
				local log = c.logs[j]
				if log.message == "Submitted quest snapshot" then
					local key = log.data.kind == "D" and "full" or "partial"
					row[key] = row[key] + 1
					if key == "full" and log.data.changeReason == "unchanged" then
						row.unchanged = row.unchanged + 1
					end
				elseif
					log.message == "Displayed sync status changed"
					and log.data.status == "refreshing"
					and log.data.sender ~= n.clients[4].sender
				then
					row.refreshing = row.refreshing + 1
				elseif log.message == "Quest snapshot timed out; requesting refresh" then
					row.timeouts = row.timeouts + 1
				end
			end
			phase.clients[i] = row
		end
		result.phases[#result.phases + 1] = phase
	end
	for i, c in ipairs(n.clients) do
		for slot = 1, 16 do
			c.quests[i * 1000 + slot] = {
				title = "Player " .. i .. " errand " .. slot .. " " .. string.rep("x", 90),
				state = "active",
				objectives = { { text = "Supplies", numFulfilled = 0, numRequired = 100, type = "item" } },
			}
		end
		expected[i * 1000 + 1] = c.quests[i * 1000 + 1].title
	end
	n:join()
	n:advance(60)
	assert(current(), "initial party did not synchronize")
	result.baselineParts = {}
	for i, c in ipairs(n.clients) do
		for _, log in ipairs(c.logs) do
			if log.message == "Submitted quest snapshot" and log.data.kind == "D" then
				result.baselineParts[i] = log.data.parts
				break
			end
		end
	end

	local isolated = n.clients[4]
	local reject = false
	for i = 1, 3 do
		local attempts = 0
		n.clients[i].sendResult = function()
			if reject then
				attempts = attempts + 1
				return attempts % 2 == 1 and 5 or 0
			end
			return 0
		end
	end
	measure("silent", function()
		if disconnect then
			n.deliver = function(from, to)
				return from ~= isolated and to ~= isolated
			end
		end
		n:advance(40)
		reject = throttling
		n:advance(70)
	end)
	result.cachedWhileSilent = true
	result.staleWhileSilent = true
	for i = 1, 3 do
		local c = n.clients[i]
		local cached, stale = false, false
		for _, group in ipairs(c.view.groups) do
			cached = cached or (group.questID == 4001 and group.title == expected[4001])
		end
		for _, notice in ipairs(c.view.notices) do
			stale = stale or (notice.player == isolated.sender and notice.reason == "stale")
		end
		result.cachedWhileSilent = result.cachedWhileSilent and cached
		result.staleWhileSilent = result.staleWhileSilent and stale
	end
	measure("offline", function()
		if disconnect then
			for i = 1, 3 do
				local c = n.clients[i]
				c.offline[4] = true
				c:fire("UNIT_CONNECTION", "party3", false)
			end
		end
		n:advance(50)
	end)

	result.offlineWhileOffline = true
	for i = 1, 3 do
		local offline = false
		for _, notice in ipairs(n.clients[i].view.notices) do
			offline = offline or (notice.player == isolated.sender and notice.reason == "offline")
		end
		result.offlineWhileOffline = result.offlineWhileOffline and offline
	end

	local reconnectAt = n.time
	n.afterTimer = function()
		if not result.convergenceSeconds and current() then
			result.convergenceSeconds = n.time - reconnectAt
		end
	end
	measure("reconnect", function()
		n.deliver = nil
		if disconnect then
			n:reload(4)
			for i = 1, 3 do
				local c = n.clients[i]
				c.offline[4] = nil
				c:fire("UNIT_CONNECTION", "party3", true)
			end
		end
		for i, c in ipairs(n.clients) do
			local id = i * 1000 + 1
			expected[id] = "Recovered player " .. i
			c.quests[id].title = expected[id]
			c:fire("QUEST_LOG_UPDATE")
		end
		n:advance(30)
	end)
	measure("drain", function()
		reject = false
		for _ = 1, 120 do
			if current() then
				break
			end
			n:advance(1)
		end
	end)
	n.afterTimer = nil
	result.converged = current()
	assert(result.converged, "party did not converge after fault removal")
	measure("update", function()
		expected[1001] = "After recovery"
		n.clients[1].quests[1001].title = expected[1001]
		n.clients[1]:fire("QUEST_LOG_UPDATE")
		n:advance(10)
	end)
	assert(current(), "post-recovery update did not converge")
	measure("idle", function()
		n:advance(120)
	end)
	result.idleCurrent = current()
	return result
end

local function report(result)
	local lines = { result.variant .. ": convergence " .. string.format("%.2fs", result.convergenceSeconds) }
	lines[#lines + 1] = "Baseline chunks: " .. table.concat(result.baselineParts, ", ")
	lines[#lines + 1] = "phase       client  full partial unchanged requests repairs rejected other-refresh timeouts"
	for _, phase in ipairs(result.phases) do
		for i, row in ipairs(phase.clients) do
			lines[#lines + 1] = string.format(
				"%-11s %d       %3d %7d %9d %8d %7d %8d %13d %8d",
				phase.name,
				i,
				row.full,
				row.partial,
				row.unchanged,
				row.requests,
				row.repairs,
				row.rejected,
				row.refreshing,
				row.timeouts
			)
		end
	end
	return table.concat(lines, "\n")
end

return { run = run, report = report }
