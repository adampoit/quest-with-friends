local QuestWithFriendsDB = QuestWithFriends.db

test("TOC loads the addon and registers its slash command", function()
	assertType("table", QuestWithFriends.Core)
	assertType("function", QuestWithFriends.Panel.show)
	assertType("function", SlashCmdList.QUESTWITHFRIENDS)
	assertEquals("/qwf", SLASH_QUESTWITHFRIENDS1)
	assertTrue(QuestWithFriendsDB.zoneFilter)
	assertFalse(QuestWithFriendsDB.showProfessionQuests)
	assertFalse(QuestWithFriendsDB.showClassQuests)
	assertEquals("smart", QuestWithFriendsDB.sortMode)
end)

test("native debug setting shares the persistent slash-command preference", function()
	local setting = Settings.GetSetting(QuestWithFriends.name .. "DebugMode")
	assertNotNil(setting)
	assertEquals("Debug mode", setting:GetName())
	assertFalse(setting:GetValue())
	local originalAddonKit = AddonKit
	local levels = {}
	AddonKit = {
		SetLogLevel = function(name, level)
			assertEquals(QuestWithFriends.name, name)
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

local function panelRegions()
	local regions = { QuestWithFriendsPanel:GetRegions() }
	for _, region in ipairs({ QuestWithFriendsPanel.content:GetRegions() }) do
		regions[#regions + 1] = region
	end
	return regions
end

local function panelTexts()
	local regions, texts = {}, {}
	for _, region in ipairs(panelRegions()) do
		if region:IsShown() and region:GetObjectType() == "FontString" then
			regions[#regions + 1] = region
		end
	end
	table.sort(regions, function(a, b)
		return a:GetTop() > b:GetTop()
	end)
	for _, region in ipairs(regions) do
		texts[#texts + 1] = region:GetText()
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

local function rightClickHeading(row)
	-- v0.1.32's Button:Click does not forward the right-button argument.
	local button = row.toggleButton
	button:GetScript("OnClick")(button, "RightButton")
end

local function abandonAction(row)
	rightClickHeading(row)
	local menu = Menu.GetManager():GetOpenMenu()
	assertNotNil(menu)
	assertTrue(menu:IsShown())
	assertEquals(row.toggleButton, menu:GetOwnerRegion())
	for _, child in ipairs({ menu:GetChildren() }) do
		local description = child.GetElementDescription and child:GetElementDescription()
		if description and MenuUtil.GetElementText(description) == "Abandon quest…" then
			assertTrue(child:IsShown())
			return child, menu
		end
	end
	error("Abandon quest action not found")
end

local function abandonableHeading(quests)
	for _, row in ipairs(panelRegions()) do
		if row:IsShown() and row.groupID then
			local quest, id = QuestWithFriends.Core.matchQuest(quests, row.groupID)
			if quest and quest.state ~= "completed" and C_QuestLog.CanAbandonQuest(id) then
				return row, id, quest.title
			end
		end
	end
	error("No abandonable local quest heading found")
end

local function withAbandonQuestAPI(items, callback)
	local names = {
		"CanAbandonQuest",
		"GetSelectedQuest",
		"SetSelectedQuest",
		"SetAbandonQuest",
		"GetAbandonQuest",
		"GetAbandonQuestItems",
		"AbandonQuest",
	}
	local originals = {}
	for _, name in ipairs(names) do
		originals[name] = C_QuestLog[name]
	end
	local previousSelection = C_QuestLog.GetSelectedQuest()
	local selected, pending, abandoned = previousSelection or 0, nil, {}
	-- Supply missing game-API behavior, not replacements for the runtime, helper or dialogs.
	C_QuestLog.CanAbandonQuest = function(id)
		local index = C_QuestLog.GetLogIndexForQuestID(id)
		return index ~= nil and index > 0
	end
	C_QuestLog.GetSelectedQuest = function()
		return selected
	end
	C_QuestLog.SetSelectedQuest = function(id)
		selected = id
	end
	C_QuestLog.SetAbandonQuest = function()
		pending = C_QuestLog.GetSelectedQuest()
	end
	C_QuestLog.GetAbandonQuest = function()
		return pending
	end
	C_QuestLog.GetAbandonQuestItems = function()
		return items
	end
	C_QuestLog.AbandonQuest = function()
		abandoned[#abandoned + 1] = pending
	end
	local ok, err = pcall(function()
		callback(abandoned)
	end)
	Menu.GetManager():CloseMenus()
	StaticPopup_Hide("ABANDON_QUEST")
	StaticPopup_Hide("ABANDON_QUEST_WITH_ITEMS")
	for _, name in ipairs(names) do
		C_QuestLog[name] = originals[name]
	end
	C_QuestLog.SetSelectedQuest(previousSelection)
	if not ok then
		error(err)
	end
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
			"1.1:D:"
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
		local part, data = message:match("^1%.1:D:%d+:(%d+):%d+:(.+)$")
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
		assertContains(panelTexts(), QuestWithFriends.title)
		assertEquals("GameFontHighlightSmall", panel.status:GetFontObject():GetName())
		assertEquals("LEFT", panel.status:GetJustifyH())
		assertContains(panelTexts(), "The Lost Supplies")
		assertContains(panelTexts(), "Alex: Gnolls slain 5/8")
		assertContains(panelTexts(), "Alex: Ready to turn in")
		assertContains(panelTexts(), "You: Completed")
		local setting = Settings.GetSetting(QuestWithFriends.name .. "PreviewMode")
		assertTrue(setting:GetValue())
		local foundShare = false
		for _, child in ipairs({ panel.content:GetChildren() }) do
			if child:GetObjectType() == "Button" and child:GetText() == "Share" and child:IsShown() then
				foundShare = true
				assertFalse(child:IsEnabled())
				child:Click()
			end
		end
		assertTrue(foundShare)
		Menu.GetManager():CloseMenus()
		for _, row in ipairs(panelRegions()) do
			if row:IsShown() and row.toggleButton and row.groupID then
				rightClickHeading(row)
				assertFalse(Menu.GetManager():IsAnyMenuOpen())
			end
		end
		assertEquals(nil, StaticPopup_FindVisible("ABANDON_QUEST"))
		assertEquals(nil, StaticPopup_FindVisible("ABANDON_QUEST_WITH_ITEMS"))
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
		assertEquals("GameFontHighlight", panel.status:GetFontObject():GetName())
		assertEquals("LEFT", panel.status:GetJustifyH())
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

local function screenshotSettings()
	for _, category in ipairs(SettingsPanel:GetAllCategories()) do
		if category:GetName() == QuestWithFriends.title then
			return category, SettingsPanel:GetLayout(category)
		end
	end
	error("Addon settings category not found")
end

local function screenshotControl(name)
	local _, layout = screenshotSettings()
	for _, initializer in ipairs(layout:GetInitializers()) do
		if initializer:GetName() == name then
			return initializer
		end
	end
	error("Screenshot control not found: " .. name)
end

local function chooseScreenshotScenario(name)
	local category = screenshotSettings()
	-- The simulator's C_SettingsUtil opener is a stub; use the native panel method.
	SettingsPanel:OpenToCategory(category:GetID())
	local initializer = screenshotControl(name)
	assertTrue(initializer:ShouldShow())
	local scrollBox = SettingsPanel:GetSettingsList().ScrollBox
	scrollBox:ScrollToElementData(initializer, ScrollBoxConstants.AlignBegin)
	local control = scrollBox:FindFrame(initializer)
	assertNotNil(control)
	assertTrue(control.Button:IsEnabled())
	control.Button:Click()
end

if QuestWithFriends.isDevelopment then
	test("screenshot slash command reveals only its settings section", function()
		A_Admin.SetPartySize(0)
		local category = screenshotSettings()
		SettingsPanel:OpenToCategory(category:GetID())
		local header = screenshotControl("Screenshot tools")
		assertFalse(header:ShouldShow())
		local provider = SettingsPanel:GetSettingsList().ScrollBox:GetDataProvider()
		assertEquals(3, provider:GetSize())
		SlashCmdList.QUESTWITHFRIENDS("screenshot")
		assertTrue(header:ShouldShow())
		assertEquals(8, provider:GetSize())
		assertFalse(QuestWithFriendsPanel:IsShown())
		SlashCmdList.QUESTWITHFRIENDS("screenshot")
		assertFalse(header:ShouldShow())
		assertEquals(3, provider:GetSize())
		assertTrue(SettingsPanel:IsShown())
		SettingsPanel:Hide()
	end)

	test("screenshot scenarios look live while sample sharing stays inert", function()
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
			SlashCmdList.QUESTWITHFRIENDS("screenshot on")
			chooseScreenshotScenario("Quest differences")
			assertFalse(SettingsPanel:IsShown())
			local panel = QuestWithFriendsPanel
			assertTrue(panel:IsShown())
			assertEquals("Party out of sync", panel.status:GetText())
			assertEquals("Quest With Friends", panel.heading:GetText())
			assertEquals("GameFontHighlight", panel.status:GetFontObject():GetName())
			assertFalse(panel.stopPreview:IsShown())
			assertContains(panelTexts(), "Alex: Gnolls slain 5/8")
			assertContains(panelTexts(), "Alex: Linen Cloth 3/10")
			assertContains(panelTexts(), "You: Linen Cloth 10/10 · 2 spare")
			assertContains(panelTexts(), "Sam: Linen Cloth 10/10 · 2 spare")
			assertContains(panelTexts(), "You: Scouts rescued 0/1")
			assertContains(panelTexts(), "Alex: Bridge timbers collected 4/6")
			local foundShare = false
			for _, child in ipairs({ panel.content:GetChildren() }) do
				if child:GetObjectType() == "Button" and child:GetText() == "Share" and child:IsShown() then
					foundShare = true
					assertTrue(child:IsEnabled())
					child:Click()
				end
			end
			assertTrue(foundShare)
			chooseFilter("Current zone only")
			assertContains(panelTexts(), "Delivery to the Next Town")
			assertEquals(0, sends)
			assertEquals(0, shares)
			SlashCmdList.QUESTWITHFRIENDS("preview on")
			assertEquals("Preview · Sample party data", panel.status:GetText())
			assertEquals(QuestWithFriends.title, panel.heading:GetText())
			assertTrue(panel.stopPreview:IsShown())
			chooseScreenshotScenario("Collapsed headings")
			assertFalse(panel.stopPreview:IsShown())
			local summaries = {}
			for _, child in ipairs({ panel.content:GetChildren() }) do
				if child.summary and child.summary:IsShown() then
					summaries[#summaries + 1] = child.summary:GetText()
				end
			end
			assertContains(summaries, "2 missing")
			assertContains(summaries, "3 affected")
			chooseScreenshotScenario("Party in sync")
			assertEquals("Party in sync", panel.status:GetText())
			chooseFilter("Current zone only")
			assertEquals("Party in sync", panel.status:GetText())
			chooseScreenshotScenario("Screenshot view")
			assertFalse(panel:IsShown())
			chooseScreenshotScenario("Quest differences")
			assertTrue(panel:IsShown())
			A_Admin.SetPartySize(1)
			A_Admin.SetPartyMember(1, "Julia", 8, 80)
			assertEquals("Party status incomplete", panel.status:GetText())
			assertFalse(Settings.GetSetting(QuestWithFriends.name .. "PreviewMode"):GetValue())
		end)
		SlashCmdList.QUESTWITHFRIENDS("preview off")
		SlashCmdList.QUESTWITHFRIENDS("screenshot off")
		SettingsPanel:Hide()
		A_Admin.SetPartySize(0)
		QuestWithFriendsDB.zoneFilter = true
		C_ChatInfo.SendAddonMessage, QuestLogPushQuest = originalSend, originalPush
		if not ok then
			error(err)
		end
	end)
else
	test("release settings omit screenshot tools", function()
		local _, layout = screenshotSettings()
		assertEquals(3, #layout:GetInitializers())
		assertEquals(nil, QuestWithFriends.Development)
	end)
end

test("preview footer stays left while scroll controls align right at different sizes", function()
	A_Admin.SetPartySize(0)
	local savedSize, savedLocked = QuestWithFriendsDB.panelSize, QuestWithFriendsDB.panelLocked
	local ok, err = pcall(function()
		for _, width in ipairs({ 300, 348, 480 }) do
			QuestWithFriendsDB.panelSize = { width = width, height = 180 }
			SlashCmdList.QUESTWITHFRIENDS("preview on")
			local panel = QuestWithFriendsPanel
			for _, locked in ipairs({ true, false }) do
				QuestWithFriends.Panel.setLocked(locked)
				assertAlmostEquals(14, panel.stopPreview:GetLeft() - panel:GetLeft())
				assertAlmostEquals(
					8 + math.max(0, (panel.status:GetStringHeight() - 22) / 2),
					panel.stopPreview:GetBottom() - panel:GetBottom()
				)
				local point, relative, relativePoint, x, y = panel.status:GetPoint()
				assertEquals("LEFT", point)
				assertEquals(panel.stopPreview, relative)
				assertEquals("RIGHT", relativePoint)
				assertEquals(8, x)
				assertEquals(0, y)
				assertTrue(panel.status:GetBottom() >= panel:GetBottom() + 8)
				assertTrue(panel.status:GetTop() < panel.scroll:GetBottom())
				if not locked then
					assertTrue(panel.status:GetRight() < panel.resize:GetLeft())
				end
				assertAlmostEquals(10, panel:GetRight() - panel.filter:GetRight())
				assertAlmostEquals(10, panel:GetTop() - panel.filter:GetTop())
				assertAlmostEquals(
					panel.filter:GetTop() - panel.filter:GetHeight() / 2,
					panel.lock:GetTop() - panel.lock:GetHeight() / 2
				)
				local scrollBar = panel.scroll.ScrollBar
				assertTrue(scrollBar:IsShown())
				assertAlmostEquals(10, panel:GetRight() - scrollBar.ScrollUpButton:GetRight())
				assertAlmostEquals(10, panel:GetRight() - scrollBar.ScrollDownButton:GetRight())
				assertAlmostEquals(panel.scroll:GetTop(), scrollBar.ScrollUpButton:GetTop())
				assertAlmostEquals(panel.scroll:GetBottom(), scrollBar.ScrollDownButton:GetBottom())
				assertTrue(panel.stopPreview:GetRight() < panel.resize:GetLeft())
			end
		end
	end)
	SlashCmdList.QUESTWITHFRIENDS("preview off")
	QuestWithFriendsDB.panelSize = savedSize
	QuestWithFriends.Panel.setLocked(savedLocked)
	if not ok then
		error(err)
	end
end)

partyTest("joining warns about unknown members and leaving hides the panel", function(_, messages)
	assertContains(messages, "1.1:H")
	assertTrue(QuestWithFriendsPanel:IsShown())
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	assertContains(panelTexts(), "Julia: Quest With Friends not detected")
	A_Admin.SetPartySize(0)
	assertFalse(QuestWithFriendsPanel:IsShown())
end)

partyTest("matching snapshots show party in sync", function(quests)
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	assertAlmostEquals(82, QuestWithFriendsPanel:GetHeight())
	assertEquals("View", QuestWithFriendsPanel.filter:GetText())
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
	assertEquals("View", panel.filter:GetText())
	assertEquals("Party in sync", panel.status:GetText())
	assertTrue(panel.filter:IsMenuOpen())
	panel.filter:CloseMenu()
	assertFalse(panel.filter:IsMenuOpen())
end)

partyTest("native sort radios switch between recent activity and alphabetical order", function(quests)
	quests[987654] = { title = "Alpha sort sample", state = "active", objectives = {} }
	quests[987653] = {
		title = "Zeta sort sample",
		state = "active",
		objectives = { { text = "Gnolls", have = 0, need = 8 } },
	}
	QuestWithFriendsDB.sortMode = "smart"
	sendSnapshot(quests, 100)
	local function firstSample()
		for _, text in ipairs(panelTexts()) do
			if text == "Alpha sort sample" or text == "Zeta sort sample" then
				return text
			end
		end
	end
	assertEquals("Alpha sort sample", firstSample())
	quests[987653].objectives[1].have = 1
	sendSnapshot(quests, 101)
	assertEquals("Zeta sort sample", firstSample())
	local _, smart = filterChoice("Smart")
	local _, title = filterChoice("Title A–Z")
	assertTrue(smart:IsSelected())
	assertFalse(title:IsSelected())
	chooseFilter("Title A–Z")
	assertEquals("title", QuestWithFriendsDB.sortMode)
	assertEquals("Alpha sort sample", firstSample())
	local _, selected = filterChoice("Title A–Z")
	assertTrue(selected:IsSelected())
	chooseFilter("Smart")
	assertEquals("smart", QuestWithFriendsDB.sortMode)
	assertEquals("Zeta sort sample", firstSample())
	sendSnapshot(quests, 102)
	assertEquals("Zeta sort sample", firstSample())
end)

partyTest("partial and duplicate chunks stay unknown until reverse-order assembly completes", function(quests)
	quests[987655] = { title = string.rep("Completed quest ", 17), state = "completed", objectives = {} }
	local payload = QuestWithFriends.Core.encode(quests)
	local total = math.ceil(#payload / 220)
	assertTrue(total > 1)
	for part = total, 2, -1 do
		local message = "1.1:D:100:" .. part .. ":" .. total .. ":" .. payload:sub((part - 1) * 220 + 1, part * 220)
		receive(message)
		receive(message)
		assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	end
	receive("1.1:D:100:1:" .. total .. ":" .. payload:sub(1, 220))
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
	receive("1.1:D:100:1:1:" .. original:sub(1, 220))
	receive("1.1:D:101:1:1:broken")
	assertContains(panelTexts(), "Simulator errand")
end)

partyTest("wrong prefixes, channels, senders and malformed payloads stay unknown", function(quests)
	local message = "1.1:D:100:1:1:" .. QuestWithFriends.Core.encode({})
	receive(message, "OTHER")
	receive(message, nil, "RAID")
	receive(message, nil, nil, "Stranger-OtherRealm")
	receive("1.1:D:100:1:1:broken")
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
end)

partyTest("a peer handshake preserves cached data with a refreshing notice", function(quests)
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	receive("1.1:X")
	assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
	sendSnapshot(quests, 101)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	receive("1.1:H")
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
	assertContains(texts, "Errand 25")
	assertEquals(53, #texts)
	assertAlmostEquals(360, QuestWithFriendsPanel:GetHeight())
	local panel = QuestWithFriendsPanel
	assertTrue(panel.scrollRange > 0)
	panel.scroll:GetScript("OnMouseWheel")(panel.scroll, -1000)
	assertAlmostEquals(panel.scrollRange, panel.scroll:GetVerticalScroll())
	sendSnapshot(quests)
	assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	assertEquals(3, #panelTexts())
	assertAlmostEquals(82, QuestWithFriendsPanel:GetHeight())
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
	for _, region in ipairs(panelRegions()) do
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
	for _, child in ipairs({ QuestWithFriendsPanel.content:GetChildren() }) do
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

partyTest(
	"quest actions open native confirmation and preserve collapse state through cancel and accept",
	function(quests)
		sendSnapshot({}, 100)
		withAbandonQuestAPI(nil, function(abandoned)
			local row, id, title = abandonableHeading(quests)
			local selected = C_QuestLog.GetSelectedQuest()
			local index = C_QuestLog.GetLogIndexForQuestID(id)
			for _, collapsed in ipairs({ false, true }) do
				if (QuestWithFriendsDB.collapsedQuests[row.groupID] == true) ~= collapsed then
					row.toggleButton:Click()
				end
				local action, menu = abandonAction(row)
				assertEquals(collapsed, row.toggleButton.summary:IsShown())
				assertEquals(nil, StaticPopup_FindVisible("ABANDON_QUEST"))
				assertEquals(0, #abandoned)
				action:Click()
				assertFalse(menu:IsShown())
				local dialog = StaticPopup_FindVisible("ABANDON_QUEST")
				assertNotNil(dialog)
				assertTrue(dialog:IsShown())
				assertTrue(dialog:GetTextFontString():GetText():find(title, 1, true) ~= nil)
				assertTrue(dialog:GetButton1():IsShown())
				assertTrue(dialog:GetButton2():IsShown())
				assertEquals(selected, C_QuestLog.GetSelectedQuest())
				assertEquals(0, #abandoned)
				if collapsed then
					dialog:GetButton1():Click()
					assertEquals(1, #abandoned)
					assertEquals(id, abandoned[1])
				else
					dialog:GetButton2():Click()
					assertEquals(0, #abandoned)
				end
				assertEquals(nil, StaticPopup_FindVisible("ABANDON_QUEST"))
				assertEquals(collapsed, row.toggleButton.summary:IsShown())
				assertEquals(index, C_QuestLog.GetLogIndexForQuestID(id))
			end
		end)
	end
)

partyTest("quest actions show Blizzard's item-removal warning before abandonment", function(quests)
	sendSnapshot({}, 100)
	withAbandonQuestAPI({ 6948 }, function(abandoned)
		local row, _, title = abandonableHeading(quests)
		local action = abandonAction(row)
		action:Click()
		assertEquals(nil, StaticPopup_FindVisible("ABANDON_QUEST"))
		local dialog = StaticPopup_FindVisible("ABANDON_QUEST_WITH_ITEMS")
		assertNotNil(dialog)
		assertTrue(dialog:IsShown())
		local text = dialog:GetTextFontString():GetText()
		assertTrue(text:find(title, 1, true) ~= nil)
		assertTrue(text:find("Hearthstone", 1, true) ~= nil)
		assertEquals(0, #abandoned)
		dialog:GetButton2():Click()
		assertEquals(0, #abandoned)
		assertEquals(nil, StaticPopup_FindVisible("ABANDON_QUEST_WITH_ITEMS"))
	end)
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
	for _, region in ipairs(panelRegions()) do
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
		if message:match("^1%.1:D:") then
			chunks = chunks + 1
		end
	end
	A_Admin.FireEvent("QUEST_LOG_UPDATE")
	A_Admin.FireEvent("QUEST_LOG_UPDATE")
	SlashCmdList.QUESTWITHFRIENDS("")
	SlashCmdList.QUESTWITHFRIENDS("")
	assertEquals(before, #messages)
	return function()
		assertEquals("1.1:H", messages[before + 1])
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
	for index, message in ipairs({ "2.0:H", "broken", "1.00:H", "1.1:" }) do
		receive(message)
		assertEquals("Party status incomplete", QuestWithFriendsPanel.status:GetText())
		assertContains(panelTexts(), "Julia: Incompatible addon protocol · update addon")
		sendSnapshot(quests, 100 + index)
		assertEquals("Party in sync", QuestWithFriendsPanel.status:GetText())
	end
end)

partyTest("drag-stop saves real frame coordinates relative to UIParent", function()
	local panel = QuestWithFriendsPanel
	QuestWithFriends.Panel.setLocked(false)
	panel.header:GetScript("OnDragStart")(panel.header)
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 140, -280)
	panel.header:GetScript("OnDragStop")(panel.header)
	assertAlmostEquals(140, QuestWithFriendsDB.panelPosition.x)
	assertAlmostEquals(-280, QuestWithFriendsDB.panelPosition.y)
	local point, relativeTo, relativePoint, x, y = panel:GetPoint(1)
	assertEquals("TOPLEFT", point)
	assertEquals(UIParent, relativeTo)
	assertEquals("TOPLEFT", relativePoint)
	assertAlmostEquals(140, x)
	assertAlmostEquals(-280, y)
	QuestWithFriends.Panel.setLocked(true)
end)

partyTest("header lock toggle and native settings stay in sync in both directions", function(quests)
	sendSnapshot(quests)
	local panel = QuestWithFriendsPanel
	local setting = Settings.GetSetting(QuestWithFriends.name .. "PanelLocked")
	assertTrue(setting:GetValue())
	assertFalse(panel.resize:IsShown())
	assertTrue(panel.lock:IsShown())
	assertFalse(panel.hint:IsShown())
	panel.lock:Click()
	assertFalse(setting:GetValue())
	assertFalse(QuestWithFriendsDB.panelLocked)
	assertAlmostEquals(360, panel:GetHeight())
	assertTrue(panel.resize:IsShown())
	assertTrue(panel.hint:IsShown())
	assertTrue(panel.lock:IsShown())
	panel.resize:GetScript("OnMouseDown")(panel.resize, "LeftButton")
	panel:SetSize(420, 240)
	panel.resize:GetScript("OnMouseUp")(panel.resize, "LeftButton")
	assertAlmostEquals(420, QuestWithFriendsDB.panelSize.width)
	assertAlmostEquals(240, QuestWithFriendsDB.panelSize.height)
	panel.lock:Click()
	assertTrue(setting:GetValue())
	assertAlmostEquals(82, panel:GetHeight())
	assertAlmostEquals(420, panel:GetWidth())
	assertFalse(panel.resize:IsShown())
	assertTrue(panel.lock:IsShown())
	setting:SetValue(false)
	assertFalse(QuestWithFriendsDB.panelLocked)
	assertAlmostEquals(240, panel:GetHeight())
	assertTrue(panel.resize:IsShown())
	panel.lock:Click()
	assertTrue(setting:GetValue())
	QuestWithFriendsDB.panelSize = nil
end)
