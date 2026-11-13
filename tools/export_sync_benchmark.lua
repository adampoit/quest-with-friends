-- Run inside the pinned, trusted QuestieDB checkout, like export_questiedb.lua.
local output = assert(arg[1], "output Lua fixture path required")
local client = dofile("emulator/client.lua")
local emulator = dofile("emulator/metadata.lua")
client.install({ expansion = "Forever", gameType = "forever" })
emulator.install("QuestieDB", emulator.parse("QuestieDB.toc"))
local db = emulator.loadAddon("QuestieDB.toc", "QuestieDB")
local active = { 9, 13, 22, 38, 64, 103, 104, 117, 151, 152, 153, 20, 34, 89, 91, 92, 115, 116, 125, 150 }
local history = {
	783,
	7,
	15,
	21,
	33,
	18,
	6,
	3903,
	5261,
	47,
	60,
	62,
	76,
	40,
	35,
	37,
	45,
	71,
	39,
	52,
	46,
	83,
	85,
	86,
	84,
	87,
	106,
	111,
	107,
	112,
}
-- Quantities reviewed against objectivesText; database target rows do not contain them.
local quantities = {
	[9] = { 20 },
	[13] = { 15, 15 },
	[22] = { 8 },
	[38] = { 3, 3, 3, 3 },
	[64] = { 1 },
	[103] = { 5 },
	[104] = { 1 },
	[117] = { 5 },
	[151] = { 8 },
	[152] = { 7, 7, 7, 7 },
	[153] = { 15 },
	[20] = { 10 },
	[34] = { 1 },
	[89] = { 5, 5 },
	[91] = { 10 },
	[92] = { 5, 5, 5 },
	[115] = { 3 },
	[116] = { 1, 1, 1, 1 },
	[125] = { 1 },
	[150] = { 8 },
}
local baseEntities = {}
local function targetName(entity, kind, id)
	local name = entity.name(id)
	if name then
		return name
	end
	-- Some legacy entity rows are absent from the composed API; retain their authored base names.
	local label = ({ "Npc", "Object", "Item" })[kind]
	if not baseEntities[kind] then
		local legacy = {}
		local env = setmetatable(
			{ QuestieLoader = {
				ImportModule = function()
					return legacy
				end,
			} },
			{ __index = _G }
		)
		setfenv(assert(loadfile("data/Forever/forever" .. label .. "DB.lua")), env)()
		baseEntities[kind] = legacy[label:lower() .. "Data"]
	end
	local data = baseEntities[kind]
	local first = data:match("\n%[" .. id .. "%]%s*=%s*{%s*()")
	if not first then
		return nil
	end
	local quote, escaped = data:sub(first, first), false
	assert(quote == "'" or quote == '"')
	for last = first + 1, #data do
		local char = data:sub(last, last)
		if char == quote and not escaped then
			return assert(loadstring("return " .. data:sub(first, last)))()
		end
		if char == "\\" and not escaped then
			escaped = true
		else
			escaped = false
		end
	end
end
local quests = {}
for _, ids in ipairs({ active, history }) do
	for _, id in ipairs(ids) do
		local name = assert(db.Quest.name(id), "missing quest " .. id)
		local summary = table.concat(db.Quest.objectivesText(id) or {}, " ")
		local numbers = {}
		for n in summary:gmatch("%d+") do
			numbers[#numbers + 1] = tonumber(n)
		end
		local objectives = {}
		local targets = db.Quest.objectives(id) or {}
		for kind, entity in ipairs({ db.Npc, db.Object, db.Item }) do
			for _, row in ipairs(targets[kind] or {}) do
				local index = #objectives + 1
				local label = row[2] or assert(targetName(entity, kind, row[1]), "missing target " .. row[1])
				objectives[index] = {
					text = label .. (kind == 1 and not row[2] and " slain" or ""),
					numRequired = quantities[id] and quantities[id][index] or numbers[index] or 1,
					type = kind == 3 and "item" or "monster",
					targetID = row[1],
				}
			end
		end
		local trigger = db.Quest.triggerEnd(id)
		if #objectives == 0 and trigger and trigger[1] then
			objectives[1] = { text = trigger[1], numRequired = 1, type = "event" }
		end
		if quantities[id] then
			assert(#quantities[id] == #objectives, "quantity/target mismatch " .. id)
		end
		quests[id] =
			{ title = name, zoneID = db.Quest.zoneOrSort(id), objectives = objectives, sourceSummary = summary }
	end
end
local function lua(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	local keys, parts = {}, {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return type(a) == type(b) and a < b or type(a) < type(b)
	end)
	for _, key in ipairs(keys) do
		parts[#parts + 1] = "[" .. lua(key) .. "]=" .. lua(value[key])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end
local file = assert(io.open(output, "w"))
file:write(
	"return ",
	lua({
		source = "Questie/QuestieDB",
		revision = "e0a6eaa86f181ac99262e34126bcd2ed1a1712d6",
		active = active,
		history = history,
		quests = quests,
	}),
	"\n"
)
file:close()
client.reset()
