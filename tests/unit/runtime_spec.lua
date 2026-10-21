describe("Quest With Friends party sync", function()
	local eventHandler, timers, messages, view, objectives, entries, party, currentMap, questMaps, pushed, pushable
	local originalBuildInfo, originalConstants, originalTradeSkillUI, originalClassMale, originalClassFemale
	local tags, questTypes
	local abandonable, disabledQuests, abandonRequests
	local originalSettings, originalSettingsPanel, originalSettingsInbound, originalHeaderInitializer, originalButtonInitializer
	local captureSettings
	local registeredEvents, originalDiagnostics
	local diagnosticGlobals = {
		"QuestMapQuestOptions_AbandonQuest",
		"GetTime",
		"InCombatLockdown",
		"UnitAffectingCombat",
		"issecure",
		"issecurevariable",
		"debugstack",
		"C_AddOns",
		"C_Container",
		"C_Item",
		"NUM_TOTAL_EQUIPPED_BAG_SLOTS",
		"NUM_BAG_SLOTS",
	}
	before_each(function()
		registeredEvents, originalDiagnostics = {}, {}
		for _, name in ipairs(diagnosticGlobals) do
			originalDiagnostics[name] = _G[name]
			rawset(_G, name, nil)
		end
		originalSettingsPanel = _G.SettingsPanel
		originalSettingsInbound = _G.SettingsInbound
		_G.SettingsInbound = nil
		originalHeaderInitializer = _G.CreateSettingsListSectionHeaderInitializer
		originalButtonInitializer = _G.CreateSettingsButtonInitializer
		_G.SettingsPanel, _G.CreateSettingsListSectionHeaderInitializer, _G.CreateSettingsButtonInitializer =
			nil, nil, nil
		originalSettings = _G.Settings
		_G.Settings = nil
		originalBuildInfo = _G.GetBuildInfo
		originalConstants = _G.Constants
		originalTradeSkillUI = _G.C_TradeSkillUI
		originalClassMale, originalClassFemale = _G.LOCALIZED_CLASS_NAMES_MALE, _G.LOCALIZED_CLASS_NAMES_FEMALE
		_G.C_TradeSkillUI = nil
		_G.LOCALIZED_CLASS_NAMES_MALE, _G.LOCALIZED_CLASS_NAMES_FEMALE = nil, nil
		tags, questTypes = {}, {}
		_G.Constants = nil
		rawset(_G, "GetBuildInfo", function()
			return "12.1.0", "69933", "", 120100
		end)
		_G.QuestWithFriends = nil
		assert(loadfile("src/Bootstrap.lua"))()
		assert(loadfile("src/QuestEquivalences.lua"))()
		assert(loadfile("tests/fixtures/quest_equivalences.lua"))()
		assert(loadfile("src/Client.lua"))()
		assert(loadfile("src/QuestCategories.lua"))()
		assert(loadfile("src/Core.lua"))()
		assert(loadfile("src/ItemStock.lua"))()
		assert(loadfile("src/Preview.lua"))()
		timers, messages, objectives, entries = {}, {}, {}, {}
		view = {}
		party = true
		currentMap, questMaps = 101, {}
		pushed, pushable = {}, {}
		abandonable, disabledQuests, abandonRequests = {}, {}, {}
		_G.QuestMapQuestOptions_AbandonQuest = function(id)
			abandonRequests[#abandonRequests + 1] = id
		end
		_G.QuestLogPushQuest = function(index)
			pushed[#pushed + 1] = index
		end
		_G.QuestWithFriendsDB = nil
		QuestWithFriends.Panel = {
			setLocked = function(locked)
				QuestWithFriendsDB.panelLocked = locked ~= false
			end,
			show = function(groups, complete, zoneFilter, toggle, share, notices, filters, presentation)
				view = {
					groups = groups,
					complete = complete,
					zoneFilter = zoneFilter,
					toggle = toggle,
					share = share,
					notices = notices,
					filters = filters,
					presentation = presentation,
				}
			end,
			hide = function()
				view.hidden = true
			end,
		}
		_G.CreateFrame = function(...)
			assert.is_true(select("#", ...) >= 1)
			return {
				RegisterEvent = function(_, event)
					registeredEvents[event] = true
				end,
				SetScript = function(_, name, fn)
					if name == "OnEvent" then
						eventHandler = fn
					end
				end,
			}
		end
		_G.C_Timer = {
			After = function(delay, fn)
				-- Transport settles here; watchdog deadlines use the clocked sync suite.
				if delay < 15 then
					timers[#timers + 1] = fn
				end
			end,
		}
		_G.C_ChatInfo = {
			RegisterAddonMessagePrefix = function(prefix)
				assert.are.equal("QWF", prefix)
				return true
			end,
			SendAddonMessage = function(_, message, channel)
				assert.are.equal("PARTY", channel)
				messages[#messages + 1] = message
			end,
		}
		_G.C_QuestLog = {
			CanAbandonQuest = function(id)
				return abandonable[id] ~= false
			end,
			IsQuestDisabledForSession = function(id)
				return disabledQuests[id] == true
			end,
			GetQuestTagInfo = function(id)
				return tags[id]
			end,
			GetQuestType = function(id)
				return questTypes[id]
			end,
			IsPushableQuest = function(id)
				return pushable[id] == true
			end,
			GetLogIndexForQuestID = function(id)
				for index, entry in ipairs(entries) do
					if entry.questID == id then
						return index
					end
				end
			end,
			GetNumQuestLogEntries = function()
				return math.max(#objectives, #entries)
			end,
			GetInfo = function(index)
				return entries[index] or { questID = index, title = "Quest " .. index }
			end,
			GetQuestObjectives = function(index)
				return objectives[index]
			end,
			IsComplete = function(_)
				return false
			end,
			IsQuestFlaggedCompleted = function(_)
				return false
			end,
			GetTitleForQuestID = function(id)
				return "Quest " .. id
			end,
		}
		_G.C_Map = {
			GetBestMapForUnit = function(unit)
				assert.are.equal("player", unit)
				return currentMap
			end,
			GetMapInfo = function(id)
				if id == 999 then
					return { mapType = 2 }
				end
				if id == 1101 then
					return { mapType = 4, parentMapID = 101 }
				end
				return { mapType = 3, parentMapID = 999 }
			end,
		}
		_G.Enum = { UIMapType = { Zone = 3 } }
		_G.GetQuestUiMapID = function(id, ignoreWaypoints)
			assert.is_true(ignoreWaypoints)
			return questMaps[id]
		end
		_G.IsInGroup = function()
			return party
		end
		_G.IsInRaid = function()
			return false
		end
		_G.UnitFullName = function(unit)
			if unit == "player" then
				return "Adam", "Realm"
			end
			return "Julia", "Realm"
		end
		_G.GetRealmName = function()
			return "Realm"
		end
		_G.UnitExists = function(unit)
			return unit == "party1"
		end
		_G.UnitName = function(_)
			return "Julia"
		end
		_G.UnitIsConnected = function(_)
			return true
		end
		_G.SlashCmdList = {}
		_G.AddonKit = nil
		assert(loadfile("src/QuestWithFriends.lua"))()
	end)

	after_each(function()
		for _, name in ipairs(diagnosticGlobals) do
			rawset(_G, name, originalDiagnostics[name])
		end
		_G.Settings = originalSettings
		_G.SettingsPanel = originalSettingsPanel
		_G.SettingsInbound = originalSettingsInbound
		_G.CreateSettingsListSectionHeaderInitializer = originalHeaderInitializer
		_G.CreateSettingsButtonInitializer = originalButtonInitializer
		_G.GetBuildInfo = originalBuildInfo
		_G.Constants = originalConstants
		_G.C_TradeSkillUI = originalTradeSkillUI
		_G.LOCALIZED_CLASS_NAMES_MALE, _G.LOCALIZED_CLASS_NAMES_FEMALE = originalClassMale, originalClassFemale
	end)

	local function fire(event, ...)
		eventHandler(nil, event, ...)
	end

	local function flush(batches)
		for _ = 1, batches or 500 do
			if #timers == 0 then
				return
			end
			local queued = timers
			timers = {}
			for _, callback in ipairs(queued) do
				callback()
			end
		end
		assert(batches ~= nil or #timers == 0, "Transport did not settle")
	end

	local function receiveSnapshot(quests, serial)
		local payload = QuestWithFriends.Core.encode(quests)
		local total = math.ceil(#payload / 220)
		for part = 1, total do
			fire(
				"CHAT_MSG_ADDON",
				"QWF",
				"1.1:D:"
					.. serial
					.. ":"
					.. part
					.. ":"
					.. total
					.. ":"
					.. payload:sub((part - 1) * 220 + 1, part * 220),
				"PARTY",
				"Julia-Realm"
			)
		end
	end

	for _, case in ipairs({
		{ text = "0/1 Felix's Chest", expected = "Felix's Chest" },
		{ text = "  0/1   Felix's Chest", expected = "Felix's Chest" },
		{ text = "Felix's Chest: 0/1", expected = "Felix's Chest" },
		{ text = "Felix's Chest: 0/1  ", expected = "Felix's Chest" },
		{ text = "Felix's Chest", expected = "Felix's Chest" },
		{ text = "7 chests opened", expected = "7 chests opened" },
		{ text = "Reach 1/2 health", expected = "Reach 1/2 health" },
	}) do
		it("normalizes objective counts for display and sync: " .. case.text, function()
			entries = { { questID = 42, title = "Errand" } }
			objectives[42] = { { text = case.text, numFulfilled = 3, numRequired = 8 } }
			questMaps[42] = 101
			fire("PLAYER_ENTERING_WORLD")
			flush()

			local parts = {}
			for _, message in ipairs(messages) do
				local payload = message:match("^1%.1:D:%d+:%d+:%d+:(.+)$")
				if payload then
					parts[#parts + 1] = payload
				end
			end
			local expected = { text = case.expected, have = 3, need = 8 }
			local snapshot = QuestWithFriends.Core.decode(table.concat(parts))
			assert.same(expected, snapshot[42].objectives[1])

			receiveSnapshot({ [42] = { title = "Errand", state = "completed", mapID = 101, objectives = {} } }, 1)
			assert.same(expected, view.groups[1].differences[1].objective)
		end)
	end

	local function carriedCloth(count)
		_G.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
		_G.C_Container = {
			GetContainerNumSlots = function(bag)
				return bag == 0 and 1 or 0
			end,
			GetContainerItemInfo = function()
				return {
					itemID = 2589,
					itemName = "Linen Cloth",
					stackCount = count,
					isBound = false,
					isLocked = false,
				}
			end,
		}
		_G.C_Item = {
			GetItemInfo = function()
				return "Linen Cloth", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0
			end,
		}
	end

	local function latestSnapshot()
		local parts, serial = {}, nil
		for _, message in ipairs(messages) do
			local revision, part, data = message:match("^1%.1:D:(%d+):(%d+):%d+:(.+)$")
			if revision then
				if revision ~= serial then
					parts, serial = {}, revision
				end
				parts[tonumber(part)] = data
			end
		end
		return assert(QuestWithFriends.Core.decode(table.concat(parts)))
	end

	it("collects item stock and syncs surplus changes even when quest progress stays capped", function()
		entries = { { questID = 42, title = "Cloth Delivery" } }
		objectives[42] = { { text = "Linen Cloth: 10/10", type = "item", numFulfilled = 10, numRequired = 10 } }
		carriedCloth(12)
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.same(
			{ text = "Linen Cloth", have = 10, need = 10, itemID = 2589, spare = 2 },
			latestSnapshot()[42].objectives[1]
		)
		receiveSnapshot({
			[42] = {
				title = "Cloth Delivery",
				state = "active",
				objectives = {
					{ text = "Linen Cloth", have = 3, need = 10 },
				},
			},
		}, 1)
		assert.are.equal(2, view.groups[1].differences[1].objective.spare)
		carriedCloth(15)
		fire("BAG_UPDATE_DELAYED")
		flush()
		assert.are.equal(5, latestSnapshot()[42].objectives[1].spare)
		assert.are.equal(5, view.groups[1].differences[1].objective.spare)
		_G.C_Container.GetContainerItemInfo = function()
			return { itemID = 2589, itemName = "Linen Cloth", stackCount = 15, isBound = false, isLocked = true }
		end
		fire("ITEM_LOCK_CHANGED", 0, 1)
		flush()
		assert.is_nil(latestSnapshot()[42].objectives[1].spare)
		assert.are.equal("Julia", view.groups[1].differences[1].player)
	end)

	it("ignores inventory lookalikes for non-item objectives and reserves filtered quests too", function()
		entries = { { questID = 42, title = "Cloth Delivery" }, { questID = 43, title = "Tailoring" } }
		questTypes[43] = 21
		objectives[42] = {
			{ text = "Linen Cloth: 10/10", type = "item", numFulfilled = 10, numRequired = 10 },
			{ text = "Linen Cloth: 1/1", type = "monster", numFulfilled = 1, numRequired = 1 },
		}
		objectives[43] = { { text = "Linen Cloth: 5/5", type = "item", numFulfilled = 5, numRequired = 5 } }
		carriedCloth(17)
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local snapshot = latestSnapshot()
		assert.are.equal(2, snapshot[42].objectives[1].spare)
		assert.is_nil(snapshot[42].objectives[2].spare)
		assert.are.equal(2, snapshot[43].objectives[1].spare)
	end)

	it("retries stock identification and retains known identities with fresh stock after turn-in", function()
		entries = { { questID = 42, title = "Cloth Delivery" } }
		objectives[42] = { { text = "Linen Cloth: 10/10", type = "item", numFulfilled = 10, numRequired = 10 } }
		carriedCloth(12)
		local loaded = _G.C_Item.GetItemInfo
		_G.C_Item.GetItemInfo = function()
			return "Linen Cloth"
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.is_nil(latestSnapshot()[42].objectives[1].spare)
		_G.C_Item.GetItemInfo = loaded
		fire("GET_ITEM_INFO_RECEIVED", 2589, true)
		flush()
		assert.are.equal(2, latestSnapshot()[42].objectives[1].spare)
		carriedCloth(2)
		-- The turn-in event can precede removal of the old quest-log entry.
		fire("QUEST_TURNED_IN", 42)
		flush()
		assert.are.equal("completed", latestSnapshot()[42].state)
		assert.same(
			{ text = "Linen Cloth", have = 10, need = 10, itemID = 2589, spare = 2 },
			latestSnapshot()[42].objectives[1]
		)
		receiveSnapshot({
			[42] = {
				title = "Cloth Delivery",
				state = "active",
				objectives = { { text = "Linen Cloth", have = 3, need = 10 } },
			},
		}, 1)
		assert.are.equal(2, view.groups[1].differences[1].objective.spare)
		assert.are.equal("completed", view.groups[1].differences[2].reason)
		entries, objectives = {}, {}
		carriedCloth(4)
		fire("BAG_UPDATE_DELAYED")
		flush()
		assert.are.equal(4, latestSnapshot()[42].objectives[1].spare)
		assert.are.equal(4, view.groups[1].differences[1].objective.spare)
		_G.C_Container.GetContainerNumSlots = function()
			return 0
		end
		fire("BAG_UPDATE_DELAYED")
		flush()
		assert.is_nil(latestSnapshot()[42].objectives[1].spare)
		assert.are.equal("completed", view.groups[1].differences[1].reason)
		carriedCloth(2)
		fire("BAG_UPDATE_DELAYED")
		flush()
		assert.are.equal(2, latestSnapshot()[42].objectives[1].spare)
		entries = { { questID = 42, title = "Cloth Delivery" } }
		objectives[42] = { { text = "Linen Cloth: 2/10", type = "item", numFulfilled = 2, numRequired = 10 } }
		fire("QUEST_ACCEPTED", 1, 42)
		flush()
		assert.are.equal("active", latestSnapshot()[42].state)
		assert.are.equal(0, latestSnapshot()[42].objectives[1].spare)
	end)

	it("retains verified identities when a bag update precedes the turn-in event", function()
		entries = { { questID = 42, title = "Cloth Delivery" } }
		objectives[42] = { { text = "Linen Cloth: 10/10", type = "item", numFulfilled = 10, numRequired = 10 } }
		carriedCloth(12)
		fire("PLAYER_ENTERING_WORLD")
		flush()
		carriedCloth(2)
		fire("BAG_UPDATE_DELAYED")
		flush()
		assert.is_nil(latestSnapshot()[42].objectives[1].itemID)
		fire("QUEST_TURNED_IN", 42)
		flush()
		assert.are.equal(2589, latestSnapshot()[42].objectives[1].itemID)
		assert.are.equal(2, latestSnapshot()[42].objectives[1].spare)
	end)

	for _, changed in ipairs({ "text", "type", "need" }) do
		it("does not retain a verified identity after objective " .. changed .. " changes", function()
			entries = { { questID = 42, title = "Cloth Delivery" } }
			objectives[42] = { { text = "Linen Cloth: 10/10", type = "item", numFulfilled = 10, numRequired = 10 } }
			carriedCloth(12)
			fire("PLAYER_ENTERING_WORLD")
			flush()
			if changed == "text" then
				objectives[42][1].text = "Collect Linen Cloth"
			elseif changed == "type" then
				objectives[42][1].type = "monster"
			else
				objectives[42][1].numRequired = 20
			end
			carriedCloth(2)
			fire("QUEST_LOG_UPDATE")
			flush()
			fire("QUEST_TURNED_IN", 42)
			flush()
			assert.is_nil(latestSnapshot()[42].objectives[1].itemID)
		end)
	end

	it("does not infer item stock from completed history without a verified local identity", function()
		carriedCloth(2)
		_G.C_QuestLog.IsQuestFlaggedCompleted = function()
			return true
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		receiveSnapshot({
			[42] = {
				title = "Cloth Delivery",
				state = "active",
				objectives = { { text = "Linen Cloth", have = 3, need = 10, itemID = 2589, spare = 0 } },
			},
		}, 1)
		assert.are.equal("completed", view.groups[1].differences[1].reason)
		assert.are.equal(2, #view.groups[1].differences)
	end)

	it("renders remote-to-remote progress and missing players from received snapshots", function()
		_G.UnitExists = function(unit)
			return unit == "party1" or unit == "party2"
		end
		_G.UnitFullName = function(unit)
			return unit == "player" and "Adam" or (unit == "party1" and "Julia" or "Bob"), "Realm"
		end
		_G.UnitName = function(unit)
			return UnitFullName(unit)
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		receiveSnapshot({ [42] = { title = "Hunt", state = "completed", mapID = 101, objectives = {} } }, 1)
		local payload = QuestWithFriends.Core.encode({
			[42] = {
				title = "Hunt",
				state = "active",
				mapID = 101,
				objectives = { { text = "Gnolls slain", have = 5, need = 8 } },
			},
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Bob-Realm")
		assert.is_true(view.complete)
		assert.same({
			{ player = "You", kind = "missing", reason = "missing" },
			{
				player = "Bob",
				kind = "needs",
				reason = "objective",
				objective = { text = "Gnolls slain", have = 5, need = 8 },
			},
			{ player = "Julia", kind = "ahead", reason = "completed" },
		}, view.groups[1].differences)
		assert.is_nil(view.groups[1].shareQuestID)
		receiveSnapshot({}, 2)
		assert.same({
			{ player = "You", kind = "missing", reason = "missing" },
			{ player = "Julia", kind = "missing", reason = "missing" },
		}, view.groups[1].differences)
	end)

	it("uses Smart by default and tracks local and remote activity without promoting refreshes", function()
		entries = {
			{ questID = 1, title = "Alpha" },
			{ questID = 2, title = "Beta" },
			{ questID = 3, title = "Missing A" },
		}
		for id = 1, 3 do
			objectives[id] = { { text = "Gnolls", numFulfilled = 0, numRequired = 8 } }
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local remote = {
			[1] = { title = "Alpha", state = "active", objectives = { { text = "Gnolls", have = 8, need = 8 } } },
			[2] = { title = "Beta", state = "active", objectives = { { text = "Gnolls", have = 8, need = 8 } } },
			[4] = { title = "Missing Z", state = "active", objectives = { { text = "Gnolls", have = 0, need = 8 } } },
		}
		local function ids()
			local result = {}
			for _, group in ipairs(view.groups) do
				result[#result + 1] = group.questID
			end
			return result
		end
		receiveSnapshot(remote, 1)
		assert.are.equal("smart", QuestWithFriendsDB.sortMode)
		assert.same({ 3, 4, 1, 2 }, ids())
		objectives[2][1].numFulfilled = 1
		fire("QUEST_LOG_UPDATE")
		flush()
		assert.same({ 3, 4, 2, 1 }, ids())
		remote[4].objectives[1].have = 1
		receiveSnapshot(remote, 2)
		assert.same({ 4, 3, 2, 1 }, ids())
		remote[1].state = "ready"
		receiveSnapshot(remote, 3)
		assert.same({ 4, 3, 1, 2 }, ids())
		SlashCmdList.QUESTWITHFRIENDS("")
		flush()
		receiveSnapshot(remote, 4)
		fire("QUEST_LOG_UPDATE")
		fire("GROUP_ROSTER_UPDATE")
		flush()
		assert.same({ 4, 3, 1, 2 }, ids())
		view.presentation.onSort("title")
		assert.are.equal("title", QuestWithFriendsDB.sortMode)
		assert.same({ 1, 2, 3, 4 }, ids())
		view.presentation.onSort("smart")
		assert.same({ 4, 3, 1, 2 }, ids())
		entries[4] = { questID = 5, title = "Newest pickup" }
		objectives[5] = {}
		fire("QUEST_ACCEPTED", 5)
		flush()
		assert.same({ 5, 4, 3, 1, 2 }, ids())
	end)

	it("keeps activity for quests hidden by zone filters or currently in sync", function()
		entries = { { questID = 1, title = "Alpha" }, { questID = 2, title = "Beta" } }
		questMaps[1], questMaps[2] = 202, 202
		for id = 1, 2 do
			objectives[id] = { { text = "Gnolls", numFulfilled = 8, numRequired = 8 } }
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local remote = {
			[1] = {
				title = "Alpha",
				state = "active",
				objectives = { { text = "Gnolls", have = 8, need = 8 } },
				mapID = 202,
			},
			[2] = {
				title = "Beta",
				state = "active",
				objectives = { { text = "Gnolls", have = 8, need = 8 } },
				mapID = 202,
			},
		}
		receiveSnapshot(remote, 1)
		assert.same({}, view.groups)
		objectives[1][1].numFulfilled = 7
		fire("QUEST_LOG_UPDATE")
		flush()
		objectives[2][1].numFulfilled = 7
		fire("QUEST_LOG_UPDATE")
		flush()
		receiveSnapshot(remote, 2)
		assert.same({}, view.groups)
		view.toggle()
		assert.are.equal(2, view.groups[1].questID)
		assert.are.equal(1, view.groups[2].questID)
	end)

	it("resets activity on reload rather than promoting initial snapshots", function()
		entries = { { questID = 1, title = "Alpha" }, { questID = 2, title = "Beta" } }
		objectives[1], objectives[2] = {}, {}
		fire("PLAYER_ENTERING_WORLD")
		flush()
		receiveSnapshot({}, 1)
		objectives[2] = { { text = "Gnolls", numFulfilled = 1, numRequired = 8 } }
		fire("QUEST_LOG_UPDATE")
		flush()
		assert.are.equal(2, view.groups[1].questID)
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		receiveSnapshot({}, 1)
		assert.are.equal("smart", view.presentation.sortMode)
		assert.are.equal(1, view.groups[1].questID)
		assert.are.equal(2, view.groups[2].questID)
	end)

	it("persists the sort choice across reloads and sorts preview samples", function()
		party = false
		SlashCmdList.QUESTWITHFRIENDS("preview")
		assert.are.equal("The Lost Supplies", view.groups[1].title)
		view.presentation.onSort("title")
		assert.are.equal("A Bridge to Safety", view.groups[1].title)
		assert.are.equal("title", QuestWithFriendsDB.sortMode)
		assert(loadfile("src/QuestWithFriends.lua"))()
		SlashCmdList.QUESTWITHFRIENDS("preview")
		assert.are.equal("title", view.presentation.sortMode)
		assert.are.equal("A Bridge to Safety", view.groups[1].title)
		QuestWithFriendsDB.sortMode = "invalid"
		assert(loadfile("src/QuestWithFriends.lua"))()
		SlashCmdList.QUESTWITHFRIENDS("preview")
		assert.are.equal("smart", view.presentation.sortMode)
	end)

	local function foreverNames(names)
		rawset(_G, "UnitFullName", function(unit)
			return unpack(names[unit] or {})
		end)
		rawset(_G, "UnitExists", function(unit)
			return names[unit] ~= nil
		end)
		rawset(_G, "GetRealmName", function()
			return "ClassicBetaPvE"
		end)
	end

	for _, game in ipairs({ "retail", "forever" }) do
		it("loads the shipped TOC and syncs, filters, shares and completes quests on " .. game, function()
			local interface
			for line in io.lines("QuestWithFriends.toc") do
				local versions = line:match("^##%s*Interface:%s*(.+)")
				if versions then
					for value in versions:gmatch("%d+") do
						local number = tonumber(value)
						local isForever = number >= 16000 and number < 20000
						if isForever == (game == "forever") then
							assert.is_nil(interface)
							interface = number
						end
					end
				end
			end
			assert.is_number(interface)
			rawset(_G, "GetBuildInfo", function()
				return "", "", "", interface
			end)
			local sender = "Julia-Realm"
			if game == "forever" then
				foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
				sender = "Florace Bastille"
			end
			local mockPanel = QuestWithFriends.Panel
			_G.QuestWithFriends = nil
			for _, file in ipairs(dofile("tests/support/manifest.lua")("QuestWithFriends.toc")) do
				assert(loadfile(file))()
			end
			QuestWithFriends.Panel = mockPanel
			assert.are.equal(game, QuestWithFriends.QuestEquivalencesGame)
			entries = { { questID = 42, title = "Errand" } }
			objectives[42] = { { text = "Gnolls slain: 3/8", numFulfilled = 3, numRequired = 8 } }
			questMaps[42] = 101
			pushable[42] = true
			fire("PLAYER_ENTERING_WORLD")
			flush()
			assert.are.equal("1.1:H", messages[1])
			local function receiveQuests(quests, serial)
				fire(
					"CHAT_MSG_ADDON",
					"QWF",
					"1.1:D:" .. serial .. ":1:1:" .. QuestWithFriends.Core.encode(quests),
					"PARTY",
					sender
				)
			end
			receiveQuests({}, 1)
			assert.is_true(view.complete)
			assert.are.equal(42, view.groups[1].shareQuestID)
			view.share(42)
			assert.same({ 1 }, pushed)
			assert.are.equal(42, view.presentation.getAbandonQuestID(42))
			assert.same({}, abandonRequests)
			view.presentation.onAbandon(42)
			assert.same({ 42 }, abandonRequests)
			receiveQuests({
				[42] = {
					title = "Errand",
					state = "active",
					mapID = 101,
					objectives = { { text = "Gnolls slain", have = 8, need = 8 } },
				},
			}, 2)
			assert.are.equal("objective", view.groups[1].differences[1].reason)
			assert.are.equal(3, view.groups[1].differences[1].objective.have)
			receiveQuests({
				[42] = { title = "Errand", state = "completed", mapID = 101, objectives = {} },
			}, 3)
			assert.are.equal(3, view.groups[1].differences[1].objective.have)
			assert.are.equal("completed", view.groups[1].differences[2].reason)
			receiveQuests({
				[42] = {
					title = "Errand",
					state = "active",
					mapID = 101,
					objectives = { { text = "Gnolls slain", have = 8, need = 8 } },
				},
			}, 4)
			currentMap = 202
			fire("ZONE_CHANGED_NEW_AREA")
			assert.same({}, view.groups)
			view.toggle()
			assert.are.equal(1, #view.groups)
			receiveQuests({
				[42] = {
					title = "Errand",
					state = "active",
					mapID = 101,
					objectives = { { text = "Gnolls slain", have = 3, need = 8 } },
				},
			}, 5)
			objectives[42][1].numFulfilled = 8
			C_QuestLog.IsComplete = function()
				return true
			end
			fire("QUEST_LOG_UPDATE")
			flush()
			assert.are.equal("ready", view.groups[1].differences[1].reason)
			assert.are.equal(3, view.groups[1].differences[2].objective.have)
			entries, objectives = {}, {}
			fire("QUEST_TURNED_IN", 42)
			flush()
			assert.are.equal("completed", view.groups[1].differences[1].reason)
			assert.are.equal(3, view.groups[1].differences[2].objective.have)
			fire("QUEST_ACCEPTED", 42)
			fire("QUEST_REMOVED", 42)
			flush()
			assert.are.equal("missing", view.groups[1].differences[1].reason)
		end)
	end

	it("resolves the real local variant for abandonment even when sharing is unavailable", function()
		entries = { { questID = 71002, title = "Local variant" } }
		questMaps[71002] = 101
		fire("PLAYER_ENTERING_WORLD")
		flush()
		receiveSnapshot({}, 1)
		assert.are.equal(71001, view.groups[1].questID)
		assert.are.equal(71002, view.presentation.getAbandonQuestID(71001))
		assert.is_false(C_QuestLog.IsPushableQuest(71002))
		view.presentation.onAbandon(71002)
		assert.same({ 71002 }, abandonRequests)
	end)

	it("rejects non-abandonable, disabled, hidden, internal and friends-only quests", function()
		entries = { { questID = 42, title = "Errand" } }
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local actions = view.presentation
		assert.are.equal(42, actions.getAbandonQuestID(42))
		assert.is_nil(actions.getAbandonQuestID(99))
		actions.onAbandon(99)
		---@type table<string, any>
		local entry = entries[1]
		for _, flag in ipairs({ "isHidden", "isInternalOnly", "isHeader" }) do
			entry[flag] = true
			assert.is_nil(actions.getAbandonQuestID(42))
			actions.onAbandon(42)
			entry[flag] = nil
		end
		abandonable[42] = false
		assert.is_nil(actions.getAbandonQuestID(42))
		actions.onAbandon(42)
		abandonable[42], disabledQuests[42] = true, true
		assert.is_nil(actions.getAbandonQuestID(42))
		actions.onAbandon(42)
		disabledQuests[42] = nil
		_G.QuestMapQuestOptions_AbandonQuest = nil
		assert.is_nil(actions.getAbandonQuestID(42))
		actions.onAbandon(42)
		assert.same({}, abandonRequests)
	end)

	it("revalidates a captured exact ID rather than abandoning a replacement variant", function()
		entries = { { questID = 71002, title = "Local variant" } }
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local actions = view.presentation
		local id = actions.getAbandonQuestID(71001)
		assert.are.equal(71002, id)
		entries = { { questID = 71001, title = "Replacement variant" } }
		actions.onAbandon(id)
		assert.same({}, abandonRequests)
		assert.are.equal(71001, actions.getAbandonQuestID(71001))
		-- A stale log index must never identify a different quest.
		C_QuestLog.GetLogIndexForQuestID = function()
			return 1
		end
		actions.onAbandon(id)
		assert.same({}, abandonRequests)
	end)

	it("rejects retained live actions after leaving the party or entering preview", function()
		entries = { { questID = 42, title = "Errand" } }
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local actions = view.presentation
		party = false
		actions.onAbandon(42)
		assert.is_nil(actions.getAbandonQuestID(42))
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		assert.is_nil(view.presentation.onAbandon)
		assert.is_nil(view.presentation.getAbandonQuestID)
		actions.onAbandon(42)
		assert.same({}, abandonRequests)
	end)

	it("refreshes and synchronizes the quest log after abandonment", function()
		entries = { { questID = 42, title = "Errand" } }
		questMaps[42] = 101
		fire("PLAYER_ENTERING_WORLD")
		flush()
		receiveSnapshot({ [42] = { title = "Errand", state = "active", mapID = 101, objectives = {} } }, 1)
		local actions = view.presentation
		actions.onAbandon(42)
		-- The native helper only opens confirmation; nothing changes until the game removes the quest.
		assert.are.equal(42, entries[1].questID)
		entries = {}
		fire("QUEST_REMOVED", 42)
		flush()
		assert.are.equal("missing", view.groups[1].differences[1].reason)
		assert.are.equal("You", view.groups[1].differences[1].player)
		assert.is_nil(view.presentation.getAbandonQuestID(42))
	end)

	for _, game in ipairs({ "retail", "forever" }) do
		it("previews plausible data solo with working filters and no network traffic on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			party = false
			fire("PLAYER_ENTERING_WORLD")
			SlashCmdList.QUESTWITHFRIENDS(" PREVIEW ON ")
			assert.is_true(view.presentation.preview)
			assert.are.equal(4, #view.groups)
			assert.is_true(view.complete)
			assert.same({}, view.notices)
			assert.is_falsy(view.share)
			local reasons = {}
			for _, group in ipairs(view.groups) do
				assert.is_true(group.questID < 0)
				for _, difference in ipairs(group.differences) do
					reasons[difference.reason] = true
				end
			end
			assert.same({ missing = true, objective = true, ready = true, completed = true }, reasons)
			view.toggle()
			assert.are.equal(5, #view.groups)
			view.filters.toggleProfessions()
			assert.are.equal(6, #view.groups)
			view.filters.toggleClasses()
			assert.are.equal(7, #view.groups)
			currentMap = 202
			fire("ZONE_CHANGED_NEW_AREA")
			fire("QUEST_LOG_UPDATE")
			SlashCmdList.QUESTWITHFRIENDS("")
			assert.is_true(view.presentation.preview)
			assert.are.equal(7, #view.groups)
			flush()
			assert.same({}, messages)
			assert.same({}, pushed)
			view.presentation.onStop()
			assert.is_true(view.hidden)
			SlashCmdList.QUESTWITHFRIENDS("preview")
			assert.is_true(view.presentation.preview)
			SlashCmdList.QUESTWITHFRIENDS("preview")
			assert.is_true(view.hidden)
		end)
	end

	for _, game in ipairs({ "retail", "forever" }) do
		it("renders screenshot scenarios safely on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			party = false
			QuestWithFriends.isDevelopment = true
			assert(loadfile("dev/Development.lua"))()
			local settings = captureSettings()
			assert(loadfile("src/QuestWithFriends.lua"))()
			fire("PLAYER_ENTERING_WORLD")
			SlashCmdList.QUESTWITHFRIENDS(" SCREENSHOT ON ")
			assert.is_true(view.hidden)
			settings.shown = true
			settings.buttons["Quest differences"].click()
			assert.is_false(settings.shown)
			assert.is_true(view.presentation.preview)
			assert.is_true(view.presentation.screenshot)
			assert.is_nil(view.presentation.onStop)
			assert.is_falsy(view.share)
			assert.are.equal(4, #view.groups)
			view.toggle()
			view.filters.toggleProfessions()
			view.filters.toggleClasses()
			assert.are.equal(7, #view.groups)
			settings.buttons["Collapsed headings"].click()
			assert.are.equal("collapsed", view.presentation.scenario)
			for _, group in ipairs(view.groups) do
				assert.is_true(view.presentation.collapsedQuests[group.questID])
			end
			settings.buttons["Party in sync"].click()
			assert.are.equal("synced", view.presentation.scenario)
			assert.same({}, view.groups)
			assert.is_true(view.complete)
			view.toggle()
			fire("QUEST_LOG_UPDATE")
			SlashCmdList.QUESTWITHFRIENDS("")
			assert.same({}, view.groups)
			flush()
			assert.same({}, messages)
			assert.same({}, pushed)
			settings.buttons["Quest differences"].click()
			assert.same({}, view.presentation.collapsedQuests)
			settings.buttons["Screenshot view"].click()
			assert.is_true(view.hidden)
			assert.is_false(settings.buttons["Screenshot view"]:EvaluateModifyPredicates())
		end)
	end

	it("ends screenshot mode on joining a party and never sends samples", function()
		party = false
		QuestWithFriends.isDevelopment = true
		assert(loadfile("dev/Development.lua"))()
		local settings = captureSettings()
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		settings.buttons["Quest differences"].click()
		entries = { { questID = 42, title = "Actual errand" } }
		party = true
		fire("GROUP_ROSTER_UPDATE")
		assert.is_false(view.presentation.preview)
		assert.is_false(view.presentation.screenshot)
		flush()
		local snapshots = 0
		for _, message in ipairs(messages) do
			local payload = message:match("^1%.1:D:%d+:%d+:%d+:(.+)$")
			if payload then
				snapshots = snapshots + 1
				assert.same(
					{ [42] = { title = "Actual errand", state = "active", objectives = {} } },
					QuestWithFriends.Core.decode(payload)
				)
			end
		end
		assert.is_true(snapshots > 0)
		settings.shown = true
		for _, name in ipairs({ "Quest differences", "Collapsed headings", "Party in sync" }) do
			assert.is_false(settings.buttons[name]:EvaluateModifyPredicates())
			settings.buttons[name].click()
			assert.is_false(view.presentation.screenshot)
			assert.is_true(settings.shown)
		end
		party = false
		fire("GROUP_ROSTER_UPDATE")
		assert.is_true(view.hidden)
	end)

	it("ends screenshot mode on joining a raid or reloading", function()
		party = false
		QuestWithFriends.isDevelopment = true
		assert(loadfile("dev/Development.lua"))()
		local settings = captureSettings()
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		settings.buttons["Quest differences"].click()
		party = true
		_G.IsInRaid = function()
			return true
		end
		fire("GROUP_ROSTER_UPDATE")
		assert.is_true(view.hidden)
		settings.buttons["Party in sync"].click()
		assert.is_true(view.hidden)
		party = false
		fire("GROUP_ROSTER_UPDATE")
		assert.is_true(view.hidden)
		settings.buttons["Collapsed headings"].click()
		assert.is_true(view.presentation.collapsedQuests[-1])
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		assert.is_true(view.hidden)
		assert.is_nil(QuestWithFriendsDB.screenshotMode)
		assert.is_false(settings.header:ShouldShow())
		settings.buttons["Quest differences"].click()
		assert.same({}, view.presentation.collapsedQuests)
		flush()
		assert.same({}, messages)
	end)

	it("ends preview on joining a party and sends only the real quest log", function()
		party = false
		fire("PLAYER_ENTERING_WORLD")
		SlashCmdList.QUESTWITHFRIENDS("preview")
		entries = { { questID = 42, title = "Actual errand" } }
		party = true
		fire("GROUP_ROSTER_UPDATE")
		assert.is_false(view.presentation.preview)
		assert.same({ { player = "Julia", reason = "unknown" } }, view.notices)
		flush()
		local payload
		for _, message in ipairs(messages) do
			payload = message:match("^1%.1:D:%d+:%d+:%d+:(.+)$") or payload
		end
		local snapshot = QuestWithFriends.Core.decode(payload)
		assert.are.equal("Actual errand", snapshot[42].title)
		assert.is_nil(next(snapshot, 42))
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		assert.is_false(view.presentation.preview)
		party = false
		fire("GROUP_ROSTER_UPDATE")
		assert.is_true(view.hidden)
	end)

	it("ends preview on joining a raid and does not resume when leaving", function()
		party = false
		fire("PLAYER_ENTERING_WORLD")
		SlashCmdList.QUESTWITHFRIENDS("preview")
		party = true
		_G.IsInRaid = function()
			return true
		end
		fire("GROUP_ROSTER_UPDATE")
		assert.is_true(view.hidden)
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		assert.is_true(view.hidden)
		party = false
		fire("GROUP_ROSTER_UPDATE")
		assert.is_true(view.hidden)
		flush()
		assert.same({}, messages)
	end)

	it("does not restore preview or its sample collapse choices after reload", function()
		party = false
		fire("PLAYER_ENTERING_WORLD")
		SlashCmdList.QUESTWITHFRIENDS("preview")
		view.presentation.collapsedQuests[-1] = true
		SlashCmdList.QUESTWITHFRIENDS("preview off")
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		assert.same({}, view.presentation.collapsedQuests)
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		assert.is_true(view.hidden)
		assert.is_nil(QuestWithFriendsDB.previewMode)
	end)

	it("handshakes, reassembles out-of-order chunks and ignores duplicates", function()
		fire("PLAYER_ENTERING_WORLD")
		assert.is_false(view.complete)
		flush()
		assert.are.equal("1.1:H", messages[1])
		local payload = QuestWithFriends.Core.encode({
			[7] = {
				title = "Remote",
				state = "active",
				objectives = {},
			},
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:2:2:" .. payload:sub(7), "PARTY", "Julia-Realm")
		assert.is_false(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:2:" .. payload:sub(1, 6), "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		assert.are.equal("Remote", view.groups[1].title)
		assert.same({ { player = "You", kind = "missing", reason = "missing" } }, view.groups[1].differences)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:bad", "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "PARTY", "Julia-Realm")
		assert.is_false(view.complete)
	end)

	it("matches a remote class variant without replacing the actual snapshot ID", function()
		entries = { { questID = 71002, title = "Branch quest" } }
		_G.C_QuestLog.IsQuestFlaggedCompleted = function(id)
			return id == 71001
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local data
		for _, message in ipairs(messages) do
			data = message:match("^1%.1:D:%d+:%d+:%d+:(.+)$") or data
		end
		local quests = QuestWithFriends.Core.decode(data)
		assert.is_not_nil(quests[71002])
		assert.is_nil(quests[71001])
		local payload = QuestWithFriends.Core.encode({
			[71001] = { title = "Branch quest", state = "active", objectives = {} },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		assert.same({}, view.groups)
	end)

	it("checks completion history for equivalent local IDs", function()
		_G.C_QuestLog.IsQuestFlaggedCompleted = function(id)
			return id == 71002
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({
			[71003] = { title = "Branch quest", state = "active", objectives = {} },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.same({
			{ player = "You", kind = "ahead", reason = "completed" },
			{ player = "Julia", kind = "needs", reason = "active" },
		}, view.groups[1].differences)
	end)

	it("uses shipped counted and transition families for completion-history checks", function()
		assert(loadfile("src/QuestEquivalences.lua"))()
		local checked = {}
		_G.C_QuestLog.IsQuestFlaggedCompleted = function(id)
			checked[id] = true
			return id == 28762 or id == 28784
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({
			[28757] = { title = "Beating Them Back!", state = "active", objectives = {} },
			[28780] = { title = "Join the Battle!", state = "active", objectives = {} },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.are.equal(2, #view.groups)
		assert.is_true(checked[28762])
		assert.is_true(checked[28784])
		for _, group in ipairs(view.groups) do
			assert.same({
				{ player = "You", kind = "ahead", reason = "completed" },
				{ player = "Julia", kind = "needs", reason = "active" },
			}, group.differences)
			assert.is_nil(group.shareQuestID)
		end
	end)

	it("never sends hidden, internal-only or header entries as party quests", function()
		entries = {
			{ questID = 0, title = "Zone", isHeader = true },
			{ questID = 77734, title = "Level 17", isHidden = true },
			{ questID = 77735, title = "Level 18", isInternalOnly = true },
			{ questID = 42, title = "Gryphons of a Feather" },
		}
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local data
		for _, message in ipairs(messages) do
			data = message:match("^1%.1:D:%d+:%d+:%d+:(.+)$") or data
		end
		local quests = QuestWithFriends.Core.decode(data)
		assert.is_nil(quests[77734])
		assert.is_nil(quests[77735])
		assert.is_nil(quests[0])
		assert.are.equal("Gryphons of a Feather", quests[42].title)
	end)

	local function captureLogs(filterLevels)
		local records = {}
		local levels = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5 }
		_G.AddonKit = {
			Registry = { addons = {} },
			RegisterAddon = function(name, options)
				AddonKit.Registry.addons[name] = options
			end,
			SetLogLevel = function(name, level)
				assert.are.equal("QuestWithFriends", name)
				AddonKit.Registry.addons[name].logLevel = level
			end,
			Log = function(name, level, category, message, data)
				if filterLevels and levels[level] < levels[AddonKit.Registry.addons[name].logLevel] then
					return
				end
				records[#records + 1] = { level = level, category = category, message = message, data = data }
			end,
		}
		return records
	end

	local function findLog(records, message)
		for _, record in ipairs(records) do
			if record.message == message then
				return record
			end
		end
	end

	local function uiRecords(records, message)
		local found = {}
		for _, record in ipairs(records) do
			if record.category == "ui" and record.message == message then
				assert.are.equal("DEBUG", record.level)
				found[#found + 1] = record.data
			end
		end
		return found
	end

	local function stockRecords(records, message)
		local found = {}
		for _, record in ipairs(records) do
			if record.category == "item_stock" and (not message or record.message == message) then
				assert.are.equal("DEBUG", record.level)
				found[#found + 1] = record.data
			end
		end
		return found
	end

	it("logs deduplicated scan and submitted stock evidence only in Debug mode", function()
		local records = captureLogs()
		assert(loadfile("src/QuestWithFriends.lua"))()
		entries = { { questID = 42, title = "Cloth Delivery" } }
		objectives[42] = { { text = "Linen Cloth: 10/10", type = "item", numFulfilled = 10, numRequired = 10 } }
		carriedCloth(12)
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.same({}, stockRecords(records))
		SlashCmdList.QUESTWITHFRIENDS("debug on")
		flush()
		local scans = stockRecords(records, "Quest objective scan changed")
		assert.are.equal(1, #scans)
		assert.are.equal(42, scans[1].questID)
		assert.are.equal(1, scans[1].objectiveIndex)
		assert.are.equal("Linen Cloth: 10/10", scans[1].rawText)
		assert.are.equal("Linen Cloth", scans[1].text)
		assert.are.equal("item", scans[1].objectiveType)
		assert.are.equal("matched", scans[1].result)
		assert.are.equal(2, scans[1].spare)
		local submitted = stockRecords(records, "Submitted objective stock changed")
		assert.are.equal(1, #submitted)
		assert.are.equal("identified", submitted[1].result)
		assert.are.equal(2589, submitted[1].itemID)
		assert.are.equal(2, submitted[1].spare)
		assert.are.equal("1.1", submitted[1].protocol)
		assert.is_number(submitted[1].revision)
		fire("BAG_UPDATE_DELAYED")
		flush()
		assert.are.equal(1, #stockRecords(records, "Quest objective scan changed"))
		assert.are.equal(1, #stockRecords(records, "Submitted objective stock changed"))
		carriedCloth(15)
		fire("BAG_UPDATE_DELAYED")
		flush()
		scans = stockRecords(records, "Quest objective scan changed")
		assert.are.equal(2, #scans)
		assert.are.equal(5, scans[2].spare)
		assert.are.equal("BAG_UPDATE_DELAYED", scans[2].trigger)
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		carriedCloth(18)
		fire("BAG_UPDATE_DELAYED")
		flush()
		assert.are.equal(2, #stockRecords(records, "Quest objective scan changed"))
		SlashCmdList.QUESTWITHFRIENDS("debug on")
		flush()
		scans = stockRecords(records, "Quest objective scan changed")
		assert.are.equal(3, #scans)
		assert.are.equal(8, scans[3].spare)
		entries, objectives = {}, {}
		fire("QUEST_REMOVED", 42)
		flush()
		scans = stockRecords(records, "Quest objective scan changed")
		assert.are.equal("removed", scans[#scans].result)
	end)

	it("logs unsupported types and fresh completed stock instead of stale pre-turn-in counts", function()
		local records = captureLogs()
		QuestWithFriendsDB.debugMode = true
		assert(loadfile("src/QuestWithFriends.lua"))()
		entries = { { questID = 42, title = "Cloth Delivery" } }
		objectives[42] = { { text = "Linen Cloth: 10/10", type = "monster", numFulfilled = 10, numRequired = 10 } }
		carriedCloth(12)
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local scans = stockRecords(records, "Quest objective scan changed")
		assert.are.equal("not_item_objective", scans[1].result)
		assert.are.equal("monster", scans[1].objectiveType)
		objectives[42][1].type = "item"
		fire("QUEST_LOG_UPDATE")
		flush()
		carriedCloth(2)
		entries, objectives = {}, {}
		fire("QUEST_TURNED_IN", 42)
		flush()
		scans = stockRecords(records, "Quest objective scan changed")
		local last = scans[#scans]
		assert.are.equal("completed", last.state)
		assert.are.equal("matched", last.result)
		assert.are.equal(2589, last.retainedItemID)
		assert.are.equal(2, last.total)
		assert.are.equal(0, last.reserved)
		assert.are.equal(2, last.spare)
	end)

	it("records peer metadata replacement without repeating unchanged snapshots", function()
		local records = captureLogs()
		QuestWithFriendsDB.debugMode = true
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local peer = {
			[42] = {
				title = "Cloth Delivery",
				state = "ready",
				objectives = { { text = "Linen Cloth", have = 10, need = 10, itemID = 2589, spare = 2 } },
			},
		}
		receiveSnapshot(peer, 1)
		receiveSnapshot(peer, 2)
		local stock = stockRecords(records, "Peer objective stock changed")
		assert.are.equal(1, #stock)
		assert.are.equal("Julia-Realm", stock[1].sender)
		assert.are.equal("identified", stock[1].result)
		assert.are.equal(2, stock[1].spare)
		peer[42].objectives[1].itemID, peer[42].objectives[1].spare = nil, nil
		receiveSnapshot(peer, 3)
		stock = stockRecords(records, "Peer objective stock changed")
		assert.are.equal(2, #stock)
		assert.are.equal("no_stock_metadata", stock[2].result)
		assert.is_nil(stock[2].itemID)
		peer[42].objectives = {}
		receiveSnapshot(peer, 4)
		stock = stockRecords(records, "Peer objective stock changed")
		local results = {}
		for _, data in ipairs(stock) do
			results[data.result] = true
		end
		assert.is_true(results.no_objectives)
		assert.is_true(results.removed)
	end)

	it("explains zone, profession, class and comparison omissions", function()
		local records = captureLogs()
		QuestWithFriendsDB.debugMode = true
		assert(loadfile("src/QuestWithFriends.lua"))()
		entries = { { questID = 42, title = "Cloth Delivery" } }
		questMaps[42] = 202
		objectives[42] = { { text = "Linen Cloth: 3/10", type = "item", numFulfilled = 3, numRequired = 10 } }
		fire("PLAYER_ENTERING_WORLD")
		flush()
		receiveSnapshot({ [42] = { title = "Cloth Delivery", state = "completed", objectives = {} } }, 1)
		local function result()
			local selections = stockRecords(records, "Quest comparison selection changed")
			return selections[#selections].result
		end
		assert.are.equal("zone_filter", result())
		view.toggle()
		assert.are.equal("included", result())
		tags[42] = { worldQuestType = 1 }
		fire("QUEST_LOG_UPDATE")
		flush()
		assert.are.equal("profession_filter", result())
		view.filters.toggleProfessions()
		assert.are.equal("included", result())
		tags[42], questTypes[42] = nil, 21
		fire("QUEST_LOG_UPDATE")
		flush()
		assert.are.equal("class_filter", result())
		view.filters.toggleClasses()
		assert.are.equal("included", result())
		receiveSnapshot({
			[42] = {
				title = "Cloth Delivery",
				state = "active",
				objectives = { { text = "Linen Cloth", have = 3, need = 10 } },
			},
		}, 2)
		assert.are.equal("no_difference", result())
	end)

	it("deduplicates panel row evidence and records collapse, removal and sample modes", function()
		local records = captureLogs()
		QuestWithFriendsDB.debugMode = true
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local function report(result)
			view.presentation.onObjectiveRows({
				{
					questID = 42,
					rowIndex = 1,
					player = "You",
					result = result,
					text = "You: Linen Cloth 10/10 · 2 spare",
					have = 10,
					need = 10,
					spare = 2,
				},
			})
		end
		report("rendered")
		report("rendered")
		assert.are.equal(1, #stockRecords(records, "Objective row changed"))
		report("quest_collapsed")
		local rows = stockRecords(records, "Objective row changed")
		assert.are.equal(2, #rows)
		assert.are.equal("quest_collapsed", rows[2].result)
		party = false
		fire("GROUP_ROSTER_UPDATE")
		rows = stockRecords(records, "Objective row changed")
		assert.are.equal("removed", rows[3].result)
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		report("rendered")
		rows = stockRecords(records, "Objective row changed")
		assert.are.equal("preview", rows[4].mode)
	end)

	it("gates UI diagnostics behind Debug mode and resets the baseline when re-enabled", function()
		local records = captureLogs()
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.is_nil(findLog(records, "Panel visibility changed"))
		assert.is_nil(findLog(records, "Panel status changed"))
		assert.is_nil(findLog(records, "Displayed sync status changed"))
		SlashCmdList.QUESTWITHFRIENDS("debug on")
		assert.are.equal(1, #uiRecords(records, "Panel visibility changed"))
		assert.are.equal(1, #uiRecords(records, "Panel status changed"))
		assert.are.equal(1, #uiRecords(records, "Displayed sync status changed"))
		SlashCmdList.QUESTWITHFRIENDS("debug on")
		assert.are.equal(1, #uiRecords(records, "Panel status changed"))
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		local payload = QuestWithFriends.Core.encode({})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		party = false
		fire("GROUP_ROSTER_UPDATE")
		assert.are.equal(1, #uiRecords(records, "Panel visibility changed"))
		assert.are.equal(1, #uiRecords(records, "Panel status changed"))
		assert.are.equal(1, #uiRecords(records, "Displayed sync status changed"))
		party = true
		SlashCmdList.QUESTWITHFRIENDS("debug on")
		local baseline = uiRecords(records, "Panel status changed")[2]
		assert.are.equal("unobserved", baseline.previous)
		assert.is_nil(baseline.duration)
		assert.are.equal("not_displayed", uiRecords(records, "Displayed sync status changed")[2].previous)
	end)

	it("logs overall displayed status at DEBUG with filter and event triggers, without a clock", function()
		local records = captureLogs(true)
		_G.QuestWithFriendsDB = { debugMode = true }
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		entries = { { questID = 42, title = "Errand" } }
		questMaps[42] = 202
		fire("QUEST_LOG_UPDATE")
		flush()
		view.toggle()
		view.toggle()
		currentMap = 202
		fire("ZONE_CHANGED_NEW_AREA")
		entries = {}
		fire("QUEST_REMOVED", 42)
		flush()
		local statuses = uiRecords(records, "Panel status changed")
		local values = {}
		for _, data in ipairs(statuses) do
			assert.is_nil(data.uptime)
			assert.is_nil(data.duration)
			values[#values + 1] = data.status
		end
		assert.same({ "incomplete", "in_sync", "out_of_sync", "in_sync", "out_of_sync", "in_sync" }, values)
		assert.are.equal("zone_filter_changed", statuses[3].trigger)
		assert.is_false(statuses[3].zoneFilter)
		assert.are.equal("ZONE_CHANGED_NEW_AREA", statuses[5].trigger)
		assert.are.equal("QUEST_REMOVED", statuses[6].trigger)
		assert.are.equal(1, #uiRecords(records, "Panel visibility changed"))
		assert.are.equal(2, #uiRecords(records, "Displayed sync status changed"))
		for _ = 1, 5 do
			fire("QUEST_LOG_UPDATE")
		end
		flush()
		assert.are.equal(6, #uiRecords(records, "Panel status changed"))
		SlashCmdList.QUESTWITHFRIENDS("")
		local refreshing = uiRecords(records, "Displayed sync status changed")[3]
		assert.are.equal("refreshing", refreshing.status)
		assert.are.equal("manual_refresh", refreshing.trigger)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:2:1:1:" .. payload, "PARTY", "Julia-Realm")
		local recovered = uiRecords(records, "Displayed sync status changed")[4]
		assert.are.equal("healthy", recovered.status)
		assert.is_nil(recovered.snapshotAge)
		assert.is_nil(recovered.recoveryDuration)
	end)

	it("logs local oversized status and recovery even while overall status remains incomplete", function()
		local records = captureLogs(true)
		_G.QuestWithFriendsDB = { debugMode = true }
		assert(loadfile("src/QuestWithFriends.lua"))()
		for id = 1, 100 do
			entries[id] = { questID = id, title = string.rep("x", 280) }
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		fire("QUEST_LOG_UPDATE")
		flush()
		entries = {}
		fire("QUEST_LOG_UPDATE")
		flush()
		local states = uiRecords(records, "Displayed sync status changed")
		assert.are.equal(3, #states)
		assert.are.equal("Adam-Realm", states[2].sender)
		assert.are.equal("You", states[2].player)
		assert.are.equal("oversized", states[2].status)
		assert.are.equal("local_snapshot_oversized", states[2].trigger)
		assert.are.equal("oversized", states[3].previous)
		assert.are.equal("healthy", states[3].status)
		assert.are.equal("local_snapshot_ready", states[3].trigger)
		assert.are.equal(1, #uiRecords(records, "Panel status changed"))
	end)

	it("separates preview and screenshot presentation from live sync diagnostics", function()
		party = false
		QuestWithFriends.isDevelopment = true
		assert(loadfile("dev/Development.lua"))()
		local settings = captureSettings()
		local records = captureLogs(true)
		_G.QuestWithFriendsDB = { debugMode = true }
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		SlashCmdList.QUESTWITHFRIENDS("")
		settings.buttons["Quest differences"].click()
		settings.buttons["Collapsed headings"].click()
		settings.buttons["Party in sync"].click()
		local statuses = uiRecords(records, "Panel status changed")
		assert.are.equal(5, #statuses)
		assert.are.equal("hidden", statuses[1].mode)
		assert.are.equal("preview", statuses[2].status)
		assert.are.equal("screenshot", statuses[3].mode)
		assert.are.equal("differences", statuses[3].scenario)
		assert.are.equal("collapsed", statuses[4].scenario)
		assert.are.equal("in_sync", statuses[5].status)
		assert.are.equal(0, #uiRecords(records, "Displayed sync status changed"))
		party = true
		fire("GROUP_ROSTER_UPDATE")
		local live = uiRecords(records, "Displayed sync status changed")[1]
		assert.are.equal("live", live.mode)
		assert.are.equal("unknown", live.status)
		assert.are.equal("GROUP_ROSTER_UPDATE", live.trigger)
	end)

	it("matches Forever First Last senders, retains surnames and ignores self echoes", function()
		QuestWithFriends.QuestEquivalencesGame = "forever"
		foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
		local records = captureLogs()
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local status = findLog(records, "Party sync status").data
		assert.are.equal("Carola Goodspeed", status.player)
		assert.same({ { key = "Florace Bastille", name = "Florace Bastille" } }, status.members)
		assert.same({ { player = "Florace Bastille", reason = "unknown" } }, view.notices)
		local sent = #messages
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "PARTY", "Carola Goodspeed")
		assert.are.equal("self message", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal(0, #timers)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "PARTY", "Florace Bastille")
		assert.are.equal("Florace Bastille", findLog(records, "Received snapshot request").data.sender)
		flush()
		assert.are.equal(sent + 1, #messages)
		local payload = QuestWithFriends.Core.encode({ [42] = { title = "Errand", state = "active", objectives = {} } })
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Florace Bastille")
		assert.is_true(view.complete)
		assert.are.equal("Florace Bastille", findLog(records, "Received quest snapshot").data.sender)
		assert.are.equal("Errand", view.groups[1].title)
		assert.same({}, view.notices)
	end)

	it("keeps Forever members with the same first name distinct and rejects abbreviated senders", function()
		QuestWithFriends.QuestEquivalencesGame = "forever"
		foreverNames({
			player = { "Carola", "Goodspeed" },
			party1 = { "Florace", "Bastille" },
			party2 = { "Florace", "Other" },
		})
		local records = captureLogs()
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		for _, sender in ipairs({ "Florace", "Florace Stranger", "Stranger Bastille" }) do
			fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", sender)
		end
		assert.are.equal("sender not in roster", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal(2, #view.notices)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Florace Bastille")
		assert.same({ { player = "Florace Other", reason = "unknown" } }, view.notices)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Florace Other")
		assert.is_true(view.complete)
	end)

	it("handles Forever missing surnames, already joined names, and hyphenated surnames", function()
		QuestWithFriends.QuestEquivalencesGame = "forever"
		foreverNames({
			player = { "Carola", "Goodspeed" },
			party1 = { "Florace Bastille", "Bastille" },
			party2 = { "Zachori", "" },
			party3 = { "Marva", "Less-Wand" },
		})
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		for _, sender in ipairs({ "Florace Bastille", "Zachori", "Marva Less-Wand" }) do
			fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", sender)
		end
		assert.is_true(view.complete)
	end)

	it("uses Forever's configured surname separator", function()
		QuestWithFriends.QuestEquivalencesGame = "forever"
		_G.Constants = { CharacterNameSeparatorConsts = { CHARACTERNAME_SURNAME_SEPARATOR = "·" } }
		foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Florace·Bastille")
		assert.is_true(view.complete)
	end)

	it("retains Retail realm normalization and same-realm unqualified senders", function()
		rawset(_G, "UnitFullName", function(unit)
			return unit == "player" and "Adam" or "Julia", "Test Realm"
		end)
		rawset(_G, "GetRealmName", function()
			return "Test Realm"
		end)
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia")
		assert.is_true(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "PARTY", "Julia-TestRealm")
		assert.is_false(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-TestRealm")
		assert.is_true(view.complete)
	end)

	it("registers with AddonKit and logs hidden quest counts", function()
		local records = captureLogs()
		assert(loadfile("src/QuestWithFriends.lua"))()
		entries = { { questID = 77734, title = "Level 17", isHidden = true } }
		fire("PLAYER_ENTERING_WORLD")
		assert.is_true(AddonKit.Registry.addons.QuestWithFriends.persistDiagnostics)
		assert.same({ visible = 0, hiddenOrInternal = 1 }, findLog(records, "Quest log scanned").data)
	end)

	captureSettings = function()
		local captured = { settings = {}, buttons = {}, initializers = {}, repairs = 0, hides = 0 }
		captured.layout = {
			AddInitializer = function(_, initializer)
				captured.initializers[#captured.initializers + 1] = initializer
			end,
		}
		local function initializer(name, tooltip)
			local result = { name = name, tooltip = tooltip, shownPredicates = {}, modifyPredicates = {} }
			function result:AddShownPredicate(predicate)
				self.shownPredicates[#self.shownPredicates + 1] = predicate
			end
			function result:AddModifyPredicate(predicate)
				self.modifyPredicates[#self.modifyPredicates + 1] = predicate
			end
			function result:ShouldShow()
				for _, predicate in ipairs(self.shownPredicates) do
					if not predicate() then
						return false
					end
				end
				return true
			end
			function result:EvaluateModifyPredicates()
				for _, predicate in ipairs(self.modifyPredicates) do
					if not predicate() then
						return false
					end
				end
				return true
			end
			return result
		end
		_G.CreateSettingsListSectionHeaderInitializer = function(name, tooltip)
			captured.header = initializer(name, tooltip)
			return captured.header
		end
		_G.CreateSettingsButtonInitializer = function(name, text, click, tooltip, searchTags)
			assert.is_false(searchTags)
			local button = initializer(name, tooltip)
			button.text, button.click = text, click
			captured.buttons[name] = button
			return button
		end
		_G.SettingsPanel = {
			IsShown = function()
				return captured.shown == true
			end,
			Hide = function()
				captured.shown = false
				captured.hides = captured.hides + 1
			end,
			GetCurrentLayout = function()
				return captured.currentLayout or captured.layout
			end,
			GetSettingsList = function()
				return {
					RepairDisplay = function(_, layout)
						assert.are.equal(captured.layout, layout)
						captured.repairs = captured.repairs + 1
					end,
				}
			end,
		}
		_G.Settings = {
			VarType = { Boolean = "boolean" },
			RegisterVerticalLayoutCategory = function(name)
				captured.category = { name = name }
				return captured.category, captured.layout
			end,
			RegisterProxySetting = function(category, variable, varType, name, default, getter, setter)
				assert.are.equal(captured.category, category)
				local record = { variable = variable, varType = varType, name = name, default = default }
				record.setting = {
					GetValue = getter,
					SetValue = function(_, value)
						setter(value)
					end,
				}
				captured.settings[variable] = record
				if variable == "QuestWithFriendsDebugMode" then
					for key, value in pairs(record) do
						captured[key] = value
					end
				end
				return record.setting
			end,
			CreateCheckbox = function(category, setting, tooltip)
				assert.are.equal(captured.category, category)
				local found = false
				for _, record in pairs(captured.settings) do
					if record.setting == setting then
						record.tooltip = tooltip
						found = true
					end
				end
				assert.is_true(found)
				if setting == captured.setting then
					captured.tooltip = tooltip
				end
			end,
			RegisterAddOnCategory = function(category)
				assert.are.equal(captured.category, category)
				captured.registered = true
			end,
		}
		return captured
	end

	it("keeps development settings, diagnostics and metadata separate while using the release protocol", function()
		local releaseDB, mockPanel = QuestWithFriendsDB, QuestWithFriends.Panel
		local settings = captureSettings()
		local logs, metadata = {}, {}
		_G.AddonKit = {
			Test = { tests = {}, assert = {} },
			RegisterAddon = function(name)
				assert.are.equal("QuestWithFriendsDev", name)
			end,
			SetLogLevel = function(name, level)
				assert.are.equal("QuestWithFriendsDev", name)
				logs.level = level
			end,
			Log = function(name, _, _, message, data)
				assert.are.equal("QuestWithFriendsDev", name)
				logs[message] = data
			end,
		}
		_G.C_AddOns = {
			GetAddOnMetadata = function(name, field)
				metadata = { name, field }
				return "0.1.7-dev"
			end,
		}
		_G.QuestWithFriends, _G.QuestWithFriendsDevDB = nil, nil
		local namespace = {}
		for _, file in ipairs({
			"src/Bootstrap.lua",
			"src/QuestEquivalences.lua",
			"src/Client.lua",
			"src/QuestCategories.lua",
			"src/Core.lua",
			"src/ItemStock.lua",
			"src/Preview.lua",
			"dev/Development.lua",
			"src/QuestWithFriends.lua",
		}) do
			assert(loadfile(file))("QuestWithFriendsDev", namespace)
		end
		namespace.Panel = mockPanel
		assert(loadfile("dev/InGameTests.lua"))("QuestWithFriendsDev", namespace)
		assert.is_function(AddonKit.Test.tests.QuestWithFriends_ProtocolRoundTrip)
		assert.are.equal("Quest With Friends (Dev)", settings.category.name)
		assert.is_not_nil(settings.buttons["Quest differences"])
		local saved = { debugMode = true, sortMode = "title", zoneFilter = false }
		_G.QuestWithFriendsDevDB = saved
		fire("ADDON_LOADED", "QuestWithFriends")
		assert.are_not.equal(saved, namespace.db)
		fire("ADDON_LOADED", "QuestWithFriendsDev")
		assert.are.equal(saved, namespace.db)
		assert.are.equal("DEBUG", logs.level)
		assert.is_true(settings.settings.QuestWithFriendsDevDebugMode.setting:GetValue())
		assert.is_nil(settings.settings.QuestWithFriendsDebugMode)
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		assert.is_false(saved.debugMode)
		assert.are.equal(releaseDB, QuestWithFriendsDB)
		assert.are.equal("smart", releaseDB.sortMode)
		entries = { { questID = 42, title = "Errand" } }
		pushable[42] = true
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.are.equal("1.1:H", messages[1])
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. namespace.Core.encode({}), "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		view.share(42)
		assert.same({ "QuestWithFriendsDev", "Version" }, metadata)
		assert.same({ 1 }, pushed)
		fire("ADDON_ACTION_BLOCKED", "QuestWithFriendsDev", "QuestLogPushQuest")
		assert.is_not_nil(logs["Quest sharing blocked"])
		_G.QuestWithFriendsDevDB = nil
	end)

	it("has no screenshot controls or in-game test registrations in the release", function()
		local settings = captureSettings()
		_G.AddonKit = { Test = { tests = {}, assert = {} } }
		assert(loadfile("dev/Development.lua"))()
		assert(loadfile("dev/InGameTests.lua"))()
		assert(loadfile("src/QuestWithFriends.lua"))()
		assert.is_nil(QuestWithFriends.Development)
		assert.same({}, AddonKit.Test.tests)
		assert.same({}, settings.initializers)
		assert.same({}, settings.buttons)
		party = false
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		assert.is_true(view.presentation.preview)
		assert.is_false(view.presentation.screenshot)
	end)

	it("registers an account-wide lock setting and routes the panel lock action through it", function()
		local settings = captureSettings()
		local locks = {}
		rawset(QuestWithFriends.Panel, "setLocked", function(locked)
			locks[#locks + 1] = locked
			QuestWithFriendsDB.panelLocked = locked ~= false
		end)
		assert(loadfile("src/QuestWithFriends.lua"))()
		local record = settings.settings.QuestWithFriendsPanelLocked
		assert.are.equal("Lock panel", record.name)
		assert.is_true(record.default)
		assert.is_true(record.setting:GetValue())
		_G.QuestWithFriendsDB = { panelLocked = false }
		fire("ADDON_LOADED", "QuestWithFriends")
		assert.is_false(record.setting:GetValue())
		fire("PLAYER_ENTERING_WORLD")
		flush()
		view.presentation.onLock(true)
		assert.same({ true }, locks)
		assert.is_true(record.setting:GetValue())
		view.presentation.onLock(false)
		assert.same({ true, false }, locks)
		assert.is_false(record.setting:GetValue())
		record.setting:SetValue(true)
		assert.same({ true, false, true }, locks)
		assert.is_true(QuestWithFriendsDB.panelLocked)
	end)

	for _, game in ipairs({ "retail", "forever" }) do
		it("restores debug logging when SavedVariables arrive after Lua files on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			local records = captureLogs(true)
			local settings = captureSettings()
			assert(loadfile("src/QuestWithFriends.lua"))()
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)

			-- WoW restores this table after executing the files listed in the TOC.
			local saved = { debugMode = true, showPersonalQuests = true, sortMode = "title", zoneFilter = false }
			_G.QuestWithFriendsDB = saved
			fire("ADDON_LOADED", "OtherAddon")
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			assert.are.equal(0, #records)
			fire("ADDON_LOADED", "QuestWithFriends")
			assert.are.equal("DEBUG", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			assert.are.equal(saved, QuestWithFriendsDB)
			assert.is_true(settings.setting:GetValue())
			assert.is_true(saved.showProfessionQuests)
			assert.is_true(saved.showClassQuests)
			assert.are.equal("title", saved.sortMode)
			assert.is_false(saved.zoneFilter)
			assert.are.equal(0, #records)

			fire("PLAYER_ENTERING_WORLD")
			flush()
			assert.is_not_nil(findLog(records, "Quest log scanned"))
			assert.is_not_nil(findLog(records, "Addon message submitted"))
			assert.is_not_nil(findLog(records, "Submitted quest snapshot"))
		end)

		it("restores disabled debug logging after SavedVariables load on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			QuestWithFriendsDB.debugMode = true
			local records = captureLogs(true)
			assert(loadfile("src/QuestWithFriends.lua"))()
			assert.are.equal("DEBUG", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			_G.QuestWithFriendsDB = { debugMode = false }
			fire("ADDON_LOADED", "QuestWithFriends")
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			fire("PLAYER_ENTERING_WORLD")
			flush()
			assert.is_not_nil(findLog(records, "Quest log scanned"))
			assert.is_nil(findLog(records, "Addon message submitted"))
			assert.is_nil(findLog(records, "Submitted quest snapshot"))
		end)

		it("registers native settings and persists debug mode on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			captureLogs()
			local settings = captureSettings()
			assert(loadfile("src/QuestWithFriends.lua"))()
			assert.is_true(settings.registered)
			assert.are.equal("Quest With Friends", settings.category.name)
			assert.are.equal("QuestWithFriendsDebugMode", settings.variable)
			assert.are.equal("boolean", settings.varType)
			assert.are.equal("Debug mode", settings.name)
			assert.is_false(settings.default)
			assert.is_false(settings.setting:GetValue())
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			assert.is_not_nil(settings.tooltip:find("Requires AddonKit", 1, true))

			settings.setting:SetValue(true)
			assert.is_true(QuestWithFriendsDB.debugMode)
			assert.are.equal("DEBUG", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			-- A new registry simulates AddonKit resetting its level on reload.
			captureLogs()
			assert(loadfile("src/QuestWithFriends.lua"))()
			assert.is_true(settings.setting:GetValue())
			assert.are.equal("DEBUG", AddonKit.Registry.addons.QuestWithFriends.logLevel)

			SlashCmdList.QUESTWITHFRIENDS(" DEBUG OFF ")
			assert.is_false(settings.setting:GetValue())
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			SlashCmdList.QUESTWITHFRIENDS("debug")
			assert.is_true(settings.setting:GetValue())
			assert.are.equal("DEBUG", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			settings.setting:SetValue(false)
			assert.is_false(QuestWithFriendsDB.debugMode)
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)
			captureLogs()
			assert(loadfile("src/QuestWithFriends.lua"))()
			assert.is_false(settings.setting:GetValue())
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)
		end)
	end

	it("exposes session-only preview in native settings and stays synchronized with slash commands", function()
		party = false
		local settings = captureSettings()
		assert(loadfile("src/QuestWithFriends.lua"))()
		local preview = settings.settings.QuestWithFriendsPreviewMode
		assert.are.equal("Preview appearance", preview.name)
		assert.is_false(preview.setting:GetValue())
		preview.setting:SetValue(true)
		assert.is_true(view.presentation.preview)
		assert.is_true(preview.setting:GetValue())
		SlashCmdList.QUESTWITHFRIENDS("preview off")
		assert.is_false(preview.setting:GetValue())
		SlashCmdList.QUESTWITHFRIENDS("preview")
		assert.is_true(preview.setting:GetValue())
		party = true
		fire("GROUP_ROSTER_UPDATE")
		assert.is_false(preview.setting:GetValue())
		assert.is_false(view.presentation.preview)
		preview.setting:SetValue(true)
		assert.is_false(preview.setting:GetValue())
	end)

	it("reveals only the screenshot tools section without starting or stopping a sample view", function()
		party = false
		QuestWithFriends.isDevelopment = true
		assert(loadfile("dev/Development.lua"))()
		local settings = captureSettings()
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		assert.are.equal(5, #settings.initializers)
		for _, initializer in ipairs(settings.initializers) do
			assert.is_false(initializer:ShouldShow())
		end
		local inboundRepairs = 0
		_G.SettingsInbound = {
			RepairDisplay = function()
				inboundRepairs = inboundRepairs + 1
				settings.repairs = settings.repairs + 1
			end,
		}
		settings.shown = true
		SlashCmdList.QUESTWITHFRIENDS("screenshot")
		assert.are.equal(1, inboundRepairs)
		assert.is_true(view.hidden)
		assert.are.equal(1, settings.repairs)
		for _, initializer in ipairs(settings.initializers) do
			assert.is_true(initializer:ShouldShow())
		end
		settings.buttons["Quest differences"].click()
		SlashCmdList.QUESTWITHFRIENDS("screenshot off")
		assert.is_false(settings.header:ShouldShow())
		assert.is_true(view.presentation.screenshot)
		SlashCmdList.QUESTWITHFRIENDS("screenshot on")
		assert.is_true(settings.header:ShouldShow())
		assert.are.equal(1, settings.repairs)
		settings.currentLayout = {}
		settings.shown = true
		SlashCmdList.QUESTWITHFRIENDS("screenshot")
		assert.are.equal(1, settings.repairs)
		assert.is_true(settings.shown)
		_G.SettingsInbound = nil
		settings.currentLayout = nil
		SlashCmdList.QUESTWITHFRIENDS("screenshot on")
		assert.are.equal(2, settings.repairs)
	end)

	it("keeps the normal appearance preview usable alongside screenshot scenarios", function()
		party = false
		QuestWithFriends.isDevelopment = true
		assert(loadfile("dev/Development.lua"))()
		local settings = captureSettings()
		assert(loadfile("src/QuestWithFriends.lua"))()
		local preview = settings.settings.QuestWithFriendsPreviewMode.setting
		settings.buttons["Quest differences"].click()
		assert.is_true(preview:GetValue())
		assert.is_true(view.presentation.screenshot)
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		assert.is_false(view.presentation.screenshot)
		assert.is_function(view.presentation.onStop)
		settings.buttons["Party in sync"].click()
		preview:SetValue(false)
		assert.is_true(view.hidden)
		preview:SetValue(true)
		assert.are.equal(4, #view.groups)
		assert.is_false(view.presentation.screenshot)
		assert.is_function(view.presentation.onStop)
	end)

	it("leaves normal preview intact when screenshot settings APIs are unavailable", function()
		party = false
		QuestWithFriends.isDevelopment = true
		assert(loadfile("dev/Development.lua"))()
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		SlashCmdList.QUESTWITHFRIENDS("screenshot")
		assert.is_false(view.presentation.screenshot)
		assert.is_function(view.presentation.onStop)
		local settings = captureSettings()
		_G.CreateSettingsButtonInitializer = nil
		assert(loadfile("src/QuestWithFriends.lua"))()
		assert.same({}, settings.initializers)
		SlashCmdList.QUESTWITHFRIENDS("screenshot on")
		assert.is_true(settings.registered)
	end)

	it("saves settings without AddonKit and applies them when it becomes available after reload", function()
		local settings = captureSettings()
		assert(loadfile("src/QuestWithFriends.lua"))()
		settings.setting:SetValue(true)
		assert.is_true(QuestWithFriendsDB.debugMode)
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		assert.is_false(settings.setting:GetValue())
		SlashCmdList.QUESTWITHFRIENDS("debug on")
		assert.is_true(settings.setting:GetValue())
		captureLogs()
		assert(loadfile("src/QuestWithFriends.lua"))()
		assert.are.equal("DEBUG", AddonKit.Registry.addons.QuestWithFriends.logLevel)
	end)

	it("keeps persistent debug commands usable without the Settings API", function()
		assert.is_false(QuestWithFriendsDB.debugMode)
		SlashCmdList.QUESTWITHFRIENDS("debug")
		assert.is_true(QuestWithFriendsDB.debugMode)
		assert(loadfile("src/QuestWithFriends.lua"))()
		assert.is_true(QuestWithFriendsDB.debugMode)
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		assert.is_false(QuestWithFriendsDB.debugMode)
	end)

	it("requests peer snapshots on manual refresh without echoing requests forever", function()
		local records = captureLogs()
		assert(loadfile("src/QuestWithFriends.lua"))()
		SlashCmdList.QUESTWITHFRIENDS("debug")
		flush(1)
		assert.same({ "1.1:H" }, messages)
		local status = findLog(records, "Party sync status").data
		assert.are.equal("Adam-Realm", status.player)
		assert.same({ { name = "Julia", key = "Julia-Realm" } }, status.members)
		assert.is_true(status.prefixRegistered)
		flush()
		local first = #messages
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "PARTY", "Julia-Realm")
		flush()
		assert.are.equal(first + 1, #messages)
		assert.is_not_nil(findLog(records, "Received snapshot request"))
		local beforeRefresh = #messages
		SlashCmdList.QUESTWITHFRIENDS("")
		flush()
		assert.are.equal("1.1:H", messages[beforeRefresh + 1])
		local snapshot = findLog(records, "Submitted quest snapshot").data
		assert.are.equal(0, snapshot.quests)
		assert.are.equal(#QuestWithFriends.Core.encode({}), snapshot.bytes)
	end)

	it("logs send failures and automatically retries an unchanged snapshot", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local records = captureLogs()
		Enum.SendAddonMessageResult = { Success = 0, Throttle = 7 }
		rawset(C_ChatInfo, "SendAddonMessage", function(_, message)
			return message == "1.1:H" and Enum.SendAddonMessageResult.Success or Enum.SendAddonMessageResult.Throttle
		end)
		SlashCmdList.QUESTWITHFRIENDS("")
		flush(2)
		local failure = findLog(records, "Addon message send failed")
		assert.are.equal("WARN", failure.level)
		assert.are.equal("Throttle", failure.data.result)
		assert.is_not_nil(findLog(records, "Quest snapshot submission failed"))
		assert.is_nil(findLog(records, "Submitted quest snapshot"))
		rawset(C_ChatInfo, "SendAddonMessage", function()
			return Enum.SendAddonMessageResult.Success
		end)
		flush()
		assert.are.equal("Success", findLog(records, "Addon message submitted").data.result)
		assert.is_not_nil(findLog(records, "Submitted quest snapshot"))
	end)

	it("logs registration failures and send APIs that return no status", function()
		local records = captureLogs()
		C_ChatInfo.RegisterAddonMessagePrefix = function()
			return false
		end
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.is_not_nil(findLog(records, "Failed to register addon message prefix"))
		assert.is_false(findLog(records, "Party sync status").data.prefixRegistered)
		assert.are.equal("nil", findLog(records, "Addon message submitted").data.result)
		assert.is_not_nil(findLog(records, "Submitted quest snapshot"))
	end)

	it("logs unknown senders and unexpected channels before silently dropping their data", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local records = captureLogs()
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "PARTY", "Stranger-Realm")
		assert.are.equal("sender not in roster", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal("Stranger-Realm", findLog(records, "Incoming addon message").data.sender)
		records = captureLogs()
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "INSTANCE_CHAT", "Julia-Realm")
		assert.are.equal("INSTANCE_CHAT", findLog(records, "Incoming addon message").data.channel)
		assert.are.equal("not PARTY channel", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal(0, #timers)
	end)

	it("logs partial snapshot assembly without storing raw quest payloads", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local records = captureLogs()
		local payload = QuestWithFriends.Core.encode({ [42] = { title = "Errand", state = "active", objectives = {} } })
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:2:2:" .. payload:sub(7), "PARTY", "Julia-Realm")
		local chunk = findLog(records, "Received snapshot chunk").data
		assert.same({ sender = "Julia-Realm", revision = 1, part = 2, parts = 2, received = 1 }, chunk)
		assert.is_nil(findLog(records, "Received quest snapshot"))
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:2:" .. payload:sub(1, 6), "PARTY", "Julia-Realm")
		assert.is_not_nil(findLog(records, "Received quest snapshot"))
		fire("CHAT_MSG_ADDON", "QWF", "1.1:bad", "PARTY", "Julia-Realm")
		assert.are.equal("invalid chunk header", findLog(records, "Ignored addon message").data.reason)
	end)

	it("defaults to zone filtering, remembers toggles and updates on zone changes", function()
		entries = { { questID = 42, title = "Distant errand" } }
		questMaps[42] = 202
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({
			[7] = { title = "Also distant", state = "active", objectives = {}, mapID = 202 },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.is_true(view.zoneFilter)
		assert.is_true(view.complete)
		assert.same({}, view.groups)
		view.toggle()
		assert.is_false(view.zoneFilter)
		assert.is_false(QuestWithFriendsDB.zoneFilter)
		local function checkGroups()
			assert.are.equal("Also distant", view.groups[1].title)
			assert.are.equal("You", view.groups[1].differences[1].player)
			assert.are.equal("Distant errand", view.groups[2].title)
			assert.are.equal("Julia", view.groups[2].differences[1].player)
		end
		checkGroups()
		view.toggle()
		assert.same({}, view.groups)
		currentMap = 202
		fire("ZONE_CHANGED_NEW_AREA")
		checkGroups()
		currentMap = nil
		fire("ZONE_CHANGED_NEW_AREA")
		assert.is_true(view.zoneFilter)
		checkGroups()
	end)

	for _, game in ipairs({ "retail", "forever" }) do
		it("hides profession/class quests by default without filtering snapshots on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			assert(loadfile("src/QuestWithFriends.lua"))()
			local sender = "Julia-Realm"
			if game == "forever" then
				foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
				sender = "Florace Bastille"
			end
			_G.LOCALIZED_CLASS_NAMES_FEMALE = { MAGE = "Magierin" }
			_G.C_TradeSkillUI = {
				GetTradeSkillDisplayName = function(id)
					return id == 356 and "Angeln" or ""
				end,
			}
			entries = {
				{ title = "Angeln", isHeader = true },
				{ questID = 41, title = "Fishing errand" },
				{ title = "Magierin", isHeader = true },
				{ questID = 42, title = "Class errand" },
				{ title = "Zone", isHeader = true },
				{ questID = 43, title = "Ordinary errand" },
				{ questID = 44, title = "Tagged class" },
				{ questID = 45, title = "Profession world quest" },
				{ questID = 46, title = "Tradeskill quest" },
				{ questID = 47, title = "Class type quest" },
			}
			tags[44] = { tagID = 21 }
			tags[45] = { worldQuestType = 1 }
			tags[46] = { tradeskillLineID = 171 }
			questTypes[47] = 21
			fire("PLAYER_ENTERING_WORLD")
			flush()
			local parts = {}
			for _, message in ipairs(messages) do
				local part, data = message:match("^1%.1:D:%d+:(%d+):%d+:(.+)$")
				if part then
					parts[tonumber(part)] = data
				end
			end
			local quests = QuestWithFriends.Core.decode(table.concat(parts))
			for id = 41, 47 do
				assert.is_not_nil(quests[id])
			end
			for _, id in ipairs({ 41, 45, 46 }) do
				assert.are.equal("profession", quests[id].category)
			end
			for _, id in ipairs({ 42, 44, 47 }) do
				assert.are.equal("class", quests[id].category)
			end
			assert.is_nil(quests[43].category)
			fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", sender)
			assert.is_false(view.filters.professions)
			assert.is_false(view.filters.classes)
			assert.is_false(QuestWithFriendsDB.showProfessionQuests)
			assert.is_false(QuestWithFriendsDB.showClassQuests)
			local function checkIDs(expected)
				local ids = {}
				for _, group in ipairs(view.groups) do
					ids[#ids + 1] = group.questID
				end
				table.sort(ids)
				assert.same(expected, ids)
			end
			checkIDs({ 43 })
			local sent = #messages
			view.filters.toggleProfessions()
			checkIDs({ 41, 43, 45, 46 })
			assert.is_false(view.filters.classes)
			view.filters.toggleProfessions()
			view.filters.toggleClasses()
			checkIDs({ 42, 43, 44, 47 })
			assert.is_false(view.filters.professions)
			view.filters.toggleProfessions()
			checkIDs({ 41, 42, 43, 44, 45, 46, 47 })
			view.filters.toggleClasses()
			checkIDs({ 41, 43, 45, 46 })
			assert.are.equal(sent, #messages)
			assert(loadfile("src/QuestWithFriends.lua"))()
			fire("PLAYER_ENTERING_WORLD")
			assert.is_true(view.filters.professions)
			assert.is_false(view.filters.classes)
		end)
	end

	for _, game in ipairs({ "retail", "forever" }) do
		it("applies reviewed Camping classifications only on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			assert(loadfile("src/QuestWithFriends.lua"))()
			local sender = "Julia-Realm"
			if game == "forever" then
				foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
				sender = "Florace Bastille"
			end
			entries = {
				{ title = "Localized unknown header", isHeader = true },
				{ questID = 42, title = "Go camping with scouts" },
			}
			local count = 0
			for id in pairs(QuestWithFriends.QuestCategories.forever) do
				entries[#entries + 1] = { questID = id, title = "Localized quest " .. id }
				count = count + 1
			end
			assert.are.equal(94, count)
			fire("PLAYER_ENTERING_WORLD")
			flush()
			local parts = {}
			for _, message in ipairs(messages) do
				local part, data = message:match("^1%.1:D:%d+:(%d+):%d+:(.+)$")
				if part then
					parts[tonumber(part)] = data
				end
			end
			local snapshot = QuestWithFriends.Core.decode(table.concat(parts))
			for id in pairs(QuestWithFriends.QuestCategories.forever) do
				assert.is_not_nil(snapshot[id])
				assert.are.equal(game == "forever" and "profession" or nil, snapshot[id].category)
			end
			fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", sender)
			assert.are.equal(game == "forever" and 1 or 95, #view.groups)
			if game == "forever" then
				assert.are.equal(42, view.groups[1].questID)
			end
			view.filters.toggleClasses()
			assert.are.equal(game == "forever" and 1 or 95, #view.groups)
			view.filters.toggleProfessions()
			assert.are.equal(95, #view.groups)
		end)
	end

	it("filters remote-only and completed Camping quests using reviewed local classifications", function()
		QuestWithFriends.QuestEquivalencesGame = "forever"
		foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
		assert(loadfile("src/QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({
			[96101] = { title = "The Great Outdoors", state = "active", objectives = {} },
			[96031] = { title = "Camping 101: Leatherworking", state = "active", objectives = {} },
			[96629] = { title = "Camping 101: Cooking", state = "active", objectives = {} },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Florace Bastille")
		assert.is_true(view.complete)
		assert.same({}, view.groups)
		view.filters.toggleClasses()
		assert.same({}, view.groups)
		view.filters.toggleProfessions()
		assert.are.equal(3, #view.groups)
		fire("QUEST_TURNED_IN", 96101)
		assert.are.equal(3, #view.groups)
		view.filters.toggleProfessions()
		assert.same({}, view.groups)
	end)

	it("filters remote categories atomically and replaces them with each snapshot", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local quests = {
			[41] = { title = "Remote fishing", state = "active", objectives = {}, category = "profession" },
			[42] = { title = "Remote class", state = "ready", objectives = {}, category = "class" },
		}
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode(quests), "PARTY", "Julia-Realm")
		assert.same({}, view.groups)
		assert.is_true(view.complete)
		view.filters.toggleProfessions()
		assert.are.equal(41, view.groups[1].questID)
		view.filters.toggleClasses()
		assert.are.equal(2, #view.groups)
		view.filters.toggleProfessions()
		assert.are.equal(42, view.groups[1].questID)
		view.filters.toggleClasses()
		quests[41].category = nil
		quests[42] = nil
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:2:1:1:" .. QuestWithFriends.Core.encode(quests), "PARTY", "Julia-Realm")
		assert.are.equal(1, #view.groups)
		assert.are.equal(41, view.groups[1].questID)
	end)

	it("marks missing, malformed and unsupported protocol envelopes as incompatible", function()
		local records = captureLogs()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		for _, message in ipairs({
			"H",
			"X",
			"P:p:41",
			"P:41:42",
			"1:H",
			"1:D:1:1:1:" .. payload,
			"D:1:1:1:" .. payload,
			"2.0:H",
			"2.0:D:1:1:1:" .. payload,
			"",
			"broken",
			"1.1:",
			"1.-1:H",
			"1.00:H",
			"01.1:H",
			"1.1000:H",
			"1.0.0:H",
		}) do
			fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
			assert.is_true(view.complete)
			fire("CHAT_MSG_ADDON", "QWF", message, "PARTY", "Julia-Realm")
			assert.is_false(view.complete)
			assert.are.equal("incompatible", view.notices[1].reason)
		end
		assert.is_not_nil(findLog(records, "Unsupported addon protocol"))
		SlashCmdList.QUESTWITHFRIENDS("")
		assert.are.equal("incompatible", view.notices[1].reason)
		flush()
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		assert.same({}, view.notices)
	end)

	it("ignores unknown message kinds and malformed chunk headers within a supported protocol", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		for _, message in ipairs({
			"1.1:H:extra",
			"1.1:X:extra",
			"1.1:P:p:42",
			"1.1:D:0:1:1:" .. payload,
			"1.1:D:100000001:1:1:" .. payload,
			"1.1:D:2:0:1:" .. payload,
			"1.1:D:2:2:1:" .. payload,
			"1.1:D:2:1:101:" .. payload,
			"1.1:D:2:1:1:",
			"1.1:D:2:1:1:" .. string.rep("x", 221),
			"1.1:D:0000000002:1:1:" .. payload,
			"1.1:D:2:0001:1:" .. payload,
			"1.1:D:2:1:1:" .. string.rep("x", 256),
		}) do
			fire("CHAT_MSG_ADDON", "QWF", message, "PARTY", "Julia-Realm")
			assert.is_true(view.complete)
		end
	end)

	it("migrates the combined preference without overwriting separate saved choices", function()
		_G.QuestWithFriendsDB = { showPersonalQuests = true }
		assert(loadfile("src/QuestWithFriends.lua"))()
		assert.is_true(QuestWithFriendsDB.showProfessionQuests)
		assert.is_true(QuestWithFriendsDB.showClassQuests)
		QuestWithFriendsDB.showClassQuests = false
		assert(loadfile("src/QuestWithFriends.lua"))()
		assert.is_true(QuestWithFriendsDB.showProfessionQuests)
		assert.is_false(QuestWithFriendsDB.showClassQuests)
		_G.QuestWithFriendsDB = { showPersonalQuests = false }
		assert(loadfile("src/QuestWithFriends.lua"))()
		assert.is_false(QuestWithFriendsDB.showProfessionQuests)
		assert.is_false(QuestWithFriendsDB.showClassQuests)
	end)

	it("chunks classified quest snapshots and automatically retries a failed submission", function()
		for index = 1, 80 do
			local id = 900000 + index
			entries[index] = { questID = id, title = "Class quest " .. index }
			tags[id] = { tagID = 21 }
		end
		local attempts = 0
		rawset(C_ChatInfo, "SendAddonMessage", function(_, message)
			if message:sub(1, 6) == "1.1:D:" then
				attempts = attempts + 1
				if attempts == 1 then
					return false
				end
			end
			messages[#messages + 1] = message
		end)
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.is_true(attempts > 1)
		local parts = {}
		for _, message in ipairs(messages) do
			local part, data = message:match("^1%.1:D:%d+:(%d+):%d+:(.+)$")
			if part then
				parts[tonumber(part)] = data
				assert.is_true(#data <= 220)
				assert.is_true(#message <= 255)
			end
		end
		assert.is_true(#parts > 1)
		local quests = QuestWithFriends.Core.decode(table.concat(parts))
		for id in pairs(tags) do
			assert.are.equal("class", quests[id].category)
		end
	end)

	it("retains personal classification after turn-in and does not hide ordinary class variants", function()
		entries = { { questID = 42, title = "Class quest" }, { questID = 71002, title = "Branch quest" } }
		tags[42] = { tagID = 21 }
		fire("PLAYER_ENTERING_WORLD")
		flush()
		entries, tags = {}, {}
		fire("QUEST_TURNED_IN", 42)
		local payload = QuestWithFriends.Core.encode({
			[42] = { title = "Class quest", state = "active", objectives = {} },
			[71001] = { title = "Branch quest", state = "active", objectives = {} },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.are.equal(1, #view.groups)
		assert.are.equal(71001, view.groups[1].questID)
		view.filters.toggleProfessions()
		assert.are.equal(1, #view.groups)
		view.filters.toggleClasses()
		assert.are.equal(2, #view.groups)
	end)

	it("maps subzones to their parent zone and retains quests with unknown maps", function()
		currentMap = 1101
		entries = {
			{ questID = 11, title = "Here" },
			{ questID = 12, title = "Unknown" },
		}
		questMaps[11] = 101
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local data
		for _, message in ipairs(messages) do
			data = message:match("^1%.1:D:%d+:%d+:%d+:(.+)$") or data
		end
		local quests = QuestWithFriends.Core.decode(data)
		assert.are.equal(101, quests[11].mapID)
		assert.is_nil(quests[12].mapID)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		assert.are.equal("Here", view.groups[1].title)
		assert.are.equal("Unknown", view.groups[2].title)
	end)

	it("marks a peer unknown when its snapshot cannot be shared", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:X", "PARTY", "Julia-Realm")
		assert.is_false(view.complete)
	end)

	it("keeps an oversized local snapshot warning outside the quest groups", function()
		for id = 1, 100 do
			entries[id] = { questID = id, title = string.rep("x", 280) }
		end
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.is_false(view.complete)
		assert.same({ player = "You", reason = "oversized" }, view.notices[1])
		assert.same({ player = "Julia", reason = "unknown" }, view.notices[2])
		assert.same({}, view.groups)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		assert.is_false(view.complete)
		assert.same({ { player = "You", reason = "oversized" } }, view.notices)
		assert.are.equal(100, #view.groups)
	end)

	it("offers sharing only for pushable missing quests and resolves the current log index on click", function()
		entries = {
			{ title = "Zone", isHeader = true },
			{ questID = 71002, title = "Local variant" },
			{ questID = 42, title = "Not shareable" },
		}
		pushable[71002] = true
		fire("PLAYER_ENTERING_WORLD")
		flush()
		assert.same({}, view.groups)
		assert.same({ { player = "Julia", reason = "unknown" } }, view.notices)
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		assert.are.equal(71002, view.groups[1].shareQuestID)
		assert.is_nil(view.groups[2].shareQuestID)
		assert.same({}, pushed)
		entries = { entries[2], entries[3] }
		view.share(71002)
		assert.same({ 1 }, pushed)
		pushable[71002] = false
		view.share(71002)
		assert.same({ 1 }, pushed)
		assert.is_nil(view.groups[1].shareQuestID)
	end)

	it("does not share quests removed from the log or after leaving the party", function()
		entries = { { questID = 42, title = "Errand" } }
		pushable[42] = true
		fire("PLAYER_ENTERING_WORLD")
		flush()
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		local share = view.share
		entries = {}
		share(42)
		entries = { { questID = 42, title = "Errand" } }
		party = false
		share(42)
		assert.same({}, pushed)
	end)

	local function captureShareDiagnostics(game)
		QuestWithFriends.QuestEquivalencesGame = game or "retail"
		_G.GetTime = function()
			return 100
		end
		_G.InCombatLockdown = function()
			return true
		end
		_G.UnitAffectingCombat = function(unit)
			assert.are.equal("player", unit)
			return true
		end
		_G.issecure = function()
			return false
		end
		_G.issecurevariable = function(name)
			assert.are.equal("QuestLogPushQuest", name)
			return false, "OtherAddon"
		end
		_G.debugstack = function(start, count, bottom)
			assert.same({ 2, 8, 0 }, { start, count, bottom })
			return "share click stack"
		end
		_G.C_AddOns = {
			GetAddOnMetadata = function(addon, field)
				assert.same({ "QuestWithFriends", "Version" }, { addon, field })
				return "0.1.7"
			end,
		}
		local records = captureLogs(true)
		assert(loadfile("src/QuestWithFriends.lua"))()
		entries = { { questID = 42, title = "Errand" } }
		pushable[42] = true
		fire("PLAYER_ENTERING_WORLD")
		flush()
		return records
	end

	for _, game in ipairs({ "retail", "forever" }) do
		for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
			it("records share context for " .. event .. " on " .. game .. " without debug mode", function()
				local records = captureShareDiagnostics(game)
				assert.is_true(registeredEvents[event])
				assert.is_false(QuestWithFriendsDB.debugMode)
				_G.QuestLogPushQuest = function(index)
					pushed[#pushed + 1] = index
					fire(event, "QuestWithFriends", "QuestLogPushQuest()")
				end
				view.share(42)
				assert.same({ 1 }, pushed)
				local attemptLog = findLog(records, "Quest sharing attempted")
				assert.are.equal("INFO", attemptLog.level)
				assert.are.equal("share", attemptLog.category)
				local attempt = attemptLog.data
				assert.are.equal(1, attempt.attemptID)
				assert.are.equal(42, attempt.questID)
				assert.are.equal(1, attempt.logIndex)
				assert.are.equal("Errand", attempt.questTitle)
				assert.are.equal(game, attempt.game)
				assert.are.equal("12.1.0", attempt.clientVersion)
				assert.are.equal("69933", attempt.clientBuild)
				assert.are.equal(120100, attempt.interfaceVersion)
				assert.are.equal("0.1.7", attempt.addonVersion)
				assert.is_true(attempt.combatLockdown)
				assert.is_true(attempt.playerInCombat)
				assert.is_true(attempt.inParty)
				assert.is_false(attempt.inRaid)
				assert.is_false(attempt.secureContext)
				assert.is_false(attempt.apiSecure)
				assert.are.equal("OtherAddon", attempt.apiTaintSource)
				assert.are.equal("share click stack", attempt.stack)
				local blocked = findLog(records, "Quest sharing blocked")
				assert.are.equal("WARN", blocked.level)
				assert.are.equal("share", blocked.category)
				assert.are.equal(event, blocked.data.event)
				assert.are.equal("QuestWithFriends", blocked.data.addon)
				assert.are.equal("QuestLogPushQuest()", blocked.data.protectedFunction)
				assert.same(attempt, blocked.data.attempt)
				assert.are.equal(0, blocked.data.elapsed)
				assert.is_true(blocked.data.context.combatLockdown)
				assert.same({}, timers)
			end)
		end
	end

	it("correlates delayed security events with the latest share attempt", function()
		local records = captureShareDiagnostics()
		view.share(42)
		entries[2] = { questID = 43, title = "Another errand" }
		pushable[43] = true
		local now, inCombat = 101, false
		_G.GetTime = function()
			return now
		end
		_G.InCombatLockdown = function()
			return inCombat
		end
		_G.UnitAffectingCombat = function()
			return false
		end
		_G.issecurevariable = function()
			return true
		end
		view.share(43)
		now, inCombat = 102, true
		fire("ADDON_ACTION_BLOCKED", "QuestWithFriends", "QuestLogPushQuest")
		local data = findLog(records, "Quest sharing blocked").data
		assert.are.equal(2, data.attempt.attemptID)
		assert.are.equal(43, data.attempt.questID)
		assert.are.equal(2, data.attempt.logIndex)
		assert.are.equal(1, data.elapsed)
		assert.is_false(data.attempt.combatLockdown)
		assert.is_true(data.context.combatLockdown)
		assert.is_false(data.attempt.playerInCombat)
		assert.is_true(data.attempt.apiSecure)
		assert.is_nil(data.attempt.apiTaintSource)
		assert.same({ 1, 2 }, pushed)
	end)

	for _, case in ipairs({ "no attempt", "expired", "clock reset", "ineligible click" }) do
		it("does not attach an unrelated quest to a share block: " .. case, function()
			local records = captureShareDiagnostics()
			if case ~= "no attempt" then
				view.share(42)
			end
			if case == "ineligible click" then
				pushable[42] = false
				view.share(42)
			end
			_G.GetTime = function()
				return case == "expired" and 106 or case == "clock reset" and 99 or 100
			end
			fire("ADDON_ACTION_BLOCKED", "QuestWithFriends", "QuestLogPushQuest()")
			local data = findLog(records, "Quest sharing blocked").data
			assert.is_nil(data.attempt)
			assert.is_nil(data.elapsed)
			assert.is_true(data.context.combatLockdown)
		end)
	end

	it("ignores unrelated security events without refreshing or sending quests", function()
		local records = captureShareDiagnostics()
		view.share(42)
		local count = #records
		fire("ADDON_ACTION_BLOCKED", "OtherAddon", "QuestLogPushQuest()")
		fire("ADDON_ACTION_FORBIDDEN", "QuestWithFriends", "OtherProtectedFunction()")
		assert.are.equal(count, #records)
		assert.same({}, timers)
	end)

	it("keeps one-click sharing working without AddonKit or optional diagnostic APIs", function()
		entries = { { questID = 42, title = "Errand" } }
		pushable[42] = true
		fire("PLAYER_ENTERING_WORLD")
		flush()
		view.share(42)
		fire("ADDON_ACTION_BLOCKED", "QuestWithFriends", "QuestLogPushQuest()")
		assert.same({ 1 }, pushed)
		assert.same({}, timers)
	end)

	it("renders the stabilized second scan even when its snapshot is unchanged", function()
		entries = { { questID = 42, title = "Errand" } }
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({ [42] = { title = "Errand", state = "active", objectives = {} } })
		fire("CHAT_MSG_ADDON", "QWF", "1.1:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.same({}, view.groups)
		local sent = #messages
		entries = {}
		fire("QUEST_LOG_UPDATE")
		assert.are.equal("missing", view.groups[1].differences[1].reason)
		entries = { { questID = 42, title = "Errand" } }
		flush()
		assert.are.equal(sent, #messages)
		assert.same({}, view.groups)
	end)

	it("honors a forced refresh received during an already scheduled unchanged scan", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local sent = #messages
		fire("QUEST_LOG_UPDATE")
		fire("CHAT_MSG_ADDON", "QWF", "1.1:H", "PARTY", "Julia-Realm")
		flush()
		assert.are.equal(sent + 1, #messages)
		assert.is_not_nil(messages[#messages]:match("^1%.1:D:"))
	end)

	it("debounces log updates and clears old party data when leaving", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local first = #messages
		objectives[1] = { { text = "Gnolls slain: 3/8", numFulfilled = 3, numRequired = 8 } }
		fire("QUEST_LOG_UPDATE")
		fire("QUEST_LOG_UPDATE")
		assert.are.equal(1, #timers)
		flush()
		assert.is_true(#messages > first)
		local second = #messages
		fire("QUEST_LOG_UPDATE")
		flush()
		assert.are.equal(second, #messages)
		party = false
		fire("GROUP_ROSTER_UPDATE")
		assert.is_true(view.hidden)
	end)
end)
