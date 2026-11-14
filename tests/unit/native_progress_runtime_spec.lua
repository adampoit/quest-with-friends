local network = require("tests.support.sync_network")
local TYPES = { QuestTitle = 17, QuestPlayer = 18, QuestObjective = 8 }

local function rows(id, have)
	return {
		lines = {
			{ type = TYPES.QuestTitle, id = id, leftText = "Hunt" },
			{ type = TYPES.QuestPlayer, guid = "guid-2", leftText = "Player2" },
			{ type = TYPES.QuestObjective, leftText = "Wolves slain", numFulfilled = have, numRequired = 8 },
		},
	}
end
local function quest(have)
	return {
		title = "Hunt",
		state = have == 8 and "ready" or "active",
		objectives = { { text = "Wolves slain", numFulfilled = have, numRequired = 8 } },
	}
end
local function counts(c)
	local result = {}
	for _, group in ipairs(c.view.groups or {}) do
		for _, difference in ipairs(group.differences) do
			if difference.objective then
				result[#result + 1] = difference.objective.have
			end
		end
	end
	return result
end

for _, game in ipairs({ "retail", "forever" }) do
	describe("native progress runtime on " .. game, function()
		local n, client, remote, data, unitData, queries
		before_each(function()
			data, unitData, queries = {}, {}, 0
			n = network(game, 2, { 3, 3 }, {
				instrument = function(c, env)
					if c.sender:match("^Player1") then
						env.Enum.TooltipDataLineType = TYPES
						env.UnitGUID = function(unit)
							local index = unit == "player" and 1 or c.units[tonumber(unit:match("^party(%d+)$"))]
							return index and "guid-" .. index
						end
						env.C_TooltipInfo = {
							GetQuestPartyProgress = function(id)
								queries = queries + 1
								return data[id]
							end,
							GetUnit = function(unit)
								return unitData[unit]
							end,
						}
						env.C_QuestLog.IsUnitOnQuest = function()
							return false
						end
					end
				end,
			})
			client, remote = unpack(n.clients)
			n.deliver = function(sender)
				return sender == client
			end
		end)

		it("shows counts without messages from the member and polls without broadcasting progress", function()
			client.quests[42] = quest(8)
			data[42] = rows(42, 3)
			n:join()
			n:advance(3)
			assert.same({ 3 }, counts(client))
			assert.is_false(client.view.complete)
			assert.are.equal("native", client.view.notices[1].reason)
			assert.is_nil(client.view.groups[1].shareQuestID)
			local messages = client:count("1.3:D:") + client:count("1.3:P:")
			data[42] = rows(42, 5)
			n:advance(3)
			assert.same({ 5 }, counts(client))
			assert.are.equal(messages, client:count("1.3:D:") + client:count("1.3:P:"))
			local snapshot = client:snapshots()[1]
			assert.are.equal("ready", snapshot[42].state)
			assert.are.equal(8, snapshot[42].objectives[1].have)
			assert.is_nil(snapshot[42].stateUnknown)
		end)

		it("refreshes on party quest events and treats missing native data as unknown", function()
			client.quests[42] = quest(8)
			data[42] = rows(42, 3)
			n:join()
			n:advance(3)
			data[42] = rows(42, 4)
			client:fire("UNIT_QUEST_LOG_CHANGED", "party1")
			assert.same({ 4 }, counts(client))
			data[42] = nil
			client:fire("UNIT_QUEST_LOG_CHANGED", "party1")
			assert.same({}, client.view.groups)
			assert.is_false(client.view.complete)
			assert.are.equal("unknown", client.view.notices[1].reason)
		end)

		it("discovers quests from nameplates, target and mouseover and checks our completion history", function()
			n:join()
			n:advance(3)
			for _, observation in ipairs({
				{ "NAME_PLATE_UNIT_ADDED", "nameplate1" },
				{ "PLAYER_TARGET_CHANGED", "target" },
				{ "UPDATE_MOUSEOVER_UNIT", "mouseover" },
			}) do
				unitData[observation[2]] = rows(99, 2)
				client:fire(observation[1], observation[2])
				assert.are.equal(99, client.view.groups[1].questID)
				assert.are.equal("missing", client.view.groups[1].differences[1].reason)
				assert.are.equal("You", client.view.groups[1].differences[1].player)
			end
			client.env.C_QuestLog.IsQuestFlaggedCompleted = function(id)
				return id == 99
			end
			client:fire("UNIT_QUEST_LOG_CHANGED", "party1")
			assert.same({}, client.view.groups)
			assert.is_false(client.view.complete)
			n:advance(16)
			assert.same({}, client.view.groups)
			assert.are.equal("unknown", client.view.notices[1].reason)
			for _, snapshot in ipairs(client:snapshots()) do
				assert.is_nil(snapshot[99])
			end
		end)

		it("refreshes visible nameplate observations and expires them after removal", function()
			client.quests[42] = quest(8)
			unitData.nameplate1 = rows(42, 3)
			local exists = client.env.UnitExists
			local visible = true
			client.env.UnitExists = function(unit)
				return unit == "nameplate1" and visible or exists(unit)
			end
			client:fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
			n:join()
			n:advance(3)
			assert.same({ 3 }, counts(client))
			unitData.nameplate1 = rows(42, 5)
			n:advance(3)
			assert.same({ 5 }, counts(client))
			visible = false
			client:fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
			n:advance(16)
			assert.same({}, client.view.groups)
			assert.are.equal("unknown", client.view.notices[1].reason)
		end)

		it(
			"prefers addon snapshots including stale snapshots and stops polling when coverage becomes complete",
			function()
				client.quests[42], remote.quests[42] = quest(8), quest(6)
				data[42] = rows(42, 3)
				n:join()
				n:advance(3)
				assert.same({ 3 }, counts(client))
				n.deliver = nil
				client.env.SlashCmdList.QUESTWITHFRIENDS("")
				n:advance(15)
				assert.same({ 6 }, counts(client))
				assert.is_true(client.view.complete)
				local previous = queries
				n:advance(10)
				assert.are.equal(previous, queries)
				n.deliver = function(sender)
					return sender == client
				end
				n:advance(100)
				assert.same({ 6 }, counts(client))
				assert.is_false(client.view.complete)
				assert.are.equal("stale", client.view.notices[1].reason)
				assert.are.equal(previous, queries)
			end
		)

		it("clears native state on disconnect, roster changes and leaving, without leaking timers", function()
			client.quests[42] = quest(8)
			data[42] = rows(42, 3)
			n:join()
			n:advance(3)
			client.offline[2] = true
			client:fire("UNIT_CONNECTION", "party1")
			assert.are.equal("offline", client.view.notices[1].reason)
			assert.same({}, client.view.groups)
			local previous = queries
			n:advance(5)
			assert.are.equal(previous, queries)
			client.offline[2] = nil
			client:fire("UNIT_CONNECTION", "party1")
			assert.same({ 3 }, counts(client))
			client.party = false
			client:fire("GROUP_ROSTER_UPDATE")
			n:advance(5)
			assert.is_true(client.view.hidden)
			previous = queries
			n:advance(20)
			assert.are.equal(previous, queries)
		end)
	end)
end
