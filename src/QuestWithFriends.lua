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
local SNAPSHOT_PREFIX = VERSION .. ":D:"
local CHUNK_SIZE = 220
local MAX_PARTS = 100
local SEND_INTERVAL = 0.5
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
local frame = CreateFrame("Frame")
local function initializeSettings()
	local savedVariables = QWF.savedVariables or "QuestWithFriendsDB"
	QWF.db = type(_G[savedVariables]) == "table" and _G[savedVariables] or {}
	_G[savedVariables] = QWF.db
	QWF.db.debugMode = QWF.db.debugMode == true
	QWF.db.panelLocked = QWF.db.panelLocked ~= false
	if QWF.db.sortMode ~= "title" then
		QWF.db.sortMode = "smart"
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

local function applyDebugMode()
	if AddonKit and AddonKit.SetLogLevel then
		AddonKit.SetLogLevel(addonName, QWF.db.debugMode and "DEBUG" or "INFO")
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

local function inParty()
	return IsInGroup() and not IsInRaid()
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
		or (not complete and not (updating and #notices == 0) and "incomplete")
		or (#groups == 0 and "in_sync" or "out_of_sync")
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
	Core.sortGroups(groups, QWF.db.sortMode, previewMode and QWF.Preview.activity or activity)
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
			getAbandonQuestID = not previewMode and getAbandonQuestID or nil,
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
			screenshotMode and screenshotScenario or nil
		)
		showPanel(groups, complete, notices, trigger)
		return
	end
	if not inParty() then
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
	local groups, complete, notices = Core.compare(localView, roster, zoneID)
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
		local allGroups = zoneID and Core.compare(localView, roster) or groups
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
			peer.revision = nil
			peer.allowReset = true
			log("WARN", "sync", "Quest snapshot timed out; requesting refresh", {
				sender = key,
				revision = peer.pending and peer.pending.serial,
				received = peer.pending and peer.pending.received,
				parts = peer.pending and peer.pending.total,
			})
			render("snapshot_timeout")
			queueRequest()
			refresh(true, "snapshot_timeout")
			watch.delay = math.min(60, watch.delay * 2)
		end
		C_Timer.After(watch.delay, check)
	end
	C_Timer.After(watch.delay, check)
end

local function awaitingSnapshot(key, peer, explicit)
	peer.detected = true
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

local pump
local function scheduleSend(delay)
	if sending then
		return
	end
	sending = true
	local currentGeneration = generation
	C_Timer.After(delay, function()
		if currentGeneration ~= generation then
			return
		end
		sending = false
		pump()
	end)
end

pump = function()
	if not inParty() then
		return
	end
	local message
	if requestPending then
		message = HANDSHAKE
	elseif oversizePending then
		message = OVERSIZED
	else
		if not outgoing then
			outgoing = queuedSnapshot
			queuedSnapshot = nil
		end
		if not outgoing then
			return
		end
		message = outgoing.messages[outgoing.next]
	end
	if not send(message) then
		if message:sub(1, #SNAPSHOT_PREFIX) == SNAPSHOT_PREFIX then
			log("WARN", "sync", "Quest snapshot submission failed", {
				revision = outgoing.revision,
				part = outgoing.next,
				parts = outgoing.parts,
				fingerprint = QWF.db.debugMode and fingerprint(outgoing.payload) or nil,
				retryDelay = retryDelay,
			})
		end
		scheduleSend(retryDelay)
		retryDelay = math.min(MAX_RETRY_DELAY, retryDelay * 2)
		return
	end
	retryDelay = 1
	if message == HANDSHAKE then
		requestPending = false
	elseif message == OVERSIZED then
		oversizePending = false
	else
		outgoing.next = outgoing.next + 1
		if outgoing.next > #outgoing.messages then
			lastPayload = outgoing.payload
			if QWF.db.debugMode then
				local diagnostics = {}
				snapshotObjectiveDiagnostics(diagnostics, Core.decode(outgoing.payload) or {}, "You")
				recordObjectiveDiagnostics("submitted", diagnostics, "snapshot_submitted", {
					revision = outgoing.revision,
					protocol = VERSION,
				})
			end
			logSnapshot("Submitted quest snapshot", outgoing.payload, lastSubmittedDiagnosticPayload, {
				quests = outgoing.quests,
				bytes = #outgoing.payload,
				parts = outgoing.parts,
				revision = outgoing.revision,
				forced = outgoing.forced == true,
				queueToSubmit = QWF.db.debugMode and GetTime and outgoing.queuedAt and (GetTime() - outgoing.queuedAt)
					or nil,
			}, outgoing.context)
			if QWF.db.debugMode then
				lastSubmittedDiagnosticPayload = outgoing.payload
			end
			outgoing = nil
		end
	end
	if requestPending or oversizePending or outgoing or queuedSnapshot then
		scheduleSend(SEND_INTERVAL)
	end
end

queueRequest = function()
	requestPending = true
	scheduleSend(SEND_INTERVAL)
end

local function broadcast(force, context)
	if not inParty() then
		return
	end
	local payload = Core.encode(localQuests)
	local function matches(snapshot)
		return snapshot and snapshot.payload == payload
	end
	local forced = force or (queuedSnapshot and queuedSnapshot.forced)
	if matches(outgoing) and not forced then
		logSuppressedSnapshot("matches_active", payload, context)
		logCanceledSnapshot(queuedSnapshot, "matches_active")
		queuedSnapshot = nil
		return
	end
	if matches(queuedSnapshot) then
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
			scheduleSend(SEND_INTERVAL)
		end
		logCanceledSnapshot(outgoing, "oversized")
		logCanceledSnapshot(queuedSnapshot, "oversized")
		outgoing, queuedSnapshot = nil, nil
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
	local snapshot = {
		payload = payload,
		messages = {},
		next = 1,
		revision = revision,
		forced = forced,
		context = mergeContext(context, queuedSnapshot and queuedSnapshot.context),
		queuedAt = QWF.db.debugMode and GetTime and GetTime() or nil,
	}
	local total = math.max(1, math.ceil(#payload / CHUNK_SIZE))
	for part = 1, total do
		snapshot.messages[#snapshot.messages + 1] = SNAPSHOT_PREFIX
			.. revision
			.. ":"
			.. part
			.. ":"
			.. total
			.. ":"
			.. payload:sub((part - 1) * CHUNK_SIZE + 1, part * CHUNK_SIZE)
	end
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
	scheduleSend(SEND_INTERVAL)
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
	C_Timer.After(0.8, function()
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
	local changed = rosterInParty ~= party
	if party then
		local myself = identity("player")
		for index = 1, 4 do
			local unit = "party" .. index
			if UnitExists(unit) then
				local key = identity(unit)
				if key and key ~= myself then
					local name = isForever and key or UnitName(unit) or key
					nextMembers[#nextMembers + 1] = { key = key, name = name }
					local connected = UnitIsConnected(unit) == true
					local peer = peers[key]
					changed = changed or not peer or peer.connected ~= connected
					peer = peer or {}
					if peer.connected ~= connected then
						peer.watch = nil
						peer.pending = nil
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
	rosterInParty = party
	if not changed and not force then
		render(trigger)
		return
	end
	if changed then
		generation = generation + 1
		scheduled, forceRefresh, sending = false, false, false
		refreshTriggers, refreshForceReasons = {}, {}
		logCanceledSnapshot(outgoing, "roster_changed")
		logCanceledSnapshot(queuedSnapshot, "roster_changed")
		outgoing, queuedSnapshot = nil, nil
		requestPending, oversizePending = false, false
		retryDelay = 1
	end
	if party then
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
	local major = Core.parseProtocolVersion(version)
	if not major or major ~= Core.PROTOCOL_MAJOR then
		peer.detected = true
		peer.status = "incompatible"
		peer.pending, peer.watch, peer.revision = nil, nil, nil
		peer.allowReset = true
		log("WARN", "sync", "Unsupported addon protocol", {
			sender = key,
			protocol = version or "unversioned",
			expected = Core.PROTOCOL_VERSION,
		})
		render("unsupported_protocol")
		return
	end
	if body == "X" then
		peer.detected = true
		peer.status = "oversized"
		peer.pending, peer.watch = nil, nil
		render("peer_snapshot_oversized")
		return
	end
	if body == "H" then
		log("DEBUG", "sync", "Received snapshot request", { sender = key, protocol = version })
		-- Refresh requests allow revision counters to restart after reloads,
		-- without discarding the last snapshot or an assembly in progress.
		peer.revision = nil
		peer.allowReset = true
		awaitingSnapshot(key, peer, true)
		render("snapshot_requested")
		refresh(true, "snapshot_requested")
		return
	end
	local serialText, partText, totalText, data = body:match("^D:(%d+):(%d+):(%d+):(.+)$")
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
	if peer.revision and serial <= peer.revision then
		log("DEBUG", "sync", "Ignored addon message", { sender = key, reason = "stale revision", revision = serial })
		return
	end
	local pending = peer.pending
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
		}
		peer.pending = pending
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
	if not pending.parts[part] then
		pending.parts[part] = data
		pending.received = pending.received + 1
		peer.progress = (peer.progress or 0) + 1
	end
	awaitingSnapshot(key, peer)
	log("DEBUG", "sync", "Received snapshot chunk", {
		sender = key,
		revision = serial,
		part = part,
		parts = total,
		received = pending.received,
	})
	if pending.received == total then
		peer.pending = nil
		local payload = table.concat(pending.parts)
		local quests = Core.decode(payload, pending.version)
		if quests then
			recordActivity(peer.quests, quests)
			peer.revision = serial
			peer.quests = quests
			peer.snapshotAt = GetTime and GetTime()
			peer.snapshotRevision = serial
			peer.status, peer.watch = nil, nil
			logSnapshot("Received quest snapshot", payload, peer.diagnosticPayload, {
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
				peer.diagnosticPayload = payload
			end
			render("snapshot_received")
		else
			if peer.status ~= "stale" then
				peer.status = peer.quests and "refreshing" or "waiting"
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
			applyDebugMode()
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
	elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
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
	applyDebugMode()
end

if AddonKit and AddonKit.RegisterAddon then
	AddonKit.RegisterAddon(addonName, { persistDiagnostics = true })
end
applyDebugMode()

local development = QWF.Development and QWF.Development.new(setPreviewMode, function()
	return screenshotMode
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
		print("Quest With Friends: Debug logging " .. (enabled and "enabled" or "disabled") .. ". Setting saved.")
		if enabled then
			if not AddonKit or not AddonKit.SetLogLevel then
				print("Quest With Friends: Enable AddonKit for debug logging.")
			else
				updateRoster(true, "debug_enabled")
			end
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
