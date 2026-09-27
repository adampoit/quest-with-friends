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
		assert.same({ { questID = 42, title = "Supplies", differences = { missing("You") } } }, groups)
	end)

	it("shows both sides of readiness differences without repeating matching quests", function()
		local mine = { [1] = quest("Local quest", "active"), [3] = quest("Shared", "ready") }
		local theirs = { [2] = quest("Their quest", "active"), [3] = quest("Shared", "active") }
		local groups = Core.compare(mine, { { name = "Julia", quests = theirs } })
		assert.same({ "Local quest", "Their quest", "Shared" }, titles(groups))
		assert.same({ missing("Julia") }, groups[1].differences)
		assert.same({ missing("You") }, groups[2].differences)
		assert.same({ state("You", "ready"), state("Julia", "active") }, groups[3].differences)
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
		assert.same({ objective("Julia", 2, 6) }, Core.compare(mine, members)[1].differences)
		mine[71001].objectives = {}
		assert.same({ state("You", "ready"), state("Julia", "active") }, Core.compare(mine, members)[1].differences)
		mine[71001].state = "completed"
		assert.same({ state("You", "completed"), state("Julia", "active") }, Core.compare(mine, members)[1].differences)
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
		mine[70001].state = "ready"
		assert.same({ state("You", "ready"), state("Julia", "active") }, Core.compare(mine, members)[1].differences)
		assert.same(peer, Core.decode(Core.encode(peer)))
		mine[70001].state = "completed"
		assert.same({ state("You", "completed"), state("Julia", "active") }, Core.compare(mine, members)[1].differences)
	end)

	it("still compares identical real IDs within a state-only family", function()
		QuestWithFriends.QuestEquivalences[70001] = { 70001, 70002, progress = "state" }
		local mine = { [70001] = quest("Same task", "active", 1, 1) }
		local peer = { [70001] = quest("Same task", "active", 0, 1) }
		assert.same(
			{ objective("Julia", 0, 1) },
			Core.compare(mine, { { name = "Julia", quests = peer } })[1].differences
		)
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
				{ state("You", "completed"), state("Julia", "active") },
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
		assert.same({ objective("You", 2) }, groups[1].differences)
		assert.same({ state("You", "active"), state("Bob", "ready"), state("Julia", "ready") }, groups[2].differences)
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
