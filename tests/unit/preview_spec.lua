describe("Quest With Friends sample data", function()
	local Preview
	before_each(function()
		QuestWithFriends = nil
		assert(loadfile("src/QuestEquivalences.lua"))()
		assert(loadfile("src/Core.lua"))()
		assert(loadfile("src/Preview.lua"))()
		Preview = QuestWithFriends.Preview
	end)

	local function groupsByID()
		local groups = {}
		for _, group in ipairs(Preview.compare(true, false, false)) do
			groups[group.questID] = group
		end
		return groups
	end

	it("groups multiple remaining objectives without duplicates", function()
		local group = groupsByID()[-2]
		assert.are.equal("Gnoll Hunt", group.title)
		assert.same({
			{
				player = "You",
				kind = "ahead",
				reason = "objective",
				objective = { text = "Linen Cloth", have = 10, need = 10, spare = 2 },
			},
			{
				player = "Alex",
				kind = "needs",
				reason = "objective",
				objective = { text = "Gnolls slain", have = 5, need = 8 },
			},
			{
				player = "Alex",
				kind = "needs",
				reason = "objective",
				objective = { text = "Linen Cloth", have = 3, need = 10 },
			},
			{
				player = "Sam",
				kind = "ahead",
				reason = "objective",
				objective = { text = "Linen Cloth", have = 10, need = 10, spare = 2 },
			},
		}, group.differences)
	end)

	it("shows remaining objectives alongside ready and completed friends", function()
		local groups = groupsByID()
		assert.same({
			{
				player = "You",
				kind = "needs",
				reason = "objective",
				objective = { text = "Scouts rescued", have = 0, need = 1 },
			},
			{ player = "Alex", kind = "ahead", reason = "ready" },
			{
				player = "Sam",
				kind = "needs",
				reason = "objective",
				objective = { text = "Scouts rescued", have = 0, need = 1 },
			},
		}, groups[-3].differences)
		assert.same({
			{ player = "You", kind = "ahead", reason = "completed" },
			{
				player = "Alex",
				kind = "needs",
				reason = "objective",
				objective = { text = "Bridge timbers collected", have = 4, need = 6 },
			},
			{ player = "Sam", kind = "ahead", reason = "completed" },
		}, groups[-4].differences)
	end)

	it("shows extra unfinished sample counts only in Always and preserves synced sample status", function()
		local groups = Preview.compare(true, false, false, nil, "always")
		local found = false
		for _, group in ipairs(groups) do
			for _, row in ipairs(group.differences) do
				found = found or (row.objective and row.objective.text == "Gnoll camps cleared")
			end
		end
		assert.is_true(found)
		assert.is_true(QuestWithFriends.Core.hasDifferences(groups))
		groups = Preview.compare(true, true, true, "synced", "always")
		assert.is_true(#groups > 0)
		assert.is_false(QuestWithFriends.Core.hasDifferences(groups))
	end)

	it("compares a truly synchronized sample party under every filter combination", function()
		for _, zone in ipairs({ false, true }) do
			for _, professions in ipairs({ false, true }) do
				for _, classes in ipairs({ false, true }) do
					local groups, complete, notices = Preview.compare(zone, professions, classes, "synced")
					assert.same({}, groups)
					assert.is_true(complete)
					assert.same({}, notices)
				end
			end
		end
		assert.are.equal(4, #Preview.compare(true, false, false))
	end)
end)
