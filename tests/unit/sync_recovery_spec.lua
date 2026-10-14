local function network(game, size, minorVersions)
	local n = { time = 0, timers = {}, clients = {}, names = {}, sequence = 0 }
	for index = 1, size or 2 do
		n.names[index] = { first = "Player" .. index, last = "Family" .. index }
	end
	local function later(delay, callback)
		n.sequence = n.sequence + 1
		n.timers[#n.timers + 1] = { time = n.time + delay, callback = callback, sequence = n.sequence }
	end
	function n:advance(seconds)
		local deadline = self.time + seconds
		for _ = 1, 10000 do
			table.sort(self.timers, function(a, b)
				return a.time == b.time and a.sequence < b.sequence or a.time < b.time
			end)
			local timer = self.timers[1]
			if not timer or timer.time > deadline then
				self.time = deadline
				return
			end
			table.remove(self.timers, 1)
			self.time = timer.time
			timer.callback()
		end
		error("Timer queue did not settle")
	end
	for index, name in ipairs(n.names) do
		local c = { quests = {}, attempts = {}, logs = {}, party = true, units = {}, offline = {} }
		n.clients[index] = c
		for peerIndex in ipairs(n.names) do
			if peerIndex ~= index then
				c.units[#c.units + 1] = peerIndex
			end
		end
		c.sender = game == "forever" and (name.first .. " " .. name.last) or (name.first .. "-Realm")
		local env = setmetatable({
			QuestWithFriends = false,
			QuestWithFriendsDB = {},
			Constants = false,
			C_Map = false,
			GetQuestUiMapID = false,
			C_TradeSkillUI = false,
			LOCALIZED_CLASS_NAMES_MALE = false,
			LOCALIZED_CLASS_NAMES_FEMALE = false,
			SlashCmdList = {},
			Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 5 } },
			print = function() end,
		}, { __index = _G })
		env._G = env
		env.GetBuildInfo = function()
			return "", "", "", game == "forever" and 16001 or 120100
		end
		env.GetRealmName = function()
			return "Realm"
		end
		local function unitIndex(unit)
			return unit == "player" and index or c.units[tonumber(unit:match("^party(%d+)$"))]
		end
		env.UnitFullName = function(unit)
			local member = n.names[unitIndex(unit)]
			if member then
				return member.first, game == "forever" and member.last or "Realm"
			end
		end
		env.UnitName = env.UnitFullName
		env.UnitExists = function(unit)
			return unitIndex(unit) ~= nil
		end
		env.UnitIsConnected = function(unit)
			return not c.offline[unitIndex(unit)]
		end
		env.IsInGroup = function()
			return c.party
		end
		env.IsInRaid = function()
			return c.raid == true
		end
		env.CreateFrame = function()
			return {
				RegisterEvent = function() end,
				SetScript = function(_, script, callback)
					assert.are.equal("OnEvent", script)
					c.event = callback
				end,
			}
		end
		env.C_Timer = { After = later }
		env.C_ChatInfo = {
			RegisterAddonMessagePrefix = function()
				return 0
			end,
			SendAddonMessage = function(prefix, message, channel)
				assert.are.equal("QWF", prefix)
				assert.are.equal("PARTY", channel)
				local result = 0
				if c.sendResult then
					result = c.sendResult(message)
				end
				c.attempts[#c.attempts + 1] = { message = message, time = n.time, result = result }
				if result == 0 then
					later(0, function()
						for _, recipient in ipairs(n.clients) do
							if not n.deliver or n.deliver(c, recipient, message) then
								recipient.event(nil, "CHAT_MSG_ADDON", "QWF", message, "PARTY", c.sender)
							end
						end
					end)
				end
				return result
			end,
		}
		local ids = {}
		env.C_QuestLog = {
			GetNumQuestLogEntries = function()
				ids = {}
				for id in pairs(c.quests) do
					ids[#ids + 1] = id
				end
				table.sort(ids)
				return #ids
			end,
			GetInfo = function(position)
				local id = ids[position]
				return { questID = id, title = c.quests[id].title }
			end,
			GetQuestObjectives = function(id)
				return c.quests[id].objectives or {}
			end,
			GetQuestTagInfo = function(id)
				return c.quests[id] and c.quests[id].tag
			end,
			IsComplete = function(id)
				return c.quests[id].state == "ready"
			end,
			IsQuestFlaggedCompleted = function()
				return false
			end,
			IsPushableQuest = function()
				return false
			end,
		}
		env.AddonKit = {
			RegisterAddon = function() end,
			Log = function(_, level, _, message, data)
				c.logs[#c.logs + 1] = { level = level, message = message, data = data }
			end,
		}
		for _, path in ipairs({
			"Bootstrap.lua",
			"QuestEquivalences.lua",
			"Client.lua",
			"QuestCategories.lua",
			"Core.lua",
			"QuestWithFriends.lua",
		}) do
			setfenv(assert(loadfile(path)), env)()
			if path == "Core.lua" and minorVersions then
				local core = env.QuestWithFriends.Core
				core.PROTOCOL_MINOR = minorVersions[index] or 0
				core.PROTOCOL_VERSION = core.PROTOCOL_MAJOR .. "." .. core.PROTOCOL_MINOR
			end
		end
		env.QuestWithFriends.Panel = {
			show = function(groups, complete, _, _, _, notices)
				c.view = { groups = groups, complete = complete, notices = notices }
			end,
			hide = function()
				c.view = { hidden = true }
			end,
		}
		c.env = env
		function c:fire(event, ...)
			self.event(nil, event, ...)
		end
		function c:receive(sender, message)
			self:fire("CHAT_MSG_ADDON", "QWF", message, "PARTY", sender)
		end
		function c:count(kind)
			local count = 0
			for _, attempt in ipairs(self.attempts) do
				if attempt.message:sub(1, #kind) == kind then
					count = count + 1
				end
			end
			return count
		end
		function c:snapshots()
			local pending, snapshots = {}, {}
			for _, attempt in ipairs(self.attempts) do
				local serial, part, total, data = attempt.message:match("^1%.%d+:D:(%d+):(%d+):(%d+):(.+)$")
				if serial and part and total and data and attempt.result == 0 then
					part, total = assert(tonumber(part)), assert(tonumber(total))
					pending[serial] = pending[serial] or { received = 0, parts = {} }
					local assembly = pending[serial]
					if not assembly.parts[part] then
						assembly.received = assembly.received + 1
						assembly.parts[part] = data
						if assembly.received == total then
							snapshots[#snapshots + 1] =
								assert(self.env.QuestWithFriends.Core.decode(table.concat(assembly.parts)))
						end
					end
				end
			end
			return snapshots
		end
	end
	function n:join()
		for _, c in ipairs(self.clients) do
			c:fire("PLAYER_ENTERING_WORLD")
		end
	end
	return n
end

local function quest(title)
	return { title = title or "Errand", state = "active", objectives = {} }
end

local function chunks(c, serial, quests, minor, extensions)
	local core = c.env.QuestWithFriends.Core
	local savedMinor = core.PROTOCOL_MINOR
	core.PROTOCOL_MINOR = minor or savedMinor
	local version = core.PROTOCOL_MAJOR .. "." .. core.PROTOCOL_MINOR
	local payload = core.encode(quests, extensions)
	core.PROTOCOL_MINOR = savedMinor
	local messages = {}
	local total = math.ceil(#payload / 220)
	for part = 1, total do
		messages[#messages + 1] = version
			.. ":D:"
			.. serial
			.. ":"
			.. part
			.. ":"
			.. total
			.. ":"
			.. payload:sub((part - 1) * 220 + 1, part * 220)
	end
	return messages
end

for _, game in ipairs({ "retail", "forever" }) do
	describe("Quest With Friends reliable sync on " .. game, function()
		it("exchanges baseline snapshots across mixed minor versions without negotiation", function()
			local n = network(game, 2, { 0, 5 })
			for _, c in ipairs(n.clients) do
				c.quests[42] = quest()
			end
			n:join()
			n:advance(5)
			for _, c in ipairs(n.clients) do
				assert.is_true(c.view.complete)
				assert.same({}, c.view.notices)
				assert.same({}, c.view.groups)
				assert.are.equal(1, #c:snapshots())
				local sender = n.clients[1] == c and n.clients[2].sender or n.clients[1].sender
				c:receive(sender, "1.9:B:optional")
				assert.is_true(c.view.complete)
				for _, log in ipairs(c.logs) do
					assert.are_not.equal("Unsupported addon protocol", log.message)
				end
			end
		end)

		it("skips future optional fields atomically while keeping baseline comparisons", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n:join()
			n:advance(5)
			local remote = { [43] = quest(string.rep("x", 250)) }
			remote[43].category = "profession"
			remote[43].extensions = { chain_id = "123:4", state = "unknown future value" }
			local messages = chunks(a, 100, remote, 7, { optional_feature = "enabled" })
			a:receive(b.sender, messages[1])
			assert.is_false(a.view.complete)
			assert.are.equal("refreshing", a.view.notices[1].reason)
			for i = #messages, 2, -1 do
				a:receive(b.sender, messages[i])
			end
			assert.is_true(a.view.complete)
			assert.same({}, a.view.groups)
			a.env.QuestWithFriendsDB.showProfessionQuests = true
			a:fire("ZONE_CHANGED")
			assert.are.equal(43, a.view.groups[1].questID)
		end)

		it("does not mix minor versions within one snapshot revision", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n:join()
			n:advance(5)
			local remote = { [43] = quest(string.rep("x", 250)) }
			local messages = chunks(a, 100, remote, 3)
			a:receive(b.sender, messages[1])
			a:receive(b.sender, (messages[2]:gsub("^1%.3:", "1.4:")))
			assert.is_false(a.view.complete)
			for i = 2, #messages do
				a:receive(b.sender, messages[i])
			end
			assert.is_true(a.view.complete)
			assert.are.equal(43, a.view.groups[1].questID)
			local mismatched = chunks(a, 101, remote, 5)
			for _, message in ipairs(mismatched) do
				a:receive(b.sender, (message:gsub("^1%.5:", "1.6:")))
			end
			assert.is_false(a.view.complete)
			assert.are.equal(43, a.view.groups[1].questID)
		end)

		it("paces classified snapshots across four clients without roster or subzone storms", function()
			local n = network(game, 4)
			for _, c in ipairs(n.clients) do
				for id = 1, 30 do
					c.quests[id] = quest(string.rep("x", 200))
				end
				c.quests[1].tag = { tagID = 21 }
			end
			n:join()
			n:advance(0.6)
			for _ = 1, 50 do
				for _, c in ipairs(n.clients) do
					c:fire("GROUP_ROSTER_UPDATE")
					c:fire("ZONE_CHANGED")
					c:fire("ZONE_CHANGED_INDOORS")
				end
			end
			n:advance(2)
			for _, c in ipairs(n.clients) do
				c.units[1], c.units[2] = c.units[2], c.units[1]
				c:fire("GROUP_ROSTER_UPDATE")
			end
			n:advance(40)
			for _, c in ipairs(n.clients) do
				assert.is_true(c.view.complete)
				assert.same({}, c.view.groups)
				assert.are.equal(1, c:count("1.0:H"))
				assert.are.equal(1, #c:snapshots())
				for i = 2, #c.attempts do
					assert.is_true(c.attempts[i].time - c.attempts[i - 1].time >= 0.499)
				end
				for _, log in ipairs(c.logs) do
					assert.are_not.equal("Quest snapshot timed out; requesting refresh", log.message)
				end
			end
		end)

		it("preserves cached quests and partial chunks through repeated snapshot requests", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			a.quests[42], b.quests[42] = quest(), quest()
			n:join()
			n:advance(5)
			assert.is_true(a.view.complete)
			n.deliver = function(_, recipient)
				return recipient ~= a
			end
			local messages = chunks(a, 100, { [42] = quest(), [43] = quest(string.rep("x", 250)) })
			a:receive(b.sender, messages[1])
			for _ = 1, 4 do
				a:receive(b.sender, "1.0:H")
			end
			assert.is_false(a.view.complete)
			assert.are.equal("refreshing", a.view.notices[1].reason)
			assert.same({}, a.view.groups)
			for i = #messages, 2, -1 do
				a:receive(b.sender, messages[i])
			end
			assert.is_true(a.view.complete)
			assert.are.equal(43, a.view.groups[1].questID)
			n:advance(2)
			assert.are.equal(1, a:count("1.0:H"))
		end)

		it("retries a throttled final chunk automatically after both players pick up a quest", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			a.quests[42], b.quests[42] = quest(), quest()
			n:join()
			n:advance(5)
			local failures, retryTimes, retryMessages = 0, {}, {}
			a.sendResult = function(message)
				local _, part, total = message:match("^1%.0:D:(%d+):(%d+):(%d+):")
				if part and part == total then
					retryTimes[#retryTimes + 1] = n.time
					retryMessages[#retryMessages + 1] = message
					if failures < 2 then
						failures = failures + 1
						return 5
					end
				end
				return 0
			end
			for _, c in ipairs(n.clients) do
				c.quests[43] = quest(string.rep("x", 250))
				c:fire("QUEST_ACCEPTED", 43)
			end
			n:advance(12)
			assert.are.equal(2, failures)
			assert.are.equal(3, #retryMessages)
			assert.are.equal(retryMessages[1], retryMessages[3])
			assert.is_true(math.abs(retryTimes[2] - retryTimes[1] - 1) < 0.001)
			assert.is_true(math.abs(retryTimes[3] - retryTimes[2] - 2) < 0.001)
			for _, c in ipairs(n.clients) do
				assert.is_true(c.view.complete)
				assert.same({}, c.view.groups)
			end
		end)

		it("retries handshake and classified snapshot failures without external events", function()
			local n = network(game)
			local a = n.clients[1]
			a.quests[42] = quest()
			a.quests[42].tag = { tagID = 21 }
			local requests, snapshots = 0, 0
			a.sendResult = function(message)
				if message == "1.0:H" then
					requests = requests + 1
					if requests == 1 then
						return false
					end
				elseif message:sub(1, 6) == "1.0:D:" then
					snapshots = snapshots + 1
					if snapshots <= 2 then
						return 5
					end
				end
				return 0
			end
			n:join()
			n:advance(12)
			assert.are.equal(2, requests)
			assert.are.equal(3, snapshots)
			assert.are.equal(1, #a:snapshots())
			assert.are.equal("class", a:snapshots()[1][42].category)
			for _, c in ipairs(n.clients) do
				assert.is_true(c.view.complete)
			end
		end)

		it("coalesces new quest updates while finishing the active snapshot", function()
			local n = network(game)
			local a = n.clients[1]
			for id = 1, 20 do
				a.quests[id] = quest(string.rep("x", 200))
			end
			n:join()
			n:advance(2)
			for version = 1, 4 do
				a.quests[99] = quest("Version " .. version)
				a:fire("QUEST_LOG_UPDATE")
				n:advance(0.9)
			end
			n:advance(40)
			local snapshots = a:snapshots()
			assert.are.equal(2, #snapshots)
			assert.is_nil(snapshots[1][99])
			assert.are.equal("Version 4", snapshots[2][99].title)
			assert.are.equal(1, a:count("1.0:H"))
		end)

		it("recovers a lost chunk after a timeout without another quest event", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			a.quests[42], b.quests[42] = quest(), quest()
			n:join()
			n:advance(5)
			local dropped = false
			n.deliver = function(from, recipient, message)
				local _, part, total = message:match("^1%.0:D:(%d+):(%d+):(%d+):")
				if from == a and recipient == b and part == total and not dropped then
					dropped = true
					return false
				end
				return true
			end
			a.quests[43] = quest(string.rep("x", 250))
			a:fire("QUEST_ACCEPTED", 43)
			n:advance(8)
			assert.is_true(dropped)
			assert.is_false(b.view.complete)
			assert.are.equal("refreshing", b.view.notices[1].reason)
			n:advance(45)
			assert.is_true(b.view.complete)
			assert.are.equal(43, b.view.groups[1].questID)
			assert.are.equal(2, b:count("1.0:H"))
		end)

		it("coalesces simultaneous timeout recovery requests from three peers", function()
			local n = network(game, 4)
			local a = n.clients[1]
			n:join()
			n:advance(5)
			n.deliver = function(_, recipient)
				return recipient ~= a
			end
			for i = 2, 4 do
				a:receive(n.clients[i].sender, chunks(a, 100 + i, { [43] = quest(string.rep("x", 250)) })[1])
			end
			n:advance(16)
			assert.are.equal(2, a:count("1.0:H"))
			assert.are.equal(3, #a.view.notices)
			for _, notice in ipairs(a.view.notices) do
				assert.are.equal("stale", notice.reason)
			end
			n.deliver = nil
			n:advance(45)
			assert.is_true(a.view.complete)
		end)

		it("labels a stalled cached snapshot stale and keeps requests bounded", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n:join()
			n:advance(5)
			n.deliver = function(_, recipient)
				return recipient ~= a
			end
			a:receive(b.sender, chunks(a, 100, { [43] = quest() })[1])
			local messages = chunks(a, 101, { [43] = quest(string.rep("x", 250)) })
			a:receive(b.sender, messages[1])
			n:advance(15)
			assert.are.equal("stale", a.view.notices[1].reason)
			assert.is_false(a.view.complete)
			assert.are.equal(43, a.view.groups[1].questID)
			n:advance(120)
			assert.is_true(a:count("1.0:H") <= 5)
			for i = 2, #messages do
				a:receive(b.sender, messages[i])
			end
			assert.is_true(a.view.complete)
			local requests = a:count("1.0:H")
			n:advance(120)
			assert.are.equal(requests, a:count("1.0:H"))
		end)

		it("applies classifications only when the full revision assembles", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n:join()
			n:advance(5)
			local remote = { [43] = quest(string.rep("x", 250)) }
			remote[43].category = "profession"
			local messages = chunks(a, 100, remote)
			a:receive(b.sender, messages[1])
			assert.is_false(a.view.complete)
			assert.same({}, a.view.groups)
			for i = 2, #messages do
				a:receive(b.sender, messages[i])
			end
			assert.is_true(a.view.complete)
			assert.same({}, a.view.groups)
			remote[43].category = nil
			messages = chunks(a, 101, remote)
			for _, message in ipairs(messages) do
				a:receive(b.sender, message)
			end
			assert.is_true(a.view.complete)
			assert.are.equal(43, a.view.groups[1].questID)
		end)

		for _, message in ipairs({ "2.0:H", "broken", "1.00:H", "1.0:" }) do
			it("stops recovery after " .. message .. " and resumes on valid data", function()
				local n = network(game)
				local a, b = unpack(n.clients)
				n:join()
				n:advance(5)
				n.deliver = function(_, recipient)
					return recipient ~= a
				end
				a:receive(b.sender, chunks(a, 100, { [43] = quest(string.rep("x", 250)) })[1])
				a:receive(b.sender, message)
				assert.are.equal("incompatible", a.view.notices[1].reason)
				assert.is_false(a.view.complete)
				local requests = a:count("1.0:H")
				n:advance(180)
				assert.are.equal(requests, a:count("1.0:H"))
				a:receive(b.sender, chunks(a, 1, {})[1])
				assert.is_true(a.view.complete)
				assert.same({}, a.view.notices)
			end)
		end

		it("distinguishes an undetected addon from one waiting for its first snapshot", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n.deliver = function()
				return false
			end
			n:join()
			n:advance(5)
			assert.are.equal("unknown", a.view.notices[1].reason)
			a:receive(b.sender, "1.0:H")
			assert.are.equal("waiting", a.view.notices[1].reason)
			n:advance(16)
			assert.are.equal("waiting", a.view.notices[1].reason)
			assert.are.equal(2, a:count("1.0:H"))
			a:receive(b.sender, chunks(a, 1, {})[1])
			assert.is_true(a.view.complete)
		end)

		it("accepts a reloaded peer's reset revision without discarding cached data first", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n:join()
			n:advance(5)
			a:receive(b.sender, chunks(a, 100, { [43] = quest() })[1])
			a:receive(b.sender, chunks(a, 101, { [43] = quest(string.rep("x", 250)) })[1])
			a:receive(b.sender, "1.0:H")
			assert.are.equal(43, a.view.groups[1].questID)
			a:receive(b.sender, chunks(a, 1, {})[1])
			assert.is_true(a.view.complete)
			assert.same({}, a.view.groups)
		end)

		it("accepts a reset revision on manual refresh even if the peer's reload announcement was lost", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n:join()
			n:advance(5)
			a:receive(b.sender, chunks(a, 100, { [43] = quest() })[1])
			a:receive(b.sender, chunks(a, 1, {})[1])
			assert.are.equal(43, a.view.groups[1].questID)
			a.env.SlashCmdList.QUESTWITHFRIENDS("")
			a:receive(b.sender, chunks(a, 2, {})[1])
			assert.is_true(a.view.complete)
			assert.same({}, a.view.groups)
		end)

		it("keeps manual refresh available and distinguishes offline members on roster updates", function()
			local n = network(game)
			local a = n.clients[1]
			n:join()
			n:advance(5)
			a.offline[2] = true
			a:fire("GROUP_ROSTER_UPDATE")
			assert.are.equal("offline", a.view.notices[1].reason)
			assert.is_false(a.view.complete)
			a.offline[2] = nil
			a:fire("GROUP_ROSTER_UPDATE")
			n:advance(5)
			assert.is_true(a.view.complete)
			local previous = a:count("1.0:H")
			a.env.SlashCmdList.QUESTWITHFRIENDS("")
			assert.are.equal("refreshing", a.view.notices[1].reason)
			n:advance(5)
			assert.are.equal(previous + 1, a:count("1.0:H"))
			assert.is_true(a.view.complete)
		end)

		it("retains cached differences offline and refreshes them on UNIT_CONNECTION", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			b.quests[42] = quest("Cached errand")
			n:join()
			n:advance(5)
			assert.are.equal("Cached errand", a.view.groups[1].title)
			a.offline[2] = true
			n.deliver = function(from, to)
				return from ~= b and to ~= b
			end
			a:fire("UNIT_CONNECTION", "party1", false)
			assert.are.equal("offline", a.view.notices[1].reason)
			assert.is_false(a.view.complete)
			assert.are.equal("Cached errand", a.view.groups[1].title)
			a.env.SlashCmdList.QUESTWITHFRIENDS("")
			n:advance(5)
			assert.are.equal("offline", a.view.notices[1].reason)
			local requests = a:count("1.0:H")
			n:advance(120)
			assert.are.equal(requests, a:count("1.0:H"))
			b.quests = { [43] = quest("Fresh errand") }
			a.offline[2], n.deliver = nil, nil
			a:fire("UNIT_CONNECTION", "party1", true)
			assert.is_false(a.view.complete)
			n:advance(5)
			assert.is_true(a.view.complete)
			assert.same({}, a.view.notices)
			assert.are.equal(1, #a.view.groups)
			assert.are.equal("Fresh errand", a.view.groups[1].title)
		end)

		it("labels offline members without snapshots and removes them when they leave", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			a.offline[2] = true
			n.deliver = function(from, to)
				return from ~= b and to ~= b
			end
			n:join()
			n:advance(5)
			assert.are.equal("offline", a.view.notices[1].reason)
			assert.is_false(a.view.complete)
			local requests = a:count("1.0:H")
			a:fire("UNIT_CONNECTION", "player", true)
			a:fire("UNIT_CONNECTION", "target", true)
			n:advance(120)
			assert.are.equal(requests, a:count("1.0:H"))
			a.offline[2], n.deliver = nil, nil
			a:fire("UNIT_CONNECTION", "party1", true)
			n:advance(5)
			assert.is_true(a.view.complete)
			assert.same({}, a.view.notices)
			a.offline[2] = true
			a:fire("UNIT_CONNECTION", "party1", false)
			assert.are.equal("offline", a.view.notices[1].reason)
			a.units = {}
			a:fire("GROUP_ROSTER_UPDATE")
			assert.same({}, a.view.notices)
			assert.is_true(a.view.complete)
		end)

		it("cancels stalled snapshot recovery when a peer goes offline", function()
			local n = network(game)
			local a, b = unpack(n.clients)
			n.deliver = function(from, _, message)
				return from ~= b or message == "1.0:H"
			end
			n:join()
			n:advance(5)
			assert.are.equal("waiting", a.view.notices[1].reason)
			a.offline[2] = true
			a:fire("UNIT_CONNECTION", "party1", false)
			n:advance(5)
			local requests = a:count("1.0:H")
			n:advance(120)
			assert.are.equal(requests, a:count("1.0:H"))
			assert.are.equal("offline", a.view.notices[1].reason)
			assert.is_false(a.view.complete)
		end)

		it("stops queued sends when the party becomes a raid", function()
			local n = network(game)
			local a = n.clients[1]
			n:join()
			n:advance(0.6)
			a.raid = true
			a:fire("GROUP_ROSTER_UPDATE")
			local attempts = #a.attempts
			n:advance(30)
			assert.are.equal(attempts, #a.attempts)
			assert.is_true(a.view.hidden)
		end)

		it("cancels retry and watchdog work when leaving and starts cleanly on rejoin", function()
			local n = network(game)
			local a = n.clients[1]
			a.sendResult = function()
				return 5
			end
			n:join()
			n:advance(4)
			a.party = false
			a:fire("GROUP_ROSTER_UPDATE")
			assert.is_true(a.view.hidden)
			local attempts = #a.attempts
			n:advance(120)
			assert.are.equal(attempts, #a.attempts)
			a.sendResult = nil
			a.party = true
			a:fire("GROUP_ROSTER_UPDATE")
			n:advance(5)
			assert.is_true(a.view.complete)
		end)
	end)
end
