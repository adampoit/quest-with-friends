local QWF = QuestWithFriends or {}
QuestWithFriends = QWF
QWF.Core = {}
local Core = QWF.Core
Core.PROTOCOL_MAJOR = 1
Core.PROTOCOL_MINOR = 0
Core.PROTOCOL_VERSION = Core.PROTOCOL_MAJOR .. "." .. Core.PROTOCOL_MINOR
Core.MAX_SNAPSHOT_BYTES = 22000
local MAX_EXTENSION_BYTES = 1024
local MAX_EXTENSIONS = 32
local MAX_EXTENSION_TAG_BYTES = 32
local MAX_EXTENSION_VALUE_BYTES = 512

local function field(value)
	value = tostring(value or "")
	return #value .. ":" .. value
end

local function readField(data, position, maxLength)
	local start, finish, size = data:find("(%d+):", position)
	if start ~= position or finish - start > 5 then
		return nil
	end
	size = tonumber(size)
	if not size or size > maxLength or finish + size > #data then
		return nil
	end
	return data:sub(finish + 1, finish + size), finish + size + 1
end

local function integer(value, maximum)
	if type(value) ~= "string" or not value:match("^%d+$") then
		return nil
	end
	local n = tonumber(value)
	if not n or n < 0 or n > maximum or n ~= math.floor(n) then
		return nil
	end
	return n
end

function Core.parseProtocolVersion(version)
	if type(version) ~= "string" then
		return nil
	end
	local majorText, minorText = version:match("^(%d+)%.(%d+)$")
	local major, minor = integer(majorText, 999), integer(minorText, 999)
	if not major or major == 0 or not minor or tostring(major) ~= majorText or tostring(minor) ~= minorText then
		return nil
	end
	return major, minor
end

local function validExtensionTag(tag)
	return type(tag) == "string" and #tag <= MAX_EXTENSION_TAG_BYTES and tag:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function encodeExtensions(extensions)
	if not extensions then
		return ""
	end
	assert(type(extensions) == "table", "Extensions must be a tag-to-string table")
	local tags = {}
	for tag, value in pairs(extensions) do
		assert(validExtensionTag(tag), "Invalid extension tag")
		assert(type(value) == "string" and #value <= MAX_EXTENSION_VALUE_BYTES, "Invalid extension value")
		tags[#tags + 1] = tag
	end
	assert(#tags <= MAX_EXTENSIONS, "Too many extensions")
	table.sort(tags)
	local parts = {}
	for _, tag in ipairs(tags) do
		parts[#parts + 1] = field(tag) .. field(extensions[tag])
	end
	local data = table.concat(parts)
	assert(#data <= MAX_EXTENSION_BYTES, "Extension block exceeds protocol limit")
	return data
end

local function validExtensions(data)
	if not data then
		return false
	end
	local position, count = 1, 0
	local seen = {}
	while position <= #data do
		local tag, following = readField(data, position, MAX_EXTENSION_TAG_BYTES)
		if not tag or not following or not validExtensionTag(tag) or seen[tag] or count >= MAX_EXTENSIONS then
			return false
		end
		local value, afterValue = readField(data, following, MAX_EXTENSION_VALUE_BYTES)
		if not value or not afterValue then
			return false
		end
		seen[tag] = true
		count = count + 1
		position = afterValue
	end
	return true
end

function Core.encode(quests, extensions)
	local ids = {}
	for id in pairs(quests) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	local parts = { field(Core.PROTOCOL_MAJOR), field(Core.PROTOCOL_MINOR), field(#ids) }
	for _, id in ipairs(ids) do
		local quest = quests[id]
		parts[#parts + 1] = field(id)
			.. field(quest.title)
			.. field(quest.state)
			.. field(quest.mapID or 0)
			.. field(quest.category or "")
			.. field(#quest.objectives)
		for _, objective in ipairs(quest.objectives) do
			parts[#parts + 1] = field(objective.text) .. field(objective.have) .. field(objective.need)
		end
		parts[#parts + 1] = field(encodeExtensions(quest.extensions))
	end
	parts[#parts + 1] = field(encodeExtensions(extensions))
	return table.concat(parts)
end

function Core.decode(data, expectedVersion)
	if type(data) ~= "string" or #data > Core.MAX_SNAPSHOT_BYTES then
		return nil
	end
	---@type integer?
	local position = 1
	local function nextField(limit)
		if not position then
			return nil
		end
		local value, following = readField(data, position, limit)
		position = following
		return value
	end
	local majorText, minorText = nextField(3), nextField(3)
	if not majorText or not minorText then
		return nil
	end
	local version = majorText .. "." .. minorText
	if
		Core.parseProtocolVersion(version) ~= Core.PROTOCOL_MAJOR or (expectedVersion and version ~= expectedVersion)
	then
		return nil
	end
	local count = integer(nextField(3), 500)
	if not count then
		return nil
	end
	local quests = {}
	for _ = 1, count do
		local id = integer(nextField(10), 100000000)
		local title = nextField(300)
		local state = nextField(12)
		local mapID = integer(nextField(10), 100000000)
		local category = nextField(10)
		local objectiveCount = integer(nextField(2), 30)
		if
			not id
			or id == 0
			or quests[id]
			or not title
			or not state
			or not mapID
			or not objectiveCount
			or (category ~= "" and category ~= "profession" and category ~= "class")
			or (state ~= "active" and state ~= "ready" and state ~= "completed")
		then
			return nil
		end
		local objectives = {}
		for _ = 1, objectiveCount do
			local text = nextField(500)
			local have = integer(nextField(10), 100000000)
			local need = integer(nextField(10), 100000000)
			if not text or not have or not need then
				return nil
			end
			objectives[#objectives + 1] = { text = text, have = have, need = need }
		end
		-- Optional fields cannot change baseline quest semantics in this reader.
		if not validExtensions(nextField(MAX_EXTENSION_BYTES)) then
			return nil
		end
		quests[id] = {
			title = title,
			state = state,
			objectives = objectives,
			mapID = mapID ~= 0 and mapID or nil,
			category = category ~= "" and category or nil,
		}
	end
	if not validExtensions(nextField(MAX_EXTENSION_BYTES)) or position ~= #data + 1 then
		return nil
	end
	return quests
end

local function safeText(value)
	-- Peer-provided strings must not be interpreted as WoW color, texture or hyperlink escapes.
	return tostring(value or ""):gsub("|", "¦"):gsub("[%c]", " ")
end

function Core.questIDs(id)
	return QWF.QuestEquivalences and QWF.QuestEquivalences[id] or { id }
end

function Core.completionIDs(id)
	local ids = Core.questIDs(id)
	return ids.history == false and { id } or ids
end

function Core.matchQuest(quests, id)
	local matched, matchedID
	for _, variantID in ipairs(Core.questIDs(id)) do
		local quest = quests[variantID]
		-- A current quest takes precedence over a completed equivalent in history.
		local eligible = quest and (quest.state ~= "completed" or variantID == id or Core.questIDs(id).history ~= false)
		if eligible and (not matched or (matched.state == "completed" and quest.state ~= "completed")) then
			matched, matchedID = quest, variantID
		end
	end
	return matched, matchedID
end

-- Initial snapshots establish a baseline, not activity. Metadata and objective wording can change on refresh.
function Core.recordActivity(activity, previous, current, sequence)
	if not previous then
		return
	end
	local function mark(id)
		activity[Core.questIDs(id)[1]] = sequence
	end
	for id, quest in pairs(current) do
		local old = previous[id]
		local changed = old and (old.state ~= quest.state or #old.objectives ~= #quest.objectives)
		if old and not changed then
			for index, objective in ipairs(quest.objectives) do
				local before = old.objectives[index]
				if before.have ~= objective.have or before.need ~= objective.need then
					changed = true
					break
				end
			end
		end
		if changed or (not old and quest.state ~= "completed") then
			mark(id)
		end
	end
	for id, quest in pairs(previous) do
		if not current[id] and quest.state ~= "completed" then
			mark(id)
		end
	end
end

function Core.sortGroups(groups, mode, activity)
	local missing = {}
	for _, group in ipairs(groups) do
		for _, difference in ipairs(group.differences) do
			if difference.kind == "missing" then
				missing[group] = true
				break
			end
		end
	end
	table.sort(groups, function(a, b)
		if mode ~= "title" then
			local am, bm = missing[a] == true, missing[b] == true
			if am ~= bm then
				return am
			end
			local aa, ba = activity and activity[a.questID] or 0, activity and activity[b.questID] or 0
			if aa ~= ba then
				return aa > ba
			end
		end
		if a.title ~= b.title then
			return a.title < b.title
		end
		return a.questID < b.questID
	end)
end

-- Returns quest groups, snapshot completeness, and connection notices outside the quest groups.
function Core.compare(localQuests, members, zoneID)
	local groups, notices = {}, {}
	local complete = true
	local ids = {}
	for id in pairs(localQuests) do
		ids[Core.questIDs(id)[1]] = true
	end
	for _, member in ipairs(members) do
		if member.quests then
			for id in pairs(member.quests) do
				ids[Core.questIDs(id)[1]] = true
			end
		end
		if member.syncStatus or not member.quests then
			complete = false
			notices[#notices + 1] = { player = safeText(member.name), reason = member.syncStatus or "unknown" }
		end
	end
	table.sort(notices, function(a, b)
		return a.player < b.player
	end)
	local ordered = {}
	for id in pairs(ids) do
		local hasMap, inZone = false, false
		local function check(quest)
			if quest and quest.mapID then
				hasMap = true
				inZone = inZone or quest.mapID == zoneID
			end
		end
		for _, variantID in ipairs(Core.questIDs(id)) do
			check(localQuests[variantID])
			for _, member in ipairs(members) do
				if member.quests then
					check(member.quests[variantID])
				end
			end
		end
		if not zoneID or not hasMap or inZone then
			ordered[#ordered + 1] = id
		end
	end
	table.sort(ordered)
	for _, id in ipairs(ordered) do
		local group = { questID = id, differences = {} }
		local seen, playerOrder, entryOrder = {}, {}, {}
		local function addDifference(playerIndex, kind, reason, objectiveIndex, objective)
			local key = playerIndex .. ":" .. reason .. ":" .. (objectiveIndex or 0)
			if seen[key] then
				return
			end
			seen[key] = true
			local difference = {
				player = playerIndex == 0 and "You" or safeText(members[playerIndex].name),
				kind = kind,
				reason = reason,
			}
			if objective then
				difference.objective = { text = safeText(objective.text), have = objective.have, need = objective.need }
			end
			group.differences[#group.differences + 1] = difference
			playerOrder[difference] = playerIndex
			entryOrder[difference] = #group.differences
		end
		local function addQuestState(playerIndex, quest, comparable)
			local hasRemaining = false
			if quest.state == "active" and comparable then
				for index, objective in ipairs(quest.objectives) do
					if objective.need > 0 and objective.have < objective.need then
						addDifference(playerIndex, "needs", "objective", index, objective)
						hasRemaining = true
					end
				end
			end
			if not hasRemaining then
				addDifference(playerIndex, quest.state == "active" and "needs" or "ahead", quest.state)
			end
		end
		local function addStates(mine, theirs, memberIndex, comparable)
			addQuestState(0, mine, comparable)
			addQuestState(memberIndex, theirs, comparable)
		end
		local localQuest = Core.matchQuest(localQuests, id)
		local useLocalTitle = localQuest and localQuest.state ~= "completed"
		if useLocalTitle then
			group.title = safeText(localQuest.title)
		end
		for memberIndex, member in ipairs(members) do
			if member.quests then
				local mine, mineID = Core.matchQuest(localQuests, id)
				local theirs, theirID = Core.matchQuest(member.quests, id)
				if Core.questIDs(id).history == false then
					if theirs and theirs.state ~= "completed" and (not mine or mine.state == "completed") then
						mine, mineID = localQuests[theirID], theirID
					elseif mine and mine.state ~= "completed" and (not theirs or theirs.state == "completed") then
						theirs, theirID = member.quests[mineID], mineID
					end
				end
				local current = (mine and mine.state ~= "completed" and mine) or theirs or mine
				if current and current.state ~= "completed" and not useLocalTitle then
					local title = safeText(current.title)
					if not group.title or title < group.title then
						group.title = title
					end
				end
				if mine and not theirs and mine.state ~= "completed" then
					addDifference(memberIndex, "missing", "missing")
					group.shareQuestID = mineID
				elseif theirs and not mine and theirs.state ~= "completed" then
					addDifference(0, "missing", "missing")
				elseif mine and theirs then
					local comparable = mineID == theirID or Core.questIDs(id).progress ~= "state"
					if mine.state ~= theirs.state then
						addStates(mine, theirs, memberIndex, comparable)
					elseif mine.state == "active" then
						for index, objective in ipairs(comparable and mine.objectives or {}) do
							local other = theirs.objectives[index]
							if other and objective.need > 0 and other.need == objective.need then
								if objective.have >= objective.need and other.have < other.need then
									addDifference(memberIndex, "needs", "objective", index, other)
								elseif other.have >= other.need and objective.have < objective.need then
									addDifference(0, "needs", "objective", index, objective)
								end
							end
						end
					end
				end
			end
		end
		if #group.differences > 0 then
			table.sort(group.differences, function(a, b)
				local ai, bi = playerOrder[a], playerOrder[b]
				if ai ~= bi then
					if ai == 0 or bi == 0 then
						return ai == 0
					end
					return a.player == b.player and ai < bi or a.player < b.player
				end
				return entryOrder[a] < entryOrder[b]
			end)
			groups[#groups + 1] = group
		end
	end
	Core.sortGroups(groups)
	return groups, complete, notices
end
