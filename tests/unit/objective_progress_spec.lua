describe("Objective progress views", function()
	local Core, Ignores
	before_each(function()
		QuestWithFriends = nil
		assert(loadfile("src/QuestEquivalences.lua"))()
		assert(loadfile("tests/fixtures/quest_equivalences.lua"))()
		assert(loadfile("src/Core.lua"))()
		assert(loadfile("src/QuestIgnores.lua"))()
		Core, Ignores = QuestWithFriends.Core, QuestWithFriends.QuestIgnores
	end)

	local function quest(have, state)
		return {
			title = "Gnoll Hunt",
			state = state or "active",
			objectives = { { text = "Gnolls slain", have = have, need = 8 } },
		}
	end

	local function compare(mode, mine, ...)
		local members = {}
		for index, progress in ipairs({ ... }) do
			members[index] = { name = "Friend " .. index, key = "friend" .. index, quests = { [1] = progress } }
		end
		return Core.compare(mine and { [1] = mine } or {}, members, nil, mode)
	end

	local function counts(groups, player)
		local rows = {}
		for _, group in ipairs(groups) do
			for _, row in ipairs(group.differences) do
				if row.objective and (not player or row.player == player) then
					rows[#rows + 1] = row.objective.have
				end
			end
		end
		return rows
	end

	it("keeps the default and unknown modes identical to the original comparison", function()
		for _, mode in ipairs({ "anyone", "unknown" }) do
			assert.same(compare(nil, quest(3), quest(8), quest(2)), compare(mode, quest(3), quest(8), quest(2)))
			assert.same({}, compare(mode, quest(3), quest(5), quest(2)))
		end
	end)

	it("always shows everyone's unfinished counts, even equal counts, without creating differences", function()
		for _, other in ipairs({ 3, 5 }) do
			local groups, complete, notices, indices = compare("always", quest(3), quest(other), quest(2))
			assert.same({ 3, other, 2 }, counts(groups))
			assert.is_true(complete)
			assert.same({}, notices)
			assert.is_false(Core.hasDifferences(groups))
			for index, row in ipairs(groups[1].differences) do
				assert.is_true(row.informational)
				assert.are.equal(index - 1, indices[row])
			end
		end
	end)

	it("preserves actionable rows when a later pair upgrades informational counts", function()
		local groups = compare("always", quest(3), quest(5), quest(8))
		assert.same({ 3, 5, 8 }, counts(groups))
		assert.is_true(Core.hasDifferences(groups))
		assert.is_nil(groups[1].differences[1].informational)
		assert.is_nil(groups[1].differences[2].informational)
		assert.are.equal("needs", groups[1].differences[2].kind)
		assert.is_true(groups[1].differences[3].informational)
	end)

	it("stops showing fully finished objectives under every mode", function()
		for _, mode in ipairs({ "anyone", "self", "always" }) do
			assert.same({}, compare(mode, quest(8), quest(8), quest(9)))
		end
	end)

	it("keeps missing and readiness differences separate from informational counts", function()
		local groups = compare("always", nil, quest(2), quest(8, "ready"))
		assert.is_true(Core.hasDifferences(groups))
		assert.same({ 2, 8 }, counts(groups))
		assert.are.equal("missing", groups[1].differences[1].reason)
		assert.are.equal("ready", groups[1].differences[#groups[1].differences].reason)
	end)

	it("does not invent counts for missing objectives or unknown members", function()
		local ready = quest(8, "ready")
		ready.objectives = {}
		assert.same({ 3 }, counts((compare("always", quest(3), ready))))
		local groups, complete, notices = Core.compare({ [1] = quest(3) }, { { name = "Unknown" } }, nil, "always")
		assert.same({}, groups)
		assert.is_false(complete)
		assert.are.equal("unknown", notices[1].reason)
	end)

	it("requires compatible positive targets for added counts", function()
		for _, need in ipairs({ 0, 9 }) do
			local other = quest(2)
			other.objectives[1].need = need
			assert.same({}, compare("always", quest(3), other))
		end
	end)

	it("hides entire objective rows including your own until you finish", function()
		for _, other in ipairs({ 6, 8 }) do
			local groups = compare("self", quest(3), quest(other))
			assert.same({}, groups)
			assert.is_false(Core.hasDifferences(groups))
		end
		assert.same({}, compare("self", quest(3), quest(5), quest(8)))
		assert.same({ 6 }, counts((compare("self", quest(8), quest(6)))))
		assert.same({ 5, 2 }, counts((compare("self", quest(8), quest(5), quest(2)))))
	end)

	it("gates each objective separately without adding generic statuses", function()
		local mine, other, ahead = quest(8), quest(2), quest(8)
		mine.objectives[2] = { text = "Camps cleared", have = 1, need = 4 }
		other.objectives[2] = { text = "Camps cleared", have = 2, need = 4 }
		ahead.objectives[2] = { text = "Camps cleared", have = 4, need = 4 }
		local groups = compare("self", mine, other, ahead)
		assert.same({}, counts(groups, "You"))
		assert.same({ 2 }, counts(groups, "Friend 1"))
		assert.are.equal(1, #groups[1].differences)
		assert.are.equal("objective", groups[1].differences[1].reason)
	end)

	it("preserves independent readiness and completion notices when objective rows are hidden", function()
		for _, state in ipairs({ "ready", "completed" }) do
			local groups = compare("self", quest(3), quest(8, state))
			assert.same({}, counts(groups))
			assert.is_true(Core.hasDifferences(groups))
			assert.same({ { player = "Friend 1", kind = "ahead", reason = state } }, groups[1].differences)
		end
	end)

	it("retains quest-state fallbacks when no comparable counts are available", function()
		local mine = quest(3)
		mine.objectives = {}
		local groups = compare("self", mine, quest(8, "ready"))
		assert.same({
			{ player = "You", kind = "needs", reason = "active" },
			{ player = "Friend 1", kind = "ahead", reason = "ready" },
		}, groups[1].differences)
	end)

	it("allows your own finished item counts once you reach the objective target", function()
		local mine = quest(8)
		mine.objectives[1].itemID, mine.objectives[1].spare = 2589, 0
		local groups = compare("self", mine, quest(3))
		assert.same({ 8 }, counts(groups, "You"))
		assert.same({ 3 }, counts(groups, "Friend 1"))
	end)

	it("recognizes ready and historical completion without requiring retained local counts", function()
		for _, state in ipairs({ "ready", "completed" }) do
			local mine = quest(8, state)
			mine.objectives = {}
			local groups = compare("self", mine, quest(3))
			assert.same({ 3 }, counts(groups, "Friend 1"))
			assert.are.equal(state, groups[1].differences[1].reason)
		end
	end)

	it("keeps friends-only differences but hides their counts when you lack the quest", function()
		local groups = compare("self", nil, quest(3), quest(8))
		assert.same({}, counts(groups))
		assert.is_true(Core.hasDifferences(groups))
		assert.are.equal("missing", groups[1].differences[1].reason)
		assert.are.equal(1, #groups[1].differences)
	end)

	it("does not unlock friends' counts from an incompatible local target", function()
		local mine = quest(9)
		mine.objectives[1].need = 9
		local groups = compare("self", mine, quest(3), quest(8))
		assert.same({}, groups)
		assert.is_false(Core.hasDifferences(groups))
	end)

	it("preserves spare metadata and readiness labels in Always", function()
		local finished = quest(10, "ready")
		finished.objectives[1].itemID, finished.objectives[1].spare = 2589, 2
		local groups = compare("always", finished, quest(3))
		assert.same({ 10, 3 }, counts(groups))
		assert.are.equal(2, groups[1].differences[1].objective.spare)
		assert.are.equal("ready", groups[1].differences[2].reason)
	end)

	it("compares reviewed objective variants but never invents state-only variant counts", function()
		local ids = QuestWithFriends.QuestEquivalences[71001]
		local mine = { [71001] = quest(8) }
		local members = { { name = "Friend", quests = { [71002] = quest(3) } } }
		assert.same({ 3 }, counts((Core.compare(mine, members, nil, "self"))))
		assert.same({ 8, 3 }, counts((Core.compare(mine, members, nil, "always"))))
		ids.progress = "state"
		assert.same({}, counts((Core.compare(mine, members, nil, "always"))))
		assert.same({}, counts((Core.compare(mine, members, nil, "self"))))
	end)

	it("uses active objective variants even when their completion history is not equivalent", function()
		QuestWithFriends.QuestEquivalences[71001].history = false
		local groups = Core.compare({ [71001] = quest(8) }, {
			{ name = "Friend", quests = { [71002] = quest(3) } },
		}, nil, "self")
		assert.same({ 3 }, counts(groups))
	end)

	it("does not use non-equivalent completion history to unlock friends' counts", function()
		QuestWithFriends.QuestEquivalences[71001].history = false
		local mine = { [71001] = quest(8, "completed") }
		local members = {
			{ name = "Behind", quests = { [71002] = quest(3) } },
			{ name = "Ahead", quests = { [71002] = quest(8) } },
		}
		local groups = Core.compare(mine, members, nil, "self")
		assert.same({}, counts(groups))
		assert.is_true(Core.hasDifferences(groups))
	end)

	it("keeps Always's actionable status invariant across missing, active, ready and completed party states", function()
		local historical = quest(8, "completed")
		historical.objectives = {}
		local snapshots = {
			{},
			{ [1] = quest(3) },
			{ [1] = quest(8) },
			{ [1] = quest(8, "ready") },
			{ [1] = quest(8, "completed") },
			{ [1] = historical },
		}
		for _, mine in ipairs(snapshots) do
			for _, first in ipairs(snapshots) do
				for _, second in ipairs(snapshots) do
					local roster = { { name = "A", quests = first }, { name = "B", quests = second } }
					local baseline = Core.hasDifferences(Core.compare(mine, roster))
					assert.are.equal(baseline, Core.hasDifferences(Core.compare(mine, roster, nil, "always")))
				end
			end
		end
	end)

	it("filters informational progress by zone", function()
		local mine, other = quest(3), quest(2)
		mine.mapID, other.mapID = 101, 101
		assert.same({}, Core.compare({ [1] = mine }, { { name = "Friend", quests = { [1] = other } } }, 202, "always"))
	end)

	it("preserves informational classification after a missing-row ignore and supports whole-quest ignores", function()
		local mine = { [1] = quest(3) }
		local roster = {
			{ name = "Friend", key = "friend", quests = { [1] = quest(2) } },
			{ name = "Missing", key = "missing", quests = {} },
		}
		local groups, _, _, indices = Core.compare(mine, roster, nil, "always")
		local session = Ignores.new()
		session:observe(groups, indices, mine, roster, "me")
		session:ignore(session:missingEntries())
		local visible = session:filter(groups, indices, roster, "me")
		assert.same({ 3, 2 }, counts(visible))
		assert.is_false(Core.hasDifferences(visible))
		session:ignoreQuest(1)
		assert.same({}, session:filter(groups, indices, roster, "me"))
	end)
end)
