describe("snapshot codec", function()
	local namespace = {}
	assert(loadfile("src/sync/SnapshotCodec.lua"))("Sync test", namespace)
	local Codec = namespace.SnapshotCodec

	local function quest(title, state, have, need)
		return {
			title = title,
			state = state,
			objectives = { { text = "Gnolls slain", have = have or 0, need = need or 8 } },
		}
	end

	it("round trips length-prefixed text and multiple quests", function()
		local input = {
			[123] = quest("The: Lost|Supplies", "active", 5, 8),
			[999] = { title = "Done", state = "completed", objectives = {} },
		}
		input[123].mapID = 101
		assert.same(input, Codec.decode(Codec.encode(input)))
	end)

	local function fields(values)
		local encoded = {}
		for _, value in ipairs(values) do
			encoded[#encoded + 1] = #value .. ":" .. value
		end
		return table.concat(encoded)
	end

	it("pins the 1.3 payload header and accepts legacy empty snapshots", function()
		assert.are.equal(1, Codec.PROTOCOL_MAJOR)
		assert.are.equal(3, Codec.PROTOCOL_MINOR)
		assert.are.equal("1.3", Codec.PROTOCOL_VERSION)
		assert.are.equal("1:11:31:00:", Codec.encode({}))
		assert.same({}, Codec.decode("1:11:01:00:"))
		assert.same({}, Codec.decode("1:11:21:00:"))
		local input = {
			[41] = { title = "Fishing", state = "active", category = "profession", objectives = {} },
			[42] = { title = "Mage", state = "completed", category = "class", objectives = {} },
			[43] = { title = "Errand", state = "ready", objectives = {} },
		}
		assert.same(input, Codec.decode(Codec.encode(input)))
	end)

	it("rejects every truncated prefix without restarting field parsing", function()
		local encoded = Codec.encode({ [42] = quest("Errand", "active", 3, 8) })
		for length = 0, #encoded - 1 do
			assert.is_nil(Codec.decode(encoded:sub(1, length)))
		end
		assert.is_nil(Codec.decode(nil))
		assert.is_nil(Codec.decode({}))
	end)

	it("rejects unversioned snapshots, unsupported versions, categories and non-decimal integers", function()
		assert.is_nil(Codec.decode("1:0"))
		assert.is_nil(Codec.decode(fields({ "1", "42", "Errand", "active", "101", "0" })))
		for _, invalid in ipairs({
			{ 1, "2" },
			{ 2, "-1" },
			{ 2, "1000" },
			{ 2, "01" },
			{ 3, "501" },
			{ 4, "0" },
			{ 4, "100000001" },
			{ 4, "4.2" },
			{ 4, "4e1" },
			{ 6, "unknown" },
			{ 7, "-1" },
			{ 8, "personal" },
			{ 8, "unknown" },
			{ 8, "Class" },
			{ 9, "31" },
		}) do
			local values = { "1", "0", "1", "42", "Errand", "active", "101", "", "0", "", "" }
			values[invalid[1]] = invalid[2]
			assert.is_nil(Codec.decode(fields(values)))
		end
		local duplicate = { "1", "0", "2" }
		for _ = 1, 2 do
			for _, value in ipairs({ "42", "Errand", "active", "0", "class", "0", "" }) do
				duplicate[#duplicate + 1] = value
			end
		end
		duplicate[#duplicate + 1] = ""
		assert.is_nil(Codec.decode(fields(duplicate)))
	end)

	it("parses canonical major/minor versions with bounded components", function()
		for _, version in ipairs({ "1.0", "1.9", "2.0", "999.999" }) do
			local major, minor = Codec.parseProtocolVersion(version)
			assert.are.equal(version, major .. "." .. minor)
		end
		for _, version in ipairs({
			"1",
			"1.",
			".1",
			"0.0",
			"01.0",
			"1.00",
			"1.-1",
			"1.1.0",
			"1e1.0",
			"1000.0",
			"1.1000",
		}) do
			assert.is_nil(Codec.parseProtocolVersion(version))
		end
		assert.is_nil(Codec.parseProtocolVersion(nil))
	end)

	it("accepts higher minor versions and skips well-formed quest and snapshot extensions", function()
		local baseline = { [42] = quest("Errand", "active", 3, 8) }
		local extended = { [42] = quest("Errand", "active", 3, 8) }
		extended[42].extensions = { chain_id = "123:456", state = "must not override active", unicode = "é|雪" }
		local encoded = Codec.encode(extended, { optional_feature = "enabled", empty_value = "" }, 7)
		assert.same(baseline, Codec.decode(encoded))
		assert.same(baseline, Codec.decode(encoded, "1.7"))
		assert.is_nil(Codec.decode(encoded, "1.0"))
	end)

	it("serializes extension maps deterministically and bounds encoder inputs", function()
		local a =
			{ [42] = { title = "Errand", state = "active", objectives = {}, extensions = { z = "last", a = "first" } } }
		local b =
			{ [42] = { title = "Errand", state = "active", objectives = {}, extensions = { a = "first", z = "last" } } }
		assert.are.equal(Codec.encode(a), Codec.encode(b))
		for _, invalid in ipairs({
			{ [1] = "x" },
			{ BadTag = "x" },
			{ a = true },
			{ a = string.rep("x", 513) },
			{ a = string.rep("x", 512), b = string.rep("x", 512) },
		}) do
			assert.has_error(function()
				Codec.encode({}, invalid)
			end)
		end
	end)

	it("accepts extension bounds exactly without off-by-one rejections", function()
		local block = { a = string.rep("x", 512), b = string.rep("y", 498) }
		assert.same({}, Codec.decode(Codec.encode({}, block)))
		local tags = {}
		for i = 1, 32 do
			tags["tag" .. i] = ""
		end
		assert.same({}, Codec.decode(Codec.encode({}, tags)))
		assert.same({}, Codec.decode(Codec.encode({}, { [string.rep("a", 32)] = "" })))
	end)

	it("rejects malformed and oversized unknown extensions at both scopes", function()
		local tooMany = {}
		for i = 1, 33 do
			tooMany[#tooMany + 1] = fields({ "tag" .. i, "" })
		end
		local invalidBlocks = {
			fields({ "a" }),
			fields({ "a", "value" }):sub(1, -2),
			fields({ "a", "x", "a", "y" }),
			fields({ "", "x" }),
			fields({ "BadTag", "x" }),
			fields({ string.rep("a", 33), "x" }),
			fields({ "a", string.rep("x", 513) }),
			table.concat(tooMany),
			string.rep("x", 1025),
			fields({ "a", "x" }) .. "junk",
		}
		for _, block in ipairs(invalidBlocks) do
			for _, scope in ipairs({ 10, 11 }) do
				local values = { "1", "4", "1", "42", "Errand", "active", "0", "", "0", "", "" }
				values[scope] = block
				assert.is_nil(Codec.decode(fields(values)))
			end
		end
	end)

	it("requires explicit extension blocks even when they are empty", function()
		assert.is_nil(Codec.decode(fields({ "1", "0", "0" })))
		assert.is_nil(Codec.decode(fields({ "1", "0", "1", "42", "Errand", "active", "0", "", "0", "" })))
	end)

	it("admits optional quests in offer order, skipping records that do not fit", function()
		local required = quest("Required", "active")
		local small = { title = "History", state = "completed", objectives = {} }
		local large = { title = string.rep("x", 300), state = "completed", objectives = {} }
		local base = { [1] = required }
		local expected = { [1] = required, [99] = small }
		local codec = Codec.new(3, #Codec.encode(expected))
		local selected, count = codec.selectQuests(base, function(current, offer)
			assert.is_false(offer(1, small))
			assert.is_false(offer(2, large))
			assert.is_true(offer(99, small))
			assert.same(expected, current)
			assert.is_false(offer(3, small))
		end)
		assert.same(expected, selected)
		assert.are.equal(2, count)
		assert.same({ [1] = required }, base)
	end)

	it("leaves an oversized required snapshot intact for the sender to handle", function()
		local base = { [1] = quest("Required", "active") }
		local codec = Codec.new(3, #Codec.encode(base) - 1)
		local selected, count = codec.selectQuests(base, function(_, offer)
			assert.is_false(offer(2, { title = "History", state = "completed", objectives = {} }))
		end)
		assert.same(base, selected)
		assert.are.equal(1, count)
		assert.is_true(#codec.encode(selected) > codec.MAX_SNAPSHOT_BYTES)
	end)

	it("rejects malformed, duplicate, oversized and trailing payloads", function()
		local encoded = Codec.encode({ [123] = quest("Quest", "active", 5, 8) })
		assert.is_nil(Codec.decode(encoded:sub(1, -2)))
		assert.is_nil(Codec.decode(encoded .. "junk"))
		assert.is_nil(Codec.decode("999:1"))
		assert.is_nil(Codec.decode(Codec.encode({}) .. Codec.encode({})))
		assert.is_nil(Codec.decode(string.rep("x", 24001)))
	end)
end)
