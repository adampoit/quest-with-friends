local QWF = QuestWithFriends
QWF.Panel = {}
local panel
local rows = {}
local activeRows = 0
local toggleFilter
local currentZoneOnly
local questFilters = {}
local shareQuest
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

local function addRow(text, y, kind, questID)
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
			if row.questID and shareQuest then
				shareQuest(row.questID)
			end
		end)
		row.shareButton:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Share quest")
			GameTooltip:AddLine("Offers this quest to the party. WoW determines who can accept it.", 1, 1, 1, true)
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
	local x = style and DETAIL_X or 15
	row:SetWidth(WIDTH - x - 15 - (questID and 60 or 0))
	if questID then
		row.shareButton:ClearAllPoints()
		row.shareButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -15, -y)
		row.shareButton:Show()
	end
	row:SetPoint("TOPLEFT", x, -y)
	row:SetText(text)
	if style then
		row:SetTextColor(unpack(style.color))
	elseif kind == "muted" then
		row:SetTextColor(0.72, 0.78, 0.85)
	else
		row:SetTextColor(0.94, 0.95, 0.97)
	end
	row:Show()
	return y + math.max(questID and 20 or 15, row:GetStringHeight()) + (kind == "quest" and 2 or 3)
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

function QWF.Panel.show(groups, complete, zoneFilter, onToggle, onShare, notices, filters)
	toggleFilter = onToggle
	currentZoneOnly = zoneFilter == true
	questFilters = filters or {}
	shareQuest = onShare
	if not panel then
		createPanel()
	end
	panel.scope:SetText(scopeText())
	panel.filter:GenerateMenu()
	for _, row in ipairs(rows) do
		row:Hide()
		row:ClearAllPoints()
		row.questID = nil
		if row.icon then
			row.icon:Hide()
		end
		if row.shareButton then
			row.shareButton:Hide()
		end
	end
	activeRows = 0
	local y = 70
	if #groups == 0 and complete then
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
		local size = #group.differences + 1
		local available = MAX_ROWS - count
		-- Never hide the first quest entirely just because its details exceed the row budget.
		local oversized = size > available and index == 1 and available >= 3
		if size <= available or oversized then
			local questID = onShare and group.shareQuestID
			y = addRow(group.title, y, "quest", questID)
			count = count + 1
			local shown = oversized and available - 2 or #group.differences
			for detailIndex = 1, shown do
				local difference = group.differences[detailIndex]
				y = addRow(differenceText(difference), y, difference.kind)
				count = count + 1
			end
			if shown < #group.differences then
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
	panel:SetHeight(math.max(58, y + 8))
	panel:Show()
end
