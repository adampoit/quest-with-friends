if not AddonKit or not AddonKit.Test or not AddonKit.Test.tests then
	return
end

local Core = QuestWithFriends.Core
local tests = AddonKit.Test.tests
local check = AddonKit.Test.assert

tests.QuestWithFriends_ProtocolRoundTrip = function()
	local quests = {
		[42] = {
			title = "A: Strange Quest",
			state = "active",
			category = "profession",
			objectives = {
				{ text = "Collect: crates", have = 3, need = 5 },
			},
		},
	}
	local decoded = Core.decode(Core.encode(quests))
	check.equals(decoded[42].title, quests[42].title)
	check.equals(decoded[42].objectives[1].have, 3)
	check.equals(decoded[42].category, "profession")
	check.equals(Core.PROTOCOL_VERSION, "1.0")
	check.equals(Core.PROTOCOL_MAJOR, 1)
	check.equals(Core.PROTOCOL_MINOR, 0)
	check.equals(Core.decode("1:0"), nil)
	check.equals(Core.decode("broken"), nil)
end

tests.QuestWithFriends_UnknownMember = function()
	local groups, complete, notices = Core.compare({}, { { name = "Unknown" } })
	check.equals(complete, false)
	check.equals(#groups, 0)
	check.equals(notices[1].player, "Unknown")
end

tests.QuestWithFriends_ObjectiveDifference = function()
	local function quest(have)
		return {
			title = "Hunt",
			state = "active",
			objectives = {
				{ text = "Gnolls slain", have = have, need = 8 },
			},
		}
	end
	local groups = Core.compare({ [100] = quest(8) }, { { name = "Julia", quests = { [100] = quest(5) } } })
	check.equals(groups[1].title, "Hunt")
	check.equals(groups[1].differences[1].player, "Julia")
	check.equals(groups[1].differences[1].objective.have, 5)
	check.equals(groups[1].differences[1].kind, "needs")
end
