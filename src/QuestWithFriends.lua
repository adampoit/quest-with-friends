local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
local addonName = QWF.name or "QuestWithFriends"
local Core = QWF.Core
local isForever = QWF.QuestEquivalencesGame == "forever"
local surnameSeparator = Constants
		and Constants.CharacterNameSeparatorConsts
		and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR
	or " "
local PREFIX = "QWF"
local VERSION = tostring(Core.PROTOCOL_VERSION)
local HANDSHAKE = VERSION .. ":H"
local OVERSIZED = VERSION .. ":X"
local CHUNK_SIZE = 220
local MAX_PARTS = 100
local SEND_INTERVAL = 0.5
local COALESCE_INTERVAL = 0.2
local SNAPSHOT_TIMEOUT = 15
local MAX_RETRY_DELAY = 8
local SHARE_DIAGNOSTIC_WINDOW = 5
local lastShareAttempt
local shareAttemptSequence = 0
local peers = {}
local members = {}
local completed = {}
local completedOrder = {}
local localQuests = {}
local localSnapshotKnown = false
local activity = {}
local activitySequence = 0
local questCategories = {}
local lastScanSummary
local lastPayload
local snapshotTooLarge = false
local revision = 0
local delta = {
	enabled = QWF.Sync ~= nil and Core.PROTOCOL_MINOR >= 2,
	targeted = QWF.Sync ~= nil and Core.PROTOCOL_MINOR >= 3,
	capabilityPending = false,
	baselineNeeded = true,
}
if delta.enabled then
	local clock = rawget(_G, "GetServerTime") or rawget(_G, "time")
	delta.session = QWF.Sync.digest(
		tostring({})
			.. tostring(clock and clock() or "")
			.. tostring(math.random(1, 100000000))
			.. tostring(GetTime and GetTime() or 0)
	)
end
local scheduled = false
local forceRefresh = false
local refreshTriggers, refreshForceReasons = {}, {}
local lastQueuedDiagnosticPayload, lastSubmittedDiagnosticPayload, lastSnapshotDecision
local generation = 0
local rosterInParty
local outgoing
local queuedSnapshot
local requestPending = false
local oversizePending = false
local sending = false
local retryDelay = 1
local nextSendAt = 0
local pumping = false
local refresh
local queueRequest
local prefixRegistered
local previewMode = false
local screenshotMode = false
local screenshotScenario = "differences"
local previewCollapsed = {}
local previewSetting
local resettingPreviewSetting = false
local panelLockSetting
local render
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

local function fingerprint(payload)
	if not payload then
		return nil
	end
	-- Adler-32 uses exact integer arithmetic in Lua 5.1 without optional bit libraries.
	local a, b = 1, 0
	for index = 1, #payload do
		a = (a + payload:byte(index)) % 65521
		b = (b + a) % 65521
	end
	return "adler32:" .. string.format("%08x", b * 65536 + a) .. ":" .. #payload
end

local function sortedKeys(set)
	local keys = {}
	for key in pairs(set or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function mergeContext(current, previous)
	if not QWF.db.debugMode then
		return nil
	end
	local context = { triggers = {}, forceReasons = {} }
	for _, source in ipairs({ current or {}, previous or {} }) do
		for _, field in ipairs({ "triggers", "forceReasons" }) do
			for reason in pairs(source[field] or {}) do
				context[field][reason] = true
			end
		end
	end
	return context
end

local function snapshotEvidence(payload, previous)
	local data = { fingerprint = fingerprint(payload), previousFingerprint = fingerprint(previous) }
	if not previous then
		data.changeReason = "baseline"
		return data
	end
	data.payloadChanged = payload ~= previous
	if not data.payloadChanged then
		data.changeReason = "unchanged"
		return data
	end
	local before, after = Core.decode(previous), Core.decode(payload)
	local changes, ids, changedIDs = {}, {}, {}
	local function change(reason)
		changes[reason] = (changes[reason] or 0) + 1
	end
	for id in pairs(before or {}) do
		ids[id] = true
	end
	for id in pairs(after or {}) do
		ids[id] = true
	end
	for _, id in ipairs(sortedKeys(ids)) do
		local old, new = before and before[id], after and after[id]
		local changed = false
		local function mark(reason)
			change(reason)
			changed = true
		end
		if not old then
			mark("added")
		elseif not new then
			mark("removed")
		else
			for _, field in ipairs({ "title", "state", "mapID", "category" }) do
				if old[field] ~= new[field] then
					mark(field)
				end
			end
			local objectivesChanged = #old.objectives ~= #new.objectives
			local stockChanged = false
			for index = 1, math.max(#old.objectives, #new.objectives) do
				local first, second = old.objectives[index] or {}, new.objectives[index] or {}
				for _, field in ipairs({ "text", "have", "need" }) do
					objectivesChanged = objectivesChanged or first[field] ~= second[field]
				end
				stockChanged = stockChanged or first.itemID ~= second.itemID or first.spare ~= second.spare
			end
			if objectivesChanged then
				mark("objectives")
			end
			if stockChanged then
				mark("item_stock")
			end
		end
		if changed then
			changedIDs[#changedIDs + 1] = id
		end
	end
	data.changeReason = next(changes) and table.concat(sortedKeys(changes), ",") or "wire_only"
	data.changes = changes
	data.changedQuests = #changedIDs
	data.changedQuestIDs = {}
	for index = 1, math.min(12, #changedIDs) do
		data.changedQuestIDs[index] = changedIDs[index]
	end
	return data
end

local function logSnapshot(message, payload, previous, data, context)
	if QWF.db.debugMode then
		for field, value in pairs(snapshotEvidence(payload, previous)) do
			data[field] = value
		end
		if context then
			data.triggers = table.concat(sortedKeys(context.triggers), ",")
			data.forceReasons = table.concat(sortedKeys(context.forceReasons), ",")
		end
	end
	log("DEBUG", "sync", message, data)
end

local function logSuppressedSnapshot(reason, payload, context)
	if not QWF.db.debugMode then
		return
	end
	local triggers = table.concat(sortedKeys(context and context.triggers), ",")
	local forceReasons = table.concat(sortedKeys(context and context.forceReasons), ",")
	local decision = { reason = reason, payload = payload, triggers = triggers, forceReasons = forceReasons }
	if sameFields(lastSnapshotDecision, decision) then
		return
	end
	lastSnapshotDecision = decision
	log("DEBUG", "sync", "Quest snapshot suppressed", {
		reason = reason,
		fingerprint = fingerprint(payload),
		bytes = #payload,
		triggers = triggers,
		forceReasons = forceReasons,
		activeRevision = outgoing and outgoing.revision,
		queuedRevision = queuedSnapshot and queuedSnapshot.revision,
	})
end

local function logCanceledSnapshot(snapshot, reason)
	if QWF.db.debugMode and snapshot then
		log("DEBUG", "sync", "Quest snapshot canceled", {
			revision = snapshot.revision,
			fingerprint = fingerprint(snapshot.payload),
			reason = reason,
			nextPart = snapshot.next,
			parts = snapshot.parts,
		})
	end
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

local function peerDisplayStatus(peer)
	if not peer.connected then
		return "offline"
	end
	return peer.status or (peer.quests and "healthy" or "unknown")
end

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
			hasSnapshot = peer and peer.quests ~= nil,
			snapshotAge = now and peer and peer.snapshotAt and (now - peer.snapshotAt),
			revision = peer and peer.snapshotRevision,
			pendingRevision = peer and peer.pending and peer.pending.serial,
			received = peer and peer.pending and peer.pending.received,
			parts = peer and peer.pending and peer.pending.total,
			mode = mode,
		})
		nextDisplayed[key] = { status = nextStatus, player = player, since = now, unhealthySince = unhealthySince }
	end
	-- Sample views never report live peers as recovered or healthy.
	if mode == "live" then
		for _, member in ipairs(members) do
			local peer = peers[member.key]
			recordPeer(member.key, member.name, peerDisplayStatus(peer), peer)
		end
		local myself = identity("player")
		if myself and (snapshotTooLarge or displayedPeers[myself]) then
			recordPeer(myself, "You", snapshotTooLarge and "oversized" or "healthy")
		end
	end
	for key, old in pairs(displayedPeers) do
		if not nextDisplayed[key] then
			recordPeer(key, old.player, "not_displayed", peers[key])
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
		cancelIgnoreDialog()
		QWF.Panel.hide()
		recordUIState(false, nil, nil, nil, trigger)
		recordObjectiveDiagnostics("rows", {}, trigger)
		recordObjectiveDiagnostics("selection", {}, trigger)
		recordObjectiveDiagnostics("peer", {}, trigger)
		return
	end
	local roster, peerDiagnostics = {}, {}
	local localView = {}
	for id, quest in pairs(localQuests) do
		localView[id] = quest
	end
	for _, member in ipairs(members) do
		local peer = peers[member.key]
		local quests = peer and peer.quests
		local status = peer and peerDisplayStatus(peer)
		roster[#roster + 1] = {
			key = member.key,
			name = member.name,
			quests = quests,
			syncStatus = status ~= "healthy" and status or nil,
		}
		if quests then
			snapshotObjectiveDiagnostics(peerDiagnostics, quests, member.key)
			for id, quest in pairs(quests) do
				if not Core.matchQuest(localView, id) then
					for _, variantID in ipairs(Core.completionIDs(id)) do
						if C_QuestLog.IsQuestFlaggedCompleted(variantID) then
							localView[id] =
								{ title = quest.title, state = "completed", objectives = {}, mapID = quest.mapID }
							break
						end
					end
				end
			end
		end
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
					local peer = peers[member.key]
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
	if snapshotTooLarge then
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
		protocol = Core.PROTOCOL_VERSION,
		bytes = #message,
		result = resultName,
	})
	return not failed
end

local function watchPeer(key, peer)
	if peer.watch or not peer.connected or peer.status == "incompatible" then
		return
	end
	local watch = { progress = peer.progress, delay = SNAPSHOT_TIMEOUT }
	peer.watch = watch
	local function check()
		if peers[key] ~= peer or peer.watch ~= watch or not inParty() then
			return
		end
		if peer.progress ~= watch.progress then
			watch.progress = peer.progress
			watch.delay = SNAPSHOT_TIMEOUT
		else
			peer.status = peer.quests and "stale" or "waiting"
			if QWF.isDevelopment then
				peer.debugRecoveryReason, peer.debugRecoveryAt = "snapshot progress timeout", GetTime and GetTime()
			end
			peer.revision = nil
			peer.allowReset = true
			log("WARN", "sync", "Quest snapshot timed out; requesting refresh", {
				sender = key,
				revision = peer.pending and peer.pending.serial,
				received = peer.pending and peer.pending.received,
				parts = peer.pending and peer.pending.total,
			})
			render("snapshot_timeout")
			if delta.enabled then
				delta.recover(key, peer, "snapshot progress timeout")
			else
				queueRequest()
				refresh(true, "snapshot_timeout")
			end
			watch.delay = math.min(60, watch.delay * 2)
		end
		C_Timer.After(watch.delay, check)
	end
	C_Timer.After(watch.delay, check)
end

local function awaitingSnapshot(key, peer, explicit)
	peer.detected = true
	if explicit then
		peer.explicitRefresh = true
	end
	if peer.status ~= "stale" then
		if not peer.quests then
			peer.status = "waiting"
		elseif explicit or (peer.status and peer.status ~= "updating") then
			peer.status = "refreshing"
		else
			peer.status = "updating"
		end
	end
	watchPeer(key, peer)
end

local pump, broadcast
local function scheduleSend()
	if sending or pumping then
		return
	end
	sending = true
	local currentGeneration = generation
	C_Timer.After(math.max(0, nextSendAt - (GetTime and GetTime() or 0)), function()
		if currentGeneration ~= generation then
			return
		end
		sending = false
		pump()
	end)
end

function delta.now()
	return GetTime and GetTime() or 0
end

function delta.canPatch()
	if not delta.enabled or delta.baselineNeeded or not delta.published then
		return false
	end
	local found = false
	for _, peer in pairs(peers) do
		if peer.connected then
			if not peer.deltaSession or not peer.capabilityAt or delta.now() - peer.capabilityAt > 45 then
				return false
			end
			found = true
		end
	end
	return found
end

function delta.materialize(snapshot)
	if snapshot.next > 1 then
		return
	end
	local data = snapshot.payload
	snapshot.kind = "D"
	if snapshot.state and not snapshot.forced and delta.canPatch() then
		local patch = QWF.Sync.patch(delta.published, snapshot.state)
		if #patch < #data then
			data, snapshot.kind = patch, "P"
		end
	end
	snapshot.wireBytes = #data
	snapshot.messages = {}
	snapshot.parts = math.max(1, math.ceil(#data / CHUNK_SIZE))
	for part = 1, snapshot.parts do
		snapshot.messages[part] = VERSION
			.. ":"
			.. snapshot.kind
			.. ":"
			.. snapshot.revision
			.. ":"
			.. part
			.. ":"
			.. snapshot.parts
			.. ":"
			.. data:sub((part - 1) * CHUNK_SIZE + 1, part * CHUNK_SIZE)
	end
end

function delta.content()
	local content = Core.encode(localQuests, delta.targeted and { repair = "r1" } or nil)
	return #content <= Core.MAX_SNAPSHOT_BYTES and content or Core.encode(localQuests)
end

function delta.targetable(peer)
	return delta.targeted
		and peer.state
		and peer.state.session == peer.deltaSession
		and tonumber(peer.state.version:match("%.(%d+)$")) >= 3
		and peer.state.extra.repair == "r1"
end

function delta.silence(key, peer)
	peer.watch, peer.repairPending = nil, nil
	if peer.silent then
		return
	end
	peer.silent = true
	peer.status = peer.quests and "stale" or "waiting"
	if QWF.isDevelopment then
		peer.debugRecoveryReason, peer.debugRecoveryAt = "heartbeat timeout", delta.now()
	end
	log("WARN", "sync", "Peer heartbeat timed out; retaining cached snapshot", { sender = key })
	render("heartbeat_timeout")
end

function delta.nextRepair()
	for _, member in ipairs(members) do
		local peer = peers[member.key]
		if
			peer.repairPending
			and peer.connected
			and not peer.silent
			and peer.status ~= "incompatible"
			and peer.status ~= "oversized"
		then
			return delta.targetable(peer) and (VERSION .. ":R:" .. peer.deltaSession) or HANDSHAKE, member.key
		end
	end
end

function delta.sentRepair(message, key)
	if message == HANDSHAKE then
		delta.fallbackAt = delta.now() + 15
	end
	for sender, peer in pairs(peers) do
		if peer.repairPending and (message == HANDSHAKE or sender == key) then
			peer.repairPending = nil
			peer.repairAfter = delta.now() + (peer.repairDelay or 15)
			peer.repairDelay = math.min(60, (peer.repairDelay or 15) * 2)
		end
	end
end

function delta.recover(key, peer, reason)
	if not peer.connected then
		return
	end
	if
		peer.deltaSession
		and delta.now() - math.max(peer.deltaSeen, peer.deltaProgressAt or 0, peer.contactAt or 0) > 45
	then
		delta.silence(key, peer)
		return
	end
	if QWF.isDevelopment then
		peer.debugRecoveryReason, peer.debugRecoveryAt = reason, delta.now()
	end
	peer.status = peer.quests and "stale" or "waiting"
	peer.partialPending = nil
	watchPeer(key, peer)
	local eligible = math.max(peer.repairAfter or 0, delta.targetable(peer) and 0 or (delta.fallbackAt or 0))
	if not peer.repairPending and delta.now() < eligible then
		local watch = peer.watch
		if not watch.repairScheduled then
			watch.repairScheduled = true
			local progress = peer.progress
			C_Timer.After(eligible - delta.now(), function()
				watch.repairScheduled = nil
				if
					peers[key] == peer
					and peer.watch == watch
					and peer.progress == progress
					and peer.connected
					and inParty()
				then
					delta.recover(key, peer, reason)
				end
			end)
		end
	elseif not peer.repairPending then
		peer.repairPending = true
		log("WARN", "sync", "Partial synchronization requires full snapshot", { sender = key, reason = reason })
		if not delta.targetable(peer) then
			-- H also announces our own baseline; older readers rely on both sides refreshing.
			refresh(true, "partial_recovery")
		end
		scheduleSend()
	end
	render("partial_recovery")
end

function delta.replyToRepair()
	if delta.responseAt and delta.now() - delta.responseAt < 15 then
		return
	end
	delta.responseAt = delta.now()
	local content = delta.content()
	if queuedSnapshot and queuedSnapshot.content == content then
		queuedSnapshot.forced = true
	elseif outgoing and outgoing.content == content and outgoing.next == 1 then
		outgoing.forced = true
	elseif not (outgoing and outgoing.kind == "D" and outgoing.content == content) then
		refresh(true, "targeted_repair")
	end
end

function delta.acceptSession(key, peer, session)
	if peer.deltaSession ~= session then
		peer.retiredSessions = peer.retiredSessions or {}
		if peer.retiredSessions[session] then
			return false
		end
		if peer.deltaSession then
			-- Bound history; recovery stays conservative even if a very old announcement reappears.
			peer.retiredSessions[peer.deltaSession] = true
			peer.retiredOrder = peer.retiredOrder or {}
			peer.retiredOrder[#peer.retiredOrder + 1] = peer.deltaSession
			if #peer.retiredOrder > 8 then
				peer.retiredSessions[table.remove(peer.retiredOrder, 1)] = nil
			end
		end
		peer.watch, peer.repairPending, peer.repairAfter, peer.repairDelay, peer.silent = nil, nil, nil, nil, nil
		peer.deltaSession = session
		peer.deltaSeen = delta.now()
		peer.deltaProgressAt, peer.contactAt = nil, nil
		peer.fullOnly = nil
		peer.state, peer.partialPending, peer.pending, peer.revision = nil, nil, nil, nil
		peer.allowReset = true
		awaitingSnapshot(key, peer, true)
	end
	peer.capabilityAt = delta.now()
	peer.detected = true
	return true
end

function delta.control(key, peer, body, minor)
	if not delta.enabled then
		return false
	end
	local target = body:match("^R:([0-9a-f]+)$")
	if target and minor >= 3 and delta.targeted and QWF.Sync.session(target) then
		if target == delta.session then
			log("DEBUG", "sync", "Received targeted snapshot request", { sender = key })
			delta.replyToRepair()
		end
		return true
	end
	local session = body:match("^C:([0-9a-f]+):q1$")
	if session and QWF.Sync.session(session) then
		local changed = peer.deltaSession ~= session
		if delta.acceptSession(key, peer, session) then
			if changed and QWF.isDevelopment then
				peer.debugRecoveryReason, peer.debugRecoveryAt = "session needs baseline", delta.now()
			end
			peer.contactAt = delta.now()
			if peer.silent then
				peer.silent = nil
				delta.recover(key, peer, "state verification unavailable")
			end
			if peer.fullOnly then
				peer.deltaSeen = delta.now()
			end
		end
		return true
	end
	local advertisedText = body:match("^V:(.+)$")
	if not advertisedText then
		return false
	end
	local advertised = QWF.Sync.identity(advertisedText)
	if not advertised then
		return true
	end
	if not delta.acceptSession(key, peer, advertised.session) then
		return true
	end
	peer.deltaSeen = delta.now()
	local wasSilent = peer.silent
	peer.silent = nil
	if not peer.state then
		if not peer.pending then
			delta.recover(key, peer, "missing baseline")
		end
	elseif advertised.sequence == peer.state.sequence and advertised.digest ~= peer.state.digest then
		delta.recover(key, peer, "state digest mismatch")
	elseif advertised.sequence > peer.state.sequence then
		local pendingSequence =
			math.max(peer.partialPending and peer.partialPending.serial or 0, peer.pending and peer.pending.serial or 0)
		if pendingSequence < advertised.sequence then
			delta.recover(key, peer, "missed update")
		end
	elseif advertised.sequence == peer.state.sequence and not peer.pending and not peer.partialPending then
		if peer.explicitRefresh then
			if wasSilent then
				delta.recover(key, peer, "explicit refresh pending")
			end
		elseif wasSilent or peer.status == "stale" then
			peer.status, peer.watch = nil, nil
			peer.repairPending, peer.repairAfter, peer.repairDelay = nil, nil, nil
			render("heartbeat_confirmed")
		end
	end
	if wasSilent and (peer.pending or peer.partialPending) then
		watchPeer(key, peer)
	end
	return true
end

function delta.ignoreTransfer(peer, pending)
	if
		peer.state
		and peer.status == "updating"
		and pending.previousStatus == nil
		and not peer.pending
		and not peer.partialPending
	then
		peer.status, peer.watch = nil, nil
		render("obsolete_transfer")
	end
end

function delta.startTimer()
	if not delta.enabled or delta.timer then
		return
	end
	local timer = {}
	delta.timer = timer
	local function tick()
		if delta.timer ~= timer or not inParty() then
			return
		end
		for key, peer in pairs(peers) do
			if
				peer.connected
				and peer.deltaSession
				and peer.status ~= "oversized"
				and peer.status ~= "incompatible"
				and delta.now() - math.max(peer.deltaSeen, peer.deltaProgressAt or 0) > 45
			then
				if delta.now() - math.max(peer.deltaSeen, peer.deltaProgressAt or 0, peer.contactAt or 0) > 45 then
					delta.silence(key, peer)
				else
					delta.recover(key, peer, "state verification unavailable")
				end
			end
		end
		if delta.published then
			delta.heartbeatPending = VERSION .. ":V:" .. QWF.Sync.identityText(delta.published)
		else
			delta.capabilityPending = true
		end
		scheduleSend()
		C_Timer.After(15 + tonumber(delta.session:sub(1, 2), 16) % 4, tick)
	end
	C_Timer.After(15 + tonumber(delta.session:sub(1, 2), 16) % 4, tick)
end

local function pumpOnce()
	if not inParty() then
		return
	end
	local message
	local repairMessage, repairKey = delta.nextRepair()
	if requestPending then
		message = HANDSHAKE
	elseif repairMessage then
		message = repairMessage
	elseif delta.capabilityPending then
		message = VERSION .. ":C:" .. delta.session .. ":q1"
	elseif oversizePending then
		message = OVERSIZED
	elseif delta.heartbeatPending then
		message = delta.heartbeatPending
	else
		if not outgoing or outgoing.next == 1 or queuedSnapshot then
			local payload = delta.content()
			local staleOutgoing = outgoing
				and outgoing.next == 1
				and not outgoing.forced
				and outgoing.content ~= payload
			local staleQueued = queuedSnapshot and not queuedSnapshot.forced and queuedSnapshot.content ~= payload
			if staleOutgoing or staleQueued then
				local context = mergeContext(staleOutgoing and outgoing.context, staleQueued and queuedSnapshot.context)
				if staleOutgoing then
					logCanceledSnapshot(outgoing, "obsolete_before_start")
					outgoing = nil
				end
				if staleQueued then
					logCanceledSnapshot(queuedSnapshot, "obsolete_before_start")
					queuedSnapshot = nil
				end
				-- Reuse this eligible send opportunity; restarting a batching timer can starve busy logs.
				broadcast(false, context)
			end
			if
				not outgoing
				and queuedSnapshot
				and not queuedSnapshot.forced
				and queuedSnapshot.content == lastPayload
			then
				logCanceledSnapshot(queuedSnapshot, "matches_submitted")
				queuedSnapshot = nil
			end
		end
		if queuedSnapshot then
			delta.materialize(queuedSnapshot)
		end
		if not outgoing and delta.resumeCheckpoint and delta.suspended then
			outgoing, delta.suspended = delta.suspended, nil
			delta.resumeCheckpoint, delta.checkpointTurn = nil, true
		end
		if
			outgoing
			and outgoing.next > 1
			and outgoing.kind == "D"
			and queuedSnapshot
			and queuedSnapshot.kind == "P"
			and not delta.suspended
			and not delta.checkpointTurn
		then
			delta.suspended, outgoing = outgoing, nil
		end
		if not outgoing then
			outgoing, queuedSnapshot = queuedSnapshot, nil
		end
		if not outgoing and delta.suspended then
			outgoing, delta.suspended = delta.suspended, nil
		end
		if not outgoing then
			return
		end
		delta.materialize(outgoing)
		message = outgoing.messages[outgoing.next]
	end
	if not send(message) then
		if message:match("^%d+%.%d+:[DP]:") then
			log("WARN", "sync", "Quest snapshot submission failed", {
				kind = outgoing.kind,
				revision = outgoing.revision,
				part = outgoing.next,
				parts = outgoing.parts,
				fingerprint = QWF.db.debugMode and fingerprint(outgoing.payload) or nil,
				retryDelay = retryDelay,
			})
		end
		nextSendAt = delta.now() + retryDelay
		retryDelay = math.min(MAX_RETRY_DELAY, retryDelay * 2)
		return
	end
	nextSendAt = delta.now() + SEND_INTERVAL
	retryDelay = 1
	if message == HANDSHAKE then
		requestPending = false
		delta.sentRepair(message)
	elseif message == repairMessage then
		delta.sentRepair(message, repairKey)
	elseif message == OVERSIZED then
		oversizePending = false
	elseif message:match("^%d+%.%d+:C:") then
		delta.capabilityPending = false
	elseif message:match("^%d+%.%d+:V:") then
		delta.heartbeatPending = nil
	else
		delta.checkpointTurn = nil
		outgoing.next = outgoing.next + 1
		if outgoing.next > #outgoing.messages then
			if outgoing.kind == "P" and delta.suspended then
				delta.resumeCheckpoint = true
			end
			if not delta.submittedRevision or outgoing.revision >= delta.submittedRevision then
				delta.submittedRevision = outgoing.revision
				lastPayload = outgoing.content
				delta.published = outgoing.state
				if not outgoing.state then
					delta.heartbeatPending = nil
				end
				if outgoing.kind == "D" then
					delta.baselineNeeded = outgoing.state == nil
				end
			end
			if QWF.db.debugMode then
				local diagnostics = {}
				snapshotObjectiveDiagnostics(diagnostics, Core.decode(outgoing.content) or {}, "You")
				recordObjectiveDiagnostics("submitted", diagnostics, "snapshot_submitted", {
					revision = outgoing.revision,
					protocol = VERSION,
				})
			end
			logSnapshot("Submitted quest snapshot", outgoing.content, lastSubmittedDiagnosticPayload, {
				kind = outgoing.kind,
				quests = outgoing.quests,
				bytes = outgoing.wireBytes,
				parts = outgoing.parts,
				revision = outgoing.revision,
				forced = outgoing.forced == true,
				queueToSubmit = QWF.db.debugMode and GetTime and outgoing.queuedAt and (GetTime() - outgoing.queuedAt)
					or nil,
			}, outgoing.context)
			if QWF.db.debugMode then
				lastSubmittedDiagnosticPayload = outgoing.content
			end
			outgoing = nil
		end
	end
end

pump = function()
	pumping = true
	local ok, err = pcall(pumpOnce)
	pumping = false
	if not ok then
		error(err, 0)
	end

	if
		inParty()
		and (
			requestPending
			or oversizePending
			or outgoing
			or queuedSnapshot
			or delta.suspended
			or delta.capabilityPending
			or delta.heartbeatPending
			or delta.nextRepair()
		)
	then
		scheduleSend()
	end
end

queueRequest = function()
	requestPending = true
	if delta.enabled then
		delta.capabilityPending = true
	end
	scheduleSend()
end

broadcast = function(force, context)
	if not inParty() then
		return
	end
	local payload = delta.content()
	local function matches(snapshot)
		return snapshot and snapshot.content == payload
	end
	local forced = force or (queuedSnapshot and queuedSnapshot.forced)
	if matches(outgoing) and not forced then
		logSuppressedSnapshot("matches_active", payload, context)
		logCanceledSnapshot(queuedSnapshot, "matches_active")
		queuedSnapshot = nil
		return
	end
	if matches(queuedSnapshot) then
		queuedSnapshot.forced = forced
		queuedSnapshot.context = mergeContext(context, queuedSnapshot.context)
		logSuppressedSnapshot("matches_queued", payload, context)
		return
	end
	if not outgoing and payload == lastPayload and not forced then
		logSuppressedSnapshot("matches_submitted", payload, context)
		logCanceledSnapshot(queuedSnapshot, "matches_submitted")
		queuedSnapshot = nil
		return
	end
	if #payload > Core.MAX_SNAPSHOT_BYTES then
		if not snapshotTooLarge or force then
			oversizePending = true
			scheduleSend()
		end
		logCanceledSnapshot(outgoing, "oversized")
		logCanceledSnapshot(queuedSnapshot, "oversized")
		outgoing, queuedSnapshot = nil, nil
		delta.suspended, delta.published, delta.heartbeatPending = nil, nil, nil
		delta.resumeCheckpoint, delta.checkpointTurn = nil, nil
		delta.baselineNeeded = true
		snapshotTooLarge = true
		lastPayload = nil
		log("WARN", "sync", "Quest snapshot exceeds protocol limit")
		render("local_snapshot_oversized")
		return
	end
	snapshotTooLarge = false
	oversizePending = false
	render("local_snapshot_ready")
	revision = revision + 1
	local content, state = payload, nil
	if delta.enabled then
		state, payload = QWF.Sync.snapshot(content, delta.session, revision)
		if not state then
			-- Metadata must not make a previously valid baseline exceed protocol limits.
			payload = content
			delta.published, delta.heartbeatPending = nil, nil
			delta.baselineNeeded = true
		end
	end
	local snapshot = {
		payload = payload,
		content = content,
		state = state,
		kind = "D",
		messages = {},
		next = 1,
		revision = revision,
		forced = forced,
		context = mergeContext(context, queuedSnapshot and queuedSnapshot.context),
		queuedAt = QWF.db.debugMode and GetTime and GetTime() or nil,
	}
	local total = math.max(1, math.ceil(#payload / CHUNK_SIZE))
	local count = 0
	for _ in pairs(localQuests) do
		count = count + 1
	end
	snapshot.quests = count
	snapshot.parts = total
	if QWF.db.debugMode then
		logSnapshot("Quest snapshot queued", payload, lastQueuedDiagnosticPayload, {
			revision = revision,
			quests = count,
			bytes = #payload,
			parts = total,
			forced = forced == true,
			activeRevision = outgoing and outgoing.revision,
			replacedRevision = queuedSnapshot and queuedSnapshot.revision,
		}, snapshot.context)
		lastQueuedDiagnosticPayload, lastSnapshotDecision = payload, nil
	end
	logCanceledSnapshot(queuedSnapshot, "superseded")
	queuedSnapshot = snapshot
	scheduleSend()
end

refresh = function(force, trigger)
	scanQuests(trigger)
	render(trigger)
	if not inParty() then
		return
	end
	forceRefresh = forceRefresh or force == true
	if QWF.db.debugMode then
		refreshTriggers[trigger or "refresh"] = true
		if force then
			refreshForceReasons[trigger or "refresh"] = true
		end
	end
	if scheduled then
		return
	end
	scheduled = true
	local currentGeneration = generation
	C_Timer.After(COALESCE_INTERVAL, function()
		if currentGeneration ~= generation then
			return
		end
		scheduled = false
		scanQuests("coalesced_refresh")
		render("coalesced_refresh")
		local forced = forceRefresh
		local context = { triggers = refreshTriggers, forceReasons = refreshForceReasons }
		forceRefresh = false
		refreshTriggers, refreshForceReasons = {}, {}
		broadcast(forced, context)
	end)
end

local function updateRoster(force, trigger)
	local party = inParty()
	local nextPeers, nextMembers = {}, {}
	local rosterPending = false
	local changed = rosterInParty ~= party
	if party then
		local myself = identity("player")
		for index = 1, 4 do
			local unit = "party" .. index
			if isPlayerPartyMember(unit) then
				local key = identity(unit)
				rosterPending = rosterPending or not key
				if key and key ~= myself then
					local name = isForever and key or UnitName(unit) or key
					nextMembers[#nextMembers + 1] = { key = key, name = name }
					local connected = UnitIsConnected(unit) == true
					local peer = peers[key]
					changed = changed or not peer or peer.connected ~= connected
					peer = peer or {}
					if peer.connected ~= connected then
						peer.watch, peer.repairPending, peer.silent = nil, nil, nil
						peer.pending, peer.partialPending, peer.state, peer.deltaSession = nil, nil, nil, nil
						peer.status = peer.quests and "stale" or nil
					end
					peer.connected = connected
					nextPeers[key] = peer
				end
			end
		end
	end
	for key, peer in pairs(peers) do
		if not nextPeers[key] then
			changed = true
			peer.watch = nil
		end
	end
	peers, members = nextPeers, nextMembers
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
	rosterInParty = party
	if not changed and not force then
		render(trigger)
		return
	end
	if changed then
		for _, peer in pairs(peers) do
			peer.repairPending, peer.repairAfter, peer.repairDelay = nil, nil, nil
		end
		delta.fallbackAt, delta.responseAt = nil, nil
		generation = generation + 1
		scheduled, forceRefresh, sending = false, false, false
		refreshTriggers, refreshForceReasons = {}, {}
		logCanceledSnapshot(outgoing, "roster_changed")
		logCanceledSnapshot(queuedSnapshot, "roster_changed")
		outgoing, queuedSnapshot = nil, nil
		delta.suspended, delta.published, delta.heartbeatPending = nil, nil, nil
		delta.resumeCheckpoint, delta.checkpointTurn = nil, nil
		delta.baselineNeeded = true
		delta.capabilityPending = delta.enabled and party
		if not party then
			delta.timer = nil
		end
		requestPending, oversizePending = false, false
		nextSendAt = math.min(nextSendAt, delta.now() + SEND_INTERVAL)
		retryDelay = 1
	end
	if party then
		delta.startTimer()
		for key, peer in pairs(peers) do
			if peer.connected and peer.detected and peer.status ~= "incompatible" then
				peer.revision = nil
				peer.allowReset = true
				awaitingSnapshot(key, peer, true)
			end
		end
		queueRequest()
	end
	log("DEBUG", "sync", "Party sync status", {
		player = identity("player"),
		inParty = inParty(),
		inRaid = IsInRaid(),
		members = members,
		game = QWF.QuestEquivalencesGame,
		prefixRegistered = prefixRegistered,
		protocol = Core.PROTOCOL_VERSION,
	})
	if changed then
		lastPayload = nil
	end
	refresh(true, trigger)
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
	local peer = key and peers[key]
	if not peer then
		log("DEBUG", "sync", "Ignored addon message", { sender = sender, key = key, reason = "sender not in roster" })
		return
	end
	if #message > 255 then
		log("DEBUG", "sync", "Ignored addon message", { sender = key, reason = "message exceeds wire limit" })
		return
	end
	local version, body = message:match("^(%d+%.%d+):(.+)$")
	local major, minor = Core.parseProtocolVersion(version)
	if QWF.isDevelopment then
		peer.debugProtocol = major and version or "unversioned / malformed"
		peer.debugMessageAt = delta.now()
	end
	if not major or major ~= Core.PROTOCOL_MAJOR then
		peer.detected = true
		peer.status = "incompatible"
		peer.pending, peer.watch, peer.revision = nil, nil, nil
		peer.state, peer.partialPending, peer.deltaSession = nil, nil, nil
		peer.repairPending = nil
		peer.allowReset = true
		log("WARN", "sync", "Unsupported addon protocol", {
			sender = key,
			protocol = version or "unversioned",
			expected = Core.PROTOCOL_VERSION,
		})
		render("unsupported_protocol")
		return
	end
	if minor >= 2 and delta.control(key, peer, body, minor) then
		return
	end
	if body == "X" then
		peer.detected = true
		peer.status = "oversized"
		peer.pending, peer.watch, peer.partialPending = nil, nil, nil
		peer.state, peer.repairPending = nil, nil
		render("peer_snapshot_oversized")
		return
	end
	if body == "H" then
		peer.contactAt, peer.silent = delta.now(), nil
		log("DEBUG", "sync", "Received snapshot request", { sender = key, protocol = version })
		-- Refresh requests allow revision counters to restart after reloads,
		-- without discarding the last snapshot or an assembly in progress.
		peer.revision = nil
		peer.allowReset = true
		if minor < 2 then
			peer.state, peer.deltaSession = nil, nil
		end
		if delta.enabled then
			delta.capabilityPending = true
			delta.baselineNeeded = true
			peer.capabilityAt = nil
		end
		awaitingSnapshot(key, peer, true)
		render("snapshot_requested")
		refresh(true, "snapshot_requested")
		return
	end
	local kind, serialText, partText, totalText, data = body:match("^([DP]):(%d+):(%d+):(%d+):(.+)$")
	if kind == "P" and (not delta.enabled or minor < 2) then
		return
	end
	local pendingField = kind == "P" and "partialPending" or "pending"
	local serial, part, total = tonumber(serialText), tonumber(partText), tonumber(totalText)
	if
		not serial
		or serial < 1
		or serial > 100000000
		or #serialText > 9
		or not part
		or #partText > 3
		or not total
		or #totalText > 3
		or total > MAX_PARTS
		or part < 1
		or part > total
		or #data > CHUNK_SIZE
	then
		log("DEBUG", "sync", "Ignored addon message", { sender = key, reason = "invalid chunk header" })
		return
	end
	if kind == "P" and peer.state and serial <= peer.state.sequence then
		return
	end
	if peer.revision and serial <= peer.revision then
		log("DEBUG", "sync", "Ignored addon message", { sender = key, reason = "stale revision", revision = serial })
		return
	end
	local pending = peer[pendingField]
	if
		not pending
		or pending.serial ~= serial
		or (peer.allowReset and (pending.total ~= total or pending.version ~= version))
	then
		if pending and serial < pending.serial and not peer.allowReset then
			log(
				"DEBUG",
				"sync",
				"Ignored addon message",
				{ sender = key, reason = "older than pending revision", revision = serial }
			)
			return
		end
		pending = {
			serial = serial,
			total = total,
			version = version,
			parts = {},
			received = 0,
			startedAt = QWF.db.debugMode and GetTime and GetTime() or nil,
			previousStatus = peer.status,
		}
		peer[pendingField] = pending
	end
	peer.allowReset = nil
	if pending.version ~= version then
		log(
			"DEBUG",
			"sync",
			"Ignored addon message",
			{ sender = key, reason = "inconsistent snapshot version", revision = serial }
		)
		return
	end
	if pending.total ~= total then
		log(
			"DEBUG",
			"sync",
			"Ignored addon message",
			{ sender = key, reason = "inconsistent chunk count", revision = serial }
		)
		return
	end
	if kind == "P" and pending.parts[part] and pending.parts[part] ~= data then
		delta.recover(key, peer, "conflicting fragment")
		return
	end
	if not pending.parts[part] then
		pending.parts[part] = data
		pending.received = pending.received + 1
		peer.progress = (peer.progress or 0) + 1
		if delta.enabled then
			peer.deltaProgressAt = delta.now()
			peer.silent = nil
		end
	end
	awaitingSnapshot(key, peer)
	log("DEBUG", "sync", "Received snapshot chunk", {
		kind = kind,
		sender = key,
		revision = serial,
		part = part,
		parts = total,
		received = pending.received,
	})
	if pending.received == total then
		peer[pendingField] = nil
		local payload = table.concat(pending.parts)
		local quests, state
		if kind == "P" then
			local target = QWF.Sync.patchTarget(payload)
			if target and peer.retiredSessions and peer.retiredSessions[target.session] then
				delta.ignoreTransfer(peer, pending)
				return
			end
			state = QWF.Sync.apply(peer.state, payload, pending.version)
			if not state or state.sequence ~= serial or state.session ~= peer.deltaSession then
				delta.recover(key, peer, "invalid partial update or base mismatch")
				return
			end
			quests = state.quests
		else
			quests = Core.decode(payload, pending.version)
			if quests and delta.enabled and minor >= 2 then
				state = QWF.Sync.readSnapshot(payload, pending.version)
				if not state then
					quests = nil
				elseif state.session then
					if state.sequence ~= serial then
						delta.recover(key, peer, "snapshot identity revision mismatch")
						return
					end
					if not delta.acceptSession(key, peer, state.session) then
						delta.ignoreTransfer(peer, pending)
						return
					end
					if peer.state and state.sequence < peer.state.sequence then
						delta.ignoreTransfer(peer, pending)
						return
					end
				else
					state = nil
					if peer.state and serial <= peer.state.sequence then
						delta.ignoreTransfer(peer, pending)
						return
					end
				end
			end
		end
		if quests then
			peer.state = state
			peer.fullOnly = peer.deltaSession and not state or nil
			if peer.deltaSession then
				peer.deltaSeen = delta.now()
			end
			recordActivity(peer.quests, quests)
			peer.revision = serial
			peer.quests = quests
			peer.snapshotAt = GetTime and GetTime()
			peer.snapshotRevision = serial
			peer.status, peer.watch, peer.silent, peer.explicitRefresh = nil, nil, nil, nil
			peer.repairPending, peer.repairAfter, peer.repairDelay = nil, nil, nil
			if kind == "P" then
				if peer.pending and peer.pending.serial <= serial then
					peer.pending = nil
				end
			else
				if peer.partialPending and peer.partialPending.serial <= serial then
					peer.partialPending = nil
				end
			end
			local diagnosticPayload = state and state.content or payload
			logSnapshot("Received quest snapshot", diagnosticPayload, peer.diagnosticPayload, {
				kind = kind,
				sender = key,
				parts = total,
				protocol = pending.version,
				revision = serial,
				bytes = #payload,
				assemblyDuration = QWF.db.debugMode
						and GetTime
						and pending.startedAt
						and (GetTime() - pending.startedAt)
					or nil,
			})
			if QWF.db.debugMode then
				peer.diagnosticPayload = diagnosticPayload
			end
			render("snapshot_received")
		else
			if peer.status ~= "stale" then
				peer.status = peer.quests and "refreshing" or "waiting"
			end
			if QWF.isDevelopment then
				peer.debugRecoveryReason, peer.debugRecoveryAt = "invalid snapshot rejected", delta.now()
			end
			log("WARN", "sync", "Rejected invalid quest snapshot", { sender = key })
			render("snapshot_rejected")
		end
	else
		render("snapshot_chunk_received")
	end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("GROUP_LEFT")
frame:RegisterEvent("UNIT_CONNECTION")
frame:RegisterEvent("QUEST_LOG_UPDATE")
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
	elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then
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
		refresh(false, event)
	end
end)

local function setDebugMode(enabled)
	if QWF.db.debugMode ~= (enabled == true) then
		displayedPeers, displayedPanel = {}, nil
		objectiveDiagnostics = {}
		refreshTriggers, refreshForceReasons = {}, {}
		lastQueuedDiagnosticPayload, lastSubmittedDiagnosticPayload, lastSnapshotDecision = nil, nil, nil
		for _, peer in pairs(peers) do
			peer.diagnosticPayload = nil
		end
		for _, snapshot in pairs({ outgoing = outgoing, queued = queuedSnapshot }) do
			snapshot.context, snapshot.queuedAt = nil, nil
		end
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
		local now = delta.now()
		local function age(timestamp)
			return timestamp and math.max(0, now - timestamp)
		end
		local function stateSummary(state)
			return state and { session = state.session, sequence = state.sequence, digest = state.digest }
		end
		local function transferSummary(snapshot)
			return snapshot
				and {
					kind = snapshot.kind,
					revision = snapshot.revision,
					sent = snapshot.next - 1,
					parts = snapshot.parts,
					bytes = snapshot.wireBytes or #snapshot.payload,
					forced = snapshot.forced == true,
					materialized = #snapshot.messages > 0,
				}
		end
		local function assemblySummary(pending)
			return pending and { revision = pending.serial, received = pending.received, parts = pending.total }
		end
		local data = {
			protocol = VERSION,
			game = isForever and "Forever" or "Retail",
			inParty = inParty(),
			inRaid = IsInRaid(),
			prefixRegistered = prefixRegistered,
			view = screenshotMode and "screenshot samples" or (previewMode and "preview samples" or "live"),
			localSnapshotKnown = localSnapshotKnown,
			localQuestCount = entryCount(localQuests),
			snapshotTooLarge = snapshotTooLarge,
			submittedBytes = lastPayload and #lastPayload,
			partialEnabled = delta.enabled,
			baselineNeeded = delta.baselineNeeded,
			published = stateSummary(delta.published),
			outgoing = transferSummary(outgoing),
			queued = transferSummary(queuedSnapshot),
			suspended = transferSummary(delta.suspended),
			requestPending = requestPending,
			capabilityPending = delta.capabilityPending,
			heartbeatPending = delta.heartbeatPending ~= nil,
			oversizePending = oversizePending,
			nextSendIn = math.max(0, nextSendAt - now),
			retryIn = retryDelay > 1 and math.max(0, nextSendAt - now) or nil,
			batching = scheduled,
			peers = {},
		}
		if C_AddOns and C_AddOns.GetAddOnMetadata then
			data.addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version")
		end
		if GetBuildInfo then
			data.clientVersion, data.clientBuild = GetBuildInfo()
		end
		for _, member in ipairs(members) do
			local peer = peers[member.key]
			data.peers[#data.peers + 1] = {
				name = member.name,
				connected = peer.connected,
				detected = peer.detected == true,
				status = peerDisplayStatus(peer),
				protocol = peer.debugProtocol,
				messageAge = age(peer.debugMessageAt),
				hasSnapshot = peer.quests ~= nil,
				questCount = peer.quests and entryCount(peer.quests),
				revision = peer.snapshotRevision,
				snapshotAge = age(peer.snapshotAt),
				session = peer.deltaSession,
				capabilityAge = age(peer.capabilityAt),
				state = stateSummary(peer.state),
				stateAge = age(peer.deltaSeen and math.max(peer.deltaSeen, peer.deltaProgressAt or 0)),
				fullOnly = peer.fullOnly,
				pending = assemblySummary(peer.pending),
				partialPending = assemblySummary(peer.partialPending),
				targetedRepair = delta.targetable(peer) == true,
				repairPending = peer.repairPending == true,
				repairIn = peer.repairAfter and math.max(0, peer.repairAfter - now),
				recoveryReason = peer.debugRecoveryReason,
				recoveryAge = age(peer.debugRecoveryAt),
			}
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
