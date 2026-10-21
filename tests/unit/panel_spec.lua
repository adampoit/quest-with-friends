describe("Quest With Friends panel", function()
	local panel, buttons, fontStrings, textures, panelFontCount
	local contextMenu, originalMenuUtil

	local function widget()
		local w = {}
		function w:SetSize(width, height)
			self.size = { width, height }
			self.width, self.height = width, height
			if self.OnSizeChanged then
				self.OnSizeChanged(self, width, height)
			end
		end
		function w:SetParent(parent)
			self.parent = parent
		end
		function w:GetParent()
			return self.parent
		end
		function w:GetEffectiveScale()
			return self.scale or 1
		end
		function w:GetWidth()
			return self.width
		end
		function w:GetHeight()
			return self.height
		end
		function w:RegisterEvent(...) end
		function w:SetResizable(value)
			self.resizable = value
		end
		function w:SetResizeBounds(...)
			self.bounds = { ... }
		end
		function w:StartSizing(corner)
			self.sizing = corner
		end
		function w:EnableMouseWheel(value)
			self.mouseWheel = value
		end
		function w:SetScrollChild(child)
			self.scrollChild = child
		end
		function w:GetVerticalScroll()
			return self.scroll or 0
		end
		function w:SetVerticalScroll(value)
			self.scroll = value
		end
		function w:SetMinMaxValues(low, high)
			self.range = { low, high }
		end
		function w:SetValue(value)
			self.value = value
		end
		function w:SetNormalTexture(...) end
		function w:SetHighlightTexture(...) end
		function w:SetPushedTexture(...) end
		function w:GetScript(event)
			return self[event]
		end
		function w:SetShown(value)
			if value then
				self:Show()
			else
				self:Hide()
			end
		end
		function w:IsShown()
			return self.shown == true
		end
		function w:SetPoint(point, relativeTo, relativePoint, x, y)
			self.point = { point, relativePoint, x, y }
			self.points = self.points or {}
			self.points[point] = { relativeTo, relativePoint, x, y }
			if self == panel and relativeTo == UIParent then
				self.left = point == "TOPRIGHT" and UIParent.width - self.width + x or x
				self.top = UIParent.top + y
			end
		end
		function w:SetFrameStrata(...) end
		function w:SetBackdrop(...) end
		function w:SetBackdropColor(...) end
		function w:SetBackdropBorderColor(...) end
		function w:SetMovable(...) end
		function w:EnableMouse(value)
			self.mouseEnabled = value
		end
		function w:RegisterForDrag(...) end
		function w:RegisterForClicks(...)
			self.clicks = { ... }
		end
		function w:SetClampedToScreen(...) end
		function w:StartMoving()
			self.moving = true
		end
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
		function w:SetFontObject(fontObject)
			self.fontObject = fontObject
			self.justifyH = "CENTER"
		end
		function w:SetTexture(texture)
			self.texture = texture
		end
		function w:SetTexCoord(...)
			self.texCoord = { ... }
		end
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
			if self.OnSizeChanged then
				self.OnSizeChanged(self, width, self.height)
			end
		end
		function w:SetJustifyH(value)
			self.justifyH = value
		end
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
		function w:ClearAllPoints()
			self.points = {}
		end
		function w:SetHeight(height)
			self.height = height
			if self.OnSizeChanged then
				self.OnSizeChanged(self, self.width, height)
			end
		end
		function w:GetStringHeight()
			return self.wordWrap == false and 15
				or math.max(1, math.ceil(self:GetStringWidth() / (self.width or 10000))) * 15
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
			function root:CreateButton(text, responder)
				local entry = self:CreateCheckbox(text, nil, responder)
				entry.kind = "button"
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
			texture.parent = self
			if self == panel or self == panel.content then
				textures[#textures + 1] = texture
			end
			return texture
		end
		function w:CreateFontString(_, _, fontObject)
			local text = widget()
			text.parent = self
			text.fontObject = fontObject
			if self == panel then
				panelFontCount = panelFontCount + 1
			end
			if (self == panel and panelFontCount ~= 4) or self == panel.content then
				fontStrings[#fontStrings + 1] = text
			end
			return text
		end
		return w
	end

	local function loadPanel()
		_G.QuestWithFriends = { db = QuestWithFriendsDB }
		assert(loadfile("src/Panel.lua"))()
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
		originalMenuUtil = _G.MenuUtil
		contextMenu = nil
		_G.MenuUtil = {
			CreateContextMenu = function(owner, generator)
				contextMenu = widget()
				contextMenu.owner = owner
				contextMenu:SetupMenu(generator)
				contextMenu:GenerateMenu()
				return contextMenu
			end,
		}
		buttons, fontStrings, textures, panelFontCount = {}, {}, {}, 0
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
		UIParent.width, UIParent.height = 1600, 900
		_G.QuestWithFriendsDB = {}
		rawset(_G, "CreateFrame", function(kind, name, parent, template)
			local w = widget()
			w.kind, w.template, w.parent = kind, template, parent
			if name == "QuestWithFriendsPanel" then
				panel = w
				panelFontCount = 0
			elseif kind == "ScrollFrame" then
				w.ScrollBar = widget()
				w.ScrollBar:SetWidth(16)
				w.ScrollBar.ScrollUpButton = widget()
				w.ScrollBar.ScrollUpButton:SetSize(18, 16)
				w.ScrollBar.ScrollDownButton = widget()
				w.ScrollBar.ScrollDownButton:SetSize(18, 16)
			elseif kind == "Button" or kind == "DropdownButton" then
				local layoutButton = parent == panel and #buttons == 1 and not panel.resize
				if not layoutButton then
					buttons[#buttons + 1] = w
				end
			end
			return w
		end)
	end)

	after_each(function()
		_G.MenuUtil = originalMenuUtil
	end)

	it("offers abandonment in a right-click menu without changing collapse or Share", function()
		loadPanel()
		local requested, shared
		local presentation = {
			getAbandonQuestID = function(id)
				assert.are.equal(42, id)
				return 43
			end,
			onAbandon = function(id)
				requested = id
			end,
		}
		QuestWithFriends.Panel.show({ group(42) }, true, true, nil, function(id)
			shared = id
		end, nil, nil, presentation)
		local heading = fontStrings[4].toggleButton
		assert.same({ "LeftButtonUp", "RightButtonUp" }, heading.clicks)
		heading.OnEnter(heading)
		assert.are.equal("Right-click for quest actions", GameTooltip.line)
		heading.OnClick(heading, "RightButton")
		assert.is_nil(QuestWithFriendsDB.collapsedQuests[42])
		assert.is_false(GameTooltip.shown)
		assert.are.equal(heading, contextMenu.owner)
		assert.same({ "Errand" }, contextMenu.menuTitles)
		assert.are.equal(1, #contextMenu.entries)
		assert.are.equal("Abandon quest…", contextMenu.entries[1].text)
		assert.is_nil(requested)
		contextMenu.entries[1].responder()
		assert.are.equal(43, requested)
		assert.is_nil(shared)
		fontStrings[4].shareButton.OnClick()
		assert.are.equal(42, shared)
		heading.OnClick(heading, "LeftButton")
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
		heading.OnClick(heading, "RightButton")
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
	end)

	it("does not offer abandonment for ineligible quests, preview or screenshot samples", function()
		loadPanel()
		local presentation = {
			getAbandonQuestID = function() end,
			onAbandon = function()
				error("Must not abandon sample quests")
			end,
		}
		for _, mode in ipairs({ "live", "preview", "screenshot" }) do
			presentation.preview = mode ~= "live"
			presentation.screenshot = mode == "screenshot"
			QuestWithFriends.Panel.show({ group(42) }, true, true, nil, nil, nil, nil, presentation)
			local heading = fontStrings[4].toggleButton
			heading.OnClick(heading, "RightButton")
			assert.is_nil(contextMenu)
			heading.OnEnter(heading)
			assert.are.equal("Click to collapse", GameTooltip.line)
			presentation.getAbandonQuestID = function()
				return 42
			end
		end
	end)

	it("keeps menu targets immutable and rejects callbacks after row reuse, hiding or preview", function()
		loadPanel()
		local requested = {}
		local presentation = {
			getAbandonQuestID = function(id)
				return id
			end,
			onAbandon = function(id)
				requested[#requested + 1] = id
			end,
		}
		local function show(id)
			QuestWithFriends.Panel.show({ group(id) }, true, true, nil, nil, nil, nil, presentation)
		end
		show(42)
		local heading = fontStrings[4].toggleButton
		heading.OnClick(heading, "RightButton")
		local oldAction = contextMenu.entries[1].responder
		show(7)
		oldAction()
		assert.same({}, requested)
		heading.OnClick(heading, "RightButton")
		local currentAction = contextMenu.entries[1].responder
		QuestWithFriends.Panel.hide()
		currentAction()
		assert.same({}, requested)
		show(7)
		heading.OnClick(heading, "RightButton")
		currentAction = contextMenu.entries[1].responder
		presentation.preview = true
		show(7)
		currentAction()
		assert.same({}, requested)
		presentation.preview = false
		show(7)
		heading.OnClick(heading, "RightButton")
		contextMenu.entries[1].responder()
		assert.same({ 7 }, requested)
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
		assert.same({ "TOPRIGHT", "TOPRIGHT", -10, -10 }, panel.filter.point)
		assert.same({ panel, "TOPLEFT", 14, -22 }, fontStrings[1].points.LEFT)
		assert.are.equal(30, panel.header.height)
		assert.are.equal("Quest With Friends", fontStrings[1].text)
		assert.are.equal("GameFontNormal", fontStrings[1].fontObject)
		assert.same({ 0.94, 0.95, 0.97 }, fontStrings[1].color)
		assert.are.equal("GameFontHighlight", panel.status.fontObject)
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
		QuestWithFriends.Panel.setLocked(false)
		panel.header.OnDragStart(panel.header)
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
			assert.are.equal(row.points.TOPLEFT[2] + 2, row.icon.points.TOPLEFT[4])
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

	it("caps tradeable progress and appends only positive confirmed spare counts", function()
		loadPanel()
		for _, case in ipairs({
			{ have = 10, spare = 2, expected = "10/10 · 2 spare" },
			{ have = 12, spare = 2, expected = "10/10 · 2 spare" },
			{ have = 10, spare = 0, expected = "10/10" },
			{ have = 12, expected = "12/10" },
		}) do
			QuestWithFriends.Panel.show({
				group(nil, {
					{
						player = "You",
						kind = "ahead",
						reason = "objective",
						objective = { text = "Linen Cloth", have = case.have, need = 10, spare = case.spare },
					},
				}),
			}, true, true)
			assert.are.equal("You: Linen Cloth " .. case.expected, fontStrings[5].text)
			assert.same({ 0.52, 0.87, 0.62 }, fontStrings[5].color)
		end
	end)

	it("reports the exact objective row text and whether its quest is collapsed", function()
		loadPanel()
		local diagnostics
		local groups = {
			group(42, {
				{
					player = "You",
					kind = "ahead",
					reason = "objective",
					objective = { text = "Linen Cloth", have = 12, need = 10, spare = 2 },
				},
			}),
		}
		local function show()
			QuestWithFriends.Panel.show(groups, true, true, nil, nil, nil, nil, {
				onObjectiveRows = function(rows)
					diagnostics = rows
				end,
			})
		end
		show()
		assert.are.equal(fontStrings[5].text, diagnostics[1].text)
		assert.are.equal("You: Linen Cloth 10/10 · 2 spare", diagnostics[1].text)
		assert.are.equal("rendered", diagnostics[1].result)
		assert.are.equal(42, diagnostics[1].questID)
		assert.are.equal(12, diagnostics[1].have)
		assert.are.equal(10, diagnostics[1].need)
		QuestWithFriendsDB.collapsedQuests[42] = true
		show()
		assert.are.equal("quest_collapsed", diagnostics[1].result)
		assert.is_false(fontStrings[5].shown)
		groups = {}
		show()
		assert.same({}, diagnostics)
	end)

	it("distinguishes offline members and sync health without claiming the party is in sync", function()
		loadPanel()
		local cases = {
			{ "offline", "Offline · sync resumes when online" },
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
		assert.are.equal(125, panel.height)
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

	it("keeps every quest and action reachable by scrolling and clears reused rows", function()
		loadPanel()
		local groups = {}
		for index = 1, 25 do
			groups[index] = group(index)
			groups[index].title = "Errand " .. index
		end
		QuestWithFriends.Panel.show(groups, true, true, nil, function() end)
		assert.are.equal(51, #buttons)
		assert.are.equal(25, #textures)
		assert.are.equal("Errand 25", fontStrings[52].text)
		assert.are.equal("Julia: Missing", fontStrings[53].text)
		assert.are.equal(360, panel.height)
		assert.is_true(panel.scroll.ScrollBar.shown)
		panel.scroll.OnMouseWheel(panel.scroll, -1000)
		assert.are.equal(panel.scrollRange, panel.scroll.scroll)
		assert.are.equal(panel.content, fontStrings[52]:GetParent())
		assert.are.equal(218, fontStrings[52].width)
		QuestWithFriends.Panel.show({}, true, true)
		for index = 2, #buttons do
			assert.is_false(buttons[index].shown)
		end
		for _, icon in ipairs(textures) do
			assert.is_false(icon.shown)
		end
	end)

	it("renders every detail of an oversized quest and pins connection notices outside the scroll body", function()
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
		assert.are.equal("Julia: Task 25 0/1", fontStrings[30].text)
		assert.are.equal("Errand", fontStrings[31].text)
		assert.are.equal(5, #buttons)
		assert.are.equal(panel, fontStrings[4]:GetParent())
		assert.are.equal(panel.content, fontStrings[5]:GetParent())
		assert.are.equal(panel.content, fontStrings[30]:GetParent())
		assert.is_true(panel.scrollRange > 0)
		local noticePoint = fontStrings[4].point
		panel.scroll.OnMouseWheel(panel.scroll, -3)
		assert.same(noticePoint, fontStrings[4].point)
	end)

	it("toggles independently while keeping Share and the comparison status visible", function()
		loadPanel()
		local shared
		QuestWithFriends.Panel.show({ group(42), group(43) }, true, true, nil, function(id)
			shared = id
		end)
		local first, second = fontStrings[4], fontStrings[6]
		assert.are.equal(-math.pi / 2, first.toggleButton.indicator.rotation)
		assert.are.equal(
			"Interface\\AddOns\\QuestWithFriends\\Media\\QuestToggle",
			first.toggleButton.indicator.texture
		)
		assert.is_nil(first.toggleButton.indicator.texCoord)
		assert.same({ 12, 12 }, first.toggleButton.indicator.size)
		assert.same({ "LEFT", "LEFT", 0, 2 }, first.toggleButton.indicator.point)
		assert.same({ 0.72, 0.79, 0.88 }, first.toggleButton.indicator.color)
		assert.is_false(first.toggleButton.summary.shown)
		first.toggleButton.OnClick()
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
		assert.is_nil(QuestWithFriendsDB.collapsedQuests[43])
		assert.are.equal(0, first.toggleButton.indicator.rotation)
		assert.same({ "LEFT", "LEFT", 0, 2 }, first.toggleButton.indicator.point)
		assert.are.equal(20, first.toggleButton.size[2])
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

	it("does not count finished item holders as needing progress in collapsed summaries", function()
		loadPanel()
		QuestWithFriendsDB.collapsedQuests[42] = true
		QuestWithFriends.Panel.show({
			group(42, {
				{
					player = "You",
					kind = "ahead",
					reason = "objective",
					objective = { text = "Linen Cloth", have = 10, need = 10, spare = 2 },
				},
				{
					player = "Julia",
					kind = "needs",
					reason = "objective",
					objective = { text = "Linen Cloth", have = 3, need = 10 },
				},
			}),
		}, true, true)
		assert.are.equal("2 affected", fontStrings[4].toggleButton.summary.text)
	end)

	it("uses one row per collapsed quest and expands the scroll range with its details", function()
		loadPanel()
		local groups = {}
		for index = 1, 25 do
			groups[index] = group(index)
			groups[index].title = "Errand " .. index
			QuestWithFriendsDB.collapsedQuests[index] = true
		end
		QuestWithFriends.Panel.show(groups, true, true)
		assert.are.equal("Errand 25", fontStrings[28].text)
		local range = panel.scrollRange
		fontStrings[4].toggleButton.OnClick()
		assert.are.equal("Julia: Missing", fontStrings[5].text)
		assert.are.equal("Errand 25", fontStrings[29].text)
		assert.are.equal(range + 18, panel.scrollRange)
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
		assert.same({ "TOPLEFT", "TOPLEFT", 1216, -180 }, panel.point)
		QuestWithFriends.Panel.setLocked(false)
		panel.header.OnDragStart(panel.header)
		panel.left, panel.top = 140, 620
		panel.header.OnDragStop(panel.header)
		assert.is_true(panel.stopped)
		assert.same({ x = 140, y = -280 }, QuestWithFriendsDB.panelPosition)
		assert.same({ "TOPLEFT", "TOPLEFT", 140, -280 }, panel.point)
		assert.are.equal(1460, panel.bounds[3])
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
		assert.are.equal("GameFontHighlightSmall", panel.status.fontObject)
		assert.are.equal("LEFT", panel.status.justifyH)
		assert.same({ 0.72, 0.78, 0.85 }, panel.status.color)
		assert.same({ panel.stopPreview, "RIGHT", 8, 0 }, panel.status.points.LEFT)
		assert.is_nil(panel.status.points.TOPLEFT)
		assert.are.equal(-36, panel.scope.points.TOPLEFT[2])
		assert.are.equal(-56, panel.scroll.points.TOPLEFT[4])
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
		assert.are.equal("GameFontHighlight", panel.status.fontObject)
		assert.are.equal("LEFT", panel.status.justifyH)
		assert.same({ 0.98, 0.73, 0.40 }, panel.status.color)
		assert.is_false(panel.stopPreview.shown)
		assert.are.equal(-36, panel.status.points.TOPLEFT[2])
		assert.is_nil(panel.status.points.LEFT)
		assert.are.equal(-54, panel.scope.points.TOPLEFT[2])
		assert.are.equal(-74, panel.scroll.points.TOPLEFT[4])
		assert.is_true(row.shareButton.enabled)
		assert.is_false(row.collapsed)
		row.toggleButton.OnClick()
		assert.is_true(QuestWithFriendsDB.collapsedQuests[42])
	end)

	it("makes screenshot samples look live without allowing sharing or saving sample collapse choices", function()
		loadPanel()
		local shared, stopped = false, false
		local collapsed = {}
		local presentation = {
			preview = true,
			collapsedQuests = collapsed,
			onStop = function()
				stopped = true
			end,
		}
		local function show(groups, complete)
			QuestWithFriends.Panel.show(groups, complete, true, nil, function()
				shared = true
			end, nil, nil, presentation)
		end
		show({ group(-1) }, true)
		assert.is_true(panel.stopPreview.shown)
		panel.scroll:SetVerticalScroll(20)
		presentation.screenshot = true
		show({ group(-1) }, true)
		assert.are.equal(0, panel.scroll:GetVerticalScroll())
		assert.are.equal("Party out of sync", panel.status.text)
		assert.are.equal("GameFontHighlight", panel.status.fontObject)
		assert.same({ 0.98, 0.73, 0.40 }, panel.status.color)
		assert.are.equal(-36, panel.status.points.TOPLEFT[2])
		assert.is_nil(panel.status.points.LEFT)
		assert.are.equal(-54, panel.scope.points.TOPLEFT[2])
		assert.are.equal(-74, panel.scroll.points.TOPLEFT[4])
		assert.are.equal(8, panel.scroll.points.BOTTOMRIGHT[4])
		assert.is_false(panel.stopPreview.shown)
		assert.is_false(stopped)
		local row = fontStrings[4]
		assert.is_true(row.shareButton.shown)
		assert.is_true(row.shareButton.enabled)
		row.shareButton.OnClick()
		assert.is_false(shared)
		row.shareButton.OnEnter(row.shareButton)
		assert.are.equal("Offers this quest to the party. WoW determines who can accept it.", GameTooltip.line)
		row.toggleButton.OnClick()
		assert.is_true(collapsed[-1])
		assert.same({}, QuestWithFriendsDB.collapsedQuests)
		panel.scroll:SetVerticalScroll(20)
		presentation.scenario = "synced"
		show({}, true)
		assert.are.equal(0, panel.scroll:GetVerticalScroll())
		assert.are.equal("Party in sync", panel.status.text)
		show({}, false)
		assert.are.equal("Party status incomplete", panel.status.text)
		presentation.screenshot = false
		show({ group(-1) }, true)
		assert.are.equal("Preview · Sample party data", panel.status.text)
		assert.is_true(panel.stopPreview.shown)
		assert.is_false(row.shareButton.enabled)
	end)

	it("keeps the preview notice in the footer even without an exit callback", function()
		loadPanel()
		QuestWithFriends.Panel.show({ group(-1) }, true, true, nil, nil, nil, nil, { preview = true })
		assert.are.equal("Preview · Sample party data", panel.status.text)
		assert.same({ panel, "BOTTOMLEFT", 14, 19 }, panel.status.points.LEFT)
		assert.are.equal(35, panel.scroll.points.BOTTOMRIGHT[4])
		assert.is_nil(panel.stopPreview)
	end)

	it("only permits moving and resizing while unlocked and shrinks again when locked", function()
		loadPanel()
		assert.are.equal(82, panel.height)
		assert.is_false(panel.header.mouseEnabled)
		assert.is_true(panel.lock.shown)
		assert.is_false(panel.hint.shown)
		assert.same({ 0, 0.5, 0, 1 }, panel.lock.icon.texCoord)
		assert.is_false(panel.resize.shown)
		panel.header.OnDragStart(panel.header)
		panel.resize.OnMouseDown(panel.resize, "LeftButton")
		assert.is_nil(panel.moving)
		assert.is_nil(panel.sizing)
		panel.lock.OnClick()
		assert.is_false(QuestWithFriendsDB.panelLocked)
		assert.are.equal(360, panel.height)
		assert.is_true(panel.header.mouseEnabled)
		assert.is_true(panel.lock.shown)
		assert.is_true(panel.hint.shown)
		assert.same({ 0.5, 1, 0, 1 }, panel.lock.icon.texCoord)
		assert.is_true(panel.resize.shown)
		panel.resize.OnMouseDown(panel.resize, "RightButton")
		assert.is_nil(panel.sizing)
		panel.resize.OnMouseDown(panel.resize, "LeftButton")
		assert.are.equal("BOTTOMRIGHT", panel.sizing)
		panel:SetSize(420, 240)
		panel.resize.OnMouseUp(panel.resize)
		assert.same({ width = 420, height = 240 }, QuestWithFriendsDB.panelSize)
		assert.are.equal(240, panel.height)
		panel.lock.OnClick()
		assert.is_true(QuestWithFriendsDB.panelLocked)
		assert.are.equal(82, panel.height)
		assert.are.equal(420, panel.width)
		assert.is_false(panel.resize.shown)
		QuestWithFriends.Panel.setLocked(false)
		assert.are.equal(240, panel.height)
	end)

	it("aligns the scroll controls with the header and keeps preview exit clear of resizing", function()
		loadPanel()
		for _, width in ipairs({ 300, 348, 480 }) do
			QuestWithFriendsDB.panelSize = { width = width, height = 360 }
			for _, unlocked in ipairs({ false, true }) do
				QuestWithFriends.Panel.setLocked(not unlocked)
				for _, count in ipairs({ 1, 25 }) do
					local groups = {}
					for index = 1, count do
						groups[index] = group(index)
					end
					QuestWithFriends.Panel.show(groups, true, true, nil, nil, nil, nil, {
						preview = true,
						onStop = function() end,
					})
					local noticeHeight = panel.status:GetStringHeight()
					local footer = math.max(35, noticeHeight + 16)
					assert.same(
						{ "BOTTOMLEFT", "BOTTOMLEFT", 14, 8 + math.max(0, (noticeHeight - 22) / 2) },
						panel.stopPreview.point
					)
					assert.are.equal(100, panel.stopPreview.width)
					assert.same({ panel.stopPreview, "RIGHT", 8, 0 }, panel.status.points.LEFT)
					assert.are.equal(width - 122 - (unlocked and 30 or 14), panel.status.width)
					assert.are.equal(panel, panel.status.parent)
					assert.are.equal(footer, panel.scroll.points.BOTTOMRIGHT[4])
					assert.are.equal(unlocked, panel.resize.shown)
					local scrollBar = panel.scroll.ScrollBar
					local top, bottom = scrollBar.points.TOPRIGHT, scrollBar.points.BOTTOMRIGHT
					assert.are.equal(-11, top[3])
					assert.are.equal(-11, bottom[3])
					assert.are.equal(footer + 16, bottom[4])
					assert.are.equal(panel.scroll.points.TOPLEFT[4] - 16, top[4])
					assert.are.equal(count > 1, scrollBar.shown)
					assert.are.equal(width - (count > 1 and 24 or 0), panel.content.width)
				end
			end
		end
	end)

	it("updates the lock tooltip and icon when toggled or changed externally", function()
		loadPanel()
		assert.same({ 24, 24 }, panel.lock.size)
		assert.are.equal("Interface\\AddOns\\QuestWithFriends\\Media\\PanelLock", panel.lock.icon.texture)
		assert.same({ "RIGHT", "LEFT", -4, 0 }, panel.lock.point)
		panel.lock.OnEnter(panel.lock)
		assert.are.equal("Unlock to move and resize", GameTooltip.text)
		assert.is_true(GameTooltip.shown)
		local lockedColor = panel.lock.icon.color
		panel.filter:OpenMenu()
		panel.lock.OnClick()
		assert.is_false(panel.filter.menuOpen)
		assert.are.equal("Lock panel", GameTooltip.text)
		assert.are_not.same(lockedColor, panel.lock.icon.color)
		QuestWithFriends.Panel.setLocked(true)
		assert.are.equal("Unlock to move and resize", GameTooltip.text)
		assert.same(lockedColor, panel.lock.icon.color)
		panel.lock.OnLeave(panel.lock)
		assert.is_false(GameTooltip.shown)
		QuestWithFriends.Panel.setLocked(false)
		assert.is_false(GameTooltip.shown)
		panel.lock.OnEnter(panel.lock)
		panel.lock:Hide()
		assert.is_false(GameTooltip.shown)
	end)

	it("passes both lock states through the presentation callback", function()
		loadPanel()
		local locks = {}
		QuestWithFriends.Panel.show({}, true, true, nil, nil, nil, nil, {
			onLock = function(locked)
				locks[#locks + 1] = locked
				QuestWithFriends.Panel.setLocked(locked)
			end,
		})
		panel.lock.OnClick()
		assert.is_false(QuestWithFriendsDB.panelLocked)
		panel.lock.OnClick()
		assert.is_true(QuestWithFriendsDB.panelLocked)
		assert.same({ false, true }, locks)
	end)

	it("restores account-wide size and lock preferences after reloading", function()
		QuestWithFriendsDB.panelSize = { width = 480, height = 220 }
		QuestWithFriendsDB.panelLocked = false
		loadPanel()
		assert.are.equal(480, panel.width)
		assert.are.equal(220, panel.height)
		loadPanel()
		assert.are.equal(480, panel.width)
		assert.are.equal(220, panel.height)
		QuestWithFriends.Panel.setLocked(true)
		loadPanel()
		assert.are.equal(480, panel.width)
		assert.are.equal(82, panel.height)
	end)

	it("reflows wrapped objectives on resize without scaling text or changing sharing", function()
		loadPanel()
		QuestWithFriends.Panel.show({
			group(42, {
				{
					player = "Julia",
					kind = "needs",
					reason = "objective",
					objective = {
						text = string.rep("Long objective ", 12),
						have = 2,
						need = 8,
					},
				},
			}),
		}, true, true, nil, function() end)
		local narrow = panel.content.height
		QuestWithFriends.Panel.setLocked(false)
		panel.resize.OnMouseDown(panel.resize, "LeftButton")
		panel:SetSize(600, 360)
		panel.resize.OnMouseUp(panel.resize)
		assert.is_true(panel.content.height < narrow)
		assert.are.equal(544, fontStrings[5].width)
		assert.is_true(fontStrings[4].shareButton.shown)
	end)

	it("preserves the visible quest when activity sorting or notices change", function()
		loadPanel()
		local groups = {}
		for index = 1, 15 do
			groups[index] = group(index)
		end
		QuestWithFriends.Panel.show(groups, true, true)
		panel.scroll:SetVerticalScroll(43 * 4 + 5)
		local last = table.remove(groups)
		table.insert(groups, 1, last)
		QuestWithFriends.Panel.show(groups, false, true, nil, nil, { { player = "Bob", reason = "offline" } })
		assert.are.equal(43 * 5 + 5, panel.scroll.scroll)
		QuestWithFriends.Panel.show({}, true, true)
		assert.are.equal(0, panel.scroll.scroll)
		assert.is_false(panel.scroll.ScrollBar.shown)
	end)

	it("raises the usable minimum for pinned notices without overwriting the saved ceiling", function()
		QuestWithFriendsDB.panelSize = { width = 300, height = 150 }
		loadPanel()
		local notices = {}
		for index = 1, 4 do
			notices[index] = { player = "Friend " .. index, reason = "waiting" }
		end
		local differences = {}
		for index = 1, 20 do
			differences[index] = { player = "Julia", kind = "missing", reason = "missing" }
		end
		QuestWithFriends.Panel.show({ group(nil, differences) }, false, true, nil, nil, notices)
		assert.is_true(panel.height > 150)
		assert.are.equal(150, QuestWithFriendsDB.panelSize.height)
		assert.is_true(panel.scrollRange > 0)
		for index = 4, 7 do
			assert.are.equal(panel, fontStrings[index]:GetParent())
		end
		QuestWithFriends.Panel.show({ group(nil, differences) }, true, true)
		assert.are.equal(150, panel.height)
	end)

	it("validates non-finite and out-of-range saved dimensions and clamps offscreen positions", function()
		for _, size in ipairs({ "bad", { width = 0 / 0, height = math.huge }, { width = -1, height = -1 } }) do
			QuestWithFriendsDB.panelSize = size
			QuestWithFriendsDB.panelPosition = { x = 100000, y = -100000 }
			loadPanel()
			assert.is_true(panel.width >= 300 and panel.width <= UIParent.width)
			assert.is_true(panel.height >= 82 and panel.height <= UIParent.height)
			assert.is_true(QuestWithFriendsDB.panelPosition.x <= UIParent.width - panel.width)
			assert.is_true(QuestWithFriendsDB.panelPosition.y >= panel.height - UIParent.height)
		end
	end)

	it("adapts to display and UI-scale changes without discarding the preferred size", function()
		QuestWithFriendsDB.panelSize = { width = 800, height = 700 }
		QuestWithFriendsDB.panelLocked = false
		loadPanel()
		UIParent.width, UIParent.height = 640, 480
		panel.OnEvent(panel, "DISPLAY_SIZE_CHANGED")
		assert.are.equal(640, panel.width)
		assert.are.equal(480, panel.height)
		assert.same({ width = 800, height = 700 }, QuestWithFriendsDB.panelSize)
		UIParent.width, UIParent.height = 1600, 900
		panel.OnEvent(panel, "DISPLAY_SIZE_CHANGED")
		assert.are.equal(800, panel.width)
		assert.are.equal(700, panel.height)
		panel.scale = 2
		panel.OnEvent(panel, "UI_SCALE_CHANGED")
		assert.are.equal(800, panel.width)
		assert.are.equal(450, panel.height)
	end)

	it("does not reopen a hidden panel when unlocking and safely ends an interrupted resize", function()
		loadPanel()
		QuestWithFriends.Panel.hide()
		QuestWithFriends.Panel.setLocked(false)
		assert.is_false(panel.shown)
		QuestWithFriends.Panel.show({}, true, true)
		panel.resize.OnMouseDown(panel.resize, "LeftButton")
		panel:SetSize(420, 260)
		QuestWithFriends.Panel.hide()
		assert.is_true(panel.stopped)
		assert.same({ width = 420, height = 260 }, QuestWithFriendsDB.panelSize)
		QuestWithFriends.Panel.show({}, true, true)
		assert.are.equal(260, panel.height)
	end)

	it("uses the default position if saved coordinates are invalid", function()
		QuestWithFriendsDB.panelPosition = { x = "bad", y = -280 }
		loadPanel()
		assert.same({ "TOPLEFT", "TOPLEFT", 1216, -180 }, panel.point)
	end)
end)
