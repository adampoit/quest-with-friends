-- Run from a trusted local QuestieDB checkout using its Lua 5.1 emulator.
local output = assert(arg[1], "output path required")
local client = dofile("emulator/client.lua")
local emulator = dofile("emulator/metadata.lua")
client.install({ expansion = "Forever", gameType = "forever" })
emulator.install("QuestieDB", emulator.parse("QuestieDB.toc"))
local db = emulator.loadAddon("QuestieDB.toc", "QuestieDB")
assert(db.flavor.name == "Forever", "Wrong QuestieDB flavor")

local function quote(value)
	return '"'
		.. value:gsub('[%z\1-\31\\"]', function(char)
			if char == '"' then
				return '\\"'
			end
			if char == "\\" then
				return "\\\\"
			end
			return string.format("\\u%04x", string.byte(char))
		end)
		.. '"'
end

local function json(value)
	local kind = type(value)
	if kind == "nil" then
		return "null"
	end
	if kind == "string" then
		return quote(value)
	end
	if kind == "number" or kind == "boolean" then
		return tostring(value)
	end
	assert(kind == "table", "unexpected value type: " .. kind)
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local result = {}
	for _, key in ipairs(keys) do
		result[#result + 1] = quote(tostring(key)) .. ":" .. json(value[key])
	end
	return "{" .. table.concat(result, ",") .. "}"
end

-- Materialize corrections and Derived passes; raw payload files omit new quests.
-- Keep positional holes and field presence, rather than normalized empty/zero getters.
local quests = {}
local entities = db.read.source.Materialize("Quest")
for _, id in ipairs(db.Quest.GetAllIds()) do
	local row = { presentFields = {} }
	for key, index in pairs(db.Enum.questKeys) do
		if not key:match("_add$") and not key:match("_remove$") then
			local value = entities[id][index]
			if value ~= nil then
				row[key] = value
				row.presentFields[key] = true
			end
		end
	end
	quests[tostring(id)] = row
end
local file = assert(io.open(output, "w"))
file:write(json({
	flavor = db.flavor.name,
	quests = quests,
	questFlags = db.Enum.questFlags,
	specialFlags = db.Enum.specialFlags,
}))
file:close()
client.reset()
