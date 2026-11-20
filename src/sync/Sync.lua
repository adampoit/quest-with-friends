local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end

local Codec, State, Sender, Peers = QWF.SnapshotCodec, QWF.SyncState, QWF.SyncSender, QWF.SyncPeers
local Sync = {}
QWF.Sync = Sync

local COALESCE_INTERVAL = 0.2
local function noop(...) end
local function disabled()
	return false
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

local function snapshotEvidence(codec, payload, previous)
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
	local before, after = codec.decode(previous), codec.decode(payload)
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

function Sync.new(options)
	local api = {}
	local now, after, send = assert(options.now), assert(options.after), assert(options.send)
	local getLocalQuests = assert(options.getLocalQuests)
	local offerOptionalQuests = options.offerOptionalQuests
	local prepareLocal, notify = options.prepareLocal or noop, options.onStatusChanged or noop
	local onPeerSnapshot = options.onPeerSnapshot or noop
	local debugMode, log = options.debugMode or disabled, options.log or noop
	local timestamp = options.timestamp or now
	local isTransportAvailable = options.isTransportAvailable
	local minor = options.minor or Codec.PROTOCOL_MINOR
	local codec = Codec.new(minor, options.maxSnapshotBytes or Codec.MAX_SNAPSHOT_BYTES)
	local session = minor >= 2 and assert(State.session(options.session) and options.session, "Sync session required")
		or nil
	local targeted = minor >= 3
	local party, batch = false, nil
	local syncSender
	local function inParty()
		return party and (not isTransportAvailable or isTransportAvailable())
	end

	local function getContent()
		local quests, count = codec.selectQuests(getLocalQuests(), offerOptionalQuests)
		local content = codec.encode(quests, targeted and { repair = "r1" } or nil)
		return #content <= codec.MAX_SNAPSHOT_BYTES and content or codec.encode(quests), count
	end

	local function queueSnapshot(force, trigger)
		if not inParty() then
			return
		end
		local pending = batch or { context = { triggers = {}, forceReasons = {} } }
		pending.forced = pending.forced or force == true
		if debugMode() then
			pending.context.triggers[trigger or "refresh"] = true
			if force then
				pending.context.forceReasons[trigger or "refresh"] = true
			end
		end
		if not batch then
			batch = pending
			after(COALESCE_INTERVAL, function()
				if batch ~= pending then
					return
				end
				batch = nil
				prepareLocal("coalesced_refresh", true)
				syncSender.broadcast(pending.forced, pending.context)
			end)
		end
	end

	local function requestFull(trigger)
		prepareLocal(trigger)
		queueSnapshot(true, trigger)
	end

	local function logSnapshot(message, payload, previous, data, context)
		if debugMode() then
			for field, value in pairs(snapshotEvidence(codec, payload, previous)) do
				data[field] = value
			end
			if context then
				data.triggers = table.concat(sortedKeys(context.triggers), ",")
				data.forceReasons = table.concat(sortedKeys(context.forceReasons), ",")
			end
		end
		log("DEBUG", "sync", message, data)
	end

	local peerSync = Peers.new({
		codec = codec,
		session = session,
		targeted = targeted,
		now = now,
		timestamp = timestamp,
		after = after,
		inParty = inParty,
		debugMode = debugMode,
		development = options.development,
		log = log,
		logSnapshot = logSnapshot,
		onStatusChanged = notify,
		requestFull = requestFull,
		onLegacyTimeout = function()
			syncSender.queueRequest()
			requestFull("snapshot_timeout")
		end,
		onTargetedRequest = function()
			syncSender.replyToRepair()
		end,
		requireBaseline = function()
			syncSender.requireBaseline()
		end,
		scheduleSend = function()
			syncSender.schedule()
		end,
		announce = function()
			syncSender.announce()
		end,
		getContent = getContent,
		onCommit = function(key, previous, quests, previousContent)
			onPeerSnapshot(key, previous, quests)
			if getContent() ~= previousContent then
				api.localChanged("peer_completion_changed")
			else
				notify("snapshot_received")
			end
		end,
	})
	syncSender = Sender.new({
		codec = codec,
		session = session,
		now = now,
		timestamp = timestamp,
		after = after,
		inParty = inParty,
		send = send,
		getContent = getContent,
		allSupportPartial = peerSync.allSupportPartial,
		nextRepair = peerSync.nextRepair,
		sentRepair = peerSync.sentRepair,
		requestFull = requestFull,
		onSizeChanged = notify,
		debugMode = debugMode,
		log = log,
		logSnapshot = logSnapshot,
		fingerprint = fingerprint,
		sortedKeys = sortedKeys,
		mergeContext = function(current, previous)
			return debugMode() and mergeContext(current, previous) or nil
		end,
		onSubmitted = options.onSubmitted or noop,
	})

	local function requestPartySnapshot(trigger)
		if inParty() then
			peerSync.expectFullSnapshots()
			syncSender.queueRequest()
			queueSnapshot(true, trigger)
		end
	end

	function api.setRoster(members, connections, grouped, trigger)
		local changed = peerSync.setRoster(members, connections, grouped)
		party = grouped
		if changed then
			peerSync.resetRecovery(party)
			batch = nil
			syncSender.reset(party)
			requestPartySnapshot(trigger)
		end
		return changed
	end

	function api.refresh(trigger)
		requestPartySnapshot(trigger or "manual_refresh")
		prepareLocal(trigger or "manual_refresh")
	end

	function api.localChanged(trigger)
		prepareLocal(trigger)
		queueSnapshot(false, trigger)
	end

	function api.receive(key, message, sender)
		if not inParty() or type(message) ~= "string" then
			log("DEBUG", "sync", "Ignored addon message", {
				sender = sender or key,
				reason = "not in party or invalid message type",
			})
			return
		end
		peerSync.receive(key, sender or key, message)
	end

	-- The view wrapper is detached. Borrowed quest data must be treated as read-only.
	api.peer = peerSync.view
	api.peerDiagnostics = peerSync.diagnostics
	api.isOversized = syncSender.isOversized

	function api.diagnostics()
		local summary = syncSender.diagnostics()
		summary.batching = batch ~= nil
		return summary
	end

	function api.clearDiagnostics()
		if batch then
			batch.context = { triggers = {}, forceReasons = {} }
		end
		peerSync.clearDiagnostics()
		syncSender.clearDiagnostics()
	end

	return api
end
