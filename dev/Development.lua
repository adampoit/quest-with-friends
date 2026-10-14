local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled or not QWF.isDevelopment then
	return
end

QWF.Development = {}

function QWF.Development.new(setPreviewMode, isScreenshot)
	local screenshotToolsShown = false
	local screenshotLayout

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
