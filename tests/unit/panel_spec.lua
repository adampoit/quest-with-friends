describe("Quest With Friends panel", function()
	local panel, buttons, fontStrings, textures

	local function widget()
		local w = {}
		function w:SetSize(width, height)
			self.size = { width, height }
		end
		function w:SetPoint(point, _, relativePoint, x, y)
			self.point = { point, relativePoint, x, y }
		end
		function w:SetFrameStrata(...) end
		function w:SetBackdrop(...) end
		function w:SetBackdropColor(...) end
		function w:SetBackdropBorderColor(...) end
		function w:SetMovable(...) end
		function w:EnableMouse(...) end
		function w:RegisterForDrag(...) end
		function w:RegisterForClicks(...) end
		function w:SetClampedToScreen(...) end
		function w:StartMoving(...) end
		function w:StopMovingOrSizing()
			self.stopped = true
		end
		function w:GetLeft()
			return self.left
		end
		function w:GetTop()
			return self.top
		end
		function w:SetText(text)
			self.text = text
		end
		function w:SetEnabled(enabled)
			self.enabled = enabled
		end
		function w:SetTextColor(...)
			self.color = { ... }
		end
		function w:SetTexture(texture)
			self.texture = texture
		end
		function w:SetTexCoord(...) end
		function w:SetRotation(rotation)
			self.rotation = rotation
		end
		function w:SetVertexColor(...)
			self.color = { ... }
		end
		function w:SetDesaturated(value)
			self.desaturated = value
		end
		function w:SetWidth(width)
			self.width = width
		end
		function w:SetJustifyH(...) end
		function w:SetJustifyV(...) end
		function w:SetWordWrap(value)
			self.wordWrap = value
		end
		function w:SetAllPoints(...) end
		function w:SetColorTexture(...) end
		function w:GetStringWidth()
			return #(self.text or "") * 6
		end
		function w:Show()
			self.shown = true
		end
		function w:Hide()
			local wasShown = self.shown
			self.shown = false
			if wasShown and self.OnHide then
				self.OnHide(self)
			end
		end
		function w:ClearAllPoints(...) end
		function w:SetHeight(height)
			self.height = height
		end
		function w:GetStringHeight()
			return 15
		end
		function w:SetScript(event, callback)
			self[event] = callback
		end
		function w:OverrideText(text)
			self.text = text
		end
		function w:SetupMenu(generator)
			self.menuGenerator = generator
		end
		function w:GenerateMenu()
			local entries = {}
			local root = { titles = {} }
			function root:CreateCheckbox(text, isSelected, responder)
				local entry = { text = text, isSelected = isSelected, responder = responder, kind = "checkbox" }
				function entry:SetEnabled(enabled)
					self.enabled = enabled
				end
				entries[#entries + 1] = entry
				return entry
			end
			function root:CreateRadio(text, isSelected, responder)
				local entry = self:CreateCheckbox(text, isSelected, responder)
				entry.kind = "radio"
				return entry
			end
			function root:CreateDivider() end
			function root:CreateTitle(text)
				self.titles[#self.titles + 1] = text
			end
			self.menuGenerator(self, root)
			self.menuTitles = root.titles
			self.entries = entries
		end
		function w:OpenMenu()
			self:GenerateMenu()
			self.menuOpen = true
		end
		function w:CloseMenu()
			self.menuOpen = false
		end
		function w:CreateTexture(_, _)
			local texture = widget()
			if self == panel then
				textures[#textures + 1] = texture
			end
			return texture
		end
		function w:CreateFontString(_, _, _)
			local text = widget()
			if self == panel then
				fontStrings[#fontStrings + 1] = text
			end
			return text
		end
		return w
	end

	local function loadPanel()
		_G.QuestWithFriends = {}
		assert(loadfile("Panel.lua"))()
		QuestWithFriends.Panel.show({}, true, true, function() end)
	end

	local function group(id, differences)
		return {
			questID = id or 42,
			title = "Errand",
			shareQuestID = id,
			differences = differences or { { player = "Julia", kind = "missing", reason = "missing" } },
		}
	end

	before_each(function()
		buttons, fontStrings, textures = {}, {}, {}
		_G.GameTooltip = widget()
		function GameTooltip:SetOwner(owner, anchor)
			assert.are.equal("ANCHOR_RIGHT", anchor)
			self.owner = owner
		end
		function GameTooltip:IsOwned(owner)
			return self.owner == owner
		end
		function GameTooltip:AddLine(text, r, g, b, wrap)
			assert.same({ 1, 1, 1, true }, { r, g, b, wrap })
			self.line = text
		end
		_G.UIParent = widget()
		UIParent.left, UIParent.top = 0, 900
		_G.QuestWithFriendsDB = {}
		rawset(_G, "CreateFrame", function(kind, _, _, template)
			local w = widget()
			w.kind, w.template = kind, template
			if kind == "Button" or kind == "DropdownButton" then
				buttons[#buttons + 1] = w
			elseif kind == "Frame" then
				panel = w
			end
			return w
		end)
	end)

	it("puts three independent checkbox filters in one native dropdown", function()
		loadPanel()
		local zone, professions, classes = true, false, false
		local function show()
			QuestWithFriends.Panel.show(
				{},
				true,
				zone,
				function()
					zone = not zone
					show()
				end,
				nil,
				nil,
				{
					professions = professions,
					classes = classes,
					toggleProfessions = function()
						professions = not professions
						show()
					end,
					toggleClasses = function()
						classes = not classes
						show()
					end,
				}
			)
		end
		show()
		assert.are.equal(1, #buttons)
		assert.are.equal("DropdownButton", panel.filter.kind)
		assert.are.equal("WowStyle1DropdownTemplate", panel.filter.template)
		assert.are.equal("View", panel.filter.text)
		assert.same({ 92, 24 }, panel.filter.size)
		assert.same({ "TOPRIGHT", "TOPRIGHT", -10, -7 }, panel.filter.point)
		assert.are.equal("Party in sync", panel.status.text)
		panel.filter:OpenMenu()
		local entries = panel.filter.entries
		assert.are.equal(5, #entries)
		assert.are.equal("Current zone only", entries[1].text)
		assert.are.equal("Show profession quests", entries[2].text)
		assert.are.equal("Show class quests", entries[3].text)
		assert.is_true(entries[1].isSelected())
		assert.is_false(entries[2].isSelected())
		assert.is_false(entries[3].isSelected())
		for index = 1, 3 do
			assert.is_true(entries[index].enabled)
		end
		entries[1].responder()
		assert.is_false(zone)
		assert.is_false(panel.filter.entries[1].isSelected())
		assert.are.equal("All zones · Standard quests", panel.scope.text)
		panel.filter.entries[2].responder()
		assert.is_true(professions)
		assert.is_false(classes)
		assert.are.equal("All zones · Includes profession quests", panel.scope.text)
		panel.filter.entries[3].responder()
		assert.is_true(classes)
		assert.are.equal("All zones · All quest types", panel.scope.text)
		assert.is_true(panel.filter.menuOpen)
		assert.are.equal("View", panel.filter.text)
	end)

	it("offers exclusive Smart and Title A–Z sort choices and redraws the selection", function()
		loadPanel()
		local mode = "smart"
		local function show()
			QuestWithFriends.Panel.show({}, true, true, nil, nil, nil, nil, {
				sortMode = mode,
				onSort = function(selected)
					mode = selected
					show()
				end,
			})
		end
		show()
		panel.filter:OpenMenu()
		assert.same({ "Show", "Sort by" }, panel.filter.menuTitles)
		local smart, title = panel.filter.entries[4], panel.filter.entries[5]
		assert.are.equal("Smart", smart.text)
		assert.are.equal("Title A–Z", title.text)
		assert.are.equal("radio", smart.kind)
		assert.is_true(smart.enabled)
		assert.is_true(title.enabled)
		assert.is_true(smart.isSelected())
		assert.is_false(title.isSelected())
		title.responder()
		assert.are.equal("title", mode)
		assert.is_false(panel.filter.entries[4].isSelected())
		assert.is_true(panel.filter.entries[5].isSelected())
		panel.filter.entries[4].responder()
		assert.are.equal("smart", mode)
		assert.is_true(panel.filter.entries[4].isSelected())
	end)

	it("summarizes every zone and category combination without changing status", function()
		loadPanel()
		for _, zone in ipairs({ true, false }) do
			for _, case in ipairs({
				{ false, false, "Standard quests" },
				{ true, false, "Includes profession quests" },
				{ false, true, "Includes class quests" },
				{ true, true, "All quest types" },
			}) do
				QuestWithFriends.Panel.show({}, true, zone, nil, nil, nil, { professions = case[1], classes = case[2] })
				assert.are.equal((zone and "Current zone" or "All zones") .. " · " .. case[3], panel.scope.text)
				assert.are.equal("Party in sync", panel.status.text)
				assert.are.equal("View", panel.filter.text)
			end
		end
		QuestWithFriends.Panel.show({}, false, true)
		assert.are.equal("Party status incomplete", panel.status.text)
	end)

	it("disables menu entries without callbacks and closes the menu when hidden or dragged", function()
		loadPanel()
		QuestWithFriends.Panel.show({}, true, true)
		panel.filter:OpenMenu()
		for _, entry in ipairs(panel.filter.entries) do
			assert.is_false(entry.enabled)
		end
		QuestWithFriends.Panel.hide()
		assert.is_false(panel.filter.menuOpen)
		loadPanel()
		panel.filter:OpenMenu()
		panel.OnDragStart(panel)
		assert.is_false(panel.filter.menuOpen)
	end)

	it("puts one Share button on the quest heading and safely reuses it", function()
		loadPanel()
		local shared
		local function show(id)
			QuestWithFriends.Panel.show(
				{
					group(id, {
						{ player = "Julia", kind = "missing", reason = "missing" },
						{ player = "Bob", kind = "missing", reason = "missing" },
					}),
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
		assert.are.equal(3, #buttons)
		local shareButton, heading = buttons[2], fontStrings[4]
		assert.are.equal("Share", shareButton.text)
		assert.is_true(shareButton.shown)
		assert.are.equal(242, heading.width)
		assert.are.equal("Errand", heading.text)
		assert.is_nil(heading.icon)
		assert.are.equal("Julia: Missing", fontStrings[5].text)
		assert.are.equal("Bob: Missing", fontStrings[6].text)
		assert.is_nil(shared)
		shareButton.OnClick()
		assert.are.equal(42, shared)
		show(7)
		shareButton.OnClick()
		assert.are.equal(7, shared)
		assert.are.equal(3, #buttons)
		shareButton.OnEnter(shareButton)
		assert.is_true(GameTooltip.shown)
		assert.matches("Offers this quest to the party", GameTooltip.line)
		show(nil)
		assert.is_false(GameTooltip.shown)
		assert.is_false(shareButton.shown)
		assert.are.equal(302, heading.width)
		shared = nil
		shareButton.OnClick()
		assert.is_nil(shared)
	end)

	it("uses structured reasons and distinct icons, not text parsing", function()
		loadPanel()
		local cases = {
			{ "missing", "missing", "Missing", "Interface\\GossipFrame\\AvailableQuestIcon", { 0.98, 0.73, 0.40 } },
			{
				"needs",
				"active",
				"Still in progress",
				"Interface\\QuestFrame\\UI-Quest-BulletPoint",
				{ 0.57, 0.78, 1.00 },
			},
			{ "ahead", "ready", "Ready to turn in", "Interface\\RaidFrame\\ReadyCheck-Ready", { 0.52, 0.87, 0.62 } },
			{ "ahead", "completed", "Completed", "Interface\\RaidFrame\\ReadyCheck-Ready", { 0.52, 0.87, 0.62 } },
		}
		for _, case in ipairs(cases) do
			QuestWithFriends.Panel.show(
				{ group(nil, { { player = "You", kind = case[1], reason = case[2] } }) },
				true,
				true
			)
			local row = fontStrings[5]
			assert.are.equal("You: " .. case[3], row.text)
			assert.same(case[5], row.color)
			assert.same(case[5], row.icon.color)
			assert.are.equal(case[4], row.icon.texture)
			assert.is_true(row.icon.desaturated)
			assert.is_true(row.icon.shown)
			assert.are.equal(292, row.width)
		end
		assert.are.equal(1, #textures)
		assert.same({ 0.94, 0.95, 0.97 }, fontStrings[4].color)
		QuestWithFriends.Panel.show({}, true, true)
		assert.is_false(textures[1].shown)
	end)

	it("displays objective counts and separates connection warnings from quests", function()
		loadPanel()
		QuestWithFriends.Panel.show({
			group(nil, {
				{
					player = "Julia",
					kind = "needs",
					reason = "objective",
					objective = { text = "Gnolls slain", have = 5, need = 8 },
				},
			}),
		}, false, true, nil, nil, { { player = "Bob", reason = "unknown" }, { player = "You", reason = "oversized" } })
		assert.are.equal("Bob: Quest With Friends not detected", fontStrings[4].text)
		assert.are.equal("You: Quest log too large to share · status unknown", fontStrings[5].text)
		assert.are.equal("Errand", fontStrings[6].text)
		assert.are.equal("Julia: Gnolls slain 5/8", fontStrings[7].text)
		assert.are.equal("Party status incomplete", panel.status.text)
	end)

	it("distinguishes waiting, refreshing and stale snapshots without claiming the party is in sync", function()
		loadPanel()
		local cases = {
			{ "waiting", "Waiting for quest snapshot · /qwf to refresh" },
			{ "refreshing", "Refreshing · showing last snapshot" },
			{ "stale", "Quest data stale · /qwf to refresh" },
			{ "incompatible", "Incompatible addon protocol · update addon" },
		}
		for _, case in ipairs(cases) do
			QuestWithFriends.Panel.show(
				{ group(nil) },
				false,
				true,
				nil,
				nil,
				{ { player = "Julia", reason = case[1] } }
			)
			assert.are.equal("Party status incomplete", panel.status.text)
			assert.are.equal("Julia: " .. case[2], fontStrings[4].text)
			assert.are.equal("Errand", fontStrings[5].text)
		end
	end)

	it("clears icons, styling and actions when warning rows become quest headings", function()
		loadPanel()
		QuestWithFriends.Panel.show({}, false, true, nil, nil, { { player = "Bob", reason = "unknown" } })
		local row, icon = fontStrings[4], fontStrings[4].icon
		assert.is_true(icon.shown)
		QuestWithFriends.Panel.show({ group(42) }, true, true, nil, function() end)
		assert.are.equal("Errand", row.text)
		assert.is_false(icon.shown)
		assert.are.equal(242, row.width)
		assert.same({ 0.94, 0.95, 0.97 }, row.color)
		QuestWithFriends.Panel.show({}, false, true, nil, nil, { { player = "Bob", reason = "unknown" } })
		assert.is_false(row.shareButton.shown)
		assert.is_nil(row.questID)
	end)

	it("keeps long headings on one line beside Share and exposes the full title on hover", function()
		loadPanel()
		local data = group(42)
		data.title = string.rep("Long quest title ", 20)
		QuestWithFriends.Panel.show({ data }, true, true, nil, function() end)
		local row = fontStrings[4]
		assert.are.equal(242, row.width)
		assert.is_false(row.wordWrap)
		assert.are.equal(121, panel.height)
		row.toggleButton.OnEnter(row.toggleButton)
		assert.are.equal(data.title, GameTooltip.text)
		assert.are.equal("Click to collapse", GameTooltip.line)
		row.toggleButton.OnLeave(row.toggleButton)
		assert.is_false(GameTooltip.shown)
	end)

	it("hides share buttons for rows no longer visible and requires a callback", function()
		loadPanel()
		QuestWithFriends.Panel.show({ group(42) }, true, true)
		assert.are.equal(2, #buttons)
		QuestWithFriends.Panel.show({ group(42) }, true, true, nil, function() end)
		assert.is_true(buttons[3].shown)
		QuestWithFriends.Panel.show({}, true, true)
		assert.is_false(buttons[3].shown)
	end)

	it("truncates whole quest groups without creating orphan headings or actions", function()
		loadPanel()
		local groups = {}
		for index = 1, 25 do
			groups[index] = group(index)
			groups[index].title = "Errand " .. index
		end
		QuestWithFriends.Panel.show(groups, true, true, nil, function() end)
		assert.are.equal(19, #buttons)
		assert.are.equal(9, #textures)
		assert.are.equal("Errand 9", fontStrings[20].text)
		assert.are.equal("Julia: Missing", fontStrings[21].text)
		assert.are.equal("+16 more quests with differences", fontStrings[22].text)
		assert.is_nil(fontStrings[22].icon)
		QuestWithFriends.Panel.show({}, true, true)
		for index = 2, #buttons do
			assert.is_false(buttons[index].shown)
		end
		for _, icon in ipairs(textures) do
			assert.is_false(icon.shown)
		end
	end)

	it("shows part of an oversized first quest and counts its hidden details separately", function()
		loadPanel()
		local differences = {}
		for index = 1, 25 do
			differences[index] = {
				player = "Julia",
				kind = "needs",
				reason = "objective",
				objective = { text = "Task " .. index, have = 0, need = 1 },
			}
		end
		QuestWithFriends.Panel.show(
			{ group(42, differences), group(43) },
			false,
			true,
			nil,
			function() end,
			{ { player = "Bob", reason = "unknown" } }
		)
		assert.are.equal("Errand", fontStrings[5].text)
		assert.are.equal("Julia: Task 15 0/1", fontStrings[20].text)
		assert.are.equal("  +10 more differences for this quest", fontStrings[21].text)
		assert.are.equal("+1 more quest with differences", fontStrings[22].text)
		assert.are.equal(3, #buttons)
	end)

	it("toggles independently while keeping Share and the comparison status visible", function()
		loadPanel()
		local shared
		QuestWithFriends.Panel.show({ group(42), group(43) }, true, true, nil, function(id)
			shared = id
		end)
		local first, second = fontStrings[4], fontStrings[6]
		assert.are.equal(-math.pi / 2, first.toggleButton.indicator.rotation)
		assert.are.equal("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", first.toggleButton.indicator.texture)
		assert.is_false(first.toggleButton.summary.shown)
		first.toggleButton.OnClick()
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
		assert.is_nil(QuestWithFriendsDB.collapsedQuests[43])
		assert.are.equal(0, first.toggleButton.indicator.rotation)
		assert.are.equal("1 missing", first.toggleButton.summary.text)
		assert.is_true(first.toggleButton.summary.shown)
		assert.is_true(first.shareButton.shown)
		first.shareButton.OnClick()
		assert.are.equal(42, shared)
		assert.is_true(first.collapsed)
		assert.are.equal("Errand", fontStrings[5].text)
		assert.are.equal("Julia: Missing", second.text)
		assert.are.equal("Party out of sync", panel.status.text)
		first.toggleButton.OnClick()
		assert.is_nil(QuestWithFriendsDB.collapsedQuests[42])
		assert.are.equal(-math.pi / 2, first.toggleButton.indicator.rotation)
		assert.is_false(first.toggleButton.summary.shown)
		assert.are.equal("Julia: Missing", fontStrings[5].text)
	end)

	it("remembers group IDs across reloads, filters, temporary disappearance and progress updates", function()
		loadPanel()
		local data = group(42)
		data.shareQuestID = 77
		QuestWithFriends.Panel.show({ data }, true, true, nil, function() end)
		fontStrings[4].toggleButton.OnClick()
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
		assert.is_nil(QuestWithFriendsDB.collapsedQuests[77])
		QuestWithFriends.Panel.show({}, true, false)
		QuestWithFriends.Panel.hide()
		buttons, fontStrings, textures = {}, {}, {}
		loadPanel()
		data.title = "Renamed errand"
		data.differences = { { player = "Bob", kind = "needs", reason = "active" } }
		QuestWithFriends.Panel.show({ data, group(43) }, true, false)
		local row = fontStrings[4]
		assert.are.equal("Renamed errand", row.text)
		assert.is_true(row.collapsed)
		assert.are.equal("1 needs progress", row.toggleButton.summary.text)
		assert.is_false(fontStrings[5].collapsed)
		assert.are.equal("Julia: Missing", fontStrings[6].text)
	end)

	it("counts distinct affected players rather than objective rows", function()
		loadPanel()
		QuestWithFriendsDB.collapsedQuests[42] = true
		local objective = { text = "Gnolls", have = 3, need = 8 }
		QuestWithFriends.Panel.show({
			group(42, {
				{ player = "Julia", kind = "needs", reason = "objective", objective = objective },
				{ player = "Julia", kind = "needs", reason = "objective", objective = objective },
				{ player = "You", kind = "needs", reason = "objective", objective = objective },
			}),
		}, true, true)
		local row = fontStrings[4]
		assert.are.equal("2 need progress", row.toggleButton.summary.text)
		assert.are.equal(302 - #"2 need progress" * 6 - 8, row.width)
		assert.is_nil(fontStrings[5])
		QuestWithFriends.Panel.show({
			group(42, {
				{ player = "You", kind = "needs", reason = "active" },
				{ player = "Julia", kind = "ahead", reason = "ready" },
			}),
		}, true, true)
		assert.are.equal("2 affected", row.toggleButton.summary.text)
	end)

	it("uses one row per collapsed quest and restores the overflow budget when expanded", function()
		loadPanel()
		local groups = {}
		for index = 1, 25 do
			groups[index] = group(index)
			groups[index].title = "Errand " .. index
			QuestWithFriendsDB.collapsedQuests[index] = true
		end
		QuestWithFriends.Panel.show(groups, true, true)
		assert.are.equal("Errand 18", fontStrings[21].text)
		assert.are.equal("+7 more quests with differences", fontStrings[22].text)
		fontStrings[4].toggleButton.OnClick()
		assert.are.equal("Julia: Missing", fontStrings[5].text)
		assert.are.equal("Errand 17", fontStrings[21].text)
		assert.are.equal("+8 more quests with differences", fontStrings[22].text)
	end)

	it("keeps notices visible and clears heading actions and tooltips when rows are reused", function()
		loadPanel()
		QuestWithFriendsDB.collapsedQuests[42] = true
		QuestWithFriends.Panel.show({ group(42) }, false, true, nil, nil, { { player = "Bob", reason = "stale" } })
		assert.are.equal("Bob: Quest data stale · /qwf to refresh", fontStrings[4].text)
		assert.are.equal("Party status incomplete", panel.status.text)
		local row = fontStrings[5]
		row.toggleButton.OnEnter(row.toggleButton)
		assert.are.equal("Click to expand", GameTooltip.line)
		assert.is_true(GameTooltip.shown)
		QuestWithFriends.Panel.show({}, false, true, nil, nil, {
			{ player = "Bob", reason = "stale" },
			{ player = "Julia", reason = "waiting" },
		})
		assert.is_false(GameTooltip.shown)
		assert.is_false(row.toggleButton.shown)
		assert.is_nil(row.groupID)
		assert.is_true(row.wordWrap)
		row.toggleButton.OnClick()
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
		QuestWithFriends.Panel.show({ group(43) }, true, true)
		assert.is_false(fontStrings[4].collapsed)
		assert.are.equal("Julia: Missing", row.text)
		assert.is_false(row.toggleButton.shown)
	end)

	it("ignores invalid saved collapse preferences", function()
		QuestWithFriendsDB.collapsedQuests = "invalid"
		loadPanel()
		assert.same({}, QuestWithFriendsDB.collapsedQuests)
		QuestWithFriendsDB.collapsedQuests[42] = "true"
		QuestWithFriends.Panel.show({ group(42) }, true, true)
		assert.is_false(fontStrings[4].collapsed)
	end)

	it("saves a dragged position and restores it after a reload", function()
		loadPanel()
		assert.same({ "TOPRIGHT", "TOPRIGHT", -36, -180 }, panel.point)
		panel.left, panel.top = 140, 620
		panel.OnDragStop(panel)
		assert.is_true(panel.stopped)
		assert.same({ x = 140, y = -280 }, QuestWithFriendsDB.panelPosition)
		assert.same({ "TOPLEFT", "TOPLEFT", 140, -280 }, panel.point)
		loadPanel()
		assert.same({ "TOPLEFT", "TOPLEFT", 140, -280 }, panel.point)
	end)

	it("labels preview data, disables sharing and keeps sample collapse choices out of saved settings", function()
		loadPanel()
		local shared, stopped = false, false
		local collapsed = {}
		QuestWithFriends.Panel.show(
			{ group(-1) },
			true,
			true,
			nil,
			function()
				shared = true
			end,
			nil,
			nil,
			{
				preview = true,
				collapsedQuests = collapsed,
				onStop = function()
					stopped = true
					QuestWithFriends.Panel.hide()
				end,
			}
		)
		assert.are.equal("Preview · Sample party data", panel.status.text)
		local row = fontStrings[4]
		assert.is_true(row.shareButton.shown)
		assert.is_false(row.shareButton.enabled)
		row.shareButton.OnClick()
		assert.is_false(shared)
		row.shareButton.OnEnter(row.shareButton)
		assert.are.equal("Sample quest only. Sharing is disabled in preview.", GameTooltip.line)
		row.toggleButton.OnClick()
		assert.is_true(collapsed[-1])
		assert.same({}, QuestWithFriendsDB.collapsedQuests)
		assert.is_true(row.collapsed)
		assert.is_true(panel.stopPreview.shown)
		panel.stopPreview.OnClick()
		assert.is_true(stopped)
		assert.is_false(panel.shown)

		QuestWithFriends.Panel.show({ group(42) }, true, true, nil, function() end)
		assert.are.equal("Party out of sync", panel.status.text)
		assert.is_false(panel.stopPreview.shown)
		assert.is_true(row.shareButton.enabled)
		assert.is_false(row.collapsed)
		row.toggleButton.OnClick()
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
	end)

	it("uses the default position if saved coordinates are invalid", function()
		QuestWithFriendsDB.panelPosition = { x = "bad", y = -280 }
		loadPanel()
		assert.same({ "TOPRIGHT", "TOPRIGHT", -36, -180 }, panel.point)
	end)
end)
