local QWF = QuestWithFriends
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
local collapsedQuests
local stopPreview
local WIDTH = 348
local MAX_ROWS = 18
local DETAIL_X = 41
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
end

local function createPanel()
	QuestWithFriendsDB.collapsedQuests = type(QuestWithFriendsDB.collapsedQuests) == "table"
			and QuestWithFriendsDB.collapsedQuests
		or {}
	panel = CreateFrame("Frame", "QuestWithFriendsPanel", UIParent, "BackdropTemplate")
	panel:SetSize(WIDTH, 58)
	local position = QuestWithFriendsDB.panelPosition
	if position and type(position.x) == "number" and type(position.y) == "number" then
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
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function(self)
		self.filter:CloseMenu()
		self:StartMoving()
	end)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local x = self:GetLeft() - UIParent:GetLeft()
		local y = self:GetTop() - UIParent:GetTop()
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
		QuestWithFriendsDB.panelPosition = { x = x, y = y }
	end)
	panel:SetClampedToScreen(true)

	local heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	heading:SetPoint("TOPLEFT", 14, -12)
	heading:SetText("QUEST WITH FRIENDS")
	heading:SetTextColor(0.72, 0.79, 0.88)

	panel.filter = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
	panel.filter:SetSize(92, 24)
	panel.filter:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -7)
	panel.filter:OverrideText("Filters")
	panel.filter:SetupMenu(generateFilterMenu)
	panel:SetScript("OnHide", function(self)
		self.filter:CloseMenu()
	end)

	panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.status:SetPoint("TOPLEFT", 14, -32)
	panel.status:SetWidth(WIDTH - 28)
	panel.status:SetJustifyH("LEFT")

	panel.scope = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panel.scope:SetPoint("TOPLEFT", 14, -50)
	panel.scope:SetWidth(WIDTH - 28)
	panel.scope:SetJustifyH("LEFT")
	panel.scope:SetTextColor(0.72, 0.78, 0.85)
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
		if difference.reason ~= reason then
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
		local button = CreateFrame("Button", nil, panel)
		row.toggleButton = button
		button:RegisterForClicks("LeftButtonUp")
		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.06)
		button.indicator = button:CreateTexture(nil, "OVERLAY")
		button.indicator:SetPoint("LEFT", 0, 0)
		button.indicator:SetSize(12, 12)
		button.indicator:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
		button.indicator:SetTexCoord(0.25, 0.75, 0.25, 0.75)
		button.indicator:SetDesaturated(true)
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
	button:SetPoint("TOPLEFT", panel, "TOPLEFT", 15, -y)
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

local function addRow(text, y, kind, questID, group, collapsed)
	activeRows = activeRows + 1
	local row = rows[activeRows]
	if not row then
		row = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row:SetWidth(WIDTH - 30)
		row:SetJustifyH("LEFT")
		row:SetJustifyV("TOP")
		row:SetWordWrap(true)
		rows[#rows + 1] = row
	end
	row.questID = questID
	if questID and not row.shareButton then
		row.shareButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
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
				isPreview and "Sample quest only. Sharing is disabled in preview."
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
		row.icon = panel:CreateTexture(nil, "OVERLAY")
		row.icon:SetSize(14, 14)
		row.icon:SetDesaturated(true)
	end
	if style then
		row.icon:ClearAllPoints()
		row.icon:SetPoint("TOPLEFT", panel, "TOPLEFT", DETAIL_X - 18, -y)
		row.icon:SetTexture(style.icon)
		row.icon:SetVertexColor(unpack(style.color))
		row.icon:Show()
	end
	local x = group and 31 or (style and DETAIL_X or 15)
	local width = WIDTH - x - 15 - (questID and 60 or 0)
	row:SetWidth(width)
	row:SetWordWrap(not group)
	if questID then
		row.shareButton:ClearAllPoints()
		row.shareButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -15, -y)
		row.shareButton:SetEnabled(not isPreview)
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
	local text = objective and (objective.text .. " " .. objective.have .. "/" .. objective.need)
		or labels[difference.reason]
		or "Status unknown"
	return difference.player .. ": " .. text
end

function QWF.Panel.show(groups, complete, zoneFilter, onToggle, onShare, notices, filters, presentation)
	presentation = presentation or {}
	isPreview = presentation.preview == true
	stopPreview = presentation.onStop
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
	collapsedQuests = presentation.collapsedQuests or QuestWithFriendsDB.collapsedQuests
	panel.scope:SetText(scopeText())
	panel.filter:GenerateMenu()
	for _, row in ipairs(rows) do
		row:Hide()
		row:ClearAllPoints()
		row.questID = nil
		row.groupID = nil
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
	local y = 70
	if isPreview then
		panel.status:SetText("Preview · Sample party data")
		panel.status:SetTextColor(0.72, 0.79, 0.88)
	elseif #groups == 0 and complete then
		panel.status:SetText("Party in sync")
		panel.status:SetTextColor(0.52, 0.87, 0.62)
	else
		panel.status:SetText(complete and "Party out of sync" or "Party status incomplete")
		panel.status:SetTextColor(0.98, 0.73, 0.40)
	end
	local count = 0
	for _, notice in ipairs(notices or {}) do
		local text = connectionLabels[notice.reason] or "Quest status unknown · /qwf to refresh"
		y = addRow(notice.player .. ": " .. text, y, "unknown")
		count = count + 1
	end
	if count > 0 then
		y = y + 3
	end
	local remaining = 0
	for index, group in ipairs(groups) do
		local collapsed = collapsedQuests[group.questID] == true
		local size = collapsed and 1 or #group.differences + 1
		local available = MAX_ROWS - count
		-- Never hide the first quest entirely just because its details exceed the row budget.
		local oversized = size > available and index == 1 and available >= 3
		if size <= available or oversized then
			local questID = (onShare or isPreview) and group.shareQuestID
			y = addRow(group.title, y, "quest", questID, group, collapsed)
			count = count + 1
			local shown = collapsed and 0 or (oversized and available - 2 or #group.differences)
			for detailIndex = 1, shown do
				local difference = group.differences[detailIndex]
				y = addRow(differenceText(difference), y, difference.kind)
				count = count + 1
			end
			if not collapsed and shown < #group.differences then
				y = addRow("  +" .. (#group.differences - shown) .. " more differences for this quest", y, "muted")
				count = count + 1
			end
			y = y + 3
		else
			remaining = #groups - index + 1
			break
		end
	end
	if remaining > 0 then
		local noun = remaining == 1 and "quest" or "quests"
		y = addRow("+" .. remaining .. " more " .. noun .. " with differences", y, "muted")
	end
	if isPreview and stopPreview then
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
		panel.stopPreview:ClearAllPoints()
		panel.stopPreview:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -15, -y)
		panel.stopPreview:Show()
		y = y + 27
	elseif panel.stopPreview then
		panel.stopPreview:Hide()
	end
	panel:SetHeight(math.max(58, y + 8))
	panel:Show()
end
