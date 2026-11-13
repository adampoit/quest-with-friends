local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
local Core = QWF.Core
local Sync = {}
QWF.Sync = Sync

-- SHA-256/128. Arithmetic fallbacks keep the wire digest identical on Lua 5.1 clients without bit libraries.
local MOD = 4294967296
local nibbleAnd = {}
for a = 0, 15 do
	nibbleAnd[a] = {}
	for b = 0, 15 do
		local x, y, value, place = a, b, 0, 1
		for _ = 1, 4 do
			if x % 2 == 1 and y % 2 == 1 then
				value = value + place
			end
			x, y, place = math.floor(x / 2), math.floor(y / 2), place * 2
		end
		nibbleAnd[a][b] = value
	end
end
local function band(a, b)
	local result, place = 0, 1
	for _ = 1, 8 do
		result = result + nibbleAnd[a % 16][b % 16] * place
		a, b, place = math.floor(a / 16), math.floor(b / 16), place * 16
	end
	return result
end
local function bxor(a, b)
	return (a + b - 2 * band(a, b)) % MOD
end
local bits = rawget(_G, "bit") or rawget(_G, "bit32")
if bits then
	band = function(a, b)
		return bits.band(a, b) % MOD
	end
	bxor = function(a, b)
		return bits.bxor(a, b) % MOD
	end
end
local function rshift(a, n)
	return math.floor(a / 2 ^ n)
end
local function rotate(a, n)
	return rshift(a, n) + (a % 2 ^ n) * 2 ^ (32 - n)
end
local function xor3(a, b, c)
	return bxor(bxor(a, b), c)
end
local K = {
	0x428a2f98,
	0x71374491,
	0xb5c0fbcf,
	0xe9b5dba5,
	0x3956c25b,
	0x59f111f1,
	0x923f82a4,
	0xab1c5ed5,
	0xd807aa98,
	0x12835b01,
	0x243185be,
	0x550c7dc3,
	0x72be5d74,
	0x80deb1fe,
	0x9bdc06a7,
	0xc19bf174,
	0xe49b69c1,
	0xefbe4786,
	0x0fc19dc6,
	0x240ca1cc,
	0x2de92c6f,
	0x4a7484aa,
	0x5cb0a9dc,
	0x76f988da,
	0x983e5152,
	0xa831c66d,
	0xb00327c8,
	0xbf597fc7,
	0xc6e00bf3,
	0xd5a79147,
	0x06ca6351,
	0x14292967,
	0x27b70a85,
	0x2e1b2138,
	0x4d2c6dfc,
	0x53380d13,
	0x650a7354,
	0x766a0abb,
	0x81c2c92e,
	0x92722c85,
	0xa2bfe8a1,
	0xa81a664b,
	0xc24b8b70,
	0xc76c51a3,
	0xd192e819,
	0xd6990624,
	0xf40e3585,
	0x106aa070,
	0x19a4c116,
	0x1e376c08,
	0x2748774c,
	0x34b0bcb5,
	0x391c0cb3,
	0x4ed8aa4a,
	0x5b9cca4f,
	0x682e6ff3,
	0x748f82ee,
	0x78a5636f,
	0x84c87814,
	0x8cc70208,
	0x90befffa,
	0xa4506ceb,
	0xbef9a3f7,
	0xc67178f2,
}
function Sync.digest(data)
	local length = #data * 8
	data = data
		.. string.char(128)
		.. string.rep("\0", (55 - #data) % 64)
		.. string.char(
			0,
			0,
			0,
			0,
			rshift(length, 24) % 256,
			rshift(length, 16) % 256,
			rshift(length, 8) % 256,
			length % 256
		)
	local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	for start = 1, #data, 64 do
		local w = {}
		for i = 0, 15 do
			local a, b, c, d = data:byte(start + i * 4, start + i * 4 + 3)
			w[i] = a * 16777216 + b * 65536 + c * 256 + d
		end
		for i = 16, 63 do
			local a, b = w[i - 15], w[i - 2]
			w[i] = (
				w[i - 16]
				+ xor3(rotate(a, 7), rotate(a, 18), rshift(a, 3))
				+ w[i - 7]
				+ xor3(rotate(b, 17), rotate(b, 19), rshift(b, 10))
			) % MOD
		end
		local a, b, c, d, e, f, g, j = unpack(h)
		for i = 0, 63 do
			local t1 = (
				j
				+ xor3(rotate(e, 6), rotate(e, 11), rotate(e, 25))
				+ bxor(band(e, f), band(MOD - 1 - e, g))
				+ K[i + 1]
				+ w[i]
			) % MOD
			local t2 = (xor3(rotate(a, 2), rotate(a, 13), rotate(a, 22)) + xor3(band(a, b), band(a, c), band(b, c)))
				% MOD
			j, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
		end
		local values = { a, b, c, d, e, f, g, j }
		for i = 1, 8 do
			h[i] = (h[i] + values[i]) % MOD
		end
	end
	return string.format("%08x%08x%08x%08x", h[1], h[2], h[3], h[4])
end

local function field(value)
	value = tostring(value)
	return #value .. ":" .. value
end
local function reader(data)
	local position = 1
	return function()
		if position == #data + 1 then
			return nil, position
		end
		local first, last, size = data:find("(%d+):", position)
		if first ~= position or last - first > 5 then
			return nil
		end
		size = tonumber(size)
		if not size or last + size > #data then
			return nil
		end
		local value = data:sub(last + 1, last + size)
		position = last + size + 1
		return value, position
	end
end
local function number(value, maximum)
	if not value or not value:match("^%d+$") then
		return nil
	end
	local n = tonumber(value)
	if not n or n > maximum or tostring(n) ~= value then
		return nil
	end
	return n
end
local function token(value)
	return type(value) == "string" and #value == 32 and value:match("^[0-9a-f]+$") ~= nil
end
local function extensions(values)
	local tags, parts = {}, {}
	for tag in pairs(values) do
		tags[#tags + 1] = tag
	end
	table.sort(tags)
	for _, tag in ipairs(tags) do
		parts[#parts + 1] = field(tag) .. field(values[tag])
	end
	return table.concat(parts)
end
local function payload(version, records, extra)
	local ids, parts = {}, { field(1), field(version:match("%.(%d+)$")) }
	for id in pairs(records) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	parts[#parts + 1] = field(#ids)
	for _, id in ipairs(ids) do
		parts[#parts + 1] = records[id]
	end
	parts[#parts + 1] = field(extensions(extra))
	return table.concat(parts)
end

function Sync.identity(data)
	local nextField = reader(data)
	local session, sequence, digest = nextField(), number(nextField(), 100000000), nextField()
	local trailing, finish = nextField()
	if
		not token(session)
		or not sequence
		or sequence < 1
		or not token(digest)
		or trailing ~= nil
		or finish ~= #data + 1
	then
		return nil
	end
	return { session = session, sequence = sequence, digest = digest }
end
function Sync.identityText(state)
	return field(state.session) .. field(state.sequence) .. field(state.digest)
end
function Sync.session(value)
	return token(value)
end

-- Retain raw quest records, including unknown extensions; decode/re-encode would discard them.
function Sync.readSnapshot(data, expectedVersion)
	local quests = Core.decode(data, expectedVersion)
	if not quests then
		return nil
	end
	local nextField = reader(data)
	local major, minor = nextField(), nextField()
	local version = major .. "." .. minor
	local count, position = nextField()
	count = tonumber(count)
	local records = {}
	for _ = 1, count do
		local start = position
		local id = tonumber((nextField()))
		for _ = 1, 4 do
			nextField()
		end
		local objectives = tonumber((nextField()))
		for _ = 1, objectives * 3 do
			nextField()
		end
		_, position = nextField()
		if not id or not position then
			return nil
		end
		records[id] = data:sub(start, position - 1)
	end
	local extra, block = {}, nextField()
	if not block then
		return nil
	end
	local nextExtension = reader(block)
	while true do
		local tag = nextExtension()
		if not tag then
			break
		end
		extra[tag] = nextExtension()
	end
	local identity
	if extra.sync and tonumber(minor) >= 2 then
		identity = Sync.identity(extra.sync)
		if not identity then
			return nil
		end
		extra.sync = nil
	end
	local content = payload(version, records, extra)
	local digest = Sync.digest(content)
	if identity and identity.digest ~= digest then
		return nil
	end
	local state = identity or { digest = digest }
	state.content, state.records, state.extra, state.version, state.quests = content, records, extra, version, quests
	return state
end

function Sync.snapshot(content, session, sequence)
	local state = Sync.readSnapshot(content)
	if not state then
		return nil
	end
	state.session, state.sequence = session, sequence
	local extra = {}
	for tag, value in pairs(state.extra) do
		extra[tag] = value
	end
	extra.sync = Sync.identityText(state)
	local encoded = payload(state.version, state.records, extra)
	if #encoded > Core.MAX_SNAPSHOT_BYTES or not Core.decode(encoded) then
		return nil
	end
	return state, encoded
end

function Sync.patch(base, target)
	local removed, changed = {}, {}
	for id in pairs(base.records) do
		if not target.records[id] then
			removed[#removed + 1] = id
		end
	end
	table.sort(removed)
	for id, record in pairs(target.records) do
		if record ~= base.records[id] then
			changed[id] = record
		end
	end
	local parts = {
		field(target.session),
		field(base.sequence),
		field(base.digest),
		field(target.sequence),
		field(target.digest),
		field(#removed),
	}
	for _, id in ipairs(removed) do
		parts[#parts + 1] = field(id)
	end
	parts[#parts + 1] = field(payload(target.version, changed, target.extra))
	return table.concat(parts)
end

function Sync.patchTarget(data)
	local nextField = reader(data)
	local session = nextField()
	nextField()
	nextField()
	local sequence, digest = nextField(), nextField()
	if not session or not sequence or not digest then
		return nil
	end
	return Sync.identity(field(session) .. field(sequence) .. field(digest))
end

function Sync.apply(base, data, expectedVersion)
	if #data > Core.MAX_SNAPSHOT_BYTES then
		return nil
	end
	local nextField = reader(data)
	local session, sequence, digest = nextField(), number(nextField(), 100000000), nextField()
	local result, resultDigest = number(nextField(), 100000000), nextField()
	if
		not token(session)
		or not sequence
		or not token(digest)
		or not result
		or result <= sequence
		or not token(resultDigest)
	then
		return nil
	end
	if not base or session ~= base.session or sequence ~= base.sequence or digest ~= base.digest then
		return nil
	end
	local count = number(nextField(), 500)
	if not count then
		return nil
	end
	local records, removed = {}, {}
	for id, record in pairs(base.records) do
		records[id] = record
	end
	local previous = 0
	for _ = 1, count do
		local id = number(nextField(), 100000000)
		if not id or id <= previous or not records[id] then
			return nil
		end
		records[id], removed[id], previous = nil, true, id
	end
	local changes = nextField()
	local trailing, finish = nextField()
	if not changes or trailing ~= nil or finish ~= #data + 1 then
		return nil
	end
	local target = Sync.readSnapshot(changes, expectedVersion)
	if not target or target.session then
		return nil
	end
	for id, record in pairs(target.records) do
		if removed[id] then
			return nil
		end
		records[id] = record
	end
	local content = payload(target.version, records, target.extra)
	local state = Sync.readSnapshot(content, expectedVersion)
	if not state or state.digest ~= resultDigest then
		return nil
	end
	state.session, state.sequence = session, result
	return state
end
