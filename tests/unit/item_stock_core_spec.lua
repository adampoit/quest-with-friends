describe("Quest item stock comparisons and protocol", function()
	local Core
	before_each(function()
		QuestWithFriends = nil
		assert(loadfile("Core.lua"))()
		Core = QuestWithFriends.Core
	end)

	local function quest(state, have, spare, itemID)
		return {
			title = "Cloth Delivery",
			state = state,
			objectives = { { text = "Linen Cloth", have = have, need = 10, itemID = itemID, spare = spare } },
		}
	end

	local function row(player, kind, have, spare)
		return {
			player = player,
			kind = kind,
			reason = "objective",
			objective = { text = "Linen Cloth", have = have, need = 10, spare = spare },
		}
	end

	local function fields(values)
		local parts = {}
		for _, value in ipairs(values) do
			value = tostring(value)
			parts[#parts + 1] = #value .. ":" .. value
		end
		return table.concat(parts)
	end

	it("round trips optional stock without changing baseline quest progress", function()
		local input = { [42] = quest("ready", 12, 2, 2589) }
		assert.same(input, Core.decode(Core.encode(input)))
		assert.is_nil(input[42].extensions)
		input[42].objectives[1].spare = 0
		assert.same(input, Core.decode(Core.encode(input)))
	end)

	it("preserves objective indices and replaces stock metadata on the next snapshot", function()
		local input = { [42] = quest("active", 3) }
		input[42].objectives[2] = { text = "Silk Cloth", have = 10, need = 10, itemID = 4306, spare = 4 }
		assert.same(input, Core.decode(Core.encode(input)))
		input[42].objectives[2].itemID, input[42].objectives[2].spare = nil, nil
		local decoded = Core.decode(Core.encode(input))
		assert.same(input, decoded)
		assert.is_nil(decoded[42].objectives[2].spare)
	end)

	it("rejects spare claims on unfinished or non-counted objectives", function()
		for _, progress in ipairs({ { have = 3, need = 10 }, { have = 0, need = 0 } }) do
			local input = { [42] = quest("active", progress.have) }
			input[42].objectives[1].need = progress.need
			input[42].extensions = { item_stock = fields({ 1, 2589, 2 }) }
			assert.is_nil(Core.decode(Core.encode(input)))
		end
	end)

	it("preserves baseline snapshots for older peers in both directions", function()
		local input = { [42] = quest("ready", 10, 2, 2589) }
		local modern = Core.encode(input)
		Core.PROTOCOL_MINOR = 0
		assert.same({ [42] = quest("ready", 10) }, Core.decode(modern))
		local legacy = Core.encode(input)
		Core.PROTOCOL_MINOR = 1
		assert.same({ [42] = quest("ready", 10) }, Core.decode(legacy))
	end)

	it("does not interpret a known tag before its introducing minor version", function()
		Core.PROTOCOL_MINOR = 0
		local input = { [42] = quest("ready", 10) }
		input[42].extensions = { item_stock = "not a 1.0 feature" }
		local legacy = Core.encode(input)
		Core.PROTOCOL_MINOR = 1
		assert.same({ [42] = quest("ready", 10) }, Core.decode(legacy))
	end)

	it("keeps optional stock inside the extension size limit for large objective lists", function()
		local input = { [42] = quest("active", 10) }
		for index = 1, 30 do
			input[42].objectives[index] = {
				text = "Item " .. index,
				have = 100000000,
				need = 100000000,
				itemID = 100000000 - index,
				spare = 100000000,
			}
		end
		local decoded = assert(Core.decode(Core.encode(input)))
		assert.are.equal(30, #decoded[42].objectives)
		assert.are.equal(100000000, decoded[42].objectives[1].spare)
		assert.is_nil(decoded[42].objectives[30].spare)
		assert.are.equal(100000000, decoded[42].objectives[30].have)
	end)

	it("rejects malformed stock atomically rather than accepting misleading extras", function()
		for _, stock in ipairs({
			fields({ 0, 2589, 2 }),
			fields({ 2, 2589, 2 }),
			fields({ 1, 0, 2 }),
			fields({ 1, 100000001, 2 }),
			fields({ 1, 2589, -1 }),
			fields({ 1, 2589, "1.5" }),
			fields({ 1, 2589, 100000001 }),
			fields({ 1, 2589 }),
			fields({ 1, 2589, 2, 1, 2589, 3 }),
			fields({ 1, 2589, 2 }) .. "junk",
		}) do
			local input = { [42] = quest("ready", 10) }
			input[42].extensions = { item_stock = stock }
			assert.is_nil(Core.decode(Core.encode(input)))
		end
	end)

	for _, state in ipairs({ "active", "ready" }) do
		for _, localAhead in ipairs({ true, false }) do
			it("shows stock for a " .. state .. " holder with localAhead=" .. tostring(localAhead), function()
				local donor, unfinished = quest(state, 10, 2, 2589), quest("active", 3)
				local mine, peer = localAhead and donor or unfinished, localAhead and unfinished or donor
				local groups = Core.compare({ [42] = mine }, { { name = "Julia", quests = { [42] = peer } } })
				local expected = {
					row("You", localAhead and "ahead" or "needs", mine.objectives[1].have, localAhead and 2 or nil),
					row(
						"Julia",
						localAhead and "needs" or "ahead",
						peer.objectives[1].have,
						not localAhead and 2 or nil
					),
				}
				if state == "ready" then
					table.insert(expected, localAhead and 2 or 3, {
						player = localAhead and "You" or "Julia",
						kind = "ahead",
						reason = "ready",
					})
				end
				assert.same(expected, groups[1].differences)
			end)
		end
	end

	it("shows a known tradeable objective at the target without claiming spare items", function()
		local groups = Core.compare({ [42] = quest("active", 10, 0, 2589) }, {
			{ name = "Julia", quests = { [42] = quest("active", 3) } },
		})
		assert.same({ row("You", "ahead", 10, 0), row("Julia", "needs", 3) }, groups[1].differences)
	end)

	it("does not add rows for non-item, bound or unidentified finished objectives", function()
		local groups = Core.compare({ [42] = quest("active", 12) }, {
			{ name = "Julia", quests = { [42] = quest("active", 3) } },
		})
		assert.same({ row("Julia", "needs", 3) }, groups[1].differences)
	end)

	it("does not show stock when everyone is finished, nobody has the quest, or it was turned in", function()
		for _, state in ipairs({ "active", "ready" }) do
			assert.same(
				{},
				Core.compare({ [42] = quest(state, 10, 2, 2589) }, {
					{ name = "Julia", quests = { [42] = quest(state, 10) } },
				})
			)
		end
		local groups = Core.compare({ [42] = quest("completed", 10, 2, 2589) }, {
			{ name = "Julia", quests = { [42] = quest("active", 3) } },
		})
		assert.same({ player = "You", kind = "ahead", reason = "completed" }, groups[1].differences[1])
		assert.are.equal(2, #groups[1].differences)
		groups = Core.compare({ [42] = quest("active", 10, 2, 2589) }, { { name = "Julia", quests = {} } })
		assert.same({ { player = "Julia", kind = "missing", reason = "missing" } }, groups[1].differences)
	end)

	it("deduplicates remote donors regardless of viewpoint and roster order", function()
		local a = { name = "Alex", quests = { [42] = quest("active", 10, 2, 2589) } }
		local b = { name = "Bob", quests = { [42] = quest("active", 3) } }
		local groups = Core.compare({ [42] = quest("active", 5) }, { a, b })
		assert.same(
			{ row("You", "needs", 5), row("Alex", "ahead", 10, 2), row("Bob", "needs", 3) },
			groups[1].differences
		)
		assert.same(groups, Core.compare({ [42] = quest("active", 5) }, { b, a }))
		groups = Core.compare({}, { a, b })
		assert.same(row("Alex", "ahead", 10, 2), groups[1].differences[2])
	end)

	it("rejects conflicting known item identities and different targets even on the same quest", function()
		local mine = { [42] = quest("active", 10, 2, 2589) }
		local peer = { [42] = quest("active", 3, 0, 999) }
		local members = { { name = "Julia", quests = peer } }
		assert.are.equal(1, #Core.compare(mine, members)[1].differences)
		peer[42].objectives[1].need = 20
		assert.same({}, Core.compare(mine, members))
	end)

	it("requires matching item identities across variants and honors state-only safeguards", function()
		local family = { 42, 43, progress = "objectives" }
		QuestWithFriends.QuestEquivalences = { [42] = family, [43] = family }
		local mine = { [42] = quest("active", 10, 2, 2589) }
		local peer = { [43] = quest("active", 3) }
		local members = { { name = "Julia", quests = peer } }
		assert.same({ row("Julia", "needs", 3) }, Core.compare(mine, members)[1].differences)
		peer[43].objectives[1].itemID, peer[43].objectives[1].spare = 999, 0
		assert.are.equal(1, #Core.compare(mine, members)[1].differences)
		peer[43].objectives[1].itemID = 2589
		assert.same(
			{ row("You", "ahead", 10, 2), row("Julia", "needs", 3, 0) },
			Core.compare(mine, members)[1].differences
		)
		family.progress = "state"
		assert.same({}, Core.compare(mine, members))
	end)
end)
