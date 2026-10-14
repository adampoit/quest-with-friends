local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
QWF.Panel = {}
local panel
local rows = {}
local activeRows = 0
local toggleFilter
local currentZoneOnly
local questFilters = {}
local shareQuest
local redraw
local isPreview = false
local isScreenshot = false
local previewScenario
local collapsedQuests
local stopPreview
local sortMode = "smart"
local selectSort
local DEFAULT_WIDTH = 348
local DEFAULT_HEIGHT = 360
local MIN_WIDTH = 300
local MIN_HEIGHT = 150
local MIN_QUEST_HEIGHT = 60
local DETAIL_X = 41
local PANEL_INSET = 14
local CONTROL_INSET = 10
local SCROLLBAR_GAP = 6
local STATUS_Y = 36
local HEADER_BODY_GAP = 5
local layoutBusy = false
local resizing = false
local moving = false
local onLock
local groupOffsets = {}
local reflow

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function screenSize()
	local scale = panel:GetEffectiveScale() / UIParent:GetEffectiveScale()
	return UIParent:GetWidth() / scale, UIParent:GetHeight() / scale
end

local function savePosition()
	local scale = panel:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local x = panel:GetLeft() - UIParent:GetLeft() / scale
	local y = panel:GetTop() - UIParent:GetTop() / scale
	local width, height = screenSize()
	x = clamp(x, 0, math.max(0, width - panel:GetWidth()))
	y = clamp(y, math.min(0, panel:GetHeight() - height), 0)
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
	QWF.db.panelPosition = { x = x, y = y }
end

local function finishLayout()
	if moving or resizing then
		panel:StopMovingOrSizing()
		if resizing then
			QWF.db.panelSize = { width = panel:GetWidth(), height = panel:GetHeight() }
		end
		moving, resizing = false, false
		savePosition()
	end
end

function QWF.Panel.setLocked(locked)
	QWF.db.panelLocked = locked ~= false
	if panel then
		finishLayout()
		if redraw and panel:IsShown() then
			redraw()
		end
	end
end
local styles = {
	missing = { color = { 0.98, 0.73, 0.40 }, icon = "Interface\\GossipFrame\\AvailableQuestIcon" },
	needs = { color = { 0.57, 0.78, 1.00 }, icon = "Interface\\QuestFrame\\UI-Quest-BulletPoint" },
	ahead = { color = { 0.52, 0.87, 0.62 }, icon = "Interface\\RaidFrame\\ReadyCheck-Ready" },
	unknown = { color = { 0.72, 0.78, 0.85 }, icon = "Interface\\GossipFrame\\ActiveQuestIcon" },
}

local function scopeText()
	local categories = "Standard quests"
	if questFilters.professions and questFilters.classes then
		categories = "All quest types"
	elseif questFilters.professions then
		categories = "Includes profession quests"
	elseif questFilters.classes then
		categories = "Includes class quests"
	end
	return (currentZoneOnly and "Current zone" or "All zones") .. " · " .. categories
end

local function generateFilterMenu(_, root)
	root:CreateTitle("Show")
	root:CreateCheckbox("Current zone only", function()
		return currentZoneOnly
	end, function()
		if toggleFilter then
			toggleFilter()
		end
	end):SetEnabled(toggleFilter ~= nil)
	root:CreateCheckbox("Show profession quests", function()
		return questFilters.professions == true
	end, function()
		if questFilters.toggleProfessions then
			questFilters.toggleProfessions()
		end
	end):SetEnabled(questFilters.toggleProfessions ~= nil)
	root:CreateCheckbox("Show class quests", function()
		return questFilters.classes == true
	end, function()
		if questFilters.toggleClasses then
			questFilters.toggleClasses()
		end
	end):SetEnabled(questFilters.toggleClasses ~= nil)
	root:CreateDivider()
	root:CreateTitle("Sort by")
	for _, option in ipairs({ { "smart", "Smart" }, { "title", "Title A–Z" } }) do
		local mode, label = option[1], option[2]
		root:CreateRadio(label, function()
			return sortMode == mode
		end, function()
			if selectSort then
				selectSort(mode)
			end
		end):SetEnabled(selectSort ~= nil)
	end
end

local function lockTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(QWF.db.panelLocked == false and "Lock panel" or "Unlock to move and resize")
	GameTooltip:Show()
end

local function createPanel()
	QWF.db.collapsedQuests = type(QWF.db.collapsedQuests) == "table" and QWF.db.collapsedQuests or {}
	panel = CreateFrame("Frame", "QuestWithFriendsPanel", UIParent, "BackdropTemplate")
	panel:SetSize(DEFAULT_WIDTH, 78)
	local position = QWF.db.panelPosition
	if type(position) == "table" and finite(position.x) and finite(position.y) then
		panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", position.x, position.y)
	else
		panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -36, -180)
	end
	panel:SetFrameStrata("MEDIUM")
	panel:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0.025, 0.035, 0.055, 0.94)
	panel:SetBackdropBorderColor(0.28, 0.34, 0.43, 0.8)
	panel:SetMovable(true)
	panel:SetResizable(true)
	panel:SetClampedToScreen(true)
	panel.header = CreateFrame("Frame", nil, panel)
	panel.header:SetPoint("TOPLEFT", 4, -4)
	panel.header:SetPoint("TOPRIGHT", -4, -4)
	panel.header:SetHeight(30)
	panel.header:EnableMouse(true)
	panel.header:RegisterForDrag("LeftButton")
	panel.header:SetScript("OnDragStart", function()
		if QWF.db.panelLocked == false then
			panel.filter:CloseMenu()
			savePosition()
			moving = true
			panel:StartMoving()
		end
	end)
	panel.header:SetScript("OnDragStop", function()
		if moving then
			finishLayout()
			reflow()
		end
	end)
	panel:SetScript("OnSizeChanged", function()
		if not layoutBusy and reflow then
			reflow()
		end
	end)
	panel:RegisterEvent("DISPLAY_SIZE_CHANGED")
	panel:RegisterEvent("UI_SCALE_CHANGED")
	panel:SetScript("OnEvent", function()
		if reflow then
			reflow()
		end
	end)

	local heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	heading:SetPoint("LEFT", panel, "TOPLEFT", PANEL_INSET, -CONTROL_INSET - 12)
	heading:SetText(QWF.title or "Quest With Friends")
	heading:SetTextColor(0.94, 0.95, 0.97)
	panel.heading = heading

	panel.filter = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
	panel.filter:SetSize(92, 24)
	panel.filter:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -CONTROL_INSET, -CONTROL_INSET)
	panel.filter:OverrideText("View")
	panel.filter:SetupMenu(generateFilterMenu)
	panel:SetScript("OnHide", function(self)
		self.filter:CloseMenu()
		finishLayout()
	end)

	panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.status:SetPoint("TOPLEFT", PANEL_INSET, -STATUS_Y)
	panel.status:SetWidth(DEFAULT_WIDTH - 2 * PANEL_INSET)
	panel.status:SetJustifyH("LEFT")

	panel.scope = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panel.scope:SetPoint("TOPLEFT", PANEL_INSET, -STATUS_Y - 18)
	panel.scope:SetWidth(DEFAULT_WIDTH - 2 * PANEL_INSET)
	panel.scope:SetJustifyH("LEFT")
	panel.scope:SetTextColor(0.72, 0.78, 0.85)

	panel.lock = CreateFrame("Button", nil, panel)
	panel.lock:SetSize(24, 24)
	panel.lock:SetPoint("RIGHT", panel.filter, "LEFT", -4, 0)
	panel.lock.icon = panel.lock:CreateTexture(nil, "ARTWORK")
	panel.lock.icon:SetSize(20, 20)
	panel.lock.icon:SetPoint("CENTER")
	panel.lock.icon:SetTexture((QWF.assetPath or "Interface\\AddOns\\QuestWithFriends\\Media\\") .. "PanelLock")
	local lockHighlight = panel.lock:CreateTexture(nil, "HIGHLIGHT")
	lockHighlight:SetAllPoints()
	lockHighlight:SetColorTexture(1, 1, 1, 0.08)
	heading:SetPoint("RIGHT", panel.lock, "LEFT", -8, 0)
	heading:SetJustifyH("LEFT")
	heading:SetWordWrap(false)
	panel.lock:RegisterForClicks("LeftButtonUp")
	panel.lock:SetScript("OnClick", function()
		panel.filter:CloseMenu()
		local locked = QWF.db.panelLocked == false
		if onLock then
			onLock(locked)
		else
			QWF.Panel.setLocked(locked)
		end
	end)
	panel.lock:SetScript("OnEnter", lockTooltip)
	panel.lock:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	panel.lock:SetScript("OnHide", panel.lock:GetScript("OnLeave"))
	panel.hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panel.hint:SetJustifyH("LEFT")
	panel.hint:SetTextColor(0.72, 0.78, 0.85)
	panel.hint:SetText("Drag header or corner")

	panel.scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	panel.content = CreateFrame("Frame", nil, panel.scroll)
	panel.content:SetSize(DEFAULT_WIDTH, 1)
	panel.scroll:SetScrollChild(panel.content)
	panel.scroll:EnableMouseWheel(true)
	panel.scroll:SetScript("OnMouseWheel", function(self, delta)
		self:SetVerticalScroll(clamp(self:GetVerticalScroll() - delta * 36, 0, panel.scrollRange or 0))
	end)

	panel.resize = CreateFrame("Button", nil, panel)
	panel.resize:SetSize(20, 20)
	panel.resize:SetPoint("BOTTOMRIGHT", -4, 4)
	panel.resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	panel.resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	panel.resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	panel.resize:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" and QWF.db.panelLocked == false then
			panel.filter:CloseMenu()
			savePosition()
			resizing = true
			panel:StartSizing("BOTTOMRIGHT")
		end
	end)
	panel.resize:SetScript("OnMouseUp", function()
		if resizing then
			finishLayout()
			reflow()
		end
	end)
	panel.resize:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to resize")
		GameTooltip:AddLine(
			"Sets the width and maximum height. Lock the panel to shrink it to fit its contents.",
			1,
			1,
			1,
			true
		)
		GameTooltip:Show()
	end)
	panel.resize:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	panel.resize:SetScript("OnHide", panel.resize:GetScript("OnLeave"))
end

local function hideTooltip(self)
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

local function collapsedSummary(group)
	local players, count, reason = {}, 0, group.differences[1] and group.differences[1].reason
	for _, difference in ipairs(group.differences) do
		if not players[difference.player] then
			players[difference.player] = true
			count = count + 1
		end
		if difference.reason ~= reason or difference.kind == "ahead" then
			reason = false
		end
	end
	if reason == "missing" then
		return count .. " missing", styles.missing.color
	elseif reason == "active" or reason == "objective" then
		return count .. " need" .. (count == 1 and "s" or "") .. " progress", styles.needs.color
	end
	return count .. " affected", { 0.72, 0.78, 0.85 }
end

local function setQuestHeading(row, group, collapsed, y, width)
	if not row.toggleButton then
		local button = CreateFrame("Button", nil, panel.content)
		row.toggleButton = button
		button:RegisterForClicks("LeftButtonUp")
		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.06)
		button.indicator = button:CreateTexture(nil, "OVERLAY")
		button.indicator:SetPoint("LEFT", button, "LEFT", 0, 2)
		button.indicator:SetSize(12, 12)
		button.indicator:SetTexture((QWF.assetPath or "Interface\\AddOns\\QuestWithFriends\\Media\\") .. "QuestToggle")
		button.indicator:SetVertexColor(0.72, 0.79, 0.88)
		button.summary = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		button.summary:SetPoint("RIGHT", 0, 0)
		button.summary:SetJustifyH("RIGHT")
		button.summary:SetWordWrap(false)
		button:SetScript("OnClick", function()
			if row.groupID then
				local saved = collapsedQuests
				saved[row.groupID] = saved[row.groupID] ~= true or nil
				redraw()
			end
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(row.title)
			GameTooltip:AddLine(row.summaryText, 1, 1, 1, true)
			GameTooltip:AddLine(row.collapsed and "Click to expand" or "Click to collapse", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", hideTooltip)
		button:SetScript("OnHide", hideTooltip)
	end
	local button = row.toggleButton
	row.groupID, row.title, row.collapsed = group.questID, group.title, collapsed
	local summary, color = collapsedSummary(group)
	row.summaryText = summary
	button:ClearAllPoints()
	if button:GetParent() ~= row:GetParent() then
		button:SetParent(row:GetParent())
	end
	button:SetPoint("TOPLEFT", row:GetParent(), "TOPLEFT", 15, -y)
	button:SetSize(width + 16, 20)
	button.indicator:SetRotation(collapsed and 0 or -math.pi / 2)
	local summaryWidth = 0
	if collapsed then
		button.summary:SetText(summary)
		button.summary:SetTextColor(unpack(color))
		summaryWidth = math.min(130, button.summary:GetStringWidth())
		button.summary:SetWidth(summaryWidth)
		button.summary:Show()
	else
		button.summary:Hide()
	end
	row:SetWidth(width - (collapsed and summaryWidth + 8 or 0))
	button:Show()
end

local function addRow(text, y, kind, questID, group, collapsed, parent, availableWidth)
	activeRows = activeRows + 1
	local row = rows[activeRows]
	if not row then
		row = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row:SetJustifyH("LEFT")
		row:SetJustifyV("TOP")
		row:SetWordWrap(true)
		rows[#rows + 1] = row
	end
	if row:GetParent() ~= parent then
		row:SetParent(parent)
	end
	row.questID = questID
	if questID and not row.shareButton then
		row.shareButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
		row.shareButton:SetSize(52, 20)
		row.shareButton:SetText("Share")
		row.shareButton:RegisterForClicks("LeftButtonUp")
		row.shareButton:SetScript("OnClick", function()
			if row.questID and shareQuest and not isPreview then
				shareQuest(row.questID)
			end
		end)
		row.shareButton:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Share quest")
			GameTooltip:AddLine(
				isPreview and not isScreenshot and "Sample quest only. Sharing is disabled in preview."
					or "Offers this quest to the party. WoW determines who can accept it.",
				1,
				1,
				1,
				true
			)
			GameTooltip:Show()
		end)
		row.shareButton:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		row.shareButton:SetScript("OnHide", function(self)
			if GameTooltip:IsOwned(self) then
				GameTooltip:Hide()
			end
		end)
	end
	local style = styles[kind]
	if style and not row.icon then
		row.icon = parent:CreateTexture(nil, "OVERLAY")
		row.icon:SetSize(14, 14)
		row.icon:SetDesaturated(true)
	end
	if style then
		if row.icon:GetParent() ~= parent then
			row.icon:SetParent(parent)
		end
		row.icon:ClearAllPoints()
		row.icon:SetPoint("TOPLEFT", parent, "TOPLEFT", DETAIL_X - 18, -y + 2)
		row.icon:SetTexture(style.icon)
		row.icon:SetVertexColor(unpack(style.color))
		row.icon:Show()
	end
	local x = group and 31 or (style and DETAIL_X or 15)
	local width = availableWidth - x - 15 - (questID and 60 or 0)
	row:SetWidth(width)
	row:SetWordWrap(not group)
	if questID then
		if row.shareButton:GetParent() ~= parent then
			row.shareButton:SetParent(parent)
		end
		row.shareButton:ClearAllPoints()
		row.shareButton:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -15, -y)
		-- Screenshot controls look live, but the click handler still rejects sample quests.
		row.shareButton:SetEnabled(not isPreview or isScreenshot)
		row.shareButton:Show()
	end
	row:SetPoint("TOPLEFT", x, -y - (group and 3 or 0))
	row:SetText(text)
	if group then
		setQuestHeading(row, group, collapsed, y, width)
	end
	if style then
		row:SetTextColor(unpack(style.color))
	elseif kind == "muted" then
		row:SetTextColor(0.72, 0.78, 0.85)
	else
		row:SetTextColor(0.94, 0.95, 0.97)
	end
	row:Show()
	return y + math.max(group and 20 or 15, row:GetStringHeight()) + (kind == "quest" and 2 or 3)
end

function QWF.Panel.hide()
	if panel then
		panel:Hide()
	end
end

local connectionLabels = {
	offline = "Offline · sync resumes when online",
	unknown = "Quest With Friends not detected",
	waiting = "Waiting for quest snapshot · /qwf to refresh",
	refreshing = "Refreshing · showing last snapshot",
	stale = "Quest data stale · /qwf to refresh",
	oversized = "Quest log too large to share · status unknown",
	incompatible = "Incompatible addon protocol · update addon",
}

local labels = {
	missing = "Missing",
	active = "Still in progress",
	ready = "Ready to turn in",
	completed = "Completed",
}

local function differenceText(difference)
	local objective = difference.objective
	local text = labels[difference.reason] or "Status unknown"
	if objective then
		local have = objective.spare ~= nil and math.min(objective.have, objective.need) or objective.have
		text = objective.text .. " " .. have .. "/" .. objective.need
		if objective.spare and objective.spare > 0 then
			text = text .. " · " .. objective.spare .. " spare"
		end
	end
	return difference.player .. ": " .. text
end

function QWF.Panel.show(groups, complete, zoneFilter, onToggle, onShare, notices, filters, presentation)
	presentation = presentation or {}
	local previewChanged = isPreview ~= (presentation.preview == true)
		or isScreenshot ~= (presentation.screenshot == true)
		or previewScenario ~= presentation.scenario
	previewScenario = presentation.scenario
	isPreview = presentation.preview == true
	isScreenshot = isPreview and presentation.screenshot == true
	local showPreviewNotice = isPreview and not isScreenshot
	stopPreview = presentation.onStop
	sortMode = presentation.sortMode or "smart"
	selectSort = presentation.onSort
	redraw = function()
		QWF.Panel.show(groups, complete, zoneFilter, onToggle, onShare, notices, filters, presentation)
	end
	toggleFilter = onToggle
	currentZoneOnly = zoneFilter == true
	questFilters = filters or {}
	shareQuest = onShare
	if not panel then
		createPanel()
	end
	panel.heading:SetText(isScreenshot and "Quest With Friends" or QWF.title or "Quest With Friends")
	if previewChanged then
		panel.scroll:SetVerticalScroll(0)
		groupOffsets = {}
	end
	collapsedQuests = presentation.collapsedQuests or QWF.db.collapsedQuests
	panel.scope:SetText(scopeText())
	panel.filter:GenerateMenu()
	panel.status:SetFontObject(showPreviewNotice and "GameFontHighlightSmall" or "GameFontHighlight")
	panel.status:SetJustifyH("LEFT")
	if showPreviewNotice then
		panel.status:SetText("Preview · Sample party data")
		panel.status:SetTextColor(0.72, 0.78, 0.85)
	elseif #groups == 0 and complete then
		panel.status:SetText("Party in sync")
		panel.status:SetTextColor(0.52, 0.87, 0.62)
	else
		panel.status:SetText(complete and "Party out of sync" or "Party status incomplete")
		panel.status:SetTextColor(0.98, 0.73, 0.40)
	end
	onLock = presentation.onLock
	if showPreviewNotice and stopPreview then
		if not panel.stopPreview then
			panel.stopPreview = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
			panel.stopPreview:SetSize(100, 22)
			panel.stopPreview:SetText("End preview")
			panel.stopPreview:RegisterForClicks("LeftButtonUp")
			panel.stopPreview:SetScript("OnClick", function()
				if stopPreview then
					stopPreview()
				end
			end)
		end
		panel.stopPreview:Show()
	elseif panel.stopPreview then
		panel.stopPreview:Hide()
	end
	reflow = function()
		if layoutBusy then
			return
		end
		layoutBusy = true
		local scroll = panel.scroll:GetVerticalScroll()
		-- Anchor to a quest, not an absolute offset, when Smart sorting moves groups.
		local anchorID, anchorDelta
		if scroll > 0 then
			for _, offset in ipairs(groupOffsets) do
				if offset.y <= scroll then
					anchorID, anchorDelta = offset.id, scroll - offset.y
				end
			end
		end
		local unlocked = QWF.db.panelLocked == false
		local screenWidth, screenHeight = screenSize()
		local saved = type(QWF.db.panelSize) == "table" and QWF.db.panelSize or {}
		local width = resizing and panel:GetWidth() or (finite(saved.width) and saved.width or DEFAULT_WIDTH)
		width = clamp(width, math.min(MIN_WIDTH, screenWidth), screenWidth)
		local ceiling = resizing and panel:GetHeight() or (finite(saved.height) and saved.height or DEFAULT_HEIGHT)
		panel:SetWidth(width)
		panel.status:ClearAllPoints()
		local footer = unlocked and 24 or 8
		if showPreviewNotice then
			local noticeX = PANEL_INSET + (stopPreview and panel.stopPreview:GetWidth() + 8 or 0)
			panel.status:SetWidth(math.max(1, width - noticeX - (unlocked and 30 or PANEL_INSET)))
			local noticeHeight = panel.status:GetStringHeight()
			local footerCenter = 8 + math.max(22, noticeHeight) / 2
			footer = math.max(35, noticeHeight + 16)
			if stopPreview then
				panel.stopPreview:ClearAllPoints()
				panel.stopPreview:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PANEL_INSET, footerCenter - 11)
				panel.status:SetPoint("LEFT", panel.stopPreview, "RIGHT", 8, 0)
			else
				panel.status:SetPoint("LEFT", panel, "BOTTOMLEFT", PANEL_INSET, footerCenter)
			end
		else
			panel.status:SetWidth(width - 2 * PANEL_INSET)
			panel.status:SetPoint("TOPLEFT", PANEL_INSET, -STATUS_Y)
		end
		panel.scope:SetWidth(width - 2 * PANEL_INSET)
		local scopeY = STATUS_Y + (showPreviewNotice and 0 or math.max(15, panel.status:GetStringHeight()) + 3)
		panel.scope:ClearAllPoints()
		panel.scope:SetPoint("TOPLEFT", PANEL_INSET, -scopeY)
		local headerHeight = scopeY + math.max(15, panel.scope:GetStringHeight()) + HEADER_BODY_GAP
		panel.lock:Show()
		panel.lock.icon:SetTexCoord(unlocked and 0.5 or 0, unlocked and 1 or 0.5, 0, 1)
		if unlocked then
			panel.lock.icon:SetVertexColor(0.98, 0.73, 0.40)
		else
			panel.lock.icon:SetVertexColor(0.72, 0.79, 0.88)
		end
		if GameTooltip:IsShown() and GameTooltip:IsOwned(panel.lock) then
			lockTooltip(panel.lock)
		end
		panel.hint:SetShown(unlocked)
		panel.resize:SetShown(unlocked)
		panel.header:EnableMouse(unlocked)
		if unlocked then
			panel.hint:ClearAllPoints()
			panel.hint:SetPoint("TOPLEFT", 15, -headerHeight - 4)
			panel.hint:SetWidth(width - 30)
			headerHeight = headerHeight + 28
		end
		local function draw(bodyWidth)
			for _, row in ipairs(rows) do
				row:Hide()
				row:ClearAllPoints()
				row.questID, row.groupID = nil, nil
				if row.toggleButton then
					row.toggleButton:Hide()
				end
				if row.icon then
					row.icon:Hide()
				end
				if row.shareButton then
					row.shareButton:Hide()
				end
			end
			activeRows = 0
			local pinned = headerHeight
			for _, notice in ipairs(notices or {}) do
				local text = connectionLabels[notice.reason] or "Quest status unknown · /qwf to refresh"
				pinned = addRow(notice.player .. ": " .. text, pinned, "unknown", nil, nil, nil, panel, width)
			end
			if #(notices or {}) > 0 then
				pinned = pinned + 3
			end
			local y = 0
			groupOffsets = {}
			for _, group in ipairs(groups) do
				groupOffsets[#groupOffsets + 1] = { id = group.questID, y = y }
				local collapsed = collapsedQuests[group.questID] == true
				local questID = (onShare or isPreview) and group.shareQuestID
				y = addRow(group.title, y, "quest", questID, group, collapsed, panel.content, bodyWidth)
				if not collapsed then
					for _, difference in ipairs(group.differences) do
						y = addRow(
							differenceText(difference),
							y,
							difference.kind,
							nil,
							nil,
							nil,
							panel.content,
							bodyWidth
						)
					end
				end
				y = y + 3
			end
			return pinned, y
		end
		local pinned, contentHeight = draw(width)
		-- Notices may raise the effective ceiling without changing the saved allowance.
		local minimum = math.min(screenHeight, math.max(MIN_HEIGHT, pinned + MIN_QUEST_HEIGHT + footer))
		ceiling = clamp(ceiling, minimum, screenHeight)
		local height = unlocked and ceiling or math.min(ceiling, pinned + contentHeight + footer)
		local viewport = math.max(1, height - pinned - footer)
		local overflow = contentHeight > viewport
		local scrollBar = panel.scroll.ScrollBar
		local controlWidth =
			math.max(scrollBar:GetWidth(), scrollBar.ScrollUpButton:GetWidth(), scrollBar.ScrollDownButton:GetWidth())
		local gutter = overflow and (controlWidth + SCROLLBAR_GAP) or 0
		if overflow then
			-- Only overflowing lists give up text width to the native scrollbar.
			pinned, contentHeight = draw(width - gutter)
		end
		local scale = panel:GetEffectiveScale() / UIParent:GetEffectiveScale()
		local left = panel:GetLeft() - UIParent:GetLeft() / scale
		local top = panel:GetTop() - UIParent:GetTop() / scale
		panel:SetResizeBounds(
			math.min(MIN_WIDTH, screenWidth),
			minimum,
			math.max(math.min(MIN_WIDTH, screenWidth), screenWidth - math.max(0, left)),
			math.max(minimum, screenHeight + math.min(0, top))
		)
		panel:SetHeight(height)
		panel.content:SetSize(width - gutter, math.max(1, contentHeight))
		panel.scroll:ClearAllPoints()
		panel.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -pinned)
		panel.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -gutter, footer)
		-- Center the wider arrow buttons on the slider while aligning their outer edge.
		local scrollRight = CONTROL_INSET + (controlWidth - scrollBar:GetWidth()) / 2
		scrollBar:ClearAllPoints()
		scrollBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -scrollRight, -pinned - scrollBar.ScrollUpButton:GetHeight())
		scrollBar:SetPoint(
			"BOTTOMRIGHT",
			panel,
			"BOTTOMRIGHT",
			-scrollRight,
			footer + scrollBar.ScrollDownButton:GetHeight()
		)
		scrollBar:SetShown(overflow)
		panel.scrollRange = math.max(0, contentHeight - viewport)
		for _, offset in ipairs(groupOffsets) do
			if offset.id == anchorID then
				scroll = offset.y + anchorDelta
				break
			end
		end
		scroll = clamp(scroll, 0, panel.scrollRange)
		panel.scroll.ScrollBar:SetMinMaxValues(0, panel.scrollRange)
		panel.scroll:SetVerticalScroll(scroll)
		panel.scroll.ScrollBar:SetValue(scroll)
		if not moving and not resizing then
			savePosition()
		end
		layoutBusy = false
	end
	reflow()
	panel:Show()
end
