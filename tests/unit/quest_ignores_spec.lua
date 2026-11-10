describe("party-session quest ignores", function()
	local ignores, Core, roster, localQuests
	local function quest(title, state, have)
		return {
			title = title or "Errand",
			state = state or "active",
			objectives = { { text = "Crates", have = have or 0, need = 8 } },
		}
	end
	local function observe()
		local groups, _, _, indices = Core.compare(localQuests, roster)
		ignores:observe(groups, indices, localQuests, roster, "Adam")
		return groups, indices
	end
	local function visible()
		local groups, indices = observe()
		return ignores:filter(groups, indices, roster, "Adam")
	end
	before_each(function()
		_G.QuestWithFriends = {}
		assert(loadfile("src/Core.lua"))()
		assert(loadfile("src/QuestIgnores.lua"))()
		Core = QuestWithFriends.Core
		ignores = QuestWithFriends.QuestIgnores.new()
		localQuests = { [42] = quest() }
		roster = { { key = "Julia", name = "Julia", quests = {} } }
	end)

	it("ignores only missing rows in bulk, preserving other friends' shared progress", function()
		roster[2] = { key = "Bob", name = "Bob", quests = { [42] = quest(nil, "ready", 8) } }
		ignores:roster({ Julia = true, Bob = true })
		observe()
		ignores:ignore(ignores:candidates())
		local groups = visible()
		assert.are.equal(1, #groups)
		assert.are.equal(2, #groups[1].differences)
		for _, difference in ipairs(groups[1].differences) do
			assert.are_not.equal("missing", difference.kind)
		end
		assert.is_nil(groups[1].shareQuestID)
		assert.are.equal(1, #ignores:list())
	end)

	it("restores a quest when any originally missing member picks it up", function()
		ignores:roster({ Julia = true })
		observe()
		ignores:ignore(ignores:candidates())
		assert.same({}, visible())
		roster[1].quests[42] = quest(nil, "ready", 8)
		assert.are.equal(1, #visible())
		assert.same({}, ignores:list())
		assert.same({}, ignores.undoEntries)
	end)

	it("keeps individual progress ignores until explicitly restored", function()
		roster[1].quests[42] = quest(nil, "ready", 8)
		observe()
		ignores:ignoreQuest(42)
		assert.same({}, visible())
		assert.is_true(ignores.saved.ignored[42].whole)
		ignores:restore(42)
		assert.are.equal(1, #visible())
		ignores:ignoreQuest(42)
		ignores:restore()
		assert.same({}, ignores:list())
	end)

	it("does not hide a new member's missing rows under an earlier bulk ignore", function()
		ignores:roster({ Julia = true })
		observe()
		ignores:ignore(ignores:candidates())
		ignores:finishOffer()
		roster[2] = { key = "Bob", name = "Bob", quests = {} }
		ignores:roster({ Julia = true, Bob = true })
		local groups = visible()
		assert.are.equal("Bob", groups[1].differences[1].player)
		assert.same({}, ignores:candidates())
	end)

	it("excludes preexisting missing quests from a later join offer", function()
		observe()
		roster[2] = { key = "Bob", name = "Bob", quests = { [43] = quest("New hub") } }
		ignores:roster({ Julia = true, Bob = true })
		observe()
		assert.is_nil(ignores:candidates()[42])
		assert.is_not_nil(ignores:candidates()[43])
	end)

	it("freezes the local baseline and each new member's first snapshot", function()
		roster[1].quests = nil
		ignores:roster({ Julia = true })
		observe()
		localQuests[43] = quest("Picked up after joining")
		roster[1].quests = {}
		observe()
		assert.is_not_nil(ignores:candidates()[42])
		assert.is_nil(ignores:candidates()[43])
		roster[1].quests[44] = quest("Later pickup")
		observe()
		assert.is_nil(ignores:candidates()[44])
	end)

	it("revalidates a retained offer against current missing players", function()
		ignores:roster({ Julia = true })
		observe()
		local offered = ignores:candidates()
		ignores:finishOffer()
		localQuests[43] = quest("Later pickup")
		roster[1].quests[42] = quest()
		observe()
		assert.same({}, ignores:candidates(offered))
	end)

	it("persists ignores and roster decisions across reloads without repeating an offer", function()
		ignores:roster({ Julia = true })
		observe()
		ignores:ignoreQuest(42)
		ignores:finishOffer()
		ignores = QuestWithFriends.QuestIgnores.new(ignores.saved)
		assert.is_false(ignores:roster({ Julia = true }))
		assert.same({}, visible())
		assert.are.equal(1, #ignores:list())
		assert.is_false(ignores:roster({}))
		assert.are.equal(1, #ignores:list())
		assert.is_true(ignores:roster({ Julia = true }))
	end)

	it("keeps unknown and disconnected members from inventing pickups", function()
		ignores:roster({ Julia = true })
		observe()
		ignores:ignoreQuest(42)
		roster[1].quests = nil
		observe()
		assert.are.equal(1, #ignores:list())
	end)

	it("undoes only its own batch and restores entries individually or together", function()
		localQuests[43] = quest("Other errand")
		observe()
		ignores:ignoreQuest(42)
		ignores:ignoreQuest(43)
		ignores:undo()
		assert.are.equal(42, ignores:list()[1].questID)
		ignores:restore(42)
		assert.same({}, ignores:list())
		ignores:ignore(ignores:missingEntries())
		assert.are.equal(2, #ignores:list())
		ignores:restore()
		assert.same({}, ignores:list())
	end)

	it("can upgrade a bulk ignore to a whole-quest ignore and undo that upgrade", function()
		roster[2] = { key = "Bob", name = "Bob", quests = { [42] = quest(nil, "ready", 8) } }
		observe()
		ignores:ignore(ignores:missingEntries())
		assert.are.equal(1, #visible())
		ignores:ignoreQuest(42)
		assert.same({}, visible())
		assert.is_true(ignores.saved.ignored[42].whole)
		ignores:undo()
		assert.is_false(ignores.saved.ignored[42].whole)
		assert.are.equal(1, #visible())
	end)

	it("can bulk-ignore newly missing players without losing an earlier ignore on undo", function()
		observe()
		ignores:ignore(ignores:missingEntries())
		roster[2] = { key = "Bob", name = "Bob", quests = {} }
		observe()
		assert.is_not_nil(ignores:missingEntries()[42])
		ignores:ignore(ignores:missingEntries())
		assert.same({}, visible())
		ignores:undo()
		assert.are.equal("Bob", visible()[1].differences[1].player)
	end)

	it("does not mistake completed non-equivalent history for a new pickup", function()
		local family = { 42, 43, history = false }
		QuestWithFriends.QuestEquivalences = { [42] = family, [43] = family }
		localQuests = { [43] = quest("Current variant") }
		roster[1].quests[42] = quest("Other variant", "completed", 8)
		observe()
		ignores:ignore(ignores:missingEntries())
		assert.same({}, visible())
		assert.are.equal(1, #ignores:list())
		roster[1].quests[43] = quest("Current variant")
		observe()
		assert.same({}, ignores:list())
	end)

	it("uses canonical quest variants for ignores and pickup detection", function()
		QuestWithFriends.QuestEquivalences = { [42] = { 42, 43 }, [43] = { 42, 43 } }
		ignores:roster({ Julia = true })
		observe()
		ignores:ignoreQuest(42)
		roster[1].quests[43] = quest(nil, "ready", 8)
		assert.are.equal(1, #visible())
		assert.same({}, ignores:list())
	end)
end)
