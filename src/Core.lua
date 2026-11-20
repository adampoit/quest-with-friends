local _, QWF = ...
QWF = QWF or QuestWithFriends or {}
if QWF.disabled then
	return
end
QuestWithFriends = QWF
QWF.Core = {}
local Core = QWF.Core

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

function Core.hasDifferences(groups)
	for _, group in ipairs(groups) do
		for _, difference in ipairs(group.differences) do
			if not difference.informational then
				return true
			end
		end
	end
	return false
end

-- Informational progress rows do not affect party status. Roster index 0 identifies You.
function Core.compare(localQuests, members, zoneID, progressMode)
	local groups, notices, playerIndices = {}, {}, {}
	local complete = true
	local snapshots = { [0] = localQuests }
	local reasonOrder = { missing = 1, active = 2, objective = 3, ready = 4, completed = 5 }
	local ids = {}
	for id in pairs(localQuests) do
		ids[Core.questIDs(id)[1]] = true
	end
	for memberIndex, member in ipairs(members) do
		if member.quests then
			snapshots[memberIndex] = member.quests
			for id in pairs(member.quests) do
				ids[Core.questIDs(id)[1]] = true
			end
		end
		if member.syncStatus or member.partial or not member.quests then
			complete = false
			notices[#notices + 1] = {
				player = safeText(member.name),
				reason = member.syncStatus or (member.partial and "native" or "unknown"),
			}
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
		local seen, playerOrder, objectiveOrder, hasObjectives = {}, {}, {}, {}
		local localQuest, localID = Core.matchQuest(localQuests, id)
		local function addDifference(playerIndex, kind, reason, objectiveIndex, objective, informational)
			local key = playerIndex .. ":" .. reason .. ":" .. (objectiveIndex or 0)
			if seen[key] then
				if not informational then
					seen[key].informational = nil
					seen[key].kind = kind
				end
				return
			end
			local difference = {
				player = playerIndex == 0 and "You" or safeText(members[playerIndex].name),
				kind = kind,
				reason = reason,
			}
			if informational then
				difference.informational = true
			end
			if objective then
				difference.objective = {
					text = safeText(objective.text),
					have = objective.have,
					need = objective.need,
					spare = objective.spare,
				}
			end
			seen[key] = difference
			group.differences[#group.differences + 1] = difference
			playerOrder[difference] = playerIndex
			playerIndices[difference] = playerIndex
			objectiveOrder[difference] = objectiveIndex or 0
			if objective then
				hasObjectives[playerIndex] = true
			end
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
		local useLocalTitle = localQuest and localQuest.state ~= "completed"
		if useLocalTitle then
			group.title = safeText(localQuest.title)
		else
			for _, member in ipairs(members) do
				local quest = member.quests and Core.matchQuest(member.quests, id)
				if quest and quest.state ~= "completed" then
					local title = safeText(quest.title)
					if not group.title or title < group.title then
						group.title = title
					end
				end
			end
		end
		local function addItemStock(playerIndex, quest, other, sameID)
			if other.state ~= "active" then
				return
			end
			for index, objective in ipairs(quest.objectives) do
				local remaining = other.objectives[index]
				if
					objective.itemID
					and objective.spare ~= nil
					and (quest.state ~= "completed" or objective.spare > 0)
					and objective.need > 0
					and objective.have >= objective.need
					and remaining
					and remaining.need == objective.need
					and remaining.have < remaining.need
					and (sameID or remaining.itemID == objective.itemID)
					and (not remaining.itemID or remaining.itemID == objective.itemID)
				then
					addDifference(playerIndex, "ahead", "objective", index, objective)
				end
			end
		end
		local function comparePair(firstIndex, secondIndex)
			local firstQuests, secondQuests = snapshots[firstIndex], snapshots[secondIndex]
			local first, firstID = Core.matchQuest(firstQuests, id)
			local second, secondID = Core.matchQuest(secondQuests, id)
			if Core.questIDs(id).history == false then
				if second and second.state ~= "completed" and (not first or first.state == "completed") then
					first, firstID = firstQuests[secondID], secondID
				elseif first and first.state ~= "completed" and (not second or second.state == "completed") then
					second, secondID = secondQuests[firstID], firstID
				end
			end
			if first and not second and first.state ~= "completed" and not members[secondIndex].partial then
				addDifference(secondIndex, "missing", "missing")
				if firstIndex == 0 then
					group.shareQuestID = firstID
				end
			elseif
				second
				and not first
				and second.state ~= "completed"
				and not (members[firstIndex] and members[firstIndex].partial)
			then
				addDifference(firstIndex, "missing", "missing")
			elseif first and second then
				local comparable = firstID == secondID or Core.questIDs(id).progress ~= "state"
				if comparable then
					addItemStock(firstIndex, first, second, firstID == secondID)
					addItemStock(secondIndex, second, first, firstID == secondID)
				end
				if first.state ~= second.state and not first.stateUnknown and not second.stateUnknown then
					addQuestState(firstIndex, first, comparable)
					addQuestState(secondIndex, second, comparable)
				elseif first.state == "active" or second.state == "active" then
					for index, objective in ipairs(comparable and first.objectives or {}) do
						local other = second.objectives[index]
						if other and objective.need > 0 and other.need == objective.need then
							if objective.have >= objective.need and other.have < other.need then
								addDifference(secondIndex, "needs", "objective", index, other)
							elseif other.have >= other.need and objective.have < objective.need then
								addDifference(firstIndex, "needs", "objective", index, objective)
							end
						end
					end
				end
			end
			if
				progressMode == "always"
				and first
				and second
				and (firstID == secondID or Core.questIDs(id).progress ~= "state")
			then
				for index, objective in ipairs(first.objectives) do
					local other = second.objectives[index]
					if
						other
						and objective.need > 0
						and other.need == objective.need
						and (
							(first.state == "active" and objective.have < objective.need)
							or (second.state == "active" and other.have < other.need)
						)
					then
						-- Existing actionable rows win deduplication, regardless of pair order.
						addDifference(firstIndex, "progress", "objective", index, objective, true)
						addDifference(secondIndex, "progress", "objective", index, other, true)
					end
				end
			end
		end
		for firstIndex = 0, #members do
			if snapshots[firstIndex] then
				for secondIndex = firstIndex + 1, #members do
					if snapshots[secondIndex] then
						comparePair(firstIndex, secondIndex)
					end
				end
			end
		end
		if progressMode == "self" then
			for index = #group.differences, 1, -1 do
				local difference = group.differences[index]
				local playerIndex = playerOrder[difference]
				if difference.objective then
					local _, sourceID = Core.matchQuest(snapshots[playerIndex], id)
					local objective = localQuest and localQuest.objectives[objectiveOrder[difference]]
					local comparable = localQuest
						and (
							localID == sourceID
							or (
								Core.questIDs(id).progress ~= "state"
								and (localQuest.state ~= "completed" or Core.questIDs(id).history ~= false)
							)
						)
					local finished = comparable
						and (
							localQuest.state ~= "active"
							or (
								objective
								and objective.need == difference.objective.need
								and objective.have >= objective.need
							)
						)
					if not finished then
						table.remove(group.differences, index)
						hasObjectives[playerIndex] = nil
					end
				end
			end
			-- A player may have both hidden and visible objectives.
			for _, difference in ipairs(group.differences) do
				if difference.objective then
					hasObjectives[playerOrder[difference]] = true
				end
			end
		end
		for index = #group.differences, 1, -1 do
			local difference = group.differences[index]
			if difference.reason == "active" and hasObjectives[playerOrder[difference]] then
				table.remove(group.differences, index)
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
				if a.reason ~= b.reason then
					return reasonOrder[a.reason] < reasonOrder[b.reason]
				end
				return objectiveOrder[a] < objectiveOrder[b]
			end)
			groups[#groups + 1] = group
		end
	end
	Core.sortGroups(groups)
	return groups, complete, notices, playerIndices
end
