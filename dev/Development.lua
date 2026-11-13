local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled or not QWF.isDevelopment then
	return
end

QWF.Development = {}

local function text(value)
	return tostring(value == nil and "unknown" or value):gsub("|", "||")
end

local function age(seconds)
	return seconds and string.format("%.1fs ago", math.max(0, seconds)) or "never"
end

local function identity(state)
	if not state then
		return "none"
	end
	return "seq "
		.. text(state.sequence)
		.. " · session "
		.. text(state.session and state.session:sub(1, 8))
		.. " · digest "
		.. text(state.digest and state.digest:sub(1, 8))
end

local function transfer(label, snapshot)
	if not snapshot then
		return label .. ": none"
	end
	return label
		.. ": "
		.. (snapshot.kind == "P" and "partial" or "full")
		.. " · revision "
		.. text(snapshot.revision)
		.. "\n  "
		.. text(snapshot.sent)
		.. "/"
		.. text(snapshot.parts)
		.. " chunks submitted · "
		.. text(snapshot.bytes)
		.. " bytes"
		.. (snapshot.forced and " · forced" or "")
		.. (snapshot.materialized == false and " (selection pending)" or "")
end

local function partialStatus(data)
	if not data.partialEnabled then
		return "Full snapshots: local partial-sync support is disabled."
	elseif data.baselineNeeded or not data.published then
		return "Full snapshots:\n  A tagged outgoing baseline must be submitted first."
	end
	local connected = false
	for _, peer in ipairs(data.peers) do
		if peer.connected then
			connected = true
			if not peer.session or not peer.capabilityAge or peer.capabilityAge > 45 then
				return "Full snapshots:\n  " .. text(peer.name) .. " has no recent q1 announcement."
			end
		end
	end
	return connected and "Partial updates eligible.\nFull snapshots still handle refreshes and smaller payloads."
		or "Full snapshots: no connected peers."
end

function QWF.Development.formatDiagnostics(data)
	local lines = {
		"|cffffd100Local client|r",
		"Addon " .. text(data.addonVersion) .. " · Protocol " .. text(data.protocol) .. " · " .. text(data.game),
		"Client " .. text(data.clientVersion) .. " · Build " .. text(data.clientBuild),
		"QWF prefix: "
			.. (data.prefixRegistered == false and "registration failed" or "registered")
			.. " · Group: "
			.. (data.inRaid and "raid (sync inactive)" or (data.inParty and "party" or "solo"))
			.. " · View: "
			.. text(data.view),
		"Local snapshot: "
			.. (data.localSnapshotKnown and (text(data.localQuestCount) .. " quests") or "not scanned")
			.. (data.snapshotTooLarge and " · OVERSIZED" or ""),
		"Last submitted payload: " .. (data.submittedBytes and (text(data.submittedBytes) .. " bytes") or "none"),
		"Published state: " .. identity(data.published),
		"",
		"|cffffd100Party peers (" .. #data.peers .. ")|r",
	}
	if #data.peers == 0 then
		lines[#lines + 1] = "No player peers. Join a party to inspect live synchronization."
	end
	for _, peer in ipairs(data.peers) do
		lines[#lines + 1] = text(peer.name)
			.. " — "
			.. text(peer.status)
			.. " · "
			.. (peer.detected and "addon detected" or "addon not detected")
		lines[#lines + 1] = "  Observed protocol: "
			.. text(peer.protocol)
			.. " · Last message: "
			.. age(peer.messageAge)
		lines[#lines + 1] = "  q1: "
			.. (peer.session and ("advertised " .. age(peer.capabilityAge)) or "not established")
		lines[#lines + 1] = "  Cached snapshot: "
			.. (peer.hasSnapshot and (text(peer.questCount) .. " quests · revision " .. text(peer.revision)) or "none")
		lines[#lines + 1] = "  Committed: " .. age(peer.snapshotAge) .. " · q1 activity: " .. age(peer.stateAge)
		lines[#lines + 1] = "  State: " .. identity(peer.state) .. (peer.fullOnly and " · full-only baseline" or "")
		for _, pending in ipairs({ { "Full", peer.pending }, { "Partial", peer.partialPending } }) do
			if pending[2] then
				local assembly = pending[2]
				lines[#lines + 1] = "  "
					.. pending[1]
					.. " assembly: revision "
					.. text(assembly.revision)
					.. " · "
					.. text(assembly.received)
					.. "/"
					.. text(assembly.parts)
					.. " chunks received"
			end
		end
		if peer.recoveryReason then
			lines[#lines + 1] = "  Last recovery: " .. text(peer.recoveryReason) .. " · " .. age(peer.recoveryAge)
		end
		lines[#lines + 1] = ""
	end
	lines[#lines + 1] = "|cffffd100Outgoing synchronization|r"
	lines[#lines + 1] = partialStatus(data)
	lines[#lines + 1] = transfer("Active", data.outgoing)
	lines[#lines + 1] = transfer("Queued", data.queued)
	lines[#lines + 1] = transfer("Suspended", data.suspended)
	local controls = {}
	for _, control in ipairs({
		{ "refresh", data.requestPending },
		{ "capability", data.capabilityPending },
		{ "state", data.heartbeatPending },
		{ "oversized", data.oversizePending },
	}) do
		if control[2] then
			controls[#controls + 1] = control[1]
		end
	end
	lines[#lines + 1] = "Control queue: " .. (#controls > 0 and table.concat(controls, ", ") or "empty")
	lines[#lines + 1] = string.format("Send pacing: %.1fs until eligible", data.nextSendIn)
	if data.retryIn then
		lines[#lines + 1] = string.format("Retry backoff active (%.1fs remaining)", data.retryIn)
	end
	if data.batching then
		lines[#lines + 1] = "Coalescing local changes."
	end
	lines[#lines + 1] = "API submission is not a delivery acknowledgement."
	return table.concat(lines, "\n")
end

local function createDiagnosticsWindow(getDiagnostics)
	local name = (QWF.name or "QuestWithFriendsDev") .. "Diagnostics"
	local window = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
	window:Hide()
	window:SetSize(700, 520)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	window:SetResizable(true)
	window:SetResizeBounds(480, 300)
	window.TitleText:SetText("Quest With Friends · Diagnostics (Dev)")
	local specialFrames = rawget(_G, "UISpecialFrames")
	if specialFrames then
		specialFrames[#specialFrames + 1] = name
	end

	local subtitle = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", 16, -34)
	subtitle:SetText("Real party data · Read-only · No AddonKit required")
	local footer = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footer:SetPoint("BOTTOMLEFT", 16, 14)
	footer:SetText("Live · Updates every 0.5s · Drag to move · Corner to resize")

	local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -56)
	scroll:SetPoint("BOTTOMRIGHT", -32, 36)
	local content = CreateFrame("Frame", nil, scroll)
	scroll:SetScrollChild(content)
	local report = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	report:SetPoint("TOPLEFT")
	report:SetJustifyH("LEFT")
	report:SetJustifyV("TOP")
	report:SetWordWrap(true)

	local function layout()
		local width = math.max(1, window:GetWidth() - 56)
		subtitle:SetWidth(window:GetWidth() - 32)
		subtitle:SetJustifyH("LEFT")
		content:SetWidth(width)
		report:SetWidth(width)
		content:SetHeight(report:GetStringHeight() + 12)
		scroll:SetVerticalScroll(
			math.min(scroll:GetVerticalScroll(), math.max(0, content:GetHeight() - scroll:GetHeight()))
		)
	end
	local function update()
		report:SetText(QWF.Development.formatDiagnostics(getDiagnostics()))
		layout()
	end
	local elapsed = 0
	window:SetScript("OnShow", function()
		elapsed = 0
		update()
	end)
	window:SetScript("OnUpdate", function(_, seconds)
		if not window:IsShown() then
			return
		end
		elapsed = elapsed + seconds
		if elapsed >= 0.5 then
			elapsed = 0
			update()
		end
	end)
	window:SetScript("OnSizeChanged", layout)
	window:SetScript("OnHide", function()
		window:StopMovingOrSizing()
	end)
	local resize = CreateFrame("Button", nil, window)
	resize:SetSize(18, 18)
	resize:SetPoint("BOTTOMRIGHT", -4, 4)
	resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	resize:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then
			window:StartSizing("BOTTOMRIGHT")
		end
	end)
	resize:SetScript("OnMouseUp", function()
		window:StopMovingOrSizing()
	end)
	return window
end

function QWF.Development.new(setPreviewMode, isScreenshot, getDiagnostics)
	local screenshotToolsShown = false
	local screenshotLayout
	local diagnosticsWindow

	local function showScreenshotScenario(scenario)
		if setPreviewMode(true, true, scenario) and SettingsPanel then
			SettingsPanel:Hide()
		end
	end

	local function addSettings(layout)
		if layout and CreateSettingsListSectionHeaderInitializer and CreateSettingsButtonInitializer then
			screenshotLayout = layout
			local function addScreenshotControl(initializer)
				initializer:AddShownPredicate(function()
					return screenshotToolsShown
				end)
				layout:AddInitializer(initializer)
			end
			addScreenshotControl(
				CreateSettingsListSectionHeaderInitializer(
					"Screenshot tools",
					"Solo-only sample scenes for promotional screenshots, without preview labels. "
						.. "Sharing is inert; samples are never synchronized. Scenes end when you join a group or reload."
				)
			)
			for _, option in ipairs({
				{
					"differences",
					"Quest differences",
					"Missing quests, multiple objectives, readiness and completion.",
				},
				{
					"collapsed",
					"Collapsed headings",
					"Compact affected-player summaries with all sample headings collapsed.",
				},
				{ "synced", "Party in sync", "A caught-up party with no quest differences." },
			}) do
				local scenario, name, tooltip = unpack(option)
				local initializer = CreateSettingsButtonInitializer(name, "Show scenario", function()
					showScreenshotScenario(scenario)
				end, tooltip .. " Shows sample data and closes settings. Solo only.", false)
				initializer:AddModifyPredicate(function()
					return not IsInGroup()
				end)
				addScreenshotControl(initializer)
			end
			local stop = CreateSettingsButtonInitializer("Screenshot view", "End screenshot view", function()
				if isScreenshot() then
					setPreviewMode(false)
				end
			end, "Return to real party data, or hide the panel while solo.", false)
			stop:AddModifyPredicate(function()
				return isScreenshot()
			end)
			addScreenshotControl(stop)
		end
	end

	local function handleCommand(command)
		if command == "dev" or command == "dev on" or command == "dev off" then
			if command == "dev off" then
				if diagnosticsWindow then
					diagnosticsWindow:Hide()
				end
			else
				diagnosticsWindow = diagnosticsWindow or createDiagnosticsWindow(getDiagnostics)
				diagnosticsWindow:SetShown(command == "dev on" or not diagnosticsWindow:IsShown())
			end
			return true
		end
		if command == "screenshot" or command == "screenshot on" or command == "screenshot off" then
			if not screenshotLayout then
				print("Quest With Friends: Screenshot tools require the addon settings panel.")
				return true
			end
			screenshotToolsShown = command == "screenshot on" or (command == "screenshot" and not screenshotToolsShown)
			if SettingsPanel and SettingsPanel:IsShown() and SettingsPanel:GetCurrentLayout() == screenshotLayout then
				if SettingsInbound and SettingsInbound.RepairDisplay then
					SettingsInbound.RepairDisplay()
				else
					SettingsPanel:GetSettingsList():RepairDisplay(screenshotLayout)
				end
			end
			print(
				"Quest With Friends: Screenshot tools "
					.. (screenshotToolsShown and "shown" or "hidden")
					.. " in addon settings."
			)
			return true
		end
		return false
	end

	return { addSettings = addSettings, command = handleCommand }
end
