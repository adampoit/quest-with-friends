local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
local Codec, Sync = QWF.SnapshotCodec, QWF.SyncState
local Sender = {}
QWF.SyncSender = Sender

local SEND_INTERVAL = 0.5
local MAX_RETRY_DELAY = 8

function Sender.new(options)
	local api = {}
	local codec, session = options.codec, options.session
	local version = codec.version
	local HANDSHAKE, OVERSIZED = version .. ":H", version .. ":X"
	local now, timestamp, after = options.now, options.timestamp, options.after
	local inParty, send, getContent = options.inParty, options.send, options.getContent
	local debugMode, log, logSnapshot = options.debugMode, options.log, options.logSnapshot
	local fingerprint, sortedKeys, mergeContext = options.fingerprint, options.sortedKeys, options.mergeContext
	local tx = { baselineNeeded = true, capabilityPending = false }
	local revision, generation = 0, 0
	local outgoing, queuedSnapshot, lastPayload
	local lastQueuedDiagnosticPayload, lastSubmittedDiagnosticPayload, lastSnapshotDecision
	local requestPending, oversizePending, snapshotTooLarge = false, false, false
	local sending, pumping, retryDelay, nextSendAt = false, false, 1, 0
	local function logSuppressedSnapshot(reason, payload, context)
		if not debugMode() then
			return
		end
		local triggers = table.concat(sortedKeys(context and context.triggers), ",")
		local forceReasons = table.concat(sortedKeys(context and context.forceReasons), ",")
		local decision = { reason = reason, payload = payload, triggers = triggers, forceReasons = forceReasons }
		local previous = lastSnapshotDecision
		if
			previous
			and previous.reason == reason
			and previous.payload == payload
			and previous.triggers == triggers
			and previous.forceReasons == forceReasons
		then
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
		if debugMode() and snapshot then
			log("DEBUG", "sync", "Quest snapshot canceled", {
				revision = snapshot.revision,
				fingerprint = fingerprint(snapshot.payload),
				reason = reason,
				nextPart = snapshot.next,
				parts = snapshot.parts,
			})
		end
	end

	local pump, broadcast
	local function scheduleSend()
		if sending or pumping then
			return
		end
		sending = true
		local currentGeneration = generation
		after(math.max(0, nextSendAt - now()), function()
			if currentGeneration ~= generation then
				return
			end
			sending = false
			pump()
		end)
	end

	local function materialize(snapshot)
		if snapshot.next > 1 then
			return
		end
		local data = snapshot.payload
		snapshot.kind = "D"
		if
			snapshot.state
			and not snapshot.forced
			and (session and not tx.baselineNeeded and tx.published and options.allSupportPartial())
		then
			local patch = Sync.patch(tx.published, snapshot.state)
			if #patch < #data then
				data, snapshot.kind = patch, "P"
			end
		end
		snapshot.wireBytes = #data
		snapshot.messages = {}
		snapshot.parts = math.max(1, math.ceil(#data / Codec.CHUNK_SIZE))
		for part = 1, snapshot.parts do
			snapshot.messages[part] = version
				.. ":"
				.. snapshot.kind
				.. ":"
				.. snapshot.revision
				.. ":"
				.. part
				.. ":"
				.. snapshot.parts
				.. ":"
				.. data:sub((part - 1) * Codec.CHUNK_SIZE + 1, part * Codec.CHUNK_SIZE)
		end
	end

	function api.replyToRepair()
		if tx.responseAt and now() - tx.responseAt < 15 then
			return
		end
		tx.responseAt = now()
		local content = getContent()
		if queuedSnapshot and queuedSnapshot.content == content then
			queuedSnapshot.forced = true
		elseif outgoing and outgoing.content == content and outgoing.next == 1 then
			outgoing.forced = true
		elseif not (outgoing and outgoing.kind == "D" and outgoing.content == content) then
			options.requestFull("targeted_repair")
		end
	end

	local function pumpOnce()
		if not inParty() then
			return
		end
		local message
		local repairMessage, repairKey = options.nextRepair()
		if requestPending then
			message = HANDSHAKE
		elseif repairMessage then
			message = repairMessage
		elseif tx.capabilityPending then
			message = version .. ":C:" .. session .. ":q1"
		elseif oversizePending then
			message = OVERSIZED
		elseif tx.heartbeatPending then
			message = tx.heartbeatPending
		else
			if not outgoing or outgoing.next == 1 or queuedSnapshot then
				local payload = getContent()
				local staleOutgoing = outgoing
					and outgoing.next == 1
					and not outgoing.forced
					and outgoing.content ~= payload
				local staleQueued = queuedSnapshot and not queuedSnapshot.forced and queuedSnapshot.content ~= payload
				if staleOutgoing or staleQueued then
					local context =
						mergeContext(staleOutgoing and outgoing.context, staleQueued and queuedSnapshot.context)
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
				materialize(queuedSnapshot)
			end
			if not outgoing and tx.resumeCheckpoint and tx.suspended then
				outgoing, tx.suspended = tx.suspended, nil
				tx.resumeCheckpoint, tx.checkpointTurn = nil, true
			end
			if
				outgoing
				and outgoing.next > 1
				and outgoing.kind == "D"
				and queuedSnapshot
				and queuedSnapshot.kind == "P"
				and not tx.suspended
				and not tx.checkpointTurn
			then
				tx.suspended, outgoing = outgoing, nil
			end
			if not outgoing then
				outgoing, queuedSnapshot = queuedSnapshot, nil
			end
			if not outgoing and tx.suspended then
				outgoing, tx.suspended = tx.suspended, nil
			end
			if not outgoing then
				return
			end
			materialize(outgoing)
			message = outgoing.messages[outgoing.next]
		end
		if not send(message) then
			if message:match("^%d+%.%d+:[DP]:") then
				log("WARN", "sync", "Quest snapshot submission failed", {
					kind = outgoing.kind,
					revision = outgoing.revision,
					part = outgoing.next,
					parts = outgoing.parts,
					fingerprint = debugMode() and fingerprint(outgoing.payload) or nil,
					retryDelay = retryDelay,
				})
			end
			nextSendAt = now() + retryDelay
			retryDelay = math.min(MAX_RETRY_DELAY, retryDelay * 2)
			return
		end
		nextSendAt = now() + SEND_INTERVAL
		retryDelay = 1
		if message == HANDSHAKE then
			requestPending = false
			options.sentRepair(message)
		elseif message == repairMessage then
			options.sentRepair(message, repairKey)
		elseif message == OVERSIZED then
			oversizePending = false
		elseif message:match("^%d+%.%d+:C:") then
			tx.capabilityPending = false
		elseif message:match("^%d+%.%d+:V:") then
			tx.heartbeatPending = nil
		else
			tx.checkpointTurn = nil
			outgoing.next = outgoing.next + 1
			if outgoing.next > #outgoing.messages then
				if outgoing.kind == "P" and tx.suspended then
					tx.resumeCheckpoint = true
				end
				if not tx.submittedRevision or outgoing.revision >= tx.submittedRevision then
					tx.submittedRevision = outgoing.revision
					lastPayload = outgoing.content
					tx.published = outgoing.state
					if not outgoing.state then
						tx.heartbeatPending = nil
					end
					if outgoing.kind == "D" then
						tx.baselineNeeded = outgoing.state == nil
					end
				end
				if debugMode() then
					options.onSubmitted(codec.decode(outgoing.content) or {}, outgoing.revision)
				end
				logSnapshot("Submitted quest snapshot", outgoing.content, lastSubmittedDiagnosticPayload, {
					kind = outgoing.kind,
					quests = outgoing.quests,
					bytes = outgoing.wireBytes,
					parts = outgoing.parts,
					revision = outgoing.revision,
					forced = outgoing.forced == true,
					queueToSubmit = debugMode() and outgoing.queuedAt and (now() - outgoing.queuedAt) or nil,
				}, outgoing.context)
				if debugMode() then
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
				or tx.suspended
				or tx.capabilityPending
				or tx.heartbeatPending
				or options.nextRepair()
			)
		then
			scheduleSend()
		end
	end

	function api.queueRequest()
		requestPending = true
		if session then
			tx.capabilityPending = true
		end
		scheduleSend()
	end

	broadcast = function(force, context)
		if not inParty() then
			return
		end
		local payload, count = getContent()
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
		if #payload > codec.MAX_SNAPSHOT_BYTES then
			if not snapshotTooLarge or force then
				oversizePending = true
				scheduleSend()
			end
			logCanceledSnapshot(outgoing, "oversized")
			logCanceledSnapshot(queuedSnapshot, "oversized")
			outgoing, queuedSnapshot = nil, nil
			tx.suspended, tx.published, tx.heartbeatPending = nil, nil, nil
			tx.resumeCheckpoint, tx.checkpointTurn = nil, nil
			tx.baselineNeeded = true
			snapshotTooLarge = true
			lastPayload = nil
			log("WARN", "sync", "Quest snapshot exceeds protocol limit")
			options.onSizeChanged("local_snapshot_oversized")
			return
		end
		snapshotTooLarge = false
		oversizePending = false
		options.onSizeChanged("local_snapshot_ready")
		revision = revision + 1
		local content, state = payload, nil
		if session then
			state, payload = Sync.snapshot(content, session, revision, codec)
			if not state then
				-- Metadata must not make a previously valid baseline exceed protocol limits.
				payload = content
				tx.published, tx.heartbeatPending = nil, nil
				tx.baselineNeeded = true
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
			queuedAt = debugMode() and timestamp() or nil,
		}
		local total = math.max(1, math.ceil(#payload / Codec.CHUNK_SIZE))
		snapshot.quests = count
		snapshot.parts = total
		if debugMode() then
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

	api.schedule = scheduleSend
	api.broadcast = broadcast

	function api.requireBaseline()
		if session then
			tx.capabilityPending = true
			tx.baselineNeeded = true
		end
	end

	function api.announce()
		if tx.published then
			tx.heartbeatPending = version .. ":V:" .. Sync.identityText(tx.published)
		else
			tx.capabilityPending = true
		end
		scheduleSend()
	end

	function api.reset(party)
		generation = generation + 1
		sending = false
		logCanceledSnapshot(outgoing, "roster_changed")
		logCanceledSnapshot(queuedSnapshot, "roster_changed")
		outgoing, queuedSnapshot = nil, nil
		tx.suspended, tx.published, tx.heartbeatPending, tx.responseAt = nil, nil, nil, nil
		tx.resumeCheckpoint, tx.checkpointTurn = nil, nil
		tx.baselineNeeded = true
		tx.capabilityPending = session ~= nil and party
		requestPending, oversizePending = false, false
		nextSendAt = math.min(nextSendAt, now() + SEND_INTERVAL)
		retryDelay = 1
		lastPayload = nil
	end

	function api.isOversized()
		return snapshotTooLarge
	end

	function api.clearDiagnostics()
		lastQueuedDiagnosticPayload, lastSubmittedDiagnosticPayload, lastSnapshotDecision = nil, nil, nil
		for _, snapshot in pairs({ outgoing = outgoing, queued = queuedSnapshot }) do
			snapshot.context, snapshot.queuedAt = nil, nil
		end
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

	function api.diagnostics()
		local delay = math.max(0, nextSendAt - now())
		local state = tx.published
		return {
			snapshotTooLarge = snapshotTooLarge,
			submittedBytes = lastPayload and #lastPayload,
			partialEnabled = session ~= nil,
			baselineNeeded = tx.baselineNeeded,
			published = state and { session = state.session, sequence = state.sequence, digest = state.digest },
			outgoing = transferSummary(outgoing),
			queued = transferSummary(queuedSnapshot),
			suspended = transferSummary(tx.suspended),
			requestPending = requestPending,
			capabilityPending = tx.capabilityPending,
			heartbeatPending = tx.heartbeatPending ~= nil,
			oversizePending = oversizePending,
			nextSendIn = delay,
			retryIn = retryDelay > 1 and delay or nil,
		}
	end

	return api
end
