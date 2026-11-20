local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
local addonName = QWF.name or "QuestWithFriends"
local Core, Codec = QWF.Core, QWF.SnapshotCodec
local isForever = QWF.QuestEquivalencesGame == "forever"
local surnameSeparator = Constants
		and Constants.CharacterNameSeparatorConsts
		and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR
	or " "
local PREFIX = "QWF"
local VERSION = Codec.PROTOCOL_VERSION
local SHARE_DIAGNOSTIC_WINDOW = 5
local lastShareAttempt
local shareAttemptSequence = 0
local sync
local members = {}
local completed = {}
local completedOrder = {}
local localQuests = {}
local localSnapshotKnown = false
local activity = {}
local activitySequence = 0
local questCategories = {}
local lastScanSummary
local prefixRegistered
local previewMode = false
local screenshotMode = false
local screenshotScenario = "differences"
local previewCollapsed = {}
local previewSetting
local resettingPreviewSetting = false
local panelLockSetting
local render
local native = { progress = QWF.NativeProgress and QWF.NativeProgress.new(), units = {} }
local setPreviewMode
local ignores, ignoreView, ignoreOffer, ignoreDialog
local worldEntered = false
local leaveCheck
local frame = CreateFrame("Frame")
local function initializeSettings()
	local savedVariables = QWF.savedVariables or "QuestWithFriendsDB"
	QWF.db = type(_G[savedVariables]) == "table" and _G[savedVariables] or {}
	_G[savedVariables] = QWF.db
	QWF.db.debugMode = QWF.db.debugMode == true
	QWF.db.panelLocked = QWF.db.panelLocked ~= false
	if QWF.db.joinQuestBehavior ~= "auto" and QWF.db.joinQuestBehavior ~= "keep" then
		QWF.db.joinQuestBehavior = "ask"
	end
	QWF.db.partySessions = type(QWF.db.partySessions) == "table" and QWF.db.partySessions or {}
	if QWF.db.sortMode ~= "title" then
		QWF.db.sortMode = "smart"
	end
	if QWF.db.objectiveProgress ~= "self" and QWF.db.objectiveProgress ~= "always" then
		QWF.db.objectiveProgress = "anyone"
	end
	if QWF.db.zoneFilter == nil then
		QWF.db.zoneFilter = true
	end
	for _, setting in ipairs({ "showProfessionQuests", "showClassQuests" }) do
		if QWF.db[setting] == nil then
			QWF.db[setting] = QWF.db.showPersonalQuests == true
		end
	end
end
initializeSettings()

local debugLoggingWarningShown = false
local function debugLoggingAvailable()
	return AddonKit
		and type(AddonKit.RegisterAddon) == "function"
		and type(AddonKit.SetLogLevel) == "function"
		and type(AddonKit.Log) == "function"
end

local function applyDebugMode(notifyUnavailable)
	if AddonKit and AddonKit.SetLogLevel then
		AddonKit.SetLogLevel(addonName, QWF.db.debugMode and "DEBUG" or "INFO")
	end
	if not QWF.db.debugMode or debugLoggingAvailable() then
		debugLoggingWarningShown = false
	elseif notifyUnavailable and not debugLoggingWarningShown then
		debugLoggingWarningShown = true
		print(
			"|cffff6060"
				.. (QWF.title or "Quest With Friends")
				.. ": Debug logging unavailable.|r Debug mode is on, but no logs are being recorded. "
				.. "Install or enable AddonKit, then /reload."
		)
	end
end

local function log(level, category, message, data)
	if AddonKit and AddonKit.Log then
		AddonKit.Log(addonName, level, category, message, data)
	end
end

local objectiveDiagnostics = {}
local objectiveMessages = {
	scan = "Quest objective scan changed",
	peer = "Peer objective stock changed",
	submitted = "Submitted objective stock changed",
	selection = "Quest comparison selection changed",
	rows = "Objective row changed",
}

local function sameFields(first, second)
	if not first then
		return false
	end
	for key, value in pairs(first) do
		if second[key] ~= value then
			return false
		end
	end
	for key, value in pairs(second) do
		if first[key] ~= value then
			return false
		end
	end
	return true
end

local function recordObjectiveDiagnostics(stage, records, trigger, context)
	if not QWF.db.debugMode then
		return
	end
	local previous = objectiveDiagnostics[stage] or {}
	local function emit(data, removed)
		local entry = {}
		for key, value in pairs(data) do
			entry[key] = value
		end
		for key, value in pairs(context or {}) do
			entry[key] = value
		end
		if removed then
			entry.previousResult, entry.result = entry.result, "removed"
		end
		entry.trigger, entry.uptime = trigger or "render", GetTime and GetTime()
		log("DEBUG", "item_stock", objectiveMessages[stage], entry)
	end
	for key, data in pairs(records) do
		if not sameFields(previous[key], data) then
			emit(data)
		end
	end
	for key, data in pairs(previous) do
		if not records[key] then
			emit(data, true)
		end
	end
	objectiveDiagnostics[stage] = records
end

local function snapshotObjectiveDiagnostics(records, quests, sender)
	if not QWF.db.debugMode then
		return
	end
	for id, quest in pairs(quests) do
		local function track(index, objective)
			records[sender .. ":" .. id .. ":" .. index] = {
				sender = sender,
				questID = id,
				title = quest.title,
				state = quest.state,
				objectiveIndex = index,
				text = objective.text,
				have = objective.have,
				need = objective.need,
				itemID = objective.itemID,
				spare = objective.spare,
				mode = "live",
				result = index == 0 and "no_objectives"
					or (objective.itemID and objective.spare ~= nil and "identified" or "no_stock_metadata"),
			}
		end
		if #quest.objectives == 0 then
			track(0, {})
		end
		for index, objective in ipairs(quest.objectives) do
			track(index, objective)
		end
	end
end

local function isPlayerPartyMember(unit)
	return UnitExists(unit) and UnitIsPlayer(unit)
end

local function inParty()
	if not IsInGroup() or IsInRaid() then
		return false
	end
	-- Delve companions can create a group without a usable PARTY chat channel.
	for index = 1, 4 do
		if isPlayerPartyMember("party" .. index) then
			return true
		end
	end
	return false
end

local function identity(unit)
	local name, second = UnitFullName(unit)
	if not name then
		return nil
	end
	-- Forever returns a surname, not a realm, as the second name component.
	if isForever then
		if type(second) == "string" and second ~= "" then
			local suffix = surnameSeparator .. second
			if name:sub(-#suffix) ~= suffix then
				name = name .. suffix
			end
		end
		return name
	end
	local realm = second and second ~= "" and second or GetRealmName()
	return name .. "-" .. (realm or ""):gsub("%s+", "")
end

local function zoneMapID(mapID)
	if type(mapID) ~= "number" or mapID <= 0 then
		return nil
	end
	if not C_Map or not C_Map.GetMapInfo or not Enum or not Enum.UIMapType then
		return mapID
	end
	for _ = 1, 12 do
		local info = C_Map.GetMapInfo(mapID)
		if not info or (info.mapType and info.mapType < Enum.UIMapType.Zone) then
			return nil
		end
		local parent = info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
		if not parent or not parent.mapType or parent.mapType < Enum.UIMapType.Zone then
			return mapID
		end
		mapID = info.parentMapID
	end
	return nil
end

local function questCategory(id)
	local overrides = QWF.QuestCategories and QWF.QuestCategories[QWF.QuestEquivalencesGame]
	if overrides and overrides[id] then
		return overrides[id]
	end
	local tag = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(id)
	local questType = C_QuestLog.GetQuestType and C_QuestLog.GetQuestType(id)
	local professionType = Enum and Enum.QuestTagType and Enum.QuestTagType.Profession or 1
	-- Class is QuestInfo ID 21, but is absent from some clients' QuestTag enum.
	if questType == 21 or (tag and tag.tagID == 21) then
		return "class"
	end
	if tag and (tag.worldQuestType == professionType or (tag.tradeskillLineID and tag.tradeskillLineID > 0)) then
		return "profession"
	end
end

local function categoryHeaders()
	local headers = {}
	for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
		for _, name in pairs(names) do
			headers[name] = "class"
		end
	end
	if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName then
		-- Include secondary professions and retired First Aid, not just learned skills.
		for _, id in ipairs({ 171, 164, 333, 202, 182, 773, 755, 165, 186, 393, 197, 185, 129, 356, 794 }) do
			local name = C_TradeSkillUI.GetTradeSkillDisplayName(id)
			if name and name ~= "" then
				headers[name] = "profession"
			end
		end
	end
	return headers
end

local function collectQuests(trigger)
	local quests, itemObjectives = {}, {}
	local scanDiagnostics, objectiveContexts = {}, {}
	local function track(objective, id, index, title, state, rawText, objectiveType)
		if QWF.db.debugMode then
			objectiveContexts[objective] = {
				questID = id,
				objectiveIndex = index,
				title = title,
				state = state,
				text = objective.text,
				have = objective.have,
				need = objective.need,
				rawText = rawText,
				objectiveType = objectiveType,
				mode = "live",
			}
		end
	end
	local function diagnose(objective, data)
		data.verifiedItemID = objective.itemID or objective.verifiedItemID
		local context = objectiveContexts[objective]
		for key, value in pairs(context) do
			data[key] = value
		end
		scanDiagnostics[context.questID .. ":" .. context.objectiveIndex] = data
	end
	local headers = categoryHeaders()
	local headerCategory
	local filtered = 0
	local count = C_QuestLog.GetNumQuestLogEntries()
	for index = 1, count do
		local info = C_QuestLog.GetInfo(index)
		if info and info.isHeader then
			headerCategory = headers[info.title]
		elseif info and (info.isHidden or info.isInternalOnly) then
			filtered = filtered + 1
		elseif
			info
			and not info.isHeader
			and type(info.questID) == "number"
			and info.questID > 0
			and not completed[info.questID]
		then
			local id = info.questID
			questCategories[id] = questCategory(id) or headerCategory or questCategories[id]
			local objectives = {}
			local raw = C_QuestLog.GetQuestObjectives(id) or {}
			local state = C_QuestLog.IsComplete(id) and "ready" or "active"
			for objectiveIndex, objective in ipairs(raw) do
				local need = tonumber(objective.numRequired) or 0
				local have = tonumber(objective.numFulfilled) or (objective.finished and need or 0)
				local text = (objective.text or ""):gsub("^%s*%d+/%d+%s+", ""):gsub(":%s*%d+/%d+%s*$", "")
				local progress = { text = text, have = have, need = need }
				objectives[#objectives + 1] = progress
				track(progress, id, objectiveIndex, info.title, state, objective.text, objective.type or "unknown")
				if objective.type == "item" then
					local previous = localQuests[id] and localQuests[id].objectives[objectiveIndex]
					if previous and previous.text == text and previous.need == need then
						progress.verifiedItemID = previous.itemID or previous.verifiedItemID
					end
					itemObjectives[#itemObjectives + 1] = progress
				elseif QWF.db.debugMode then
					diagnose(progress, { result = "not_item_objective" })
				end
			end
			quests[id] = {
				title = info.title or ("Quest " .. id),
				state = state,
				objectives = objectives,
				mapID = GetQuestUiMapID and zoneMapID(GetQuestUiMapID(id, true)) or nil,
				category = questCategories[id],
			}
		end
	end
	local completedObjectives = {}
	for id, record in pairs(completed) do
		local objectives = {}
		for index, saved in ipairs(record.objectives) do
			local objective = { text = saved.text, have = saved.need, need = saved.need, itemID = saved.itemID }
			objectives[#objectives + 1] = objective
			track(objective, id, index, record.title, "completed", nil, "retained")
			if saved.itemID then
				completedObjectives[#completedObjectives + 1] = objective
			elseif QWF.db.debugMode then
				diagnose(objective, { result = "completed_identity_unavailable" })
			end
		end
		quests[id] = {
			title = record.title,
			state = "completed",
			objectives = objectives,
			mapID = record.mapID,
			category = questCategories[id],
		}
	end
	QWF.ItemStock.annotate(itemObjectives, completedObjectives, QWF.db.debugMode and diagnose or nil)
	for _, objective in ipairs(itemObjectives) do
		objective.verifiedItemID = objective.itemID or objective.verifiedItemID
	end
	if QWF.db.debugMode then
		for id, quest in pairs(quests) do
			if #quest.objectives == 0 then
				scanDiagnostics[id .. ":0"] = {
					questID = id,
					objectiveIndex = 0,
					title = quest.title,
					state = quest.state,
					result = "no_objectives",
					mode = "live",
				}
			end
		end
	end
	recordObjectiveDiagnostics("scan", scanDiagnostics, trigger)
	local visible = 0
	for _, quest in pairs(quests) do
		if quest.state ~= "completed" then
			visible = visible + 1
		end
	end
	local summary = visible .. ":" .. filtered
	if summary ~= lastScanSummary then
		lastScanSummary = summary
		log("INFO", "scan", "Quest log scanned", { visible = visible, hiddenOrInternal = filtered })
	end
	return quests
end

local function recordActivity(previous, current)
	activitySequence = activitySequence + 1
	Core.recordActivity(activity, previous, current, activitySequence)
end

local function scanQuests(trigger)
	local quests = collectQuests(trigger)
	recordActivity(localSnapshotKnown and localQuests or nil, quests)
	localQuests = quests
	localSnapshotKnown = true
end

local function offerCompletionHistory(quests, offer)
	local candidates, ids = {}, {}
	-- Only logged peer quests create demand; completion replies must not sustain each other.
	for _, member in ipairs(members) do
		local peer = sync.peer(member.key)
		for id, quest in pairs(peer and peer.quests or {}) do
			if quest.state ~= "completed" and not candidates[id] then
				candidates[id] = quest
				ids[#ids + 1] = id
			end
		end
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		if not Core.matchQuest(quests, id) and C_QuestLog.IsQuestFlaggedCompleted then
			for _, variantID in ipairs(Core.completionIDs(id)) do
				if C_QuestLog.IsQuestFlaggedCompleted(variantID) then
					local source = candidates[id]
					offer(variantID, {
						title = source.title,
						state = "completed",
						objectives = {},
						mapID = source.mapID,
						category = questCategory(variantID) or source.category,
					})
					break
				end
			end
		end
	end
end

local function questSnapshot()
	local quests = {}
	for id, quest in pairs(localQuests) do
		quests[id] = quest
	end
	offerCompletionHistory(quests, function(id, quest)
		quests[id] = quest
	end)
	return quests
end

local function shareableQuestIndex(id)
	if not inParty() or not C_QuestLog.IsPushableQuest(id) then
		return nil
	end
	local index = C_QuestLog.GetLogIndexForQuestID(id)
	if index and index > 0 then
		return index
	end
end

local function shareContext()
	local context = {
		game = isForever and "forever" or "retail",
		uptime = GetTime and GetTime(),
		combatLockdown = InCombatLockdown and InCombatLockdown(),
		playerInCombat = UnitAffectingCombat and UnitAffectingCombat("player"),
		inParty = inParty(),
		inRaid = IsInRaid(),
		secureContext = issecure and issecure(),
	}
	if GetBuildInfo then
		context.clientVersion, context.clientBuild, context.buildDate, context.interfaceVersion = GetBuildInfo()
	end
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		context.addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version")
	end
	if issecurevariable then
		context.apiSecure, context.apiTaintSource = issecurevariable("QuestLogPushQuest")
	end
	return context
end

local function recordShareAttempt(id, index)
	shareAttemptSequence = shareAttemptSequence + 1
	local attempt = shareContext()
	attempt.attemptID, attempt.questID, attempt.logIndex = shareAttemptSequence, id, index
	local info = C_QuestLog.GetInfo(index)
	attempt.questTitle = info and info.title
	attempt.stack = debugstack and debugstack(2, 8, 0)
	lastShareAttempt = attempt
	log("INFO", "share", "Quest sharing attempted", attempt)
end

local function recordShareBlocked(event, blockedAddon, functionName)
	if blockedAddon ~= addonName or (functionName ~= "QuestLogPushQuest" and functionName ~= "QuestLogPushQuest()") then
		return
	end
	local context = shareContext()
	local data = { event = event, addon = blockedAddon, protectedFunction = functionName, context = context }
	-- Security events may arrive after OnClick returns; never attach an old quest to a later block.
	local elapsed = lastShareAttempt
		and lastShareAttempt.uptime
		and context.uptime
		and (context.uptime - lastShareAttempt.uptime)
	if elapsed and elapsed >= 0 and elapsed <= SHARE_DIAGNOSTIC_WINDOW then
		data.attempt, data.elapsed = lastShareAttempt, elapsed
	end
	log("WARN", "share", "Quest sharing blocked", data)
end

local function canAbandonQuest(id)
	if previewMode or not inParty() or type(QuestMapQuestOptions_AbandonQuest) ~= "function" then
		return false
	end
	local index = C_QuestLog.GetLogIndexForQuestID(id)
	local info = index and index > 0 and C_QuestLog.GetInfo(index)
	return info
			and info.questID == id
			and not info.isHeader
			and not info.isHidden
			and not info.isInternalOnly
			and C_QuestLog.CanAbandonQuest(id)
			and not C_QuestLog.IsQuestDisabledForSession(id)
		or false
end

local function getAbandonQuestID(groupID)
	for _, id in ipairs(Core.questIDs(groupID)) do
		if canAbandonQuest(id) then
			return id
		end
	end
end

local function requestAbandonQuest(id)
	-- Recheck the exact quest captured by the menu, not a replacement variant.
	if canAbandonQuest(id) then
		QuestMapQuestOptions_AbandonQuest(id)
	else
		render()
	end
end

local displayedPeers = {}
local displayedPanel

local function recordUIState(visible, groups, complete, notices, trigger, updating)
	if not QWF.db.debugMode then
		return
	end
	local now = GetTime and GetTime()
	local mode = not visible and "hidden" or (screenshotMode and "screenshot" or (previewMode and "preview" or "live"))
	local status = not visible and "hidden"
		or (previewMode and not screenshotMode and "preview")
		or (not previewMode and ignoreView and "ignored")
		or (not complete and not (updating and #notices == 0) and "incomplete")
		or (not Core.hasDifferences(groups or {}) and "in_sync" or "out_of_sync")
	local scenario = screenshotMode and screenshotScenario or nil
	local previous = displayedPanel
	if not previous or previous.visible ~= visible then
		log("DEBUG", "ui", "Panel visibility changed", {
			previous = previous and previous.visible or false,
			visible = visible,
			mode = mode,
			trigger = trigger,
			uptime = now,
		})
	end
	if
		not previous
		or previous.status ~= status
		or previous.mode ~= mode
		or previous.scenario ~= scenario
		or previous.updating ~= updating
	then
		log("DEBUG", "ui", "Panel status changed", {
			previous = previous and previous.status or "unobserved",
			status = status,
			previousMode = previous and previous.mode,
			mode = mode,
			scenario = scenario,
			trigger = trigger,
			uptime = now,
			duration = now and previous and previous.since and (now - previous.since),
			groups = groups and #groups or 0,
			notices = notices and #notices or 0,
			updating = updating,
			zoneFilter = QWF.db.zoneFilter,
			showProfessionQuests = QWF.db.showProfessionQuests,
			showClassQuests = QWF.db.showClassQuests,
			objectiveProgress = QWF.db.objectiveProgress,
		})
		displayedPanel =
			{ visible = visible, status = status, mode = mode, scenario = scenario, since = now, updating = updating }
	end

	local nextDisplayed = {}
	local function recordPeer(key, player, nextStatus, peer)
		local old = displayedPeers[key]
		if old and old.status == nextStatus then
			nextDisplayed[key] = old
			return
		end
		local unhealthySince = nextStatus ~= "healthy"
				and nextStatus ~= "updating"
				and nextStatus ~= "not_displayed"
				and ((old and old.unhealthySince) or now)
			or nil
		log("DEBUG", "ui", "Displayed sync status changed", {
			sender = key,
			player = player,
			previous = old and old.status or "not_displayed",
			status = nextStatus,
			trigger = trigger,
			uptime = now,
			duration = now and old and old.since and (now - old.since),
			recoveryDuration = nextStatus == "healthy"
					and now
					and old
					and old.unhealthySince
					and (now - old.unhealthySince)
				or nil,
			hasSnapshot = peer and peer.hasSnapshot == true,
			snapshotAge = now and peer and peer.snapshotAge,
			revision = peer and peer.revision,
			pendingRevision = peer and peer.pending and peer.pending.revision,
			received = peer and peer.pending and peer.pending.received,
			parts = peer and peer.pending and peer.pending.parts,
			mode = mode,
		})
		nextDisplayed[key] = { status = nextStatus, player = player, since = now, unhealthySince = unhealthySince }
	end
	-- Sample views never report live peers as recovered or healthy.
	if mode == "live" then
		for _, member in ipairs(members) do
			local peer = sync.peerDiagnostics(member.key)
			recordPeer(member.key, member.name, peer.status, peer)
		end
		local myself = identity("player")
		if myself and (sync.isOversized() or displayedPeers[myself]) then
			recordPeer(myself, "You", sync.isOversized() and "oversized" or "healthy")
		end
	end
	for key, old in pairs(displayedPeers) do
		if not nextDisplayed[key] then
			recordPeer(key, old.player, "not_displayed", sync.peerDiagnostics(key))
			nextDisplayed[key] = nil
		end
	end
	displayedPeers = nextDisplayed
end

local function entryCount(entries)
	local count = 0
	for _ in pairs(entries or {}) do
		count = count + 1
	end
	return count
end

local function cancelIgnoreDialog()
	ignoreDialog = nil
	if QWF.Panel and QWF.Panel.hideIgnorePrompt then
		QWF.Panel.hideIgnorePrompt()
	end
end

local function ignoreSessionKey()
	local key = identity("player")
	return key and (isForever and (key .. "@" .. (GetRealmName() or "")) or key)
end

local function clearIgnoreSession()
	local key = ignoreSessionKey()
	if key then
		QWF.db.partySessions[key] = nil
	end
	ignores, ignoreView, ignoreOffer, leaveCheck = nil, false, nil, nil
	cancelIgnoreDialog()
end

local function ensureIgnoreSession()
	local key = ignoreSessionKey()
	if not key then
		return
	end
	local saved = QWF.db.partySessions[key]
	if not ignores or ignores.saved ~= saved then
		ignores = QWF.QuestIgnores.new(saved)
		QWF.db.partySessions[key] = ignores.saved
	end
	return ignores
end

local function finishIgnoreOffer(token)
	if ignoreOffer ~= token or not inParty() or not ignores then
		return
	end
	local session = ignores
	local entries = session:candidates()
	session:finishOffer()
	ignoreOffer = nil
	if not next(entries) or QWF.db.joinQuestBehavior == "keep" then
		return
	end
	if QWF.db.joinQuestBehavior == "auto" then
		session:ignore(entries)
		render("quests_auto_ignored")
	elseif QWF.Panel.promptIgnore then
		local dialog = { entries = entries }
		ignoreDialog = dialog
		QWF.Panel.promptIgnore(entryCount(entries), function()
			if ignoreDialog == dialog and ignores == session and inParty() then
				ignoreDialog = nil
				session:ignore(session:candidates(entries))
				render("quests_bulk_ignored")
			end
		end, function()
			if ignoreDialog == dialog then
				ignoreDialog = nil
			end
		end)
	end
end

local function beginIgnoreOffer()
	local previous = ignoreDialog
	cancelIgnoreDialog()
	if previous then
		for id, entry in pairs(previous.entries) do
			ignores.saved.candidates[id] = entry
		end
	end
	local token = {}
	ignoreOffer = token
	-- A member without the addon must not hold the offer open indefinitely.
	C_Timer.After(8, function()
		finishIgnoreOffer(token)
	end)
end

local function settleIgnoreOffer()
	local token = ignoreOffer
	if token and not token.settling and not next(ignores.saved.pending) then
		token.settling = true
		C_Timer.After(1, function()
			finishIgnoreOffer(token)
		end)
	end
end

local function showPanel(groups, complete, notices, trigger)
	local updating, warnings = false, {}
	for _, notice in ipairs(notices) do
		if notice.reason == "updating" then
			updating = true
		else
			warnings[#warnings + 1] = notice
		end
	end
	notices = warnings
	Core.sortGroups(
		groups,
		not previewMode and ignoreView and "title" or QWF.db.sortMode,
		previewMode and QWF.Preview.activity or activity
	)
	QWF.Panel.show(
		groups,
		complete,
		QWF.db.zoneFilter,
		function()
			QWF.db.zoneFilter = not QWF.db.zoneFilter
			render("zone_filter_changed")
		end,
		not previewMode
				and function(id)
					-- Resolve the index again: the quest log may have changed since rendering.
					local index = shareableQuestIndex(id)
					lastShareAttempt = nil
					if index then
						recordShareAttempt(id, index)
						QuestLogPushQuest(index)
					else
						render("share_unavailable")
					end
				end
			or nil,
		notices,
		{
			professions = QWF.db.showProfessionQuests,
			classes = QWF.db.showClassQuests,
			toggleProfessions = function()
				QWF.db.showProfessionQuests = not QWF.db.showProfessionQuests
				render("profession_filter_changed")
			end,
			toggleClasses = function()
				QWF.db.showClassQuests = not QWF.db.showClassQuests
				render("class_filter_changed")
			end,
		},
		{
			hasDifferences = Core.hasDifferences(groups),
			objectiveProgress = QWF.db.objectiveProgress,
			onObjectiveProgress = function(mode)
				QWF.db.objectiveProgress = (mode == "self" or mode == "always") and mode or "anyone"
				render("objective_progress_changed")
			end,
			ignoreSession = not previewMode and ignores and ignores.saved or nil,
			ignoredView = not previewMode and ignoreView == true,
			ignoredCount = not previewMode and ignores and entryCount(ignores.saved.ignored) or 0,
			onView = not previewMode and function(ignored)
				ignoreView = ignored == true
				render("ignore_view_changed")
			end or nil,
			onIgnore = not previewMode and ignores and function(id)
				ignores:ignoreQuest(id)
				render("quest_ignored")
			end or nil,
			onIgnoreMissing = not previewMode and ignores and function()
				ignores:ignore(ignores:missingEntries())
				render("quests_bulk_ignored")
			end or nil,
			missingCount = not previewMode and ignores and entryCount(ignores:missingEntries()) or 0,
			onRestore = not previewMode and ignores and function(id)
				ignores:restore(id)
				render("quests_restored")
			end or nil,
			undoBatch = not previewMode and ignores and ignores.undoEntries or nil,
			undoCount = not previewMode and ignores and entryCount(ignores.undoEntries) or 0,
			onUndo = not previewMode and ignores and function()
				ignores:undo()
				render("ignore_undone")
			end or nil,
			getAbandonQuestID = not previewMode and not ignoreView and getAbandonQuestID or nil,
			onAbandon = not previewMode and requestAbandonQuest or nil,
			updating = updating,
			onObjectiveRows = QWF.db.debugMode and function(rows)
				local records = {}
				for _, row in ipairs(rows) do
					row.mode = screenshotMode and "screenshot" or (previewMode and "preview" or "live")
					row.scenario = screenshotMode and screenshotScenario or nil
					records[row.questID .. ":" .. row.rowIndex] = row
				end
				recordObjectiveDiagnostics("rows", records, "panel_layout")
			end or nil,
			onLock = function(locked)
				if panelLockSetting then
					panelLockSetting:SetValue(locked)
				else
					QWF.Panel.setLocked(locked)
				end
			end,
			sortMode = QWF.db.sortMode,
			onSort = function(mode)
				QWF.db.sortMode = mode == "title" and "title" or "smart"
				render("sort_changed")
			end,
			preview = previewMode,
			screenshot = screenshotMode,
			scenario = screenshotMode and screenshotScenario or nil,
			collapsedQuests = previewMode and previewCollapsed or nil,
			onStop = previewMode and not screenshotMode and function()
				if previewSetting then
					previewSetting:SetValue(false)
				else
					setPreviewMode(false)
				end
			end or nil,
		}
	)
	recordUIState(true, groups, complete, notices, trigger, updating)
end

function native.startTimer()
	if native.timer or not native.wanted then
		return
	end
	local timer = {}
	native.timer = timer
	local function tick()
		if native.timer ~= timer then
			return
		end
		if not inParty() or not native.wanted then
			native.timer = nil
			return
		end
		local now = GetTime and GetTime() or 0
		for _, unit in ipairs({ "target", "mouseover" }) do
			if UnitExists(unit) then
				native.progress:observeUnit(unit, now)
			end
		end
		for unit in pairs(native.units) do
			if UnitExists(unit) then
				native.progress:observeUnit(unit, now)
			end
		end
		render("native_progress_poll")
		C_Timer.After(2, tick)
	end
	C_Timer.After(2, tick)
end

render = function(trigger)
	trigger = trigger or "render"
	if not QWF.Panel or resettingPreviewSetting then
		return
	end
	if previewMode and IsInGroup() then
		previewMode = false
		screenshotMode = false
		screenshotScenario = "differences"
		previewCollapsed = {}
		if previewSetting then
			-- Keep the party event as the trigger instead of a nested settings redraw.
			resettingPreviewSetting = true
			previewSetting:SetValue(false)
			resettingPreviewSetting = false
		end
	end
	if previewMode then
		local groups, complete, notices = QWF.Preview.compare(
			QWF.db.zoneFilter,
			QWF.db.showProfessionQuests,
			QWF.db.showClassQuests,
			screenshotMode and screenshotScenario or nil,
			QWF.db.objectiveProgress
		)
		showPanel(groups, complete, notices, trigger)
		return
	end
	if not inParty() then
		native.timer, native.wanted = nil, nil
		if native.progress then
			native.progress:reset()
		end
		cancelIgnoreDialog()
		QWF.Panel.hide()
		recordUIState(false, nil, nil, nil, trigger)
		recordObjectiveDiagnostics("rows", {}, trigger)
		recordObjectiveDiagnostics("selection", {}, trigger)
		recordObjectiveDiagnostics("peer", {}, trigger)
		return
	end
	local roster, peerDiagnostics, templates = {}, {}, {}
	local localView = questSnapshot()
	for id, quest in pairs(localView) do
		templates[id] = quest
	end
	native.wanted = false
	for _, member in ipairs(members) do
		local peer = sync.peer(member.key)
		local quests = peer and peer.quests
		local status = peer and peer.status
		roster[#roster + 1] = {
			key = member.key,
			name = member.name,
			quests = quests,
			syncStatus = status ~= "healthy" and status or nil,
			unit = member.unit,
			nativeEligible = peer
				and peer.connected
				and not quests
				and status ~= "incompatible"
				and status ~= "oversized",
		}
		if roster[#roster].nativeEligible then
			native.wanted = native.progress and native.progress:available()
		end
		if quests then
			for id, quest in pairs(quests) do
				templates[id] = templates[id] or quest
			end
			snapshotObjectiveDiagnostics(peerDiagnostics, quests, member.key)
		end
	end
	if native.progress then
		local observed = native.progress:collect(templates, roster, GetTime and GetTime() or 0)
		for _, member in ipairs(roster) do
			local quests = observed[member.key]
			if quests and next(quests) then
				member.quests, member.partial, member.syncStatus = quests, true, "native"
				for id, quest in pairs(quests) do
					-- Native discoveries can demand our history locally, never remote completion guesses.
					if not Core.matchQuest(localView, id) and C_QuestLog.IsQuestFlaggedCompleted then
						for _, variantID in ipairs(Core.completionIDs(id)) do
							if C_QuestLog.IsQuestFlaggedCompleted(variantID) then
								localView[variantID] = {
									title = quest.title,
									state = "completed",
									objectives = {},
									mapID = quest.mapID,
									category = quest.category,
								}
								break
							end
						end
					end
				end
			end
		end
	end
	if native.wanted then
		native.startTimer()
	else
		native.timer = nil
	end
	recordObjectiveDiagnostics("peer", peerDiagnostics, trigger)
	local zoneID = QWF.db.zoneFilter
			and C_Map
			and C_Map.GetBestMapForUnit
			and zoneMapID(C_Map.GetBestMapForUnit("player"))
		or nil
	local allGroups, complete, notices, allIndices = Core.compare(localView, roster, nil, QWF.db.objectiveProgress)
	local groups, indices = allGroups, allIndices
	if zoneID then
		groups, complete, notices, indices = Core.compare(localView, roster, zoneID, QWF.db.objectiveProgress)
	end
	if ignores and localSnapshotKnown then
		ignores:observe(allGroups, allIndices, localView, roster, identity("player"))
		settleIgnoreOffer()
	end
	local selectionDiagnostics = {}
	if QWF.db.debugMode then
		local function track(quests)
			for id, quest in pairs(quests) do
				local canonicalID = Core.questIDs(id)[1]
				selectionDiagnostics[canonicalID] = {
					questID = canonicalID,
					title = quest.title,
					result = "no_difference",
					zoneID = zoneID,
					mode = "live",
				}
			end
		end
		track(localView)
		for _, member in ipairs(roster) do
			track(member.quests or {})
		end
		for _, group in ipairs(allGroups) do
			selectionDiagnostics[group.questID].result = "zone_filter"
		end
		for _, group in ipairs(groups) do
			selectionDiagnostics[group.questID].result = "included"
		end
	end
	if not QWF.db.showProfessionQuests or not QWF.db.showClassQuests then
		local visible = {}
		local function hidden(category)
			return (category == "profession" and not QWF.db.showProfessionQuests)
				or (category == "class" and not QWF.db.showClassQuests)
		end
		for _, group in ipairs(groups) do
			local excluded = false
			for _, id in ipairs(Core.questIDs(group.questID)) do
				local category = questCategories[id] or questCategory(id)
				for _, member in ipairs(members) do
					local peer = sync.peer(member.key)
					local remote = peer and peer.quests and peer.quests[id]
					category = category or (remote and remote.category)
				end
				if hidden(category) then
					excluded = true
					if QWF.db.debugMode then
						selectionDiagnostics[group.questID].result = category .. "_filter"
					end
				end
			end
			if not excluded then
				visible[#visible + 1] = group
			end
		end
		groups = visible
	end
	if ignores then
		local visible = ignores:filter(groups, indices, roster, identity("player"))
		if QWF.db.debugMode then
			local included = {}
			for _, group in ipairs(visible) do
				included[group.questID] = true
			end
			for _, group in ipairs(groups) do
				if not included[group.questID] then
					selectionDiagnostics[group.questID].result = "ignored"
				end
			end
		end
		groups = ignoreView and ignores:list() or visible
	end
	recordObjectiveDiagnostics("selection", selectionDiagnostics, trigger)
	for _, group in ipairs(groups) do
		if group.shareQuestID and not shareableQuestIndex(group.shareQuestID) then
			group.shareQuestID = nil
		end
	end
	if sync.isOversized() then
		complete = false
		table.insert(notices, 1, { player = "You", reason = "oversized" })
	end
	showPanel(groups, complete, notices, trigger)
end

setPreviewMode = function(enabled, screenshot, scenario)
	if enabled and IsInGroup() then
		print("Quest With Friends: Leave your group to preview sample quest data.")
		return false
	end
	local wasScreenshot = screenshotMode
	previewMode = enabled == true
	screenshotMode = previewMode and QWF.Development ~= nil and screenshot == true
	screenshotScenario = screenshotMode and (scenario or screenshotScenario) or "differences"
	if not previewMode or wasScreenshot ~= screenshotMode or scenario then
		previewCollapsed = {}
		if screenshotMode and screenshotScenario == "collapsed" then
			for _, group in ipairs(QWF.Preview.compare(false, true, true)) do
				previewCollapsed[group.questID] = true
			end
		end
	end
	render("preview_changed")
	return true
end

local function send(message)
	local result = C_ChatInfo.SendAddonMessage(PREFIX, message, "PARTY")
	local results = Enum and Enum.SendAddonMessageResult
	local resultName = tostring(result)
	if results then
		for name, value in pairs(results) do
			if value == result then
				resultName = name
				break
			end
		end
	end
	local failed = result == false
		or (type(result) == "number" and results and results.Success ~= nil and result ~= results.Success)
	log(failed and "WARN" or "DEBUG", "sync", failed and "Addon message send failed" or "Addon message submitted", {
		channel = "PARTY",
		kind = message:match("^%d+%.%d+:([^:]+)"),
		protocol = Codec.PROTOCOL_VERSION,
		bytes = #message,
		result = resultName,
	})
	return not failed
end

local function timestamp()
	return GetTime and GetTime()
end

local function now()
	return timestamp() or 0
end

local function after(delay, callback)
	return C_Timer.After(delay, callback)
end

local function debugMode()
	return QWF.db.debugMode
end

local syncSession
if Codec.PROTOCOL_MINOR >= 2 then
	local clock = rawget(_G, "GetServerTime") or rawget(_G, "time")
	syncSession = QWF.SyncState.digest(
		tostring({}) .. tostring(clock and clock() or "") .. tostring(math.random(1, 100000000)) .. tostring(now())
	)
end
local function prepareLocal(trigger, batched)
	if not batched and native.progress then
		native.progress:invalidate()
	end
	scanQuests(trigger)
	render(trigger)
end

sync = QWF.Sync.new({
	session = syncSession,
	now = now,
	timestamp = timestamp,
	after = after,
	isTransportAvailable = inParty,
	send = send,
	getLocalQuests = function()
		return localQuests
	end,
	offerOptionalQuests = offerCompletionHistory,
	prepareLocal = prepareLocal,
	onStatusChanged = render,
	onPeerSnapshot = function(_, previous, quests)
		recordActivity(previous, quests)
	end,
	debugMode = debugMode,
	development = QWF.isDevelopment,
	log = log,
	onSubmitted = function(quests, revision)
		local diagnostics = {}
		snapshotObjectiveDiagnostics(diagnostics, quests, "You")
		recordObjectiveDiagnostics("submitted", diagnostics, "snapshot_submitted", {
			revision = revision,
			protocol = VERSION,
		})
	end,
})

local function updateRoster(force, trigger)
	local party = inParty()
	local nextMembers, connections = {}, {}
	local rosterPending = false
	if party then
		local myself = identity("player")
		for index = 1, 4 do
			local unit = "party" .. index
			if isPlayerPartyMember(unit) then
				local key = identity(unit)
				rosterPending = rosterPending or not key
				if key and key ~= myself then
					local name = isForever and key or UnitName(unit) or key
					nextMembers[#nextMembers + 1] = {
						key = key,
						name = name,
						unit = unit,
					}
					connections[key] = UnitIsConnected(unit) == true
				end
			end
		end
	end
	local changed = sync.setRoster(nextMembers, connections, party, trigger)
	members = nextMembers
	if party then
		leaveCheck = nil
		local session = ensureIgnoreSession()
		if session then
			local keys = {}
			for _, member in ipairs(members) do
				keys[member.key] = true
			end
			-- Transient empty/unnamed rosters on reload must not turn returning members into new joins.
			if not rosterPending and #members > 0 then
				if session:roster(keys) or (not ignoreOffer and next(session.saved.pending)) then
					beginIgnoreOffer()
				end
			end
		end
	elseif not IsInGroup() and worldEntered and not leaveCheck then
		local check = {}
		leaveCheck = check
		-- Group information can arrive after the first world/roster event following a reconnect.
		C_Timer.After(2, function()
			if leaveCheck == check then
				leaveCheck = nil
				if not IsInGroup() then
					clearIgnoreSession()
				end
			end
		end)
	end
	if not changed and not force then
		render(trigger)
		return
	end
	if changed and native.progress then
		native.progress:reset()
	end
	log("DEBUG", "sync", "Party sync status", {
		player = identity("player"),
		inParty = inParty(),
		inRaid = IsInRaid(),
		members = members,
		game = QWF.QuestEquivalencesGame,
		prefixRegistered = prefixRegistered,
		protocol = Codec.PROTOCOL_VERSION,
	})
	if changed then
		prepareLocal(trigger)
	else
		sync.refresh(trigger)
	end
end

local function senderKey(sender)
	if type(sender) ~= "string" then
		return nil
	end
	if isForever then
		return sender
	end
	local name, realm = sender:match("^([^%-]+)%-(.+)$")
	if not name then
		name, realm = sender, GetRealmName()
	end
	return name .. "-" .. (realm or ""):gsub("%s+", "")
end

local function receive(sender, message)
	if not inParty() or type(message) ~= "string" then
		log(
			"DEBUG",
			"sync",
			"Ignored addon message",
			{ sender = sender, reason = "not in party or invalid message type" }
		)
		return
	end
	local key = senderKey(sender)
	if key and key == identity("player") then
		log("DEBUG", "sync", "Ignored addon message", { sender = sender, key = key, reason = "self message" })
		return
	end
	sync.receive(key, message, sender)
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("GROUP_LEFT")
frame:RegisterEvent("UNIT_CONNECTION")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("ITEM_LOCK_CHANGED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		recordShareBlocked(event, ...)
	elseif event == "ADDON_LOADED" then
		if ... == addonName then
			-- SavedVariables are restored after the TOC's Lua files execute.
			initializeSettings()
			applyDebugMode(true)
		end
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = ...
		if prefix == PREFIX then
			log("DEBUG", "sync", "Incoming addon message", {
				sender = sender,
				channel = channel,
				bytes = type(message) == "string" and #message or nil,
			})
			if channel == "PARTY" then
				receive(sender, message)
			else
				log(
					"DEBUG",
					"sync",
					"Ignored addon message",
					{ sender = sender, channel = channel, reason = "not PARTY channel" }
				)
			end
		end
	elseif event == "GROUP_LEFT" then
		clearIgnoreSession()
		if not inParty() then
			updateRoster(false, event)
		end
	elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
		if event == "PLAYER_ENTERING_WORLD" then
			worldEntered = true
		end
		updateRoster(event == "PLAYER_ENTERING_WORLD", event)
	elseif event == "UNIT_CONNECTION" then
		local unit = ...
		if type(unit) == "string" and unit:match("^party[1-4]$") then
			updateRoster(false, event)
		end
	elseif event == "UNIT_QUEST_LOG_CHANGED" then
		local unit = ...
		if native.wanted and type(unit) == "string" and unit:match("^party[1-4]$") then
			native.progress:invalidate()
			render(event)
		end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		local unit = ...
		if type(unit) == "string" then
			native.units[unit] = nil
		end
	elseif event == "NAME_PLATE_UNIT_ADDED" or event == "PLAYER_TARGET_CHANGED" or event == "UPDATE_MOUSEOVER_UNIT" then
		local unit = event == "PLAYER_TARGET_CHANGED" and "target"
			or (event == "UPDATE_MOUSEOVER_UNIT" and "mouseover" or ...)
		if event == "NAME_PLATE_UNIT_ADDED" and type(unit) == "string" then
			native.units[unit] = true
		end
		if
			native.wanted
			and type(unit) == "string"
			and native.progress:observeUnit(unit, GetTime and GetTime() or 0)
		then
			render(event)
		end
	elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then
		if native.progress then
			native.progress:reset()
		end
		render(event)
	elseif event == "GET_ITEM_INFO_RECEIVED" and select(2, ...) ~= true then
		return
	else
		if event == "QUEST_TURNED_IN" then
			local id = ...
			if type(id) == "number" and id > 0 then
				local info = C_QuestLog.GetTitleForQuestID(id)
				local objectives = {}
				-- Bag updates may consume the turn-in items before this event arrives.
				for _, objective in ipairs(localQuests[id] and localQuests[id].objectives or {}) do
					objectives[#objectives + 1] = {
						text = objective.text,
						need = objective.need,
						itemID = objective.itemID or objective.verifiedItemID,
					}
				end
				completed[id] = {
					title = info or (localQuests[id] and localQuests[id].title) or ("Quest " .. id),
					mapID = localQuests[id] and localQuests[id].mapID,
					objectives = objectives,
				}
				completedOrder[#completedOrder + 1] = id
				if #completedOrder > 30 then
					completed[table.remove(completedOrder, 1)] = nil
				end
			end
		elseif event == "QUEST_ACCEPTED" then
			local first, second = ...
			local id = second or first
			if id then
				completed[id] = nil
			end
		end
		sync.localChanged(event)
	end
end)

local function setDebugMode(enabled)
	if QWF.db.debugMode ~= (enabled == true) then
		displayedPeers, displayedPanel = {}, nil
		objectiveDiagnostics = {}
		sync.clearDiagnostics()
	end
	QWF.db.debugMode = enabled == true
	applyDebugMode(true)
end

if AddonKit and AddonKit.RegisterAddon then
	AddonKit.RegisterAddon(addonName, { persistDiagnostics = true })
end
applyDebugMode()

local development = QWF.Development
	and QWF.Development.new(setPreviewMode, function()
		return screenshotMode
	end, function()
		local data = {
			protocol = VERSION,
			game = isForever and "Forever" or "Retail",
			inParty = inParty(),
			inRaid = IsInRaid(),
			prefixRegistered = prefixRegistered,
			view = screenshotMode and "screenshot samples" or (previewMode and "preview samples" or "live"),
			localSnapshotKnown = localSnapshotKnown,
			localQuestCount = entryCount(localQuests),
			peers = {},
		}
		for field, value in pairs(sync.diagnostics()) do
			data[field] = value
		end
		if C_AddOns and C_AddOns.GetAddOnMetadata then
			data.addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version")
		end
		if GetBuildInfo then
			data.clientVersion, data.clientBuild = GetBuildInfo()
		end
		for _, member in ipairs(members) do
			local summary = sync.peerDiagnostics(member.key)
			summary.name = member.name
			data.peers[#data.peers + 1] = summary
		end
		return data
	end)

local debugSetting
if
	Settings
	and Settings.RegisterVerticalLayoutCategory
	and Settings.RegisterProxySetting
	and Settings.CreateCheckbox
then
	local category, layout = Settings.RegisterVerticalLayoutCategory(QWF.title or "Quest With Friends")
	debugSetting = Settings.RegisterProxySetting(
		category,
		addonName .. "DebugMode",
		Settings.VarType.Boolean,
		"Debug mode",
		false,
		function()
			return QWF.db.debugMode
		end,
		setDebugMode
	)
	Settings.CreateCheckbox(
		category,
		debugSetting,
		"Capture detailed Quest With Friends logs with AddonKit. Requires AddonKit to be installed and enabled. "
			.. "Applies immediately and stays enabled across reloads and logins. Turn off to return to normal INFO logging."
	)
	panelLockSetting = Settings.RegisterProxySetting(
		category,
		addonName .. "PanelLocked",
		Settings.VarType.Boolean,
		"Lock panel",
		true,
		function()
			return QWF.db.panelLocked
		end,
		function(locked)
			QWF.Panel.setLocked(locked)
		end
	)
	Settings.CreateCheckbox(
		category,
		panelLockSetting,
		"Uncheck to move and resize the panel. While unlocked, it shows its full maximum height. "
			.. "The lock icon beside View also toggles this setting. Layout is shared across characters."
	)
	if Settings.CreateDropdown and Settings.CreateControlTextContainer then
		local joinSetting = Settings.RegisterProxySetting(
			category,
			addonName .. "JoinQuestBehavior",
			Settings.VarType.String,
			"Existing quests when the party changes",
			"ask",
			function()
				return QWF.db.joinQuestBehavior
			end,
			function(value)
				QWF.db.joinQuestBehavior = (value == "auto" or value == "keep") and value or "ask"
			end
		)
		Settings.CreateDropdown(
			category,
			joinSetting,
			function()
				local options = Settings.CreateControlTextContainer()
				options:Add("ask", "Ask what to ignore")
				options:Add("auto", "Automatically ignore existing missing quests")
				options:Add("keep", "Keep showing all differences")
				return options:GetData()
			end,
			"Applies when you join a party or someone joins. Includes all zones and quest types. "
				.. "Only existing missing-quest differences are ignored; new pickups and shared progress still appear. "
				.. "Ignores last until you leave the party and can be restored through View → Ignored quests."
		)
	end
	previewSetting = Settings.RegisterProxySetting(
		category,
		addonName .. "PreviewMode",
		Settings.VarType.Boolean,
		"Preview appearance",
		false,
		function()
			return previewMode
		end,
		function(enabled)
			setPreviewMode(enabled)
		end
	)
	Settings.CreateCheckbox(
		category,
		previewSetting,
		"Show sample party quest data while solo. Try filters, collapse quest headings, or unlock the panel to move and resize it. "
			.. "Sample quests cannot be shared. Preview ends when you join a group or reload."
	)
	if development then
		development.addSettings(layout)
	end
	Settings.RegisterAddOnCategory(category)
end

prefixRegistered = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
if prefixRegistered == false then
	log("ERROR", "sync", "Failed to register addon message prefix")
end

SLASH_QUESTWITHFRIENDS1 = "/qwf"
SlashCmdList.QUESTWITHFRIENDS = function(command)
	command = (command or ""):lower():match("^%s*(.-)%s*$")
	if development and development.command(command) then
		return
	end
	if command == "preview" or command == "preview on" or command == "preview off" then
		local enabled = command == "preview on" or (command == "preview" and not previewMode)
		if previewSetting and not screenshotMode then
			previewSetting:SetValue(enabled)
		else
			setPreviewMode(enabled)
		end
		return
	end
	if command == "" and previewMode then
		render("manual_refresh")
		return
	end
	if command == "debug" or command == "debug on" or command == "debug off" then
		local enabled = command ~= "debug off"
		if debugSetting then
			debugSetting:SetValue(enabled)
		else
			setDebugMode(enabled)
		end
		if not enabled or debugLoggingAvailable() then
			print("Quest With Friends: Debug logging " .. (enabled and "enabled" or "disabled") .. ". Setting saved.")
		end
		if enabled and debugLoggingAvailable() then
			updateRoster(true, "debug_enabled")
		end
		return
	end
	if not inParty() then
		print("Quest With Friends: Join a party to compare quests, or use /qwf preview to see sample data.")
	else
		updateRoster(true, "manual_refresh")
		print("Quest With Friends: Refreshing party quest status.")
	end
end
