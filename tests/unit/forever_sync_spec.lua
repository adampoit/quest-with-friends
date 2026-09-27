describe("Quest With Friends two Forever clients", function()
	it("exchanges real snapshots using First Last chat senders and answers manual refreshes", function()
		local outgoing = {}
		local function client(first, last, peerFirst, peerLast, have)
			local c = { timers = {}, logs = {}, have = have, snapshots = 0 }
			local env = setmetatable({
				QuestWithFriends = false,
				QuestWithFriendsDB = {},
				AddonKit = false,
				Constants = false,
				C_Map = false,
				GetQuestUiMapID = false,
				SlashCmdList = {},
				Enum = { SendAddonMessageResult = { Success = 0 } },
			}, { __index = _G })
			env._G = env
			env.GetBuildInfo = function()
				return "1.60.1", "70170", "", 16001
			end
			env.GetRealmName = function()
				return "ClassicBetaPvE"
			end
			env.UnitFullName = function(unit)
				if unit == "player" then
					return first, last
				end
				if unit == "party1" then
					return peerFirst, peerLast
				end
			end
			env.UnitName = env.UnitFullName
			env.UnitExists = function(unit)
				return unit == "player" or unit == "party1"
			end
			env.UnitIsConnected = function()
				return true
			end
			env.IsInGroup = function()
				return true
			end
			env.IsInRaid = function()
				return false
			end
			env.CreateFrame = function()
				return {
					RegisterEvent = function() end,
					SetScript = function(_, script, handler)
						assert.are.equal("OnEvent", script)
						c.event = handler
					end,
				}
			end
			env.C_Timer = {
				After = function(delay, callback)
					if delay < 15 then
						c.timers[#c.timers + 1] = callback
					end
				end,
			}
			env.C_ChatInfo = {
				RegisterAddonMessagePrefix = function()
					return 0
				end,
				SendAddonMessage = function(prefix, message, channel)
					assert.are.equal("QWF", prefix)
					assert.are.equal("PARTY", channel)
					outgoing[#outgoing + 1] = { sender = first .. " " .. last, message = message }
					if message:match("^1%.0:D:") then
						c.snapshots = c.snapshots + 1
					end
					return 0
				end,
			}
			env.C_QuestLog = {
				GetNumQuestLogEntries = function()
					return 1
				end,
				GetInfo = function()
					return { questID = 42, title = "Errand" }
				end,
				GetQuestObjectives = function()
					return { { text = "Gnolls slain: " .. c.have .. "/8", numFulfilled = c.have, numRequired = 8 } }
				end,
				IsComplete = function()
					return false
				end,
				IsQuestFlaggedCompleted = function()
					return false
				end,
			}
			env.AddonKit = {
				RegisterAddon = function() end,
				Log = function(_, _, _, message, data)
					c.logs[#c.logs + 1] = { message = message, data = data }
				end,
			}
			for _, path in ipairs({
				"QuestEquivalences.lua",
				"Client.lua",
				"QuestCategories.lua",
				"Core.lua",
				"QuestWithFriends.lua",
			}) do
				setfenv(assert(loadfile(path)), env)()
			end
			env.QuestWithFriends.Panel = {
				show = function(groups, complete, _, _, _, notices)
					c.groups, c.complete, c.notices = groups, complete, notices
				end,
			}
			c.env = env
			return c
		end

		local alice = client("Carola", "Goodspeed", "Florace", "Bastille", 8)
		local bob = client("Florace", "Bastille", "Carola", "Goodspeed", 3)
		local clients = { alice, bob }
		local function pump()
			for _ = 1, 20 do
				local queued = outgoing
				outgoing = {}
				for _, message in ipairs(queued) do
					for _, c in ipairs(clients) do
						c.event(nil, "CHAT_MSG_ADDON", "QWF", message.message, "PARTY", message.sender)
					end
				end
				for _, c in ipairs(clients) do
					local timers = c.timers
					c.timers = {}
					for _, callback in ipairs(timers) do
						callback()
					end
				end
				if #outgoing == 0 and #alice.timers == 0 and #bob.timers == 0 then
					return
				end
			end
			error("Snapshot exchange did not settle")
		end

		for _, c in ipairs(clients) do
			c.event(nil, "PLAYER_ENTERING_WORLD")
		end
		pump()
		assert.is_true(alice.complete)
		assert.is_true(bob.complete)
		assert.are.equal("Florace Bastille", alice.groups[1].differences[1].player)
		assert.are.equal("You", bob.groups[1].differences[1].player)
		for _, c in ipairs(clients) do
			for _, record in ipairs(c.logs) do
				if record.message == "Ignored addon message" then
					assert.are.equal("self message", record.data.reason)
				end
			end
		end

		bob.have = 8
		bob.event(nil, "QUEST_LOG_UPDATE")
		pump()
		assert.same({}, alice.groups)
		assert.same({}, bob.groups)
		local previous = bob.snapshots
		alice.env.SlashCmdList.QUESTWITHFRIENDS("")
		pump()
		assert.is_true(bob.snapshots > previous)
		assert.is_true(alice.complete)
		assert.is_true(bob.complete)
	end)
end)
