describe("Quest item stock", function()
	local annotate, bags, names, bindings, originals
	local globals = { "QuestWithFriends", "C_Container", "C_Item", "NUM_TOTAL_EQUIPPED_BAG_SLOTS", "NUM_BAG_SLOTS" }

	before_each(function()
		originals = {}
		for _, key in ipairs(globals) do
			originals[key] = _G[key]
		end
		_G.QuestWithFriends = {}
		assert(loadfile("src/ItemStock.lua"))()
		annotate = QuestWithFriends.ItemStock.annotate
		bags, names, bindings = { [0] = {} }, {}, {}
		_G.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
		_G.NUM_BAG_SLOTS = 4
		_G.C_Container = {
			GetContainerNumSlots = function(bag)
				assert.is_true(bag >= 0 and bag <= 5)
				return #(bags[bag] or {})
			end,
			GetContainerItemInfo = function(bag, slot)
				return bags[bag][slot]
			end,
		}
		_G.C_Item = {
			GetItemInfo = function(id)
				local info = { [1] = names[id], [14] = bindings[id] }
				return unpack(info, 1, 14)
			end,
		}
	end)

	after_each(function()
		for _, key in ipairs(globals) do
			_G[key] = originals[key]
		end
	end)

	local function stack(id, name, count)
		names[id], bindings[id] = name, 0
		return { itemID = id, itemName = name, stackCount = count, isBound = false, isLocked = false }
	end

	local function objective(have, need, text)
		return { text = text or "Linen Cloth", have = have or 10, need = need or 10 }
	end

	it("uses carried stock whether quest progress is capped or uncapped", function()
		bags[0] = { stack(2589, "Linen Cloth", 12) }
		for _, have in ipairs({ 10, 12 }) do
			local progress = objective(have)
			annotate({ progress })
			assert.same({ text = "Linen Cloth", have = have, need = 10, itemID = 2589, spare = 2 }, progress)
		end
	end)

	it("identifies tradeable objectives at exactly the target and before completion", function()
		for _, count in ipairs({ 3, 10 }) do
			bags[0] = { stack(2589, "Linen Cloth", count) }
			local progress = objective(count)
			annotate({ progress })
			assert.are.equal(2589, progress.itemID)
			assert.are.equal(0, progress.spare)
		end
	end)

	it("sums equipped bags including the reagent bag but never scans banks", function()
		bags[0] = { stack(2589, "Linen Cloth", 4) }
		bags[5] = { stack(2589, "Linen Cloth", 8) }
		bags[6] = { stack(2589, "Linen Cloth", 100) }
		local progress = objective()
		annotate({ progress })
		assert.are.equal(2, progress.spare)
	end)

	it("supports clients with only the ordinary bag-slot constant", function()
		_G.NUM_TOTAL_EQUIPPED_BAG_SLOTS = nil
		bags[4] = { stack(2589, "Linen Cloth", 12) }
		local progress = objective()
		annotate({ progress })
		assert.are.equal(2, progress.spare)
	end)

	it("reserves requirements across all logged quests before offering extras", function()
		bags[0] = { stack(2589, "Linen Cloth", 17) }
		local first, second = objective(10, 10), objective(5, 5)
		annotate({ first, second })
		assert.are.equal(2, first.spare)
		assert.are.equal(2, second.spare)
	end)

	it("excludes bound and locked stacks while keeping the full personal reserve", function()
		bags[0] = {
			stack(2589, "Linen Cloth", 12),
			stack(2589, "Linen Cloth", 20),
			stack(2589, "Linen Cloth", 30),
		}
		bags[0][2].isBound = true
		bags[0][3].isLocked = true
		local progress = objective()
		annotate({ progress })
		assert.are.equal(2, progress.spare)
	end)

	for _, field in ipairs({ "isBound", "isLocked" }) do
		it("requires explicitly known " .. field .. " status", function()
			bags[0] = { stack(2589, "Linen Cloth", 12) }
			bags[0][1][field] = nil
			local progress = objective()
			annotate({ progress })
			assert.is_nil(progress.spare)
		end)
	end

	for _, binding in ipairs({ 1, 2, 3, 4, 7, 8, 9 }) do
		it("does not infer tradeability for binding type " .. binding, function()
			bags[0] = { stack(2589, "Linen Cloth", 12) }
			bindings[2589] = binding
			local progress = objective()
			annotate({ progress })
			assert.is_nil(progress.spare)
		end)
	end

	it("does not offer stock if item data is not cached", function()
		bags[0] = { stack(2589, "Linen Cloth", 12) }
		bindings[2589] = nil
		local progress = objective()
		annotate({ progress })
		assert.is_nil(progress.spare)
		bindings[2589] = 0
		annotate({ progress })
		assert.are.equal(2, progress.spare)
	end)

	it("rejects different item IDs sharing the same localized name", function()
		bags[0] = { stack(2589, "Linen Cloth", 12), stack(999, "Linen Cloth", 12) }
		local progress = objective()
		annotate({ progress })
		assert.is_nil(progress.itemID)
		assert.is_nil(progress.spare)
	end)

	it("rejects fuzzy text matches and stale, bank-only or non-counted progress", function()
		bags[0] = { stack(2589, "Linen Cloth", 12) }
		for _, progress in ipairs({
			objective(10, 10, "Collect Linen Cloth"),
			objective(10, 10, "linen cloth"),
			objective(3, 10),
			objective(0, 0),
		}) do
			annotate({ progress })
			assert.is_nil(progress.spare)
		end
		bags[0][1].stackCount = 5
		local progress = objective()
		annotate({ progress })
		assert.is_nil(progress.spare)
	end)

	it("does not trust name uniqueness while any occupied slot is unnamed", function()
		bags[0] = { stack(2589, "Linen Cloth", 12), stack(999, nil, 1) }
		local progress = objective()
		annotate({ progress })
		assert.is_nil(progress.spare)
	end)

	it("falls back without optional inventory APIs or bag-slot information", function()
		for _, key in ipairs({ "C_Container", "C_Item", "NUM_BAG_SLOTS" }) do
			local saved = _G[key]
			_G[key], _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS = nil, nil
			local progress = objective()
			annotate({ progress })
			assert.is_nil(progress.spare)
			_G[key] = saved
		end
	end)
end)
