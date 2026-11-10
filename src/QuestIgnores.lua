local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
local Core = QWF.Core
QWF.QuestIgnores = {}
local Ignores = QWF.QuestIgnores

local function copySet(source)
	local result = {}
	for key, value in pairs(source or {}) do
		if value == true then
			result[key] = true
		end
	end
	return result
end

function Ignores.new(saved)
	saved = type(saved) == "table" and saved or {}
	for _, field in ipairs({ "ignored", "members", "pending", "lastMissing", "baseline", "candidates", "existing" }) do
		saved[field] = type(saved[field]) == "table" and saved[field] or {}
	end
	for id, entry in pairs(saved.ignored) do
		if
			type(id) ~= "number"
			or type(entry) ~= "table"
			or type(entry.title) ~= "string"
			or type(entry.missing) ~= "table"
		then
			saved.ignored[id] = nil
		end
	end
	return setmetatable({ saved = saved }, { __index = Ignores })
end

function Ignores:roster(keys)
	local saved, added = self.saved, false
	for key in pairs(keys) do
		if not saved.members[key] then
			if not next(saved.pending) then
				saved.baseline = copySet(saved.lastMissing)
				saved.existing = {}
				saved.baselineKnown = false
			end
			saved.pending[key] = true
			added = true
		end
	end
	for key in pairs(saved.pending) do
		if not keys[key] then
			saved.pending[key] = nil
		end
	end
	saved.members = copySet(keys)
	return added
end

local function missingPlayers(group, indices, roster, myself)
	local missing = {}
	for _, difference in ipairs(group.differences) do
		if difference.kind == "missing" then
			local index = indices[difference]
			local key = index == 0 and myself or (roster[index] and roster[index].key)
			if key then
				missing[key] = true
			end
		end
	end
	return missing
end

function Ignores:observe(groups, indices, localQuests, roster, myself)
	local saved, snapshots = self.saved, { [myself] = localQuests }
	local available = false
	local function remember(quests)
		for id, quest in pairs(quests or {}) do
			if quest.state ~= "completed" then
				saved.existing[Core.questIDs(id)[1]] = true
			end
		end
	end
	if not saved.baselineKnown and next(saved.pending) then
		remember(localQuests)
		for _, member in ipairs(roster) do
			remember(member.quests)
		end
		saved.baselineKnown = true
	end
	for _, member in ipairs(roster) do
		snapshots[member.key] = member.quests
		if saved.pending[member.key] and member.quests then
			remember(member.quests)
			available = true
		end
	end
	for id, entry in pairs(saved.ignored) do
		for key in pairs(entry.missing) do
			local quest = snapshots[key] and Core.matchQuest(snapshots[key], id)
			if quest and quest.state ~= "completed" then
				saved.ignored[id] = nil
				if self.undoEntries then
					self.undoEntries[id] = nil
				end
				break
			end
		end
	end
	local missingNow = {}
	for _, group in ipairs(groups) do
		local missing = missingPlayers(group, indices, roster, myself)
		if next(missing) then
			missingNow[group.questID] = true
			if
				available
				and saved.existing[group.questID]
				and (saved.candidates[group.questID] or not saved.baseline[group.questID])
				and not saved.ignored[group.questID]
			then
				-- Freeze each member's first comparison; later pickups are not part of the join offer.
				local entry = saved.candidates[group.questID]
				if not entry then
					saved.candidates[group.questID] = { title = group.title, missing = missing }
				else
					for key in pairs(missing) do
						entry.missing[key] = true
					end
				end
			end
		end
	end
	for key in pairs(saved.pending) do
		if snapshots[key] then
			saved.pending[key] = nil
		end
	end
	saved.lastMissing = missingNow
	self.groups, self.indices, self.currentRoster, self.myself = groups, indices, roster, myself
end

function Ignores:candidates(source)
	local result = {}
	for _, group in ipairs(self.groups or {}) do
		local candidate = (source or self.saved.candidates)[group.questID]
		local ignored = self.saved.ignored[group.questID]
		if candidate and not (ignored and ignored.whole) then
			local missing, retained = missingPlayers(group, self.indices, self.currentRoster, self.myself), {}
			for key in pairs(candidate.missing) do
				if missing[key] and not (ignored and ignored.missing[key]) then
					retained[key] = true
				end
			end
			if next(retained) then
				result[group.questID] = { title = group.title, missing = retained }
			end
		end
	end
	return result
end

function Ignores:missingEntries()
	local entries = {}
	for _, group in ipairs(self.groups or {}) do
		local missing = missingPlayers(group, self.indices, self.currentRoster, self.myself)
		local ignored = self.saved.ignored[group.questID]
		for key in pairs(missing) do
			if ignored and (ignored.whole or ignored.missing[key]) then
				missing[key] = nil
			end
		end
		if next(missing) then
			entries[group.questID] = { title = group.title, missing = missing }
		end
	end
	return entries
end

function Ignores:finishOffer()
	self.saved.pending, self.saved.candidates, self.saved.baseline, self.saved.existing = {}, {}, {}, {}
	self.saved.baselineKnown = nil
end

function Ignores:ignore(entries)
	local undo = {}
	for id, entry in pairs(entries) do
		local before = self.saved.ignored[id]
		local after = {
			title = entry.title,
			missing = copySet(before and before.missing),
			whole = entry.whole == true or (before and before.whole) or false,
		}
		local changed = not before or after.whole ~= before.whole
		for key in pairs(entry.missing) do
			changed = changed or not after.missing[key]
			after.missing[key] = true
		end
		if changed then
			self.saved.ignored[id] = after
			undo[id] = { before = before, after = after }
		end
	end
	self.undoEntries = undo
	return undo
end

function Ignores:ignoreQuest(id)
	for _, group in ipairs(self.groups or {}) do
		if group.questID == id then
			return self:ignore({
				[id] = {
					title = group.title,
					missing = missingPlayers(group, self.indices, self.currentRoster, self.myself),
					whole = true,
				},
			})
		end
	end
end

function Ignores:undo()
	for id, entry in pairs(self.undoEntries or {}) do
		if self.saved.ignored[id] == entry.after then
			self.saved.ignored[id] = entry.before
		end
	end
	self.undoEntries = nil
end

function Ignores:restore(id)
	if id then
		self.saved.ignored[id] = nil
		if self.undoEntries then
			self.undoEntries[id] = nil
		end
	else
		self.saved.ignored = {}
		self.undoEntries = nil
	end
end

function Ignores:list()
	local groups = {}
	for id, entry in pairs(self.saved.ignored) do
		groups[#groups + 1] = { questID = id, title = entry.title, differences = {}, ignored = true }
	end
	Core.sortGroups(groups, "title")
	return groups
end

function Ignores:filter(groups, indices, roster, myself)
	local result = {}
	for _, group in ipairs(groups) do
		local entry = self.saved.ignored[group.questID]
		if not entry then
			result[#result + 1] = group
		elseif not entry.whole then
			local filtered = { questID = group.questID, title = group.title, differences = {} }
			for _, difference in ipairs(group.differences) do
				local index = indices[difference]
				local key = index == 0 and myself or (roster[index] and roster[index].key)
				if difference.kind ~= "missing" or not entry.missing[key] then
					filtered.differences[#filtered.differences + 1] = difference
					if difference.kind == "missing" then
						filtered.shareQuestID = group.shareQuestID
					end
				end
			end
			if #filtered.differences > 0 then
				result[#result + 1] = filtered
			end
		end
	end
	return result
end
