local QWF = QuestWithFriends
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
local screenshotToolsShown = false
local screenshotLayout
local previewCollapsed = {}
local previewSetting
local panelLockSetting
local render
local setPreviewMode
local frame = CreateFrame("Frame")
local function initializeSettings()
	QuestWithFriendsDB = type(QuestWithFriendsDB) == "table" and QuestWithFriendsDB or {}
	QuestWithFriendsDB.debugMode = QuestWithFriendsDB.debugMode == true
	QuestWithFriendsDB.panelLocked = QuestWithFriendsDB.panelLocked ~= false
	if QuestWithFriendsDB.sortMode ~= "title" then
		QuestWithFriendsDB.sortMode = "smart"
	end
	if QuestWithFriendsDB.zoneFilter == nil then
		QuestWithFriendsDB.zoneFilter = true
	end
	for _, setting in ipairs({ "showProfessionQuests", "showClassQuests" }) do
		if QuestWithFriendsDB[setting] == nil then
			QuestWithFriendsDB[setting] = QuestWithFriendsDB.showPersonalQuests == true
		end
	end
end
initializeSettings()

local function applyDebugMode()
	if AddonKit and AddonKit.SetLogLevel then
		AddonKit.SetLogLevel("QuestWithFriends", QuestWithFriendsDB.debugMode and "DEBUG" or "INFO")
	end
end

local function log(level, category, message, data)
	if AddonKit and AddonKit.Log then
		AddonKit.Log("QuestWithFriends", level, category, message, data)
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

local function collectQuests()
	local quests = {}
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
		elseif info and not info.isHeader and type(info.questID) == "number" and info.questID > 0 then
			local id = info.questID
			questCategories[id] = questCategory(id) or headerCategory or questCategories[id]
			local objectives = {}
			local raw = C_QuestLog.GetQuestObjectives(id) or {}
			for _, objective in ipairs(raw) do
				local need = tonumber(objective.numRequired) or 0
				local have = tonumber(objective.numFulfilled) or (objective.finished and need or 0)
				local text = (objective.text or ""):gsub(":%s*%d+/%d+%s*$", "")
				objectives[#objectives + 1] = { text = text, have = have, need = need }
			end
			quests[id] = {
				title = info.title or ("Quest " .. id),
				state = C_QuestLog.IsComplete(id) and "ready" or "active",
				objectives = objectives,
				mapID = GetQuestUiMapID and zoneMapID(GetQuestUiMapID(id, true)) or nil,
				category = questCategories[id],
			}
		end
	end
	local visible = 0
	for _ in pairs(quests) do
		visible = visible + 1
	end
	local summary = visible .. ":" .. filtered
	if summary ~= lastScanSummary then
		lastScanSummary = summary
		log("INFO", "scan", "Quest log scanned", { visible = visible, hiddenOrInternal = filtered })
	end
	for id, record in pairs(completed) do
		if not quests[id] then
			quests[id] = {
				title = record.title,
				state = "completed",
				objectives = {},
				mapID = record.mapID,
				category = questCategories[id],
			}
		end
	end
	return quests
end

local function recordActivity(previous, current)
	activitySequence = activitySequence + 1
	Core.recordActivity(activity, previous, current, activitySequence)
end

local function scanQuests()
	local quests = collectQuests()
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

local function showPanel(groups, complete, notices)
	Core.sortGroups(groups, QuestWithFriendsDB.sortMode, previewMode and QWF.Preview.activity or activity)
	QWF.Panel.show(
		groups,
		complete,
		QuestWithFriendsDB.zoneFilter,
		function()
			QuestWithFriendsDB.zoneFilter = not QuestWithFriendsDB.zoneFilter
			render()
		end,
		not previewMode
				and function(id)
					-- Resolve the index again: the quest log may have changed since rendering.
					local index = shareableQuestIndex(id)
					if index then
						QuestLogPushQuest(index)
					else
						render()
					end
				end
			or nil,
		notices,
		{
			professions = QuestWithFriendsDB.showProfessionQuests,
			classes = QuestWithFriendsDB.showClassQuests,
			toggleProfessions = function()
				QuestWithFriendsDB.showProfessionQuests = not QuestWithFriendsDB.showProfessionQuests
				render()
			end,
			toggleClasses = function()
				QuestWithFriendsDB.showClassQuests = not QuestWithFriendsDB.showClassQuests
				render()
			end,
		},
		{
			onLock = function(locked)
				if panelLockSetting then
					panelLockSetting:SetValue(locked)
				else
					QWF.Panel.setLocked(locked)
				end
			end,
			sortMode = QuestWithFriendsDB.sortMode,
			onSort = function(mode)
				QuestWithFriendsDB.sortMode = mode == "title" and "title" or "smart"
				render()
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
end

render = function()
	if not QWF.Panel then
		return
	end
	if previewMode and IsInGroup() then
		previewMode = false
		screenshotMode = false
		screenshotScenario = "differences"
		previewCollapsed = {}
		if previewSetting then
			previewSetting:SetValue(false)
		end
	end
	if previewMode then
		showPanel(
			QWF.Preview.compare(
				QuestWithFriendsDB.zoneFilter,
				QuestWithFriendsDB.showProfessionQuests,
				QuestWithFriendsDB.showClassQuests,
				screenshotMode and screenshotScenario or nil
			)
		)
		return
	end
	if not inParty() then
		QWF.Panel.hide()
		return
	end
	local roster = {}
	local localView = {}
	for id, quest in pairs(localQuests) do
		localView[id] = quest
	end
	for _, member in ipairs(members) do
		local peer = peers[member.key]
		local quests = peer and peer.quests
		local status = peer and peer.status
		if peer and not peer.connected then
			status = "offline"
		end
		roster[#roster + 1] = { name = member.name, quests = quests, syncStatus = status }
		if quests then
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
	local zoneID = QuestWithFriendsDB.zoneFilter
			and C_Map
			and C_Map.GetBestMapForUnit
			and zoneMapID(C_Map.GetBestMapForUnit("player"))
		or nil
	local groups, complete, notices = Core.compare(localView, roster, zoneID)
	if not QuestWithFriendsDB.showProfessionQuests or not QuestWithFriendsDB.showClassQuests then
		local visible = {}
		local function hidden(category)
			return (category == "profession" and not QuestWithFriendsDB.showProfessionQuests)
				or (category == "class" and not QuestWithFriendsDB.showClassQuests)
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
				excluded = excluded or hidden(category)
			end
			if not excluded then
				visible[#visible + 1] = group
			end
		end
		groups = visible
	end
	for _, group in ipairs(groups) do
		if group.shareQuestID and not shareableQuestIndex(group.shareQuestID) then
			group.shareQuestID = nil
		end
	end
	if snapshotTooLarge then
		complete = false
		table.insert(notices, 1, { player = "You", reason = "oversized" })
	end
	showPanel(groups, complete, notices)
end

setPreviewMode = function(enabled, screenshot, scenario)
	if enabled and IsInGroup() then
		print("Quest With Friends: Leave your group to preview sample quest data.")
		return false
	end
	local wasScreenshot = screenshotMode
	previewMode = enabled == true
	screenshotMode = previewMode and screenshot == true
	screenshotScenario = screenshotMode and (scenario or screenshotScenario) or "differences"
	if not previewMode or wasScreenshot ~= screenshotMode or scenario then
		previewCollapsed = {}
		if screenshotMode and screenshotScenario == "collapsed" then
			for _, group in ipairs(QWF.Preview.compare(false, true, true)) do
				previewCollapsed[group.questID] = true
			end
		end
	end
	render()
	return true
end

local function showScreenshotScenario(scenario)
	if setPreviewMode(true, true, scenario) and SettingsPanel then
		SettingsPanel:Hide()
	end
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
			render()
			queueRequest()
			refresh(true)
			watch.delay = math.min(60, watch.delay * 2)
		end
		C_Timer.After(watch.delay, check)
	end
	C_Timer.After(watch.delay, check)
end

local function awaitingSnapshot(key, peer)
	peer.detected = true
	if peer.status ~= "stale" then
		peer.status = peer.quests and "refreshing" or "waiting"
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
			log("DEBUG", "sync", "Submitted quest snapshot", {
				quests = outgoing.quests,
				bytes = #outgoing.payload,
				parts = outgoing.parts,
				revision = outgoing.revision,
			})
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

local function broadcast(force)
	if not inParty() then
		return
	end
	local payload = Core.encode(localQuests)
	local function matches(snapshot)
		return snapshot and snapshot.payload == payload
	end
	local forced = force or (queuedSnapshot and queuedSnapshot.forced)
	if matches(outgoing) and not forced then
		queuedSnapshot = nil
		return
	end
	if matches(queuedSnapshot) then
		return
	end
	if not outgoing and payload == lastPayload and not forced then
		queuedSnapshot = nil
		return
	end
	if #payload > Core.MAX_SNAPSHOT_BYTES then
		if not snapshotTooLarge or force then
			oversizePending = true
			scheduleSend(SEND_INTERVAL)
		end
		outgoing, queuedSnapshot = nil, nil
		snapshotTooLarge = true
		lastPayload = nil
		log("WARN", "sync", "Quest snapshot exceeds protocol limit")
		render()
		return
	end
	snapshotTooLarge = false
	oversizePending = false
	render()
	revision = revision + 1
	local snapshot = {
		payload = payload,
		messages = {},
		next = 1,
		revision = revision,
		forced = forced,
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
	queuedSnapshot = snapshot
	scheduleSend(SEND_INTERVAL)
end

refresh = function(force)
	scanQuests()
	render()
	if not inParty() then
		return
	end
	forceRefresh = forceRefresh or force == true
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
		scanQuests()
		render()
		local forced = forceRefresh
		forceRefresh = false
		broadcast(forced)
	end)
end

local function updateRoster(force)
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
		render()
		return
	end
	if changed then
		generation = generation + 1
		scheduled, forceRefresh, sending = false, false, false
		outgoing, queuedSnapshot = nil, nil
		requestPending, oversizePending = false, false
		retryDelay = 1
	end
	if party then
		for key, peer in pairs(peers) do
			if peer.connected and peer.detected and peer.status ~= "incompatible" then
				peer.revision = nil
				peer.allowReset = true
				awaitingSnapshot(key, peer)
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
	refresh(true)
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
		render()
		return
	end
	if body == "X" then
		peer.detected = true
		peer.status = "oversized"
		peer.pending, peer.watch = nil, nil
		render()
		return
	end
	if body == "H" then
		log("DEBUG", "sync", "Received snapshot request", { sender = key, protocol = version })
		-- Refresh requests allow revision counters to restart after reloads,
		-- without discarding the last snapshot or an assembly in progress.
		peer.revision = nil
		peer.allowReset = true
		awaitingSnapshot(key, peer)
		render()
		refresh(true)
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
		pending = { serial = serial, total = total, version = version, parts = {}, received = 0 }
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
		local quests = Core.decode(table.concat(pending.parts), pending.version)
		if quests then
			recordActivity(peer.quests, quests)
			peer.revision = serial
			peer.quests = quests
			peer.status, peer.watch = nil, nil
			log("DEBUG", "sync", "Received quest snapshot", { sender = key, parts = total, protocol = pending.version })
			render()
		else
			log("WARN", "sync", "Rejected invalid quest snapshot", { sender = key })
			render()
		end
	else
		render()
	end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("UNIT_CONNECTION")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == "QuestWithFriends" then
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
		updateRoster(event == "PLAYER_ENTERING_WORLD")
	elseif event == "UNIT_CONNECTION" then
		local unit = ...
		if type(unit) == "string" and unit:match("^party[1-4]$") then
			updateRoster(false)
		end
	elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then
		render()
	else
		if event == "QUEST_TURNED_IN" then
			local id = ...
			if type(id) == "number" and id > 0 then
				local info = C_QuestLog.GetTitleForQuestID(id)
				completed[id] = {
					title = info or (localQuests[id] and localQuests[id].title) or ("Quest " .. id),
					mapID = localQuests[id] and localQuests[id].mapID,
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
		refresh(false)
	end
end)

local function setDebugMode(enabled)
	QuestWithFriendsDB.debugMode = enabled == true
	applyDebugMode()
end

if AddonKit and AddonKit.RegisterAddon then
	AddonKit.RegisterAddon("QuestWithFriends", { persistDiagnostics = true })
end
applyDebugMode()

local debugSetting
if
	Settings
	and Settings.RegisterVerticalLayoutCategory
	and Settings.RegisterProxySetting
	and Settings.CreateCheckbox
then
	local category, layout = Settings.RegisterVerticalLayoutCategory("Quest With Friends")
	debugSetting = Settings.RegisterProxySetting(
		category,
		"QuestWithFriendsDebugMode",
		Settings.VarType.Boolean,
		"Debug mode",
		false,
		function()
			return QuestWithFriendsDB.debugMode
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
		"QuestWithFriendsPanelLocked",
		Settings.VarType.Boolean,
		"Lock panel",
		true,
		function()
			return QuestWithFriendsDB.panelLocked
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
		"QuestWithFriendsPreviewMode",
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
			{ "differences", "Quest differences", "Missing quests, multiple objectives, readiness and completion." },
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
			if screenshotMode then
				setPreviewMode(false)
			end
		end, "Return to real party data, or hide the panel while solo.", false)
		stop:AddModifyPredicate(function()
			return screenshotMode
		end)
		addScreenshotControl(stop)
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
	if command == "screenshot" or command == "screenshot on" or command == "screenshot off" then
		if not screenshotLayout then
			print("Quest With Friends: Screenshot tools require the addon settings panel.")
			return
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
		render()
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
				updateRoster(true)
			end
		end
		return
	end
	if not inParty() then
		print("Quest With Friends: Join a party to compare quests, or use /qwf preview to see sample data.")
	else
		updateRoster(true)
		print("Quest With Friends: Refreshing party quest status.")
	end
end
