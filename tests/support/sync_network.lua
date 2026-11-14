local function network(game, size, minorVersions, options)
	options = options or {}
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
			if self.afterTimer then
				self.afterTimer()
			end
		end
		error("Timer queue did not settle")
	end
	local function loadClient(index, c)
		c.incarnation = (c.incarnation or 0) + 1
		local env = setmetatable({
			QuestWithFriends = false,
			QuestWithFriendsDB = c.env and c.env.QuestWithFriendsDB or { debugMode = options.debug ~= false },
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
		env.GetTime = function()
			return n.time
		end
		env.GetRealmName = function()
			return "Realm"
		end
		local function unitIndex(unit)
			return unit == "player" and index or c.units[tonumber(unit:match("^party(%d+)$"))]
		end
		env.UnitFullName = function(unit)
			if c.companions[unit] then
				return c.companions[unit]
			end
			local member = n.names[unitIndex(unit)]
			if member then
				return member.first, game == "forever" and member.last or "Realm"
			end
		end
		env.UnitName = env.UnitFullName
		env.UnitExists = function(unit)
			return c.companions[unit] ~= nil or unitIndex(unit) ~= nil
		end
		env.UnitIsPlayer = function(unit)
			return not c.companions[unit] and unitIndex(unit) ~= nil
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
					assert(script == "OnEvent")
					c.event = callback
				end,
			}
		end
		env.C_Timer = {
			After = function(delay, callback)
				local wrapped = options.wrap and options.wrap(c, "runtime.other", callback) or callback
				later(delay, function()
					-- A reload destroys the old runtime's timers, not already-submitted messages.
					if c.env == env then
						wrapped()
					end
				end)
			end,
		}
		env.C_ChatInfo = {
			RegisterAddonMessagePrefix = function()
				return 0
			end,
			SendAddonMessage = function(prefix, message, channel)
				assert(prefix == "QWF")
				assert(channel == "PARTY")
				local result = 0
				if c.sendResult then
					result = c.sendResult(message)
				end
				c.attempts[#c.attempts + 1] = { message = message, time = n.time, result = result }
				if result == 0 then
					later(options.latency or 0, function()
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
		if options.configure then
			options.configure(c, env, index)
		end
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
			GetTitleForQuestID = function(id)
				return c.quests[id] and c.quests[id].title
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
			Log = function(_, level, category, message, data)
				c.logs[#c.logs + 1] = { level = level, category = category, message = message, data = data }
			end,
		}
		for _, path in ipairs({
			"src/Bootstrap.lua",
			"src/QuestEquivalences.lua",
			"src/Client.lua",
			"src/QuestCategories.lua",
			"src/Core.lua",
			"src/Sync.lua",
			"src/QuestIgnores.lua",
			"src/ItemStock.lua",
			"src/QuestWithFriends.lua",
		}) do
			setfenv(assert(loadfile(path)), env)()
			if path == "src/Core.lua" then
				local core = env.QuestWithFriends.Core
				core.PROTOCOL_MINOR = minorVersions and (minorVersions[index] or 0) or 1
				core.PROTOCOL_VERSION = core.PROTOCOL_MAJOR .. "." .. core.PROTOCOL_MINOR
			end
		end
		env.QuestWithFriends.Panel = {
			show = function(groups, complete, _, _, _, notices, _, presentation)
				c.view = { groups = groups, complete = complete, notices = notices, updating = presentation.updating }
			end,
			hide = function()
				c.view = { hidden = true }
			end,
		}
		c.env = env
		if options.instrument then
			options.instrument(c, env)
		end
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
	for index, name in ipairs(n.names) do
		local c = { quests = {}, attempts = {}, logs = {}, party = true, units = {}, offline = {}, companions = {} }
		n.clients[index] = c
		for peerIndex in ipairs(n.names) do
			if peerIndex ~= index then
				c.units[#c.units + 1] = peerIndex
			end
		end
		c.sender = game == "forever" and (name.first .. " " .. name.last) or (name.first .. "-Realm")
		loadClient(index, c)
	end
	function n:reload(index)
		local c = assert(self.clients[index], "unknown client")
		loadClient(index, c)
		c:fire("PLAYER_ENTERING_WORLD")
		return c
	end
	function n:join()
		for _, c in ipairs(self.clients) do
			c:fire("PLAYER_ENTERING_WORLD")
		end
	end
	return n
end

return network
