local network = require("tests.support.sync_network")
local hasBits, bits = pcall(require, "bit")

local function setupParty(game, versions)
	local n = network(game, #versions, versions, {
		configure = function(c, env, index)
			env.bit, env.bit32 = hasBits and bits or false, false
			env.tostring = function(value)
				return type(value) == "table" and ("repair-" .. index .. "-" .. c.incarnation) or tostring(value)
			end
			env.math = setmetatable({
				random = function()
					return index
				end,
			}, { __index = math })
		end,
	})
	for index, c in ipairs(n.clients) do
		for slot = 1, 8 do
			c.quests[index * 100 + slot] = {
				title = "Player " .. index .. " errand " .. slot .. string.rep("x", 110),
				state = "active",
				objectives = {},
			}
		end
	end
	n:join()
	n:advance(20)
	for _, c in ipairs(n.clients) do
		assert.is_true(c.view.complete)
	end
	return n, unpack(n.clients)
end

local function title(c, id)
	for _, group in ipairs(c.view.groups) do
		if group.questID == id then
			return group.title
		end
	end
end

local function identity(c)
	for i = #c.attempts, 1, -1 do
		local text = c.attempts[i].message:match("^1%.%d+:V:(.+)$")
		if text then
			return assert(c.env.QuestWithFriends.Sync.identity(text))
		end
	end
	error("missing heartbeat")
end

local function dataCount(c)
	return c:count("1.3:D:") + c:count("1.3:P:") + c:count("1.2:D:") + c:count("1.2:P:")
end

for _, game in ipairs({ "retail", "forever" }) do
	describe("heartbeat freshness and peer repair on " .. game, function()
		it("marks silence stale without requests and confirms unchanged returning heartbeats without data", function()
			local n, a, b = setupParty(game, { 3, 3, 3, 3 })
			local before, cached = {}, title(b, 101)
			for _, c in ipairs(n.clients) do
				before[c] = #c.attempts
			end
			n.deliver = function(from, to)
				return from ~= a and to ~= a
			end
			n:advance(180)
			assert.is_false(b.view.complete)
			assert.are.equal("stale", b.view.notices[1].reason)
			assert.are.equal(cached, title(b, 101))
			n.deliver = nil
			n:advance(25)
			for _, c in ipairs(n.clients) do
				assert.is_true(c.view.complete)
				for i = before[c] + 1, #c.attempts do
					assert.is_truthy(c.attempts[i].message:match("^1%.3:V:"))
				end
			end
		end)

		it("repairs a lost final update only from the advertised r1 peer", function()
			local n, a, b, c, d = setupParty(game, { 3, 3, 3, 3 })
			local full, requestData, otherData, requests =
				#a:snapshots(), dataCount(b), { dataCount(c), dataCount(d) }, b:count("1.3:H")
			local dropped = 0
			n.deliver = function(from, to, message)
				if from == a and to == b and message:match("^1%.3:P:") then
					dropped = dropped + 1
					return false
				end
				return true
			end
			a.quests[101].title = "Recovered final update"
			a:fire("QUEST_LOG_UPDATE")
			n:advance(40)
			assert.is_true(dropped > 0)
			assert.are.equal("Recovered final update", title(b, 101))
			assert.is_true(b.view.complete)
			assert.are.equal(1, b:count("1.3:R:"))
			assert.are.equal(full + 1, #a:snapshots())
			assert.are.equal(requestData, dataCount(b))
			assert.are.equal(otherData[1], dataCount(c))
			assert.are.equal(otherData[2], dataCount(d))
			assert.are.equal(requests, b:count("1.3:H"))
		end)

		it("repairs after capability-only contact returns without treating it as state verification", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local state = identity(a)
			n.deliver = function(from, to)
				return from ~= a or to ~= b
			end
			n:advance(90)
			b:receive(a.sender, "1.3:C:" .. state.session .. ":q1")
			assert.is_false(b.view.complete)
			n.deliver = nil
			n:advance(15)
			assert.are.equal(1, b:count("1.3:R:"))
			assert.is_true(b.view.complete)
		end)

		it("repairs an update missed during silence after the newer heartbeat returns", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local requests = b:count("1.3:H")
			n.deliver = function(from, to)
				return from ~= a or to ~= b
			end
			a.quests[101].title = "Changed while unreachable"
			a:fire("QUEST_LOG_UPDATE")
			n:advance(90)
			assert.are.equal("stale", b.view.notices[1].reason)
			assert.are.equal(0, b:count("1.3:R:"))
			n.deliver = nil
			n:advance(35)
			assert.is_true(b.view.complete)
			assert.are.equal("Changed while unreachable", title(b, 101))
			assert.are.equal(1, b:count("1.3:R:"))
			assert.are.equal(requests, b:count("1.3:H"))
		end)

		it("coalesces requests from multiple peers without refreshing the requester or healthy peers", function()
			local n, a, b, c = setupParty(game, { 3, 3, 3 })
			local state, full, bData, cData = identity(a), #a:snapshots(), dataCount(b), dataCount(c)
			for _ = 1, 3 do
				a:receive(b.sender, "1.3:R:" .. state.session)
				a:receive(c.sender, "1.3:R:" .. state.session)
			end
			n:advance(10)
			assert.are.equal(full + 1, #a:snapshots())
			assert.are.equal(bData, dataCount(b))
			assert.are.equal(cData, dataCount(c))
			assert.is_true(a.view.complete)
			assert.is_true(b.view.complete)
			assert.is_true(c.view.complete)
		end)

		it("upgrades an equivalent unsent throttled partial to the requested full baseline", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local state, full, partial = identity(a), #a:snapshots(), a:count("1.3:P:")
			local reject = true
			a.sendResult = function(message)
				return reject and message:match("^1%.3:[DP]:") and 5 or 0
			end
			a.quests[101].title = "Coalesced unsent target"
			a:fire("QUEST_LOG_UPDATE")
			n:advance(1)
			assert.are.equal(partial + 1, a:count("1.3:P:"))
			a:receive(b.sender, "1.3:R:" .. state.session)
			reject = false
			n:advance(15)
			assert.are.equal(full + 1, #a:snapshots())
			assert.are.equal(partial + 1, a:count("1.3:P:"))
			assert.are.equal("Coalesced unsent target", title(b, 101))
			assert.is_true(b.view.complete)
		end)

		for _, minor in ipairs({ 2, 3 }) do
			it("backs off repairs to 1." .. minor .. " and stops retrying during silence", function()
				local n, a, b = setupParty(game, { minor, 3 })
				local state, before = identity(a), #b.attempts
				state.sequence = state.sequence + 1
				local advertised = "1." .. minor .. ":V:" .. a.env.QuestWithFriends.Sync.identityText(state)
				local kind = minor == 3 and "1.3:R:" or "1.3:H"
				n.deliver = function(from, to)
					return from ~= a or to ~= b
				end
				local times = {}
				for _ = 1, 110 do
					b:receive(a.sender, advertised)
					n:advance(1)
				end
				for i = before + 1, #b.attempts do
					local attempt = b.attempts[i]
					if attempt.message:sub(1, #kind) == kind then
						times[#times + 1] = attempt.time
					end
				end
				assert.are.equal(4, #times)
				for i = 2, #times do
					assert.is_true(times[i] - times[i - 1] >= math.min(60, 15 * 2 ^ (i - 2)))
				end
				n:advance(65)
				local repairs = b:count(kind)
				n:advance(180)
				assert.are.equal(repairs, b:count(kind))
				assert.are.equal("stale", b.view.notices[1].reason)
			end)
		end

		it("uses a bounded H fallback for a peer without the explicit repair capability", function()
			local n, a, b = setupParty(game, { 2, 3 })
			local requests = b:count("1.3:H")
			n.deliver = function(from, to, message)
				return not (from == a and to == b and message:match("^1%.2:P:"))
			end
			a.quests[101].title = "Legacy repair"
			a:fire("QUEST_LOG_UPDATE")
			n:advance(40)
			assert.are.equal("Legacy repair", title(b, 101))
			assert.is_true(a.view.complete)
			assert.is_true(b.view.complete)
			assert.are.equal(0, b:count("1.3:R:"))
			assert.are.equal(requests + 1, b:count("1.3:H"))
		end)

		it("does not infer repair capability from a higher minor number", function()
			local n, a, b = setupParty(game, { 7, 3 })
			local state = identity(a)
			local core = a.env.QuestWithFriends.Core
			local _, payload = a.env.QuestWithFriends.Sync.snapshot(core.encode({}), state.session, state.sequence + 1)
			b:receive(a.sender, "1.7:D:" .. (state.sequence + 1) .. ":1:1:" .. payload)
			state.sequence = state.sequence + 2
			b:receive(a.sender, "1.7:V:" .. a.env.QuestWithFriends.Sync.identityText(state))
			n:advance(1)
			assert.are.equal(0, b:count("1.3:R:"))
			assert.are.equal(2, b:count("1.3:H"))
		end)

		it("cancels a rejected queued repair when a heartbeat confirms the cached state", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local state = identity(a)
			local confirmed = "1.3:V:" .. a.env.QuestWithFriends.Sync.identityText(state)
			state.sequence = state.sequence + 1
			b.sendResult = function(message)
				return message:match("^1%.3:R:") and 5 or 0
			end
			b:receive(a.sender, "1.3:V:" .. a.env.QuestWithFriends.Sync.identityText(state))
			n:advance(0.1)
			assert.are.equal(1, b:count("1.3:R:"))
			b:receive(a.sender, confirmed)
			n:advance(30)
			assert.are.equal(1, b:count("1.3:R:"))
			assert.is_true(b.view.complete)
		end)

		it("ignores malformed, wrong-session and old-minor targeted requests", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local state, full = identity(a), a:count("1.3:D:")
			for _, message in ipairs({
				"1.3:R:",
				"1.3:R:" .. string.rep("a", 31),
				"1.3:R:" .. string.rep("a", 33),
				"1.3:R:" .. string.rep("A", 32),
				"1.3:R:" .. string.rep("0", 32),
				"1.3:R:" .. state.session .. ":junk",
				"1.2:R:" .. state.session,
			}) do
				a:receive(b.sender, message)
			end
			n:advance(20)
			assert.are.equal(full, a:count("1.3:D:"))
			assert.is_true(a.view.complete)
		end)

		it("does not let a matching heartbeat satisfy an explicit refresh", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local state = identity(a)
			n.deliver = function(from, to)
				return from ~= a or to ~= b
			end
			b.env.SlashCmdList.QUESTWITHFRIENDS("")
			b:receive(a.sender, "1.3:V:" .. a.env.QuestWithFriends.Sync.identityText(state))
			assert.is_false(b.view.complete)
			assert.are.equal("refreshing", b.view.notices[1].reason)
		end)

		it("repairs a stalled partial without discarding its cached comparison", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local cached, dropped = title(b, 101), false
			n.deliver = function(from, to, message)
				local part, total = message:match("^1%.3:P:%d+:(%d+):(%d+):")
				if from == a and to == b and part and part == total and not dropped then
					dropped = true
					return false
				end
				return true
			end
			a.quests[101].title = string.rep("Changed", 40)
			a:fire("QUEST_LOG_UPDATE")
			n:advance(3)
			assert.is_true(dropped)
			assert.are.equal(cached, title(b, 101))
			n:advance(60)
			assert.are.equal(a.quests[101].title, title(b, 101))
			assert.is_true(b.view.complete)
			assert.is_true(b:count("1.3:R:") > 0)
			assert.are.equal(1, b:count("1.3:H"))
		end)

		it("preserves explicit refresh obligations across a silent interval", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local state = identity(a)
			n.deliver = function(from, to)
				return from ~= a or to ~= b
			end
			b.env.SlashCmdList.QUESTWITHFRIENDS("")
			n:advance(90)
			b:receive(a.sender, "1.3:V:" .. a.env.QuestWithFriends.Sync.identityText(state))
			assert.is_false(b.view.complete)
			n:advance(1)
			assert.is_true(b:count("1.3:R:") > 0)
			n.deliver = nil
			n:advance(90)
			assert.is_true(b.view.complete)
		end)

		it("omits optional repair metadata rather than making a baseline oversized", function()
			local n, a, b = setupParty(game, { 3, 3 })
			a.quests = {}
			for id = 1, 68 do
				a.quests[id] = { title = string.rep("x", 300), state = "active", objectives = {} }
			end
			local core = a.env.QuestWithFriends.Core
			while #core.encode(a.quests) > core.MAX_SNAPSHOT_BYTES do
				a.quests[68].title = a.quests[68].title:sub(1, -2)
				assert.is_true(#a.quests[68].title > 0)
			end
			assert.is_true(core.MAX_SNAPSHOT_BYTES - #core.encode(a.quests) <= 1)
			a:fire("QUEST_LOG_UPDATE")
			n:advance(120)
			assert.is_true(a.view.complete)
			assert.is_true(b.view.complete)
			assert.are.equal(a.quests[68].title, title(b, 68))
			local capabilities = a:count("1.3:C:")
			n:advance(60)
			assert.is_true(a:count("1.3:C:") > capabilities)
			assert.is_true(b.view.complete)
		end)

		it("uses state heartbeats instead of redundant periodic capability announcements", function()
			local n, a, b = setupParty(game, { 3, 3 })
			local capabilities, heartbeats = a:count("1.3:C:"), a:count("1.3:V:")
			n:advance(60)
			assert.are.equal(capabilities, a:count("1.3:C:"))
			assert.is_true(a:count("1.3:V:") > heartbeats)
			assert.is_true(b.view.complete)
		end)
	end)
end
