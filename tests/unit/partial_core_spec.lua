describe("partial snapshot codec", function()
	local Core, Sync
	local session = string.rep("a", 32)
	local function q(have)
		return {
			title = "Errand",
			state = "active",
			category = "class",
			objectives = { { text = "Cloth", have = have or 0, need = 8, itemID = 2589, spare = 0 } },
		}
	end
	local function state(quests, sequence, extra)
		return assert(Sync.snapshot(Core.encode(quests, extra), session, sequence))
	end
	before_each(function()
		_G.QuestWithFriends = nil
		assert(loadfile("src/Core.lua"))()
		assert(loadfile("src/Sync.lua"))()
		Core, Sync = QuestWithFriends.Core, QuestWithFriends.Sync
	end)
	it("matches SHA-256/128 standard vectors", function()
		assert.equal("e3b0c44298fc1c149afbf4c8996fb924", Sync.digest(""))
		assert.equal("ba7816bf8f01cfea414140de5dae2223", Sync.digest("abc"))
		assert.equal(
			"248d6a61d20638b8e5c026930c3e6039",
			Sync.digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
		)
	end)
	it("has the same digest without optional bit libraries", function()
		local env = setmetatable({ QuestWithFriends = QuestWithFriends, bit = false, bit32 = false }, { __index = _G })
		env._G = env
		setfenv(assert(loadfile("src/Sync.lua")), env)()
		assert.equal(Sync.digest(string.rep("abc", 100)), QuestWithFriends.Sync.digest(string.rep("abc", 100)))
	end)
	it("adds metadata without changing baseline decoding", function()
		local original = { [42] = q(3) }
		local target, wire = Sync.snapshot(Core.encode(original), session, 7)
		assert.same(Core.decode(Core.encode(original)), Core.decode(wire))
		assert.equal(target.content, Sync.readSnapshot(wire).content)
		assert.equal(7, Sync.readSnapshot(wire).sequence)
	end)
	it("applies replacements, additions, removals and optional-data clearing atomically", function()
		local base = state({ [42] = q(1), [43] = q(2) }, 1)
		local changed = q(3)
		changed.category = nil
		changed.objectives[1].itemID, changed.objectives[1].spare = nil, nil
		local target = state({ [42] = changed, [44] = q(4) }, 9)
		local result = assert(Sync.apply(base, Sync.patch(base, target), "1.2"))
		assert.equal(target.content, result.content)
		assert.equal(9, result.sequence)
		assert.same(target.quests, result.quests)
		assert.is_not_nil(base.quests[43])
		assert.equal(1, base.quests[42].objectives[1].have)
	end)
	it("preserves unknown quest and snapshot extensions across patches", function()
		local original = q(1)
		original.extensions = { future = "opaque:|\195\169" }
		Core.PROTOCOL_MINOR = 3
		local base = state({ [42] = original, [43] = q(2) }, 1, { future_snapshot = "present" })
		local target = state({ [42] = original, [43] = q(3) }, 2, { future_snapshot = "changed" })
		local result = assert(Sync.apply(base, Sync.patch(base, target), "1.3"))
		assert.equal(target.content, result.content)
		assert.is_truthy(result.records[42]:find("opaque:|\195\169", 1, true))
		assert.equal("changed", result.extra.future_snapshot)
	end)
	it("rejects a missed base, changed session, corruption and duplicate application", function()
		local base = state({ [42] = q(1) }, 1)
		local middle = state({ [42] = q(2) }, 2)
		local target = state({ [42] = q(3) }, 3)
		local patch = Sync.patch(middle, target)
		assert.is_nil(Sync.apply(base, patch, "1.2"))
		assert.is_nil(Sync.apply(target, patch, "1.2"))
		local wrong = state({ [42] = q(2) }, 2)
		wrong.session = string.rep("b", 32)
		assert.is_nil(Sync.apply(wrong, patch, "1.2"))
		local damaged = patch:gsub("Errand", "Broken")
		assert.is_nil(Sync.apply(middle, damaged, "1.2"))
		assert.equal(2, middle.quests[42].objectives[1].have)
	end)
	it("rejects every truncated patch and undeclared trailing bytes", function()
		local base, target = state({ [42] = q(1) }, 1), state({ [42] = q(2) }, 2)
		local patch = Sync.patch(base, target)
		for length = 0, #patch - 1 do
			assert.is_nil(Sync.apply(base, patch:sub(1, length), "1.2"))
		end
		for _, suffix in ipairs({ "junk", "0:", "3:x" }) do
			assert.is_nil(Sync.apply(base, patch .. suffix, "1.2"))
			assert.is_nil(Sync.identity(Sync.identityText(base) .. suffix))
		end
	end)
	it("rejects malformed metadata and digest mismatches", function()
		local _, wire = Sync.snapshot(Core.encode({ [42] = q(1) }), session, 1)
		assert.is_nil(Sync.readSnapshot(wire:gsub("Errand", "Broken")))
		assert.is_nil(Sync.identity(""))
		assert.is_nil(Sync.identity("32:" .. session .. "2:0132:" .. string.rep("a", 32)))
	end)
	it("does not exceed the existing snapshot or extension limits", function()
		local original = Core.encode({}, { padding = string.rep("x", 512), other = string.rep("y", 480) })
		assert.is_not_nil(Core.decode(original))
		assert.is_nil(Sync.snapshot(original, session, 1))
	end)
end)
