describe("Quest With Friends party sync", function()
	local eventHandler, timers, messages, view, objectives, entries, party, currentMap, questMaps, pushed, pushable
	local originalBuildInfo, originalConstants, originalTradeSkillUI, originalClassMale, originalClassFemale
	local tags, questTypes
	local originalSettings
	before_each(function()
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
		QuestWithFriends = nil
		assert(loadfile("QuestEquivalences.lua"))()
		assert(loadfile("tests/fixtures/quest_equivalences.lua"))()
		assert(loadfile("Client.lua"))()
		assert(loadfile("QuestCategories.lua"))()
		assert(loadfile("Core.lua"))()
		assert(loadfile("Preview.lua"))()
		timers, messages, objectives, entries = {}, {}, {}, {}
		view = {}
		party = true
		currentMap, questMaps = 101, {}
		pushed, pushable = {}, {}
		_G.QuestLogPushQuest = function(index)
			pushed[#pushed + 1] = index
		end
		_G.QuestWithFriendsDB = nil
		QuestWithFriends.Panel = {
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
				RegisterEvent = function(_, _) end,
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
		assert(loadfile("QuestWithFriends.lua"))()
	end)

	after_each(function()
		_G.Settings = originalSettings
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

	for _, target in ipairs({ { game = "retail", interface = 120100 }, { game = "forever", interface = 16001 } }) do
		it("loads the shipped TOC and syncs, filters, shares and completes quests on " .. target.game, function()
			rawset(_G, "GetBuildInfo", function()
				return "", "", "", target.interface
			end)
			local sender = "Julia-Realm"
			if target.game == "forever" then
				foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
				sender = "Florace Bastille"
			end
			local mockPanel = QuestWithFriends.Panel
			QuestWithFriends = nil
			for line in io.lines("QuestWithFriends.toc") do
				if line:match("^## Interface:") then
					assert.is_not_nil(line:find(tostring(target.interface), 1, true))
				elseif line:match("%.lua$") then
					assert(loadfile(line))()
				end
			end
			QuestWithFriends.Panel = mockPanel
			assert.are.equal(target.game, QuestWithFriends.QuestEquivalencesGame)
			entries = { { questID = 42, title = "Errand" } }
			objectives[42] = { { text = "Gnolls slain: 3/8", numFulfilled = 3, numRequired = 8 } }
			questMaps[42] = 101
			pushable[42] = true
			fire("PLAYER_ENTERING_WORLD")
			flush()
			assert.are.equal("1.0:H", messages[1])
			local function receiveQuests(quests, serial)
				fire(
					"CHAT_MSG_ADDON",
					"QWF",
					"1.0:D:" .. serial .. ":1:1:" .. QuestWithFriends.Core.encode(quests),
					"PARTY",
					sender
				)
			end
			receiveQuests({}, 1)
			assert.is_true(view.complete)
			assert.are.equal(42, view.groups[1].shareQuestID)
			view.share(42)
			assert.same({ 1 }, pushed)
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
			currentMap = 202
			fire("ZONE_CHANGED_NEW_AREA")
			assert.same({}, view.groups)
			view.toggle()
			assert.are.equal(1, #view.groups)
			objectives[42][1].numFulfilled = 8
			C_QuestLog.IsComplete = function()
				return true
			end
			fire("QUEST_LOG_UPDATE")
			flush()
			assert.are.equal("ready", view.groups[1].differences[1].reason)
			entries, objectives = {}, {}
			fire("QUEST_TURNED_IN", 42)
			flush()
			assert.are.equal("completed", view.groups[1].differences[1].reason)
			fire("QUEST_ACCEPTED", 42)
			fire("QUEST_REMOVED", 42)
			flush()
			assert.are.equal("missing", view.groups[1].differences[1].reason)
		end)
	end

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
			assert.same({ missing = true, objective = true, active = true, ready = true, completed = true }, reasons)
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
			payload = message:match("^1%.0:D:%d+:%d+:%d+:(.+)$") or payload
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
		assert(loadfile("QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		assert.is_true(view.hidden)
		assert.is_nil(QuestWithFriendsDB.previewMode)
	end)

	it("handshakes, reassembles out-of-order chunks and ignores duplicates", function()
		fire("PLAYER_ENTERING_WORLD")
		assert.is_false(view.complete)
		flush()
		assert.are.equal("1.0:H", messages[1])
		local payload = QuestWithFriends.Core.encode({
			[7] = {
				title = "Remote",
				state = "active",
				objectives = {},
			},
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:2:2:" .. payload:sub(7), "PARTY", "Julia-Realm")
		assert.is_false(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:2:" .. payload:sub(1, 6), "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		assert.are.equal("Remote", view.groups[1].title)
		assert.same({ { player = "You", kind = "missing", reason = "missing" } }, view.groups[1].differences)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:bad", "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "PARTY", "Julia-Realm")
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
			data = message:match("^1%.0:D:%d+:%d+:%d+:(.+)$") or data
		end
		local quests = QuestWithFriends.Core.decode(data)
		assert.is_not_nil(quests[71002])
		assert.is_nil(quests[71001])
		local payload = QuestWithFriends.Core.encode({
			[71001] = { title = "Branch quest", state = "active", objectives = {} },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.same({
			{ player = "You", kind = "ahead", reason = "completed" },
			{ player = "Julia", kind = "needs", reason = "active" },
		}, view.groups[1].differences)
	end)

	it("uses shipped counted and transition families for completion-history checks", function()
		assert(loadfile("QuestEquivalences.lua"))()
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
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
			data = message:match("^1%.0:D:%d+:%d+:%d+:(.+)$") or data
		end
		local quests = QuestWithFriends.Core.decode(data)
		assert.is_nil(quests[77734])
		assert.is_nil(quests[77735])
		assert.is_nil(quests[0])
		assert.are.equal("Gryphons of a Feather", quests[42].title)
	end)

	local function captureLogs()
		local records = {}
		_G.AddonKit = {
			Registry = { addons = {} },
			RegisterAddon = function(name, options)
				AddonKit.Registry.addons[name] = options
			end,
			SetLogLevel = function(name, level)
				assert.are.equal("QuestWithFriends", name)
				AddonKit.Registry.addons[name].logLevel = level
			end,
			Log = function(_, level, category, message, data)
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

	it("matches Forever First Last senders, retains surnames and ignores self echoes", function()
		QuestWithFriends.QuestEquivalencesGame = "forever"
		foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
		local records = captureLogs()
		assert(loadfile("QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local status = findLog(records, "Party sync status").data
		assert.are.equal("Carola Goodspeed", status.player)
		assert.same({ { key = "Florace Bastille", name = "Florace Bastille" } }, status.members)
		assert.same({ { player = "Florace Bastille", reason = "unknown" } }, view.notices)
		local sent = #messages
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "PARTY", "Carola Goodspeed")
		assert.are.equal("self message", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal(0, #timers)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "PARTY", "Florace Bastille")
		assert.are.equal("Florace Bastille", findLog(records, "Received snapshot request").data.sender)
		flush()
		assert.are.equal(sent + 1, #messages)
		local payload = QuestWithFriends.Core.encode({ [42] = { title = "Errand", state = "active", objectives = {} } })
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Florace Bastille")
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
		assert(loadfile("QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		for _, sender in ipairs({ "Florace", "Florace Stranger", "Stranger Bastille" }) do
			fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", sender)
		end
		assert.are.equal("sender not in roster", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal(2, #view.notices)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Florace Bastille")
		assert.same({ { player = "Florace Other", reason = "unknown" } }, view.notices)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Florace Other")
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
		assert(loadfile("QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		for _, sender in ipairs({ "Florace Bastille", "Zachori", "Marva Less-Wand" }) do
			fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", sender)
		end
		assert.is_true(view.complete)
	end)

	it("uses Forever's configured surname separator", function()
		QuestWithFriends.QuestEquivalencesGame = "forever"
		_G.Constants = { CharacterNameSeparatorConsts = { CHARACTERNAME_SURNAME_SEPARATOR = "·" } }
		foreverNames({ player = { "Carola", "Goodspeed" }, party1 = { "Florace", "Bastille" } })
		assert(loadfile("QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Florace·Bastille")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia")
		assert.is_true(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "PARTY", "Julia-TestRealm")
		assert.is_false(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-TestRealm")
		assert.is_true(view.complete)
	end)

	it("registers with AddonKit and logs hidden quest counts", function()
		local records = captureLogs()
		assert(loadfile("QuestWithFriends.lua"))()
		entries = { { questID = 77734, title = "Level 17", isHidden = true } }
		fire("PLAYER_ENTERING_WORLD")
		assert.is_true(AddonKit.Registry.addons.QuestWithFriends.persistDiagnostics)
		assert.same({ visible = 0, hiddenOrInternal = 1 }, findLog(records, "Quest log scanned").data)
	end)

	local function captureSettings()
		local captured = { settings = {} }
		_G.Settings = {
			VarType = { Boolean = "boolean" },
			RegisterVerticalLayoutCategory = function(name)
				captured.category = { name = name }
				return captured.category
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

	for _, game in ipairs({ "retail", "forever" }) do
		it("registers native settings and persists debug mode on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			captureLogs()
			local settings = captureSettings()
			assert(loadfile("QuestWithFriends.lua"))()
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
			assert(loadfile("QuestWithFriends.lua"))()
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
			assert(loadfile("QuestWithFriends.lua"))()
			assert.is_false(settings.setting:GetValue())
			assert.are.equal("INFO", AddonKit.Registry.addons.QuestWithFriends.logLevel)
		end)
	end

	it("exposes session-only preview in native settings and stays synchronized with slash commands", function()
		party = false
		local settings = captureSettings()
		assert(loadfile("QuestWithFriends.lua"))()
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

	it("saves settings without AddonKit and applies them when it becomes available after reload", function()
		local settings = captureSettings()
		assert(loadfile("QuestWithFriends.lua"))()
		settings.setting:SetValue(true)
		assert.is_true(QuestWithFriendsDB.debugMode)
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		assert.is_false(settings.setting:GetValue())
		SlashCmdList.QUESTWITHFRIENDS("debug on")
		assert.is_true(settings.setting:GetValue())
		captureLogs()
		assert(loadfile("QuestWithFriends.lua"))()
		assert.are.equal("DEBUG", AddonKit.Registry.addons.QuestWithFriends.logLevel)
	end)

	it("keeps persistent debug commands usable without the Settings API", function()
		assert.is_false(QuestWithFriendsDB.debugMode)
		SlashCmdList.QUESTWITHFRIENDS("debug")
		assert.is_true(QuestWithFriendsDB.debugMode)
		assert(loadfile("QuestWithFriends.lua"))()
		assert.is_true(QuestWithFriendsDB.debugMode)
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		assert.is_false(QuestWithFriendsDB.debugMode)
	end)

	it("requests peer snapshots on manual refresh without echoing requests forever", function()
		local records = captureLogs()
		assert(loadfile("QuestWithFriends.lua"))()
		SlashCmdList.QUESTWITHFRIENDS("debug")
		flush(1)
		assert.same({ "1.0:H" }, messages)
		local status = findLog(records, "Party sync status").data
		assert.are.equal("Adam-Realm", status.player)
		assert.same({ { name = "Julia", key = "Julia-Realm" } }, status.members)
		assert.is_true(status.prefixRegistered)
		flush()
		local first = #messages
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "PARTY", "Julia-Realm")
		flush()
		assert.are.equal(first + 1, #messages)
		assert.is_not_nil(findLog(records, "Received snapshot request"))
		local beforeRefresh = #messages
		SlashCmdList.QUESTWITHFRIENDS("")
		flush()
		assert.are.equal("1.0:H", messages[beforeRefresh + 1])
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
			return message == "1.0:H" and Enum.SendAddonMessageResult.Success or Enum.SendAddonMessageResult.Throttle
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
		assert(loadfile("QuestWithFriends.lua"))()
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "PARTY", "Stranger-Realm")
		assert.are.equal("sender not in roster", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal("Stranger-Realm", findLog(records, "Incoming addon message").data.sender)
		records = captureLogs()
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "INSTANCE_CHAT", "Julia-Realm")
		assert.are.equal("INSTANCE_CHAT", findLog(records, "Incoming addon message").data.channel)
		assert.are.equal("not PARTY channel", findLog(records, "Ignored addon message").data.reason)
		assert.are.equal(0, #timers)
	end)

	it("logs partial snapshot assembly without storing raw quest payloads", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local records = captureLogs()
		local payload = QuestWithFriends.Core.encode({ [42] = { title = "Errand", state = "active", objectives = {} } })
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:2:2:" .. payload:sub(7), "PARTY", "Julia-Realm")
		local chunk = findLog(records, "Received snapshot chunk").data
		assert.same({ sender = "Julia-Realm", revision = 1, part = 2, parts = 2, received = 1 }, chunk)
		assert.is_nil(findLog(records, "Received quest snapshot"))
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:2:" .. payload:sub(1, 6), "PARTY", "Julia-Realm")
		assert.is_not_nil(findLog(records, "Received quest snapshot"))
		fire("CHAT_MSG_ADDON", "QWF", "1.0:bad", "PARTY", "Julia-Realm")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
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
			assert(loadfile("QuestWithFriends.lua"))()
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
				local part, data = message:match("^1%.0:D:%d+:(%d+):%d+:(.+)$")
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
			fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", sender)
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
			assert(loadfile("QuestWithFriends.lua"))()
			fire("PLAYER_ENTERING_WORLD")
			assert.is_true(view.filters.professions)
			assert.is_false(view.filters.classes)
		end)
	end

	for _, game in ipairs({ "retail", "forever" }) do
		it("applies reviewed Camping classifications only on " .. game, function()
			QuestWithFriends.QuestEquivalencesGame = game
			assert(loadfile("QuestWithFriends.lua"))()
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
				local part, data = message:match("^1%.0:D:%d+:(%d+):%d+:(.+)$")
				if part then
					parts[tonumber(part)] = data
				end
			end
			local snapshot = QuestWithFriends.Core.decode(table.concat(parts))
			for id in pairs(QuestWithFriends.QuestCategories.forever) do
				assert.is_not_nil(snapshot[id])
				assert.are.equal(game == "forever" and "profession" or nil, snapshot[id].category)
			end
			fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", sender)
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
		assert(loadfile("QuestWithFriends.lua"))()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({
			[96101] = { title = "The Great Outdoors", state = "active", objectives = {} },
			[96031] = { title = "Camping 101: Leatherworking", state = "active", objectives = {} },
			[96629] = { title = "Camping 101: Cooking", state = "active", objectives = {} },
		})
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Florace Bastille")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode(quests), "PARTY", "Julia-Realm")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:2:1:1:" .. QuestWithFriends.Core.encode(quests), "PARTY", "Julia-Realm")
		assert.are.equal(1, #view.groups)
		assert.are.equal(41, view.groups[1].questID)
	end)

	it("marks missing, malformed and unsupported protocol envelopes as incompatible", function()
		local records = captureLogs()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
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
			"1.0:",
			"1.-1:H",
			"1.00:H",
			"01.0:H",
			"1.1000:H",
			"1.0.0:H",
		}) do
			fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
			assert.is_true(view.complete)
			fire("CHAT_MSG_ADDON", "QWF", message, "PARTY", "Julia-Realm")
			assert.is_false(view.complete)
			assert.are.equal("incompatible", view.notices[1].reason)
		end
		assert.is_not_nil(findLog(records, "Unsupported addon protocol"))
		SlashCmdList.QUESTWITHFRIENDS("")
		assert.are.equal("incompatible", view.notices[1].reason)
		flush()
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		assert.same({}, view.notices)
	end)

	it("ignores unknown message kinds and malformed chunk headers within a supported protocol", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({})
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
		for _, message in ipairs({
			"1.0:H:extra",
			"1.0:X:extra",
			"1.0:P:p:42",
			"1.0:D:0:1:1:" .. payload,
			"1.0:D:100000001:1:1:" .. payload,
			"1.0:D:2:0:1:" .. payload,
			"1.0:D:2:2:1:" .. payload,
			"1.0:D:2:1:101:" .. payload,
			"1.0:D:2:1:1:",
			"1.0:D:2:1:1:" .. string.rep("x", 221),
			"1.0:D:0000000002:1:1:" .. payload,
			"1.0:D:2:0001:1:" .. payload,
			"1.0:D:2:1:1:" .. string.rep("x", 256),
		}) do
			fire("CHAT_MSG_ADDON", "QWF", message, "PARTY", "Julia-Realm")
			assert.is_true(view.complete)
		end
	end)

	it("migrates the combined preference without overwriting separate saved choices", function()
		_G.QuestWithFriendsDB = { showPersonalQuests = true }
		assert(loadfile("QuestWithFriends.lua"))()
		assert.is_true(QuestWithFriendsDB.showProfessionQuests)
		assert.is_true(QuestWithFriendsDB.showClassQuests)
		QuestWithFriendsDB.showClassQuests = false
		assert(loadfile("QuestWithFriends.lua"))()
		assert.is_true(QuestWithFriendsDB.showProfessionQuests)
		assert.is_false(QuestWithFriendsDB.showClassQuests)
		_G.QuestWithFriendsDB = { showPersonalQuests = false }
		assert(loadfile("QuestWithFriends.lua"))()
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
			if message:sub(1, 6) == "1.0:D:" then
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
			local part, data = message:match("^1%.0:D:%d+:(%d+):%d+:(.+)$")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
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
			data = message:match("^1%.0:D:%d+:%d+:%d+:(.+)$") or data
		end
		local quests = QuestWithFriends.Core.decode(data)
		assert.are.equal(101, quests[11].mapID)
		assert.is_nil(quests[12].mapID)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		assert.are.equal("Here", view.groups[1].title)
		assert.are.equal("Unknown", view.groups[2].title)
	end)

	it("marks a peer unknown when its snapshot cannot be shared", function()
		fire("PLAYER_ENTERING_WORLD")
		flush()
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		assert.is_true(view.complete)
		fire("CHAT_MSG_ADDON", "QWF", "1.0:X", "PARTY", "Julia-Realm")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. QuestWithFriends.Core.encode({}), "PARTY", "Julia-Realm")
		local share = view.share
		entries = {}
		share(42)
		entries = { { questID = 42, title = "Errand" } }
		party = false
		share(42)
		assert.same({}, pushed)
	end)

	it("renders the stabilized second scan even when its snapshot is unchanged", function()
		entries = { { questID = 42, title = "Errand" } }
		fire("PLAYER_ENTERING_WORLD")
		flush()
		local payload = QuestWithFriends.Core.encode({ [42] = { title = "Errand", state = "active", objectives = {} } })
		fire("CHAT_MSG_ADDON", "QWF", "1.0:D:1:1:1:" .. payload, "PARTY", "Julia-Realm")
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
		fire("CHAT_MSG_ADDON", "QWF", "1.0:H", "PARTY", "Julia-Realm")
		flush()
		assert.are.equal(sent + 1, #messages)
		assert.is_not_nil(messages[#messages]:match("^1%.0:D:"))
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
