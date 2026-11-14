local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
QWF.NativeProgress = {}
local Native = QWF.NativeProgress
local OBSERVATION_LIFETIME = 15
local QUERY_INTERVAL = 2

local function public(value)
	return not (issecretvalue and issecretvalue(value))
end

local function readableTable(value)
	return public(value) and type(value) == "table"
end

local function text(value)
	return public(value) and type(value) == "string" and value or nil
end

local function number(value)
	return public(value) and type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function objectiveText(value)
	return value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%s*%d+/%d+%s+", ""):gsub(":%s*%d+/%d+%s*$", "")
end

local function query(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if ok and public(result) then
		return result
	end
end

function Native.new()
	return setmetatable({ observed = {}, queried = {} }, { __index = Native })
end

function Native:available()
	return C_TooltipInfo
		and type(C_TooltipInfo.GetQuestPartyProgress) == "function"
		and type(UnitGUID) == "function"
		and Enum
		and Enum.TooltipDataLineType
end

function Native:reset()
	self.observed, self.queried = {}, {}
end

function Native:invalidate()
	self.queried = {}
end

-- QuestPlayer.guid and QuestObjective counters are shared by unit and party tooltips.
-- See dev/NATIVE_PROGRESS.md for the source references and deliberately unknown states.
local function read(data, seedID, seedTitle)
	local result = {}
	local types = Enum and Enum.TooltipDataLineType
	if not types or not readableTable(data) or not readableTable(data.lines) then
		return result
	end
	local id, title, objectives = seedID, seedTitle, nil
	for _, line in ipairs(data.lines) do
		if not readableTable(line) or not public(line.type) then
			-- Never let an unreadable header assign subsequent rows to the previous player.
			id, objectives = nil, nil
		elseif line.type == types.QuestTitle then
			id = number(line.id) and line.id > 0 and line.id <= 100000000 and line.id % 1 == 0 and line.id or nil
			title, objectives = text(line.leftText) or seedTitle, nil
		elseif line.type == types.QuestPlayer then
			objectives = nil
			local guid = text(line.guid)
			if id and guid then
				local quest = result[id] or { title = title, players = {} }
				result[id] = quest
				objectives = {}
				quest.players[guid] = objectives
			end
		elseif line.type == types.QuestObjective and objectives then
			local label = text(line.leftText)
			local have, need = line.numFulfilled, line.numRequired
			if
				label
				and number(have)
				and number(need)
				and need > 0
				and public(line.progressBarPercent)
				and line.progressBarPercent == nil
				and not label:find("%%")
			then
				objectives[#objectives + 1] = { text = objectiveText(label), have = have, need = need }
			end
		end
	end
	return result
end

function Native:observeUnit(unit, now)
	local changed = false
	local data = query(C_TooltipInfo and C_TooltipInfo.GetUnit, unit)
	for id, quest in pairs(read(data)) do
		local saved = self.observed[id] or { title = quest.title, players = {} }
		self.observed[id] = saved
		for guid, objectives in pairs(quest.players) do
			if #objectives > 0 then
				saved.players[guid] = { objectives = objectives, at = now }
				changed = true
			end
		end
	end
	return changed
end

local function matchObjectives(template, observed)
	local objectives = {}
	for index, objective in ipairs(template.objectives) do
		local match, matches = nil, 0
		local label = objectiveText(objective.text)
		for _, candidate in ipairs(observed) do
			if candidate.text == label and candidate.need == objective.need then
				match, matches = candidate, matches + 1
			end
		end
		local duplicates = 0
		for _, other in ipairs(template.objectives) do
			if objectiveText(other.text) == label and other.need == objective.need then
				duplicates = duplicates + 1
			end
		end
		-- Preserve indices without inventing a zero count for an unobserved objective.
		if match and matches == 1 and duplicates == 1 then
			objectives[index] = { text = objective.text, have = match.have, need = match.need }
		else
			objectives[index] = { text = objective.text, have = 0, need = 0 }
		end
	end
	return objectives
end

local function playerObjectives(party, unit, guid)
	local rows = party and party.players[guid]
	if rows and #rows > 0 then
		return rows
	end
	return unit and unit.players[guid] and unit.players[guid].objectives
end

function Native:collect(templates, members, now)
	local result, eligible, candidates = {}, {}, {}
	if not self:available() then
		return result
	end
	for _, member in ipairs(members) do
		if member.nativeEligible then
			local guid = query(UnitGUID, member.unit)
			if public(guid) and type(guid) == "string" then
				eligible[guid] = member
				result[member.key] = {}
			end
		end
	end
	if not next(eligible) then
		self:reset()
		return result
	end
	for id, quest in pairs(templates) do
		candidates[id] = quest
	end
	for id, quest in pairs(self.observed) do
		for guid, record in pairs(quest.players) do
			if not eligible[guid] or now - record.at >= OBSERVATION_LIFETIME then
				quest.players[guid] = nil
			end
		end
		if not next(quest.players) then
			self.observed[id] = nil
		else
			candidates[id] = candidates[id] or { title = quest.title, objectives = {} }
		end
	end
	for id in pairs(self.queried) do
		if not candidates[id] then
			self.queried[id] = nil
		end
	end
	for id, template in pairs(candidates) do
		local cached = self.queried[id]
		if not cached or now - cached.at >= QUERY_INTERVAL then
			cached = {
				at = now,
				data = read(query(C_TooltipInfo.GetQuestPartyProgress, id, false, true), id, template.title),
			}
			self.queried[id] = cached
			local discovered = self.observed[id]
			local party = cached.data[id]
			if discovered and party then
				for guid, rows in pairs(party.players) do
					if eligible[guid] and #rows > 0 then
						discovered.players[guid] = { objectives = rows, at = now }
					end
				end
			end
		end
		local party = cached.data[id]
		local unit = self.observed[id]
		local mapping = template
		if #template.objectives == 0 then
			mapping = { objectives = {} }
			local seen = {}
			for guid in pairs(eligible) do
				local rows = playerObjectives(party, unit, guid)
				for _, objective in ipairs(rows or {}) do
					local key = objective.text .. ":" .. objective.need
					if not seen[key] then
						seen[key] = true
						mapping.objectives[#mapping.objectives + 1] = objective
					end
				end
			end
		end
		for guid, member in pairs(eligible) do
			local observed = playerObjectives(party, unit, guid)
			local onQuest = query(C_QuestLog and C_QuestLog.IsUnitOnQuest, member.unit, id)
			-- A false IsUnitOnQuest cannot distinguish missing from previously completed.
			if (observed and #observed > 0) or onQuest == true then
				local objectives = matchObjectives(mapping, observed or {})
				result[member.key][id] = {
					title = template.title or ("Quest " .. id),
					state = "active",
					stateUnknown = true,
					objectives = objectives,
					mapID = template.mapID,
					category = template.category,
				}
			end
		end
	end
	return result
end
