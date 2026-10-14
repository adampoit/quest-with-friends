describe("Quest With Friends client quest data", function()
	local originalBuildInfo
	before_each(function()
		originalBuildInfo = _G.GetBuildInfo
		_G.QuestWithFriends = nil
		assert(loadfile("src/QuestEquivalences.lua"))()
	end)

	after_each(function()
		_G.GetBuildInfo = originalBuildInfo
	end)

	local function loadClient(interfaceVersion)
		rawset(_G, "GetBuildInfo", function()
			return "", "", "", interfaceVersion
		end)
		assert(loadfile("src/Client.lua"))()
		assert(loadfile("src/Core.lua"))()
	end

	it("ships explicitly reviewed Retail completion-sharing families", function()
		loadClient(120100)
		assert.are.equal("retail", QuestWithFriends.QuestEquivalencesGame)
		assert.are.equal(28757, QuestWithFriends.Core.questIDs(28762)[1])
		assert.are.equal(QuestWithFriends.Core.questIDs(28762), QuestWithFriends.Core.completionIDs(28762))
		assert.are.equal("objectives", QuestWithFriends.QuestEquivalences[28762].progress)
		assert.are.equal("state", QuestWithFriends.QuestEquivalences[28784].progress)
		assert.are.equal("state", QuestWithFriends.QuestEquivalences[28818].progress)
		local count = 0
		for _, ids in pairs(QuestWithFriends.QuestEquivalences) do
			assert.is_true(ids.history)
			count = count + 1
		end
		assert.are.equal(54, count)
		assert.same({ 71002 }, QuestWithFriends.Core.questIDs(71002))
		assert.same({ 71002 }, QuestWithFriends.Core.completionIDs(71002))
	end)

	it("compares completed source variants without rewriting snapshots or sharing other steps", function()
		loadClient(120100)
		local Core = QuestWithFriends.Core
		for _, id in ipairs({ 28762, 28769, 28784, 28792, 28808, 28818 }) do
			local first = Core.questIDs(id)[1]
			local mine = { [first] = { title = "Reviewed step", state = "completed", objectives = {} } }
			local peer = { [id] = { title = "Reviewed step", state = "active", objectives = {} } }
			assert.are.equal(Core.questIDs(id), Core.completionIDs(id))
			local groups = Core.compare(mine, { { name = "Julia", quests = peer } })
			assert.are.equal(1, #groups)
			assert.same({
				{ player = "You", kind = "ahead", reason = "completed" },
				{ player = "Julia", kind = "needs", reason = "active" },
			}, groups[1].differences)
			assert.is_nil(groups[1].shareQuestID)
			assert.is_nil(mine[id])
			assert.same(peer, Core.decode(Core.encode(peer)))
		end
		assert.is_nil(Core.matchQuest({ [28762] = { state = "completed" } }, 28769))
	end)

	it("never applies shipped completion-sharing families in Forever", function()
		loadClient(16001)
		assert.same({}, QuestWithFriends.QuestEquivalences)
		assert.same({ 28762 }, QuestWithFriends.Core.completionIDs(28762))
		assert.is_nil(QuestWithFriends.Core.matchQuest({ [28757] = { state = "completed" } }, 28762))
	end)

	it("retains a reviewed table for its own game", function()
		assert(loadfile("tests/fixtures/quest_equivalences.lua"))()
		loadClient(120100)
		assert.are.equal("retail", QuestWithFriends.QuestEquivalencesGame)
		assert.are.equal(71001, QuestWithFriends.Core.questIDs(71002)[1])
	end)

	it("never applies Retail equivalences or completion inference in Forever", function()
		assert(loadfile("tests/fixtures/quest_equivalences.lua"))()
		loadClient(16001)
		assert.are.equal("forever", QuestWithFriends.QuestEquivalencesGame)
		assert.same({}, QuestWithFriends.QuestEquivalences)
		assert.same({ 71002 }, QuestWithFriends.Core.questIDs(71002))
		assert.same({ 71002 }, QuestWithFriends.Core.completionIDs(71002))
	end)

	it("recognizes subsequent Forever beta interfaces without treating Era as Forever", function()
		loadClient(16002)
		assert.are.equal("forever", QuestWithFriends.QuestEquivalencesGame)
		assert(loadfile("src/QuestEquivalences.lua"))()
		loadClient(11508)
		assert.are.equal("retail", QuestWithFriends.QuestEquivalencesGame)
		assert.same({ 71002 }, QuestWithFriends.Core.questIDs(71002))
	end)

	it("defaults to Retail in simulator environments without GetBuildInfo", function()
		_G.GetBuildInfo = nil
		assert(loadfile("src/Client.lua"))()
		assert.are.equal("retail", QuestWithFriends.QuestEquivalencesGame)
		assert.is_not_nil(QuestWithFriends.QuestEquivalences[28762])
	end)
end)
