describe("Quest With Friends core", function()
	local Core
	before_each(function()
		QuestWithFriends = nil
		assert(loadfile("QuestEquivalences.lua"))()
		assert(loadfile("tests/fixtures/quest_equivalences.lua"))()
		assert(loadfile("Core.lua"))()
		Core = QuestWithFriends.Core
	end)

	local function quest(title, state, have, need)
		return {
			title = title,
			state = state,
			objectives = { { text = "Gnolls slain", have = have or 0, need = need or 8 } },
		}
	end

	local function state(player, reason)
		return { player = player, kind = reason == "active" and "needs" or "ahead", reason = reason }
	end

	local function missing(player)
		return { player = player, kind = "missing", reason = "missing" }
	end

	local function objective(player, have, need, text)
		return {
			player = player,
			kind = "needs",
			reason = "objective",
			objective = { text = text or "Gnolls slain", have = have, need = need or 8 },
		}
	end

	local function titles(groups)
		local result = {}
		for _, group in ipairs(groups) do
			result[#result + 1] = group.title
		end
		return result
	end

	it("sorts missing quests first and recent activity within both groups", function()
		local groups = {
			{ questID = 1, title = "A progress", differences = { state("You", "active") } },
			{ questID = 2, title = "B missing", differences = { missing("You") } },
			{ questID = 3, title = "C missing", differences = { missing("Julia") } },
			{ questID = 4, title = "D progress", differences = { objective("Julia", 5) } },
		}
		Core.sortGroups(groups, "smart", { [1] = 10, [2] = 1, [3] = 2, [4] = 20 })
		assert.same({ "C missing", "B missing", "D progress", "A progress" }, titles(groups))
		Core.sortGroups(groups, "title", { [4] = 20 })
		assert.same({ "A progress", "B missing", "C missing", "D progress" }, titles(groups))
	end)

	it("breaks equal or unknown activity ties by title then numeric quest ID", function()
		local groups = {
			{ questID = 3, title = "Same", differences = {} },
			{ questID = 2, title = "Same", differences = {} },
			{ questID = 1, title = "Alpha", differences = {} },
		}
		for _, mode in ipairs({ "smart", "title" }) do
			Core.sortGroups(groups, mode)
			assert.are.equal(1, groups[1].questID)
			assert.are.equal(2, groups[2].questID)
			assert.are.equal(3, groups[3].questID)
		end
		Core.sortGroups(groups, "smart", { [2] = 5, [3] = 5 })
		assert.are.equal(2, groups[1].questID)
		assert.are.equal(3, groups[2].questID)
	end)

	it("baselines initial snapshots and ignores identical refreshes and metadata changes", function()
		local activity = {}
		local old = { [1] = quest("Errand", "active", 3) }
		Core.recordActivity(activity, nil, old, 1)
		assert.same({}, activity)
		local current = Core.decode(Core.encode(old))
		Core.recordActivity(activity, old, current, 2)
		current[1].title, current[1].mapID, current[1].category = "New title", 101, "class"
		current[1].objectives[1].text = "Localized objective"
		Core.recordActivity(activity, old, current, 3)
		assert.same({}, activity)
	end)

	it("records pickup, objective and state changes, abandonment, but not expired completion history", function()
		local activity = {}
		local old = { [1] = quest("Errand", "active", 3), [2] = quest("Done", "completed") }
		local current = { [1] = quest("Errand", "active", 4), [3] = quest("Pickup", "active") }
		Core.recordActivity(activity, old, current, 10)
		assert.same({ [1] = 10, [3] = 10 }, activity)
		old, current = current, { [1] = quest("Errand", "ready", 8) }
		Core.recordActivity(activity, old, current, 11)
		assert.same({ [1] = 11, [3] = 11 }, activity)
		old, current = current, { [1] = quest("Errand", "completed") }
		Core.recordActivity(activity, old, current, 12)
		assert.are.equal(12, activity[1])
		Core.recordActivity(activity, current, current, 13)
		assert.are.equal(12, activity[1])
		Core.recordActivity(activity, current, {}, 14)
		assert.are.equal(12, activity[1])
		Core.recordActivity(activity, {}, current, 15)
		assert.are.equal(12, activity[1])
	end)

	it("records changes to objective counts and targets", function()
		local activity = {}
		local old = { [1] = quest("Errand", "active", 3) }
		local current = { [1] = quest("Errand", "active", 3, 10) }
		Core.recordActivity(activity, old, current, 1)
		assert.are.equal(1, activity[1])
		old = current
		current = { [1] = { title = "Errand", state = "active", objectives = {} } }
		Core.recordActivity(activity, old, current, 2)
		assert.are.equal(2, activity[1])
	end)

	it("shares activity across equivalent quest IDs and party snapshots", function()
		local activity = {}
		Core.recordActivity(activity, {}, { [71002] = quest("Variant", "active") }, 1)
		assert.same({ [71001] = 1 }, activity)
		local old = { [71003] = quest("Variant", "active", 3) }
		Core.recordActivity(activity, old, { [71003] = quest("Variant", "active", 4) }, 2)
		assert.same({ [71001] = 2 }, activity)
	end)

	it("round trips length-prefixed text and multiple quests", function()
		local input = {
			[123] = quest("The: Lost|Supplies", "active", 5, 8),
			[999] = { title = "Done", state = "completed", objectives = {} },
		}
		input[123].mapID = 101
		assert.same(input, Core.decode(Core.encode(input)))
	end)

	local function fields(values)
		local encoded = {}
		for _, value in ipairs(values) do
			encoded[#encoded + 1] = #value .. ":" .. value
		end
		return table.concat(encoded)
	end

	it("pins the 1.0 payload header and empty extensions, and round trips classifications", function()
		assert.are.equal(1, Core.PROTOCOL_MAJOR)
		assert.are.equal(0, Core.PROTOCOL_MINOR)
		assert.are.equal("1.0", Core.PROTOCOL_VERSION)
		assert.are.equal("1:11:01:00:", Core.encode({}))
		local input = {
			[41] = { title = "Fishing", state = "active", category = "profession", objectives = {} },
			[42] = { title = "Mage", state = "completed", category = "class", objectives = {} },
			[43] = { title = "Errand", state = "ready", objectives = {} },
		}
		assert.same(input, Core.decode(Core.encode(input)))
	end)

	it("rejects every truncated prefix without restarting field parsing", function()
		local encoded = Core.encode({ [42] = quest("Errand", "active", 3, 8) })
		for length = 0, #encoded - 1 do
			assert.is_nil(Core.decode(encoded:sub(1, length)))
		end
		assert.is_nil(Core.decode(nil))
		assert.is_nil(Core.decode({}))
	end)

	it("rejects unversioned snapshots, unsupported versions, categories and non-decimal integers", function()
		assert.is_nil(Core.decode("1:0"))
		assert.is_nil(Core.decode(fields({ "1", "42", "Errand", "active", "101", "0" })))
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
			assert.is_nil(Core.decode(fields(values)))
		end
		local duplicate = { "1", "0", "2" }
		for _ = 1, 2 do
			for _, value in ipairs({ "42", "Errand", "active", "0", "class", "0", "" }) do
				duplicate[#duplicate + 1] = value
			end
		end
		duplicate[#duplicate + 1] = ""
		assert.is_nil(Core.decode(fields(duplicate)))
	end)

	it("parses canonical major/minor versions with bounded components", function()
		for _, version in ipairs({ "1.0", "1.9", "2.0", "999.999" }) do
			local major, minor = Core.parseProtocolVersion(version)
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
			assert.is_nil(Core.parseProtocolVersion(version))
		end
		assert.is_nil(Core.parseProtocolVersion(nil))
	end)

	it("accepts higher minor versions and skips well-formed quest and snapshot extensions", function()
		local baseline = { [42] = quest("Errand", "active", 3, 8) }
		local extended = { [42] = quest("Errand", "active", 3, 8) }
		extended[42].extensions = { chain_id = "123:456", state = "must not override active", unicode = "é|雪" }
		Core.PROTOCOL_MINOR = 7
		local encoded = Core.encode(extended, { optional_feature = "enabled", empty_value = "" })
		assert.same(baseline, Core.decode(encoded))
		assert.same(baseline, Core.decode(encoded, "1.7"))
		assert.is_nil(Core.decode(encoded, "1.0"))
	end)

	it("serializes extension maps deterministically and bounds encoder inputs", function()
		local a =
			{ [42] = { title = "Errand", state = "active", objectives = {}, extensions = { z = "last", a = "first" } } }
		local b =
			{ [42] = { title = "Errand", state = "active", objectives = {}, extensions = { a = "first", z = "last" } } }
		assert.are.equal(Core.encode(a), Core.encode(b))
		for _, invalid in ipairs({
			{ [1] = "x" },
			{ BadTag = "x" },
			{ a = true },
			{ a = string.rep("x", 513) },
			{ a = string.rep("x", 512), b = string.rep("x", 512) },
		}) do
			assert.has_error(function()
				Core.encode({}, invalid)
			end)
		end
	end)

	it("accepts extension bounds exactly without off-by-one rejections", function()
		local block = { a = string.rep("x", 512), b = string.rep("y", 498) }
		assert.same({}, Core.decode(Core.encode({}, block)))
		local tags = {}
		for i = 1, 32 do
			tags["tag" .. i] = ""
		end
		assert.same({}, Core.decode(Core.encode({}, tags)))
		assert.same({}, Core.decode(Core.encode({}, { [string.rep("a", 32)] = "" })))
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
				assert.is_nil(Core.decode(fields(values)))
			end
		end
	end)

	it("requires explicit extension blocks even when they are empty", function()
		assert.is_nil(Core.decode(fields({ "1", "0", "0" })))
		assert.is_nil(Core.decode(fields({ "1", "0", "1", "42", "Errand", "active", "0", "", "0", "" })))
	end)

	it("rejects malformed, duplicate, oversized and trailing payloads", function()
		local encoded = Core.encode({ [123] = quest("Quest", "active", 5, 8) })
		assert.is_nil(Core.decode(encoded:sub(1, -2)))
		assert.is_nil(Core.decode(encoded .. "junk"))
		assert.is_nil(Core.decode("999:1"))
		assert.is_nil(Core.decode(Core.encode({}) .. Core.encode({})))
		assert.is_nil(Core.decode(string.rep("x", 24001)))
	end)

	it("shows only differences that affect readiness", function()
		local mine = { [123] = quest("Gnoll hunt", "active", 8), [124] = quest("Crates", "active", 2, 6) }
		local peer = { [123] = quest("Gnoll hunt", "active", 5), [124] = quest("Crates", "active", 3, 6) }
		local groups, complete, notices = Core.compare(mine, { { name = "Julia", quests = peer } })
		assert.is_true(complete)
		assert.same({}, notices)
		assert.same({ { questID = 123, title = "Gnoll hunt", differences = { objective("Julia", 5) } } }, groups)
	end)

	it("groups missing members beneath one quest and attaches one real local share ID", function()
		local groups = Core.compare({ [42] = quest("Supplies", "active") }, {
			{ name = "Julia", quests = {} },
			{ name = "Bob", quests = {} },
		})
		assert.same({
			{
				questID = 42,
				title = "Supplies",
				shareQuestID = 42,
				differences = { missing("Bob"), missing("Julia") },
			},
		}, groups)
	end)

	it("deduplicates local missing quests reported by multiple members", function()
		local groups = Core.compare({}, {
			{ name = "Julia", quests = { [42] = quest("Supplies", "active") } },
			{ name = "Bob", quests = { [42] = quest("Supplies", "ready") } },
		})
		assert.same({
			{
				questID = 42,
				title = "Supplies",
				differences = { missing("You"), state("Bob", "ready"), objective("Julia", 0) },
			},
		}, groups)
	end)

	it("shows both sides of readiness differences without repeating matching quests", function()
		local mine = { [1] = quest("Local quest", "active"), [3] = quest("Shared", "ready") }
		local theirs = { [2] = quest("Their quest", "active"), [3] = quest("Shared", "active") }
		local groups = Core.compare(mine, { { name = "Julia", quests = theirs } })
		assert.same({ "Local quest", "Their quest", "Shared" }, titles(groups))
		assert.same({ missing("Julia") }, groups[1].differences)
		assert.same({ missing("You") }, groups[2].differences)
		assert.same({ state("You", "ready"), objective("Julia", 0) }, groups[3].differences)
	end)

	it("shows only remaining objectives against ready or completed quests in both directions", function()
		for _, aheadState in ipairs({ "ready", "completed" }) do
			for _, localAhead in ipairs({ true, false }) do
				local ahead = { title = "Hunt", state = aheadState, objectives = {} }
				local active = quest("Hunt", "active", 2)
				active.objectives[2] = { text = "Crates collected", have = 1, need = 4 }
				active.objectives[3] = { text = "Scout found", have = 1, need = 1 }
				active.objectives[4] = { text = "Unknown target", have = 0, need = 0 }
				local mine, peer = localAhead and ahead or active, localAhead and active or ahead
				local group = Core.compare({ [1] = mine }, { { name = "Julia", quests = { [1] = peer } } })[1]
				local expected = localAhead
						and {
							state("You", aheadState),
							objective("Julia", 2),
							objective("Julia", 1, 4, "Crates collected"),
						}
					or { objective("You", 2), objective("You", 1, 4, "Crates collected"), state("Julia", aheadState) }
				assert.same(expected, group.differences)
				assert.is_nil(group.shareQuestID)
			end
		end
	end)

	it("uses remaining objectives even when the ready quest has different objective targets", function()
		local groups = Core.compare({ [1] = quest("Hunt", "ready", 10, 10) }, {
			{ name = "Julia", quests = { [1] = quest("Hunt", "active", 2, 8) } },
		})
		assert.same({ state("You", "ready"), objective("Julia", 2) }, groups[1].differences)
	end)

	it("falls back to active state when no usable remaining objectives are available", function()
		for _, aheadState in ipairs({ "ready", "completed" }) do
			for _, objectives in ipairs({
				{},
				{ { text = "Unknown", have = 0, need = 0 } },
				{ { text = "Done", have = 8, need = 8 } },
			}) do
				local active = { title = "Hunt", state = "active", objectives = objectives }
				local ahead = quest("Hunt", aheadState, 8)
				for _, localAhead in ipairs({ true, false }) do
					local mine, peer = localAhead and ahead or active, localAhead and active or ahead
					local group = Core.compare({ [1] = mine }, { { name = "Julia", quests = { [1] = peer } } })[1]
					assert.same({ state("You", mine.state), state("Julia", peer.state) }, group.differences)
				end
			end
		end
	end)

	it("hides matching ready and completed quests without showing old objective counts", function()
		for _, matchingState in ipairs({ "ready", "completed" }) do
			assert.same(
				{},
				Core.compare({ [1] = quest("Hunt", matchingState, 8) }, {
					{ name = "Julia", quests = { [1] = quest("Hunt", matchingState, 2) } },
				})
			)
		end
	end)

	it("keeps completed and ready states distinct", function()
		local mine = { [123] = quest("Hunt", "completed") }
		local peer = { [123] = quest("Hunt", "ready", 8) }
		local groups = Core.compare(mine, { { name = "Julia", quests = peer } })
		assert.same({ state("You", "completed"), state("Julia", "ready") }, groups[1].differences)
		assert.is_nil(groups[1].shareQuestID)
	end)

	it("filters to a zone but keeps quests with unknown map IDs", function()
		local mine = {
			[1] = quest("Here", "active"),
			[2] = quest("Elsewhere", "active"),
			[3] = quest("Unmapped", "active"),
		}
		mine[1].mapID, mine[2].mapID = 101, 202
		local members = { { name = "Julia", quests = {} } }
		assert.same({ "Here", "Unmapped" }, titles(Core.compare(mine, members, 101)))
		assert.same({ "Elsewhere", "Unmapped" }, titles(Core.compare(mine, members, 202)))
		assert.same({ "Elsewhere", "Here", "Unmapped" }, titles(Core.compare(mine, members)))
	end)

	it("matches every verified variant without changing wire IDs", function()
		local mine = { [71001] = quest("Branch quest", "active", 2, 6) }
		for _, id in ipairs(Core.questIDs(71001)) do
			local peer = { [id] = quest("Branch quest", "active", 3, 6) }
			local groups, complete = Core.compare(mine, { { name = "Julia", quests = peer } })
			assert.is_true(complete)
			assert.same({}, groups)
			assert.same(peer, Core.decode(Core.encode(peer)))
		end
	end)

	it("does not merge unlisted quests with the same title", function()
		local groups = Core.compare(
			{ [71001] = quest("Branch quest", "active") },
			{ { name = "Julia", quests = { [99999] = quest("Branch quest", "active") } } }
		)
		assert.are.equal(2, #groups)
		assert.are.equal(71001, groups[1].questID)
		assert.are.equal(99999, groups[2].questID)
		assert.same({ missing("Julia") }, groups[1].differences)
		assert.same({ missing("You") }, groups[2].differences)
	end)

	it("preserves objective, readiness and completion differences across variants", function()
		local mine = { [71001] = quest("Branch quest", "ready", 6, 6) }
		local peer = { [71002] = quest("Branch quest", "active", 2, 6) }
		local members = { { name = "Julia", quests = peer } }
		assert.same({ state("You", "ready"), objective("Julia", 2, 6) }, Core.compare(mine, members)[1].differences)
		mine[71001].objectives = {}
		assert.same({ state("You", "ready"), objective("Julia", 2, 6) }, Core.compare(mine, members)[1].differences)
		mine[71001].state = "completed"
		assert.same({ state("You", "completed"), objective("Julia", 2, 6) }, Core.compare(mine, members)[1].differences)
		mine[71001].state, peer[71002].state = "active", "completed"
		assert.same({ state("You", "active"), state("Julia", "completed") }, Core.compare(mine, members)[1].differences)
	end)

	it("prefers active variants over history and uses the real share ID", function()
		local mine = {
			[71001] = quest("Old variant", "completed"),
			[71002] = quest("Current variant", "active"),
		}
		local peer = { [71003] = quest("Monk variant", "active") }
		assert.same({}, Core.compare(mine, { { name = "Julia", quests = peer } }))
		local group = Core.compare(mine, { { name = "Julia", quests = {} } })[1]
		assert.are.equal(71001, group.questID)
		assert.are.equal(71002, group.shareQuestID)
		assert.are.equal("Current variant", group.title)
		assert.same({ missing("Julia") }, group.differences)
		assert.are.equal("completed", mine[71001].state)
		assert.are.equal("active", mine[71002].state)
	end)

	it("includes a group when any variant is in the selected zone", function()
		local mine = { [71001] = quest("Branch quest", "ready") }
		local peer = { [71003] = quest("Branch quest", "active") }
		mine[71001].mapID, peer[71003].mapID = 101, 202
		local members = { { name = "Julia", quests = peer } }
		assert.are.equal(1, #Core.compare(mine, members, 101))
		assert.are.equal(1, #Core.compare(mine, members, 202))
		assert.same({}, Core.compare(mine, members, 303))
	end)

	it("compares only readiness across state-only variant schemas", function()
		local ids = { 70001, 70002, progress = "state" }
		QuestWithFriends.QuestEquivalences[70001], QuestWithFriends.QuestEquivalences[70002] = ids, ids
		local mine = { [70001] = quest("Race-specific task", "active", 1, 1) }
		local peer = { [70002] = quest("Other target", "active", 0, 1) }
		local members = { { name = "Julia", quests = peer } }
		assert.same({}, Core.compare(mine, members))
		assert.same(peer, Core.decode(Core.encode(peer)))
		for _, aheadState in ipairs({ "ready", "completed" }) do
			mine[70001].state, peer[70002].state = aheadState, "active"
			assert.same(
				{ state("You", aheadState), state("Julia", "active") },
				Core.compare(mine, members)[1].differences
			)
			mine[70001].state, peer[70002].state = "active", aheadState
			assert.same(
				{ state("You", "active"), state("Julia", aheadState) },
				Core.compare(mine, members)[1].differences
			)
		end
	end)

	it("still compares identical real IDs within a state-only family", function()
		QuestWithFriends.QuestEquivalences[70001] = { 70001, 70002, progress = "state" }
		local mine = { [70001] = quest("Same task", "active", 1, 1) }
		local peer = { [70001] = quest("Same task", "active", 0, 1) }
		local members = { { name = "Julia", quests = peer } }
		assert.same({ objective("Julia", 0, 1) }, Core.compare(mine, members)[1].differences)
		for _, aheadState in ipairs({ "ready", "completed" }) do
			mine[70001].state = aheadState
			assert.same(
				{ state("You", aheadState), objective("Julia", 0, 1) },
				Core.compare(mine, members)[1].differences
			)
		end
	end)

	it("does not infer completion across active-only reviewed variants", function()
		local ids = { 70001, 70002, progress = "objectives", history = false }
		QuestWithFriends.QuestEquivalences[70001], QuestWithFriends.QuestEquivalences[70002] = ids, ids
		local mine = { [70001] = quest("Old branch", "completed") }
		local peer = { [70002] = quest("Current branch", "active") }
		assert.same({ 70002 }, Core.completionIDs(70002))
		assert.is_nil(Core.matchQuest(mine, 70002))
		local group = Core.compare(mine, { { name = "Julia", quests = peer } })[1]
		assert.are.equal("Current branch", group.title)
		assert.same({ missing("You") }, group.differences)
		for _, id in ipairs(ids) do
			mine = { [id] = quest("Same branch", "completed") }
			peer = { [id] = quest("Same branch", "active") }
			assert.same(
				{ state("You", "completed"), objective("Julia", 0) },
				Core.compare(mine, { { name = "Julia", quests = peer } })[1].differences
			)
		end
	end)

	it("keeps multiple objectives under their affected player without redundant finished rows", function()
		local mine = quest("Mixed", "active", 8)
		local peer = quest("Mixed", "active", 2)
		mine.objectives[2] = { text = "Crates collected", have = 1, need = 4 }
		peer.objectives[2] = { text = "Crates collected", have = 4, need = 4 }
		local group = Core.compare({ [1] = mine }, { { name = "Julia", quests = { [1] = peer } } })[1]
		assert.same({ objective("You", 1, 4, "Crates collected"), objective("Julia", 2) }, group.differences)
		assert.is_nil(group.shareQuestID)
	end)

	it("deduplicates local objective and state differences across peers", function()
		local mine = { [1] = quest("Hunt", "active", 2), [2] = quest("Scout", "active") }
		local peer = { [1] = quest("Hunt", "ready", 8), [2] = quest("Scout", "ready") }
		local groups = Core.compare(mine, { { name = "Julia", quests = peer }, { name = "Bob", quests = peer } })
		assert.same({ objective("You", 2), state("Bob", "ready"), state("Julia", "ready") }, groups[1].differences)
		assert.same({ objective("You", 0), state("Bob", "ready"), state("Julia", "ready") }, groups[2].differences)
	end)

	it("keeps objective order stable within each player", function()
		local mine = quest("Hunt", "active", 8)
		local peer = quest("Hunt", "active", 2)
		for index = 2, 10 do
			mine.objectives[index] = { text = "Task " .. index, have = 1, need = 1 }
			peer.objectives[index] = { text = "Task " .. index, have = 0, need = 1 }
		end
		local differences = Core.compare({ [1] = mine }, { { name = "Julia", quests = { [1] = peer } } })[1].differences
		for index = 2, 10 do
			assert.are.equal("Task " .. index, differences[index].objective.text)
		end
	end)

	it("orders missing groups first, then title and ID, regardless of roster order", function()
		local mine = { [1] = quest("A hunt", "active", 8), [2] = quest("Z missing", "active") }
		local a = { name = "Julia", quests = { [1] = quest("A hunt", "active", 2) } }
		local b = { name = "Bob", quests = { [1] = quest("A hunt", "active", 3) } }
		local groups = Core.compare(mine, { a, b })
		assert.same({ "Z missing", "A hunt" }, titles(groups))
		assert.same(groups, Core.compare(mine, { b, a }))
	end)

	it("chooses a stable active title when only remote variants are known", function()
		local a = { name = "Julia", quests = { [71001] = quest("Z variant", "active") } }
		local b = { name = "Bob", quests = { [71002] = quest("A variant", "active") } }
		local history = { name = "Charlie", quests = { [71003] = quest("Completed variant", "completed") } }
		local groups = Core.compare({}, { history, a, b })
		assert.are.equal("A variant", groups[1].title)
		assert.same(groups, Core.compare({}, { b, a, history }))
	end)

	it("shows friends' remaining objectives when the local player is missing or unfinished", function()
		for _, aheadState in ipairs({ "active", "ready", "completed" }) do
			local julia = { name = "Julia", quests = { [1] = quest("Hunt", aheadState, 8) } }
			local bob = { name = "Bob", quests = { [1] = quest("Hunt", "active", 5) } }
			for _, mine in ipairs({ {}, { [1] = quest("Hunt", "active", 3) } }) do
				local expected = { mine[1] and objective("You", 3) or missing("You"), objective("Bob", 5) }
				if aheadState ~= "active" then
					expected[#expected + 1] = state("Julia", aheadState)
				end
				local groups = Core.compare(mine, { julia, bob })
				assert.same(expected, groups[1].differences)
				assert.is_nil(groups[1].shareQuestID)
				assert.same(groups, Core.compare(mine, { bob, julia }))
			end
		end
	end)

	it("reports the same affected players regardless of whose viewpoint is local", function()
		local players = {
			{ name = "Adam", quests = { [1] = quest("Hunt", "active", 3) } },
			{ name = "Bob", quests = { [1] = quest("Hunt", "active", 5) } },
			{ name = "Julia", quests = { [1] = quest("Hunt", "ready", 8) } },
			{ name = "Charlie", quests = {} },
		}
		local expected = {
			Adam = { objective("Adam", 3) },
			Bob = { objective("Bob", 5) },
			Julia = { state("Julia", "ready") },
			Charlie = { missing("Charlie") },
		}
		for localIndex, player in ipairs(players) do
			local members = {}
			for index, member in ipairs(players) do
				if index ~= localIndex then
					members[#members + 1] = member
				end
			end
			local groups, complete = Core.compare(player.quests, members)
			assert.is_true(complete)
			local byPlayer = {}
			for _, difference in ipairs(groups[1].differences) do
				if difference.player == "You" then
					difference.player = player.name
				end
				byPlayer[difference.player] = byPlayer[difference.player] or {}
				table.insert(byPlayer[difference.player], difference)
			end
			assert.same(expected, byPlayer)
		end
	end)

	it("finds missing friends from remote quests without showing partial-progress differences", function()
		local julia = { name = "Julia", quests = { [1] = quest("Hunt", "active", 3) } }
		local bob = { name = "Bob", quests = {} }
		local charlie = { name = "Charlie", quests = { [1] = quest("Hunt", "active", 5) } }
		local groups = Core.compare({}, { julia, bob, charlie })
		assert.same({ missing("You"), missing("Bob") }, groups[1].differences)
		assert.is_nil(groups[1].shareQuestID)
		assert.same(groups, Core.compare({}, { charlie, bob, julia }))
	end)

	it("deduplicates objectives found by multiple finished players", function()
		local mine = { [1] = quest("Hunt", "active", 3) }
		local julia = { name = "Julia", quests = { [1] = quest("Hunt", "ready", 8) } }
		local bob = { name = "Bob", quests = { [1] = quest("Hunt", "active", 5) } }
		local charlie = { name = "Charlie", quests = { [1] = quest("Hunt", "ready", 8) } }
		local groups = Core.compare(mine, { julia, bob, charlie })
		assert.same(
			{ objective("You", 3), objective("Bob", 5), state("Charlie", "ready"), state("Julia", "ready") },
			groups[1].differences
		)
		assert.same(groups, Core.compare(mine, { charlie, bob, julia }))
	end)

	it("keeps objective ordering stable when different friends finish different objectives", function()
		local mine = quest("Hunt", "active", 1)
		local julia = quest("Hunt", "active", 1)
		local bob = quest("Hunt", "active", 8)
		mine.objectives[2] = { text = "Crates collected", have = 1, need = 4 }
		julia.objectives[2] = { text = "Crates collected", have = 4, need = 4 }
		bob.objectives[2] = { text = "Crates collected", have = 1, need = 4 }
		local a, b = { name = "Julia", quests = { [1] = julia } }, { name = "Bob", quests = { [1] = bob } }
		local groups = Core.compare({ [1] = mine }, { a, b })
		assert.same({
			objective("You", 1),
			objective("You", 1, 4, "Crates collected"),
			objective("Bob", 1, 4, "Crates collected"),
			objective("Julia", 1),
		}, groups[1].differences)
		assert.same(groups, Core.compare({ [1] = mine }, { b, a }))
	end)

	it("compares remote progress and completion across reviewed objective variants", function()
		local julia = { name = "Julia", quests = { [71001] = quest("Hunt", "completed", 6, 6) } }
		local bob = { name = "Bob", quests = { [71002] = quest("Hunt", "active", 2, 6) } }
		local charlie = { name = "Charlie", quests = { [71003] = quest("Hunt", "ready", 6, 6) } }
		local groups = Core.compare({}, { julia, bob, charlie })
		assert.same(
			{ missing("You"), objective("Bob", 2, 6), state("Charlie", "ready"), state("Julia", "completed") },
			groups[1].differences
		)
		assert.is_nil(groups[1].shareQuestID)
		assert.same(groups, Core.compare({}, { charlie, bob, julia }))
	end)

	it("retains state-only safeguards between remote variants", function()
		local ids = { 70001, 70002, progress = "state" }
		QuestWithFriends.QuestEquivalences[70001], QuestWithFriends.QuestEquivalences[70002] = ids, ids
		local julia = { name = "Julia", quests = { [70001] = quest("Hunt", "ready", 8) } }
		local bob = { name = "Bob", quests = { [70002] = quest("Hunt", "active", 3) } }
		local groups = Core.compare({}, { julia, bob })
		assert.same({ missing("You"), state("Bob", "active"), state("Julia", "ready") }, groups[1].differences)
		assert.same(groups, Core.compare({}, { bob, julia }))
	end)

	it("does not infer completion between remote active-only variants", function()
		local ids = { 70001, 70002, progress = "objectives", history = false }
		QuestWithFriends.QuestEquivalences[70001], QuestWithFriends.QuestEquivalences[70002] = ids, ids
		local julia = { name = "Julia", quests = { [70001] = quest("Hunt", "completed", 8) } }
		local bob = { name = "Bob", quests = { [70002] = quest("Hunt", "active", 3) } }
		local groups = Core.compare({}, { julia, bob })
		assert.same({ missing("You"), missing("Julia") }, groups[1].differences)
		assert.same(groups, Core.compare({}, { bob, julia }))
	end)

	it("prefers usable objectives over redundant active status from a state-only comparison", function()
		local ids = { 70001, 70002, progress = "state" }
		QuestWithFriends.QuestEquivalences[70001], QuestWithFriends.QuestEquivalences[70002] = ids, ids
		local mine = { [70001] = quest("Hunt", "active", 3) }
		local julia = { name = "Julia", quests = { [70002] = quest("Hunt", "ready", 8) } }
		local bob = { name = "Bob", quests = { [70001] = quest("Hunt", "ready", 8) } }
		local groups = Core.compare(mine, { julia, bob })
		assert.same({ objective("You", 3), state("Bob", "ready"), state("Julia", "ready") }, groups[1].differences)
		assert.same(groups, Core.compare(mine, { bob, julia }))
	end)

	it("uses only the real local quest ID for sharing with multiple remote variants", function()
		local mine = { [71002] = quest("Local title", "active", 3) }
		local julia = { name = "Julia", quests = { [71003] = quest("Remote title", "ready", 8) } }
		local bob = { name = "Bob", quests = {} }
		local groups = Core.compare(mine, { julia, bob })
		assert.are.equal(71002, groups[1].shareQuestID)
		assert.are.equal("Local title", groups[1].title)
		assert.same({ objective("You", 3), missing("Bob"), state("Julia", "ready") }, groups[1].differences)
		assert.same(groups, Core.compare(mine, { bob, julia }))
	end)

	it("compares cached remote snapshots while excluding members whose quests are unknown", function()
		local groups, complete, notices = Core.compare({}, {
			{ name = "Julia", quests = { [1] = quest("Hunt", "completed", 8) }, syncStatus = "offline" },
			{ name = "Charlie" },
			{ name = "Bob", quests = { [1] = quest("Hunt", "active", 3) } },
		})
		assert.is_false(complete)
		assert.same({ { player = "Charlie", reason = "unknown" }, { player = "Julia", reason = "offline" } }, notices)
		assert.same({ missing("You"), objective("Bob", 3), state("Julia", "completed") }, groups[1].differences)
	end)

	it("does not show completion history as a missing quest when all known holders are done", function()
		assert.same(
			{},
			Core.compare({}, {
				{ name = "Julia", quests = { [1] = quest("Hunt", "completed", 8) } },
				{ name = "Bob", quests = { [1] = quest("Hunt", "completed", 8) } },
			})
		)
	end)

	it("never calls an unknown member synchronized or assigns them quest differences", function()
		local groups, complete, notices = Core.compare({ [42] = quest("Supplies", "active") }, { { name = "Bob" } })
		assert.is_false(complete)
		assert.same({}, groups)
		assert.same({ { player = "Bob", reason = "unknown" } }, notices)
	end)

	it("escapes remote titles, names and objectives", function()
		local peer = { [3] = quest("|cffff0000Bad|r", "active", 2) }
		peer[3].objectives[1].text = "|Ticon:2|t\nTask"
		local groups = Core.compare({ [3] = quest("|cffff0000Bad|r", "active", 8) }, {
			{ name = "|Ticon:2|t", quests = peer },
		})
		assert.is_nil(groups[1].title:find("|", 1, true))
		assert.is_nil(groups[1].differences[1].player:find("|", 1, true))
		assert.is_nil(groups[1].differences[1].objective.text:find("|", 1, true))
		assert.is_nil(groups[1].differences[1].objective.text:find("\n", 1, true))
		local _, _, notices = Core.compare({}, { { name = "|cBad|r" } })
		assert.is_nil(notices[1].player:find("|", 1, true))
	end)
end)
