test("TOC loads the addon and registers its slash command", function()
	assertType("table", QuestWithFriends.Core)
	assertType("function", QuestWithFriends.Panel.show)
	assertType("function", SlashCmdList.QUESTWITHFRIENDS)
	assertEquals("/qwf", SLASH_QUESTWITHFRIENDS1)
	assertTrue(QuestWithFriendsDB.zoneFilter)
	assertFalse(QuestWithFriendsDB.showProfessionQuests)
	assertFalse(QuestWithFriendsDB.showClassQuests)
end)

test("native debug setting shares the persistent slash-command preference", function()
	local setting = Settings.GetSetting("QuestWithFriendsDebugMode")
	assertNotNil(setting)
	assertEquals("Debug mode", setting:GetName())
	assertFalse(setting:GetValue())
	local originalAddonKit = AddonKit
	local levels = {}
	AddonKit = {
		SetLogLevel = function(name, level)
			assertEquals("QuestWithFriends", name)
			levels[#levels + 1] = level
		end,
	}
	local ok, err = pcall(function()
		setting:SetValue(true)
		assertTrue(QuestWithFriendsDB.debugMode)
		assertEquals("DEBUG", levels[#levels])
		SlashCmdList.QUESTWITHFRIENDS("debug off")
		assertFalse(setting:GetValue())
		assertFalse(QuestWithFriendsDB.debugMode)
		assertEquals("INFO", levels[#levels])
	end)
	setting:SetValue(false)
	AddonKit = originalAddonKit
	if not ok then
		error(err)
	end
end)

local function panelTexts()
	local texts = {}
	for _, region in ipairs({ QuestWithFriendsPanel:GetRegions() }) do
		if region:IsShown() and region:GetObjectType() == "FontString" then
			texts[#texts + 1] = region:GetText()
		end
	end
	return texts
end

local function filterChoice(text)
	local dropdown = QuestWithFriendsPanel.filter
	dropdown:OpenMenu()
	assertTrue(dropdown:IsMenuOpen())
	for _, child in ipairs({ dropdown.menu:GetChildren() }) do
		local description = child.GetElementDescription and child:GetElementDescription()
		if description and MenuUtil.GetElementText(description) == text then
			return child, description
		end
	end
	error("Filter option not found: " .. text)
end

local function chooseFilter(text)
	local button = filterChoice(text)
	button:Click()
end

local function receive(message, prefix, channel, sender)
	local name, realm = UnitFullName("party1")
	realm = realm and realm ~= "" and realm or GetRealmName()
	A_Admin.FireEvent(
		"CHAT_MSG_ADDON",
		prefix or "QWF",
		message,
		channel or "PARTY",
		sender or (name .. "-" .. realm:gsub("%s+", ""))
	)
end

local function sendSnapshot(quests, revision)
	local payload = QuestWithFriends.Core.encode(quests)
	local total = math.max(1, math.ceil(#payload / 220))
	for part = total, 1, -1 do
		receive(
			"1.0:D:"
				.. (revision or 100)
				.. ":"
				.. part
				.. ":"
				.. total
				.. ":"
				.. payload:sub((part - 1) * 220 + 1, part * 220)
		)
	end
end

local function outgoingSnapshot(messages)
	local parts = {}
	for _, message in ipairs(messages) do
		local part, data = message:match("^1%.0:D:%d+:(%d+):%d+:(.+)$")
		if part then
			parts[tonumber(part)] = data
		end
	end
	assertTrue(#parts > 0)
	local quests = QuestWithFriends.Core.decode(table.concat(parts))
	assertNotNil(quests)
	return quests
end

-- v0.1.32 drops timers queued inside timer callbacks. Pump short transport
-- timers on successive frames; watchdog timing is covered by the clocked suite.
local function partyTest(name, callback)
	async_test(name, function(done)
		local originalSend = C_ChatInfo.SendAddonMessage
		local originalAfter = C_Timer.After
		local observer = CreateFrame("Frame")
		local pendingTimers = {}
		C_Timer.After = function(delay, fn)
			if delay < 15 then
				pendingTimers[#pendingTimers + 1] = fn
			end
		end
		local messages = {}
		C_ChatInfo.SendAddonMessage = function(prefix, message, channel)
			assertEquals("QWF", prefix)
			assertEquals("PARTY", channel)
			messages[#messages + 1] = message
		end
		local function finish(check)
			done(function()
				local ok, err = pcall(check)
				observer:SetScript("OnUpdate", nil)
				A_Admin.SetPartySize(0)
				C_ChatInfo.SendAddonMessage = originalSend
				C_Timer.After = originalAfter
				if not ok then
					error(err)
				end
			end)
		end
		local followUp
		local function run()
			local ok, result = pcall(function()
				return callback(outgoingSnapshot(messages), messages)
			end)
			if not ok then
				finish(function()
					error(result)
				end)
			elseif type(result) == "function" then
				followUp = result
			else
				finish(function() end)
			end
		end
		local ok, err = pcall(function()
			A_Admin.SetPartySize(0)
			QuestWithFriendsDB.zoneFilter = true
			QuestWithFriendsDB.showProfessionQuests = false
			QuestWithFriendsDB.showClassQuests = false
			QuestWithFriendsDB.collapsedQuests = {}
			A_Admin.SetPartySize(1)
			A_Admin.SetPartyMember(1, "Julia", 8, 80)
			A_Admin.FireEvent("PLAYER_ENTERING_WORLD")
			observer:SetScript("OnUpdate", function()
				if #pendingTimers > 0 then
					local queued = pendingTimers
					pendingTimers = {}
					local ok, err = pcall(function()
						for _, fn in ipairs(queued) do
							fn()
						end
					end)
					if not ok then
						finish(function()
							error(err)
						end)
					end
				elseif followUp then
					finish(followUp)
				else
					run()
				end
			end)
		end)
		if not ok then
			observer:SetScript("OnUpdate", nil)
			A_Admin.SetPartySize(0)
			C_ChatInfo.SendAddonMessage = originalSend
			C_Timer.After = originalAfter
			done(function()
				error(err)
			end)
		end
	end)
end

test("solo preview uses the real panel and filters without sending or sharing sample quests", function()
	A_Admin.SetPartySize(0)
	QuestWithFriendsDB.zoneFilter = true
	QuestWithFriendsDB.showProfessionQuests = false
	QuestWithFriendsDB.showClassQuests = false
	local originalSend, originalPush = C_ChatInfo.SendAddonMessage, QuestLogPushQuest
	local sends, shares = 0, 0
	C_ChatInfo.SendAddonMessage = function()
		sends = sends + 1
	end
	QuestLogPushQuest = function()
		shares = shares + 1
	end
	local ok, err = pcall(function()
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		local panel = QuestWithFriendsPanel
		assertTrue(panel:IsShown())
		assertEquals("Preview · Sample party data", panel.status:GetText())
		assertContains(panelTexts(), "The Lost Supplies")
		assertContains(panelTexts(), "Alex: Gnolls slain 5/8")
		assertContains(panelTexts(), "Alex: Ready to turn in")
		assertContains(panelTexts(), "You: Completed")
		local setting = Settings.GetSetting("QuestWithFriendsPreviewMode")
		assertTrue(setting:GetValue())
		local foundShare = false
		for _, child in ipairs({ panel:GetChildren() }) do
			if child:GetObjectType() == "Button" and child:GetText() == "Share" and child:IsShown() then
				foundShare = true
				assertFalse(child:IsEnabled())
				child:Click()
			end
		end
		assertTrue(foundShare)
		chooseFilter("Current zone only")
		assertContains(panelTexts(), "Delivery to the Next Town")
		chooseFilter("Show profession quests")
		assertContains(panelTexts(), "Fresh Fish for the Camp")
		chooseFilter("Show class quests")
		assertContains(panelTexts(), "A Lesson in Courage")
		assertEquals(0, sends)
		assertEquals(0, shares)
		panel.stopPreview:Click()
		assertFalse(panel:IsShown())
		assertFalse(setting:GetValue())
		SlashCmdList.QUESTWITHFRIENDS("preview on")
		A_Admin.SetPartySize(1)
		A_Admin.SetPartyMember(1, "Julia", 8, 80)
		assertFalse(setting:GetValue())
		assertEquals("Party status incomplete", panel.status:GetText())
		assertFalse(panel.stopPreview:IsShown())
	end)
	SlashCmdList.QUESTWITHFRIENDS("preview off")
	A_Admin.SetPartySize(0)
	QuestWithFriendsDB.zoneFilter = true
	QuestWithFriendsDB.showProfessionQuests = false
	QuestWithFriendsDB.showClassQuests = false
	C_ChatInfo.SendAddonMessage, QuestLogPushQuest = originalSend, originalPush
	if not ok then
		error(err)
	end
end)

partyTest("joining warns about unknown members and leaving hides the panel", function(_, messages)
	assertContains(messages, "1.0:H")
	assertTrue(QuestWithFriendsPanel:IsShown())
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	assertContains(panelTexts(), "Julia: Quest With Friends not detected")
	A_Admin.SetPartySize(0)
	assertFalse(QuestWithFriendsPanel:IsShown())
end)

partyTest("matching snapshots show party in sync", function(quests)
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	assertAlmostEquals(78, QuestWithFriendsPanel:GetHeight())
	assertEquals("Filters", QuestWithFriendsPanel.filter:GetText())
	assertEquals("Current zone · Standard quests", QuestWithFriendsPanel.scope:GetText())
end)

partyTest("profession and class menu choices independently filter snapshot classifications", function(quests)
	quests[987654] = { title = "Profession errand", state = "active", objectives = {}, category = "profession" }
	quests[987653] = { title = "Class errand", state = "active", objectives = {}, category = "class" }
	sendSnapshot(quests)
	local panel = QuestWithFriendsPanel
	local function hasTitle(title)
		for _, text in ipairs(panelTexts()) do
			if text == title then
				return true
			end
		end
		return false
	end
	assertEquals("Current zone · Standard quests", panel.scope:GetText())
	assertEquals("Party in sync", panel.status:GetText())
	local _, profession = filterChoice("Show profession quests")
	local _, class = filterChoice("Show class quests")
	assertFalse(profession:IsSelected())
	assertFalse(class:IsSelected())
	chooseFilter("Show profession quests")
	assertTrue(QuestWithFriendsDB.showProfessionQuests)
	assertFalse(QuestWithFriendsDB.showClassQuests)
	assertEquals("Current zone · Includes profession quests", panel.scope:GetText())
	assertTrue(hasTitle("Profession errand"))
	assertFalse(hasTitle("Class errand"))
	chooseFilter("Show class quests")
	assertTrue(QuestWithFriendsDB.showClassQuests)
	assertEquals("Current zone · All quest types", panel.scope:GetText())
	assertTrue(hasTitle("Profession errand"))
	assertTrue(hasTitle("Class errand"))
	chooseFilter("Show profession quests")
	assertFalse(hasTitle("Profession errand"))
	assertTrue(hasTitle("Class errand"))
	assertEquals("Current zone · Includes class quests", panel.scope:GetText())
	chooseFilter("Show class quests")
	assertFalse(QuestWithFriendsDB.showClassQuests)
	assertEquals("Current zone · Standard quests", panel.scope:GetText())
	assertEquals("Filters", panel.filter:GetText())
	assertEquals("Party in sync", panel.status:GetText())
	assertTrue(panel.filter:IsMenuOpen())
	panel.filter:CloseMenu()
	assertFalse(panel.filter:IsMenuOpen())
end)

partyTest("partial and duplicate chunks stay unknown until reverse-order assembly completes", function(quests)
	quests[987655] = { title = string.rep("Completed quest ", 17), state = "completed", objectives = {} }
	local payload = QuestWithFriends.Core.encode(quests)
	local total = math.ceil(#payload / 220)
	assertTrue(total > 1)
	for part = total, 2, -1 do
		local message = "1.0:D:100:" .. part .. ":" .. total .. ":" .. payload:sub((part - 1) * 220 + 1, part * 220)
		receive(message)
		receive(message)
		assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	end
	receive("1.0:D:100:1:" .. total .. ":" .. payload:sub(1, 220))
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
end)

partyTest("remote quest differences render and stale snapshots cannot replace them", function(quests)
	sendSnapshot(quests, 100)
	local original = QuestWithFriends.Core.encode(quests)
	quests[987654] = { title = "Simulator errand", state = "active", objectives = {} }
	sendSnapshot(quests, 101)
	assertEquals("Party out of sync", QuestWithFriendsPanel.status:GetText())
	assertContains(panelTexts(), "Simulator errand")
	assertContains(panelTexts(), "You: Missing")
	receive("1.0:D:100:1:1:" .. original:sub(1, 220))
	receive("1.0:D:101:1:1:broken")
	assertContains(panelTexts(), "Simulator errand")
end)

partyTest("wrong prefixes, channels, senders and malformed payloads stay unknown", function(quests)
	local message = "1.0:D:100:1:1:" .. QuestWithFriends.Core.encode({})
	receive(message, "OTHER")
	receive(message, nil, "RAID")
	receive(message, nil, nil, "Stranger-OtherRealm")
	receive("1.0:D:100:1:1:broken")
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
end)

partyTest("a peer handshake preserves cached data with a refreshing notice", function(quests)
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	receive("1.0:X")
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	sendSnapshot(quests, 101)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	receive("1.0:H")
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	assertContains(panelTexts(), "Julia: Refreshing · showing last snapshot")
end)

partyTest("the real zone menu checkbox reveals distant quests and saves the selection", function(quests)
	assertNotNil(C_Map.GetBestMapForUnit("player"))
	quests[987654] = { title = "Distant errand", state = "active", objectives = {}, mapID = 999999 }
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	chooseFilter("Current zone only")
	assertFalse(QuestWithFriendsDB.zoneFilter)
	assertEquals("All zones · Standard quests", QuestWithFriendsPanel.scope:GetText())
	assertEquals("Party out of sync", QuestWithFriendsPanel.status:GetText())
	assertContains(panelTexts(), "Distant errand")
	assertContains(panelTexts(), "You: Missing")
	chooseFilter("Current zone only")
	assertTrue(QuestWithFriendsDB.zoneFilter)
	assertEquals("Current zone · Standard quests", QuestWithFriendsPanel.scope:GetText())
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	A_Admin.SetPartySize(0)
	assertFalse(QuestWithFriendsPanel.filter:IsMenuOpen())
end)

partyTest("panel bounds long lists and hides reused rows when back in sync", function(quests)
	local groups = {}
	for index = 1, 25 do
		groups[index] = {
			questID = index,
			title = "Errand " .. index,
			differences = { { player = "Julia", kind = "missing", reason = "missing" } },
		}
	end
	QuestWithFriends.Panel.show(groups, true, true, function() end)
	local texts = panelTexts()
	assertContains(texts, "Errand 9")
	assertContains(texts, "+16 more quests with differences")
	assertEquals(22, #texts)
	assertTrue(QuestWithFriendsPanel:GetHeight() > 58)
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	assertEquals(3, #panelTexts())
	assertAlmostEquals(78, QuestWithFriendsPanel:GetHeight())
end)

partyTest("status icons render once per detail and hide when rows are reused", function(quests)
	local groups, complete, notices = QuestWithFriends.Core.compare({
		[1] = { title = "Local", state = "active", objectives = {} },
		[2] = { title = "Shared", state = "active", objectives = { { text = "Gnolls", have = 8, need = 8 } } },
		[3] = { title = "Ready", state = "active", objectives = {} },
	}, {
		{
			name = "Julia",
			quests = {
				[2] = { title = "Shared", state = "active", objectives = { { text = "Gnolls", have = 2, need = 8 } } },
				[3] = { title = "Ready", state = "ready", objectives = {} },
			},
		},
		{ name = "Bob" },
	})
	QuestWithFriends.Panel.show(groups, complete, true, nil, nil, notices)
	local icons = {}
	for _, region in ipairs({ QuestWithFriendsPanel:GetRegions() }) do
		if region:IsShown() and region:GetObjectType() == "Texture" and region:GetWidth() == 14 then
			icons[#icons + 1] = region
		end
	end
	assertEquals(5, #icons)
	assertContains(panelTexts(), "Local")
	assertContains(panelTexts(), "Julia: Missing")
	assertContains(panelTexts(), "Julia: Gnolls 2/8")
	assertContains(panelTexts(), "You: Still in progress")
	assertContains(panelTexts(), "Julia: Ready to turn in")
	assertContains(panelTexts(), "Bob: Quest With Friends not detected")
	sendSnapshot(quests)
	for _, icon in ipairs(icons) do
		assertFalse(icon:IsShown())
	end
end)

partyTest("real Share buttons use current row IDs and disappear when differences clear", function(quests)
	local shared
	local function show(id)
		QuestWithFriends.Panel.show(
			{
				{
					questID = id,
					title = "Simulator errand",
					differences = {
						{ player = "Julia", kind = "missing", reason = "missing" },
						{ player = "Bob", kind = "missing", reason = "missing" },
					},
					shareQuestID = id,
				},
			},
			true,
			true,
			nil,
			function(questID)
				shared = questID
			end
		)
	end
	show(42)
	local shareButton
	local shareCount, titleCount = 0, 0
	for _, child in ipairs({ QuestWithFriendsPanel:GetChildren() }) do
		if child:IsShown() and child:GetObjectType() == "Button" and child:GetText() == "Share" then
			shareButton = child
			shareCount = shareCount + 1
		end
	end
	for _, text in ipairs(panelTexts()) do
		if text == "Simulator errand" then
			titleCount = titleCount + 1
		end
	end
	assertEquals(1, shareCount)
	assertEquals(1, titleCount)
	assertContains(panelTexts(), "Julia: Missing")
	assertContains(panelTexts(), "Bob: Missing")
	assertNotNil(shareButton)
	assertEquals(nil, shared)
	shareButton:Click()
	assertEquals(42, shared)
	show(7)
	shareButton:Click()
	assertEquals(7, shared)
	shareButton:GetScript("OnEnter")(shareButton)
	assertTrue(GameTooltip:IsOwned(shareButton))
	sendSnapshot(quests)
	assertFalse(shareButton:IsShown())
	assertFalse(GameTooltip:IsShown())
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
end)

partyTest("quest heading clicks persist collapse choices without hiding sharing or notices", function(quests)
	local title = string.rep("Long simulator quest title ", 10)
	local groups = {
		{
			questID = 42,
			shareQuestID = 77,
			title = title,
			differences = {
				{ player = "Julia", kind = "missing", reason = "missing" },
				{ player = "Bob", kind = "missing", reason = "missing" },
			},
		},
		{
			questID = 43,
			title = "Other errand",
			differences = { { player = "You", kind = "needs", reason = "active" } },
		},
	}
	local shared
	local function show()
		QuestWithFriends.Panel.show(groups, false, true, nil, function(id)
			shared = id
		end, { { player = "Charlie", reason = "waiting" } })
	end
	show()
	local heading
	for _, region in ipairs({ QuestWithFriendsPanel:GetRegions() }) do
		if region:GetObjectType() == "FontString" and region:GetText() == title then
			heading = region
		end
	end
	assertNotNil(heading)
	local toggle, share = heading.toggleButton, heading.shareButton
	assertFalse(toggle.summary:IsShown())
	assertAlmostEquals(-math.pi / 2, toggle.indicator:GetRotation())
	assertContains(panelTexts(), "Julia: Missing")
	local expandedHeight = QuestWithFriendsPanel:GetHeight()
	toggle:Click()
	assertTrue(QuestWithFriendsDB.collapsedQuests[42])
	assertEquals(nil, QuestWithFriendsDB.collapsedQuests[77])
	assertAlmostEquals(0, toggle.indicator:GetRotation())
	assertEquals("2 missing", toggle.summary:GetText())
	assertTrue(toggle.summary:IsShown())
	assertTrue(share:IsShown())
	assertTrue(QuestWithFriendsPanel:GetHeight() < expandedHeight)
	assertTrue(heading:GetHeight() < 20)
	local shareLeft = share:GetLeft()
	assertTrue(toggle:GetRight() < shareLeft)
	assertTrue(heading:GetRight() < toggle.summary:GetLeft())
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	assertContains(panelTexts(), "Charlie: Waiting for quest snapshot · /qwf to refresh")
	assertContains(panelTexts(), "You: Still in progress")
	share:Click()
	assertEquals(77, shared)
	assertTrue(QuestWithFriendsDB.collapsedQuests[42])
	sendSnapshot(quests)
	assertFalse(toggle:IsShown())
	show()
	assertAlmostEquals(0, toggle.indicator:GetRotation())
	toggle:GetScript("OnEnter")(toggle)
	assertTrue(GameTooltip:IsOwned(toggle))
	toggle:Click()
	assertFalse(GameTooltip:IsShown())
	assertEquals(nil, QuestWithFriendsDB.collapsedQuests[42])
	assertContains(panelTexts(), "Julia: Missing")
	assertFalse(toggle.summary:IsShown())
end)

partyTest("quest event bursts and slash refreshes queue only one new snapshot", function(_, messages)
	local before = #messages
	local chunks = 0
	for _, message in ipairs(messages) do
		if message:match("^1%.0:D:") then
			chunks = chunks + 1
		end
	end
	A_Admin.FireEvent("QUEST_LOG_UPDATE")
	A_Admin.FireEvent("QUEST_LOG_UPDATE")
	SlashCmdList.QUESTWITHFRIENDS("")
	SlashCmdList.QUESTWITHFRIENDS("")
	assertEquals(before, #messages)
	return function()
		assertEquals("1.0:H", messages[before + 1])
		assertEquals(before + 1 + chunks, #messages)
	end
end)

partyTest("higher minors and unknown optional extensions preserve baseline comparisons", function(quests)
	quests[987654] = {
		title = "Future profession errand",
		state = "active",
		category = "profession",
		objectives = {},
		extensions = { chain_id = "123:4", state = "must not override active" },
	}
	local core = QuestWithFriends.Core
	local minor = core.PROTOCOL_MINOR
	core.PROTOCOL_MINOR = 7
	local payload = core.encode(quests, { optional_feature = "enabled" })
	core.PROTOCOL_MINOR = minor
	local total = math.ceil(#payload / 220)
	receive("1.7:H")
	for part = total, 1, -1 do
		receive("1.7:D:100:" .. part .. ":" .. total .. ":" .. payload:sub((part - 1) * 220 + 1, part * 220))
	end
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	chooseFilter("Show profession quests")
	assertContains(panelTexts(), "Future profession errand")
	assertEquals("Party out of sync", QuestWithFriendsPanel.status:GetText())
end)

partyTest("invalid protocol envelopes show a warning and valid data restores sync", function(quests)
	sendSnapshot(quests)
	for index, message in ipairs({ "2.0:H", "broken", "1.00:H", "1.0:" }) do
		receive(message)
		assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
		assertContains(panelTexts(), "Julia: Incompatible addon protocol · update addon")
		sendSnapshot(quests, 100 + index)
		assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	end
end)

partyTest("drag-stop saves real frame coordinates relative to UIParent", function()
	local panel = QuestWithFriendsPanel
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 140, -280)
	panel:GetScript("OnDragStop")(panel)
	assertAlmostEquals(140, QuestWithFriendsDB.panelPosition.x)
	assertAlmostEquals(-280, QuestWithFriendsDB.panelPosition.y)
	local point, relativeTo, relativePoint, x, y = panel:GetPoint(1)
	assertEquals("TOPLEFT", point)
	assertEquals(UIParent, relativeTo)
	assertEquals("TOPLEFT", relativePoint)
	assertAlmostEquals(140, x)
	assertAlmostEquals(-280, y)
end)
