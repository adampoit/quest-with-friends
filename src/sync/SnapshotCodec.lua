local _, QWF = ...
QWF = QWF or QuestWithFriends or {}
if QWF.disabled then
	return
end
QWF.SnapshotCodec = {}
local Codec = QWF.SnapshotCodec
Codec.PROTOCOL_MAJOR = 1
Codec.PROTOCOL_MINOR = 3
Codec.PROTOCOL_VERSION = Codec.PROTOCOL_MAJOR .. "." .. Codec.PROTOCOL_MINOR
Codec.MAX_SNAPSHOT_BYTES = 22000
local MAX_QUESTS = 500
Codec.CHUNK_SIZE = 220
Codec.MAX_PARTS = 100
Codec.MAX_MESSAGE_BYTES = 255
local MAX_EXTENSION_BYTES = 1024
local MAX_EXTENSIONS = 32
local MAX_EXTENSION_TAG_BYTES = 32
local MAX_EXTENSION_VALUE_BYTES = 512

function Codec.field(value)
	value = tostring(value or "")
	return #value .. ":" .. value
end

function Codec.readField(data, position, maxLength)
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

local field, readField = Codec.field, Codec.readField

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

function Codec.parseProtocolVersion(version)
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

local function sortedKeys(values)
	local keys = {}
	for key in pairs(values) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function serializeExtensions(extensions, tags)
	local parts = {}
	for _, tag in ipairs(tags) do
		parts[#parts + 1] = field(tag) .. field(extensions[tag])
	end
	return table.concat(parts)
end

local function encodeExtensions(extensions)
	if not extensions then
		return ""
	end
	assert(type(extensions) == "table", "Extensions must be a tag-to-string table")
	for tag, value in pairs(extensions) do
		assert(validExtensionTag(tag), "Invalid extension tag")
		assert(type(value) == "string" and #value <= MAX_EXTENSION_VALUE_BYTES, "Invalid extension value")
	end
	local tags = sortedKeys(extensions)
	assert(#tags <= MAX_EXTENSIONS, "Too many extensions")
	local data = serializeExtensions(extensions, tags)
	assert(#data <= MAX_EXTENSION_BYTES, "Extension block exceeds protocol limit")
	return data
end

local function decodeExtensions(data)
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
		seen[tag] = value
		count = count + 1
		position = afterValue
	end
	return seen
end

local function encodeItemStock(objectives)
	local parts, size = {}, 0
	for index, objective in ipairs(objectives) do
		if objective.itemID and objective.spare ~= nil then
			local row = field(index) .. field(objective.itemID) .. field(objective.spare)
			if size + #row > MAX_EXTENSION_VALUE_BYTES then
				break
			end
			parts[#parts + 1] = row
			size = size + #row
		end
	end
	return #parts > 0 and table.concat(parts) or nil
end

local function decodeItemStock(data, objectives)
	local position, previous = 1, 0
	while position <= #data do
		local indexText, afterIndex = readField(data, position, 2)
		local index = integer(indexText, #objectives)
		if not index or index <= previous or not afterIndex then
			return false
		end
		local idText, afterID = readField(data, afterIndex, 9)
		local id = integer(idText, 100000000)
		if not id or id == 0 or not afterID then
			return false
		end
		local spareText, afterSpare = readField(data, afterID, 9)
		local spare = integer(spareText, 100000000)
		if
			not spare
			or not afterSpare
			or objectives[index].need == 0
			or (spare > 0 and objectives[index].have < objectives[index].need)
		then
			return false
		end
		objectives[index].itemID, objectives[index].spare = id, spare
		previous, position = index, afterSpare
	end
	return true
end

function Codec.encode(quests, extensions, minor)
	minor = minor or Codec.PROTOCOL_MINOR
	local ids = sortedKeys(quests)
	local parts = { field(Codec.PROTOCOL_MAJOR), field(minor), field(#ids) }
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
		local questExtensions = {}
		for tag, value in pairs(quest.extensions or {}) do
			questExtensions[tag] = value
		end
		if minor >= 1 then
			questExtensions.item_stock = encodeItemStock(quest.objectives) or questExtensions.item_stock
		end
		parts[#parts + 1] = field(encodeExtensions(questExtensions))
	end
	parts[#parts + 1] = field(encodeExtensions(extensions))
	return table.concat(parts)
end

-- Reassemble canonical snapshot content from already validated wire records.
-- The caller validates the result when adding metadata or merging records.
function Codec.encodeRecords(version, records, extensions)
	local major, minor = version:match("^(%d+)%.(%d+)$")
	local ids = sortedKeys(records)
	local parts = { field(major), field(minor), field(#ids) }
	for _, id in ipairs(ids) do
		parts[#parts + 1] = records[id]
	end
	parts[#parts + 1] = field(serializeExtensions(extensions, sortedKeys(extensions)))
	return table.concat(parts)
end

function Codec.decode(data, expectedVersion, retainWireRecords, minor, maxSnapshotBytes)
	minor = minor or Codec.PROTOCOL_MINOR
	if type(data) ~= "string" or #data > (maxSnapshotBytes or Codec.MAX_SNAPSHOT_BYTES) then
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
		Codec.parseProtocolVersion(version) ~= Codec.PROTOCOL_MAJOR or (expectedVersion and version ~= expectedVersion)
	then
		return nil
	end
	local count = integer(nextField(3), MAX_QUESTS)
	if not count then
		return nil
	end
	local quests = {}
	local records = retainWireRecords and {} or nil
	for _ = 1, count do
		local recordStart = position
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
		local extensions = decodeExtensions(nextField(MAX_EXTENSION_BYTES))
		if not extensions then
			return nil
		end
		if
			minor >= 1
			and tonumber(minorText) >= 1
			and extensions.item_stock
			and not decodeItemStock(extensions.item_stock, objectives)
		then
			return nil
		end
		if records then
			records[id] = data:sub(recordStart, position - 1)
		end
		quests[id] = {
			title = title,
			state = state,
			objectives = objectives,
			mapID = mapID ~= 0 and mapID or nil,
			category = category ~= "" and category or nil,
		}
	end
	local extra = decodeExtensions(nextField(MAX_EXTENSION_BYTES))
	if not extra or position ~= #data + 1 then
		return nil
	end
	if records then
		return quests, { version = version, records = records, extra = extra }
	end
	return quests
end

function Codec.new(minor, maxSnapshotBytes)
	local function encode(quests, extensions)
		return Codec.encode(quests, extensions, minor)
	end

	local function selectQuests(base, offerOptionalQuests)
		local count = 0
		if not offerOptionalQuests then
			for _ in pairs(base) do
				count = count + 1
			end
			return base, count
		end

		local selected = {}
		for id, quest in pairs(base) do
			selected[id] = quest
			count = count + 1
		end
		local size, emptySize
		offerOptionalQuests(selected, function(id, quest)
			if selected[id] or count >= MAX_QUESTS then
				return false
			end
			-- Budget against the baseline; callers can drop optional snapshot extensions later.
			size = size or #encode(selected)
			emptySize = emptySize or #encode({})
			local recordSize = #encode({ [id] = quest }) - emptySize
			local nextSize = size + recordSize + #field(count + 1) - #field(count)
			if nextSize > maxSnapshotBytes then
				return false
			end
			selected[id] = quest
			count, size = count + 1, nextSize
			return true
		end)
		return selected, count
	end

	return {
		version = Codec.PROTOCOL_MAJOR .. "." .. minor,
		MAX_SNAPSHOT_BYTES = maxSnapshotBytes,
		encode = encode,
		selectQuests = selectQuests,
		decode = function(data, expectedVersion, retainWireRecords)
			return Codec.decode(data, expectedVersion, retainWireRecords, minor, maxSnapshotBytes)
		end,
	}
end
