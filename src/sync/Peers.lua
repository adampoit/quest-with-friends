local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
local Codec, Sync = QWF.SnapshotCodec, QWF.SyncState
local Peers = {}
QWF.SyncPeers = Peers

local SNAPSHOT_TIMEOUT = 15

function Peers.new(options)
	local api = {}
	local codec, session, targeted = options.codec, options.session, options.targeted
	local localVersion = codec.version
	local HANDSHAKE = localVersion .. ":H"
	local now, timestamp, after = options.now, options.timestamp, options.after
	local inParty, debugMode, log = options.inParty, options.debugMode, options.log
	local notify = options.onStatusChanged
	local peers, members, rosterInParty = {}, {}, nil
	local fallbackAt, timer
	local recover
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
				if options.development then
					peer.debugRecoveryReason, peer.debugRecoveryAt = "snapshot progress timeout", timestamp()
				end
				peer.revision = nil
				peer.allowReset = true
				log("WARN", "sync", "Quest snapshot timed out; requesting refresh", {
					sender = key,
					revision = peer.pending and peer.pending.serial,
					received = peer.pending and peer.pending.received,
					parts = peer.pending and peer.pending.total,
				})
				notify("snapshot_timeout")
				if session then
					recover(key, peer, "snapshot progress timeout")
				else
					options.onLegacyTimeout()
				end
				watch.delay = math.min(60, watch.delay * 2)
			end
			after(watch.delay, check)
		end
		after(watch.delay, check)
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

	local function targetable(peer)
		return targeted
			and peer.state
			and peer.state.session == peer.deltaSession
			and tonumber(peer.state.version:match("%.(%d+)$")) >= 3
			and peer.state.extra.repair == "r1"
	end

	local function silence(key, peer)
		peer.watch, peer.repairPending = nil, nil
		if peer.silent then
			return
		end
		peer.silent = true
		peer.status = peer.quests and "stale" or "waiting"
		if options.development then
			peer.debugRecoveryReason, peer.debugRecoveryAt = "heartbeat timeout", now()
		end
		log("WARN", "sync", "Peer heartbeat timed out; retaining cached snapshot", { sender = key })
		notify("heartbeat_timeout")
	end

	function api.nextRepair()
		for _, key in ipairs(members) do
			local peer = peers[key]
			if
				peer.repairPending
				and peer.connected
				and not peer.silent
				and peer.status ~= "incompatible"
				and peer.status ~= "oversized"
			then
				return targetable(peer) and (localVersion .. ":R:" .. peer.deltaSession) or HANDSHAKE, key
			end
		end
	end

	function api.sentRepair(message, key)
		if message == HANDSHAKE then
			fallbackAt = now() + 15
		end
		for sender, peer in pairs(peers) do
			if peer.repairPending and (message == HANDSHAKE or sender == key) then
				peer.repairPending = nil
				peer.repairAfter = now() + (peer.repairDelay or 15)
				peer.repairDelay = math.min(60, (peer.repairDelay or 15) * 2)
			end
		end
	end

	recover = function(key, peer, reason)
		if not peer.connected then
			return
		end
		if
			peer.deltaSession
			and now() - math.max(peer.deltaSeen, peer.deltaProgressAt or 0, peer.contactAt or 0) > 45
		then
			silence(key, peer)
			return
		end
		if options.development then
			peer.debugRecoveryReason, peer.debugRecoveryAt = reason, now()
		end
		peer.status = peer.quests and "stale" or "waiting"
		peer.partialPending = nil
		watchPeer(key, peer)
		local eligible = math.max(peer.repairAfter or 0, targetable(peer) and 0 or (fallbackAt or 0))
		if not peer.repairPending and now() < eligible then
			local watch = peer.watch
			if not watch.repairScheduled then
				watch.repairScheduled = true
				local progress = peer.progress
				after(eligible - now(), function()
					watch.repairScheduled = nil
					if
						peers[key] == peer
						and peer.watch == watch
						and peer.progress == progress
						and peer.connected
						and inParty()
					then
						recover(key, peer, reason)
					end
				end)
			end
		elseif not peer.repairPending then
			peer.repairPending = true
			log("WARN", "sync", "Partial synchronization requires full snapshot", { sender = key, reason = reason })
			if not targetable(peer) then
				-- H also announces our own baseline; older readers rely on both sides refreshing.
				options.requestFull("partial_recovery")
			end
			options.scheduleSend()
		end
		notify("partial_recovery")
	end

	local function acceptSession(key, peer, remoteSession)
		if peer.deltaSession ~= remoteSession then
			peer.retiredSessions = peer.retiredSessions or {}
			if peer.retiredSessions[remoteSession] then
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
			peer.deltaSession = remoteSession
			peer.deltaSeen = now()
			peer.deltaProgressAt, peer.contactAt = nil, nil
			peer.fullOnly = nil
			peer.state, peer.partialPending, peer.pending, peer.revision = nil, nil, nil, nil
			peer.allowReset = true
			awaitingSnapshot(key, peer, true)
		end
		peer.capabilityAt = now()
		peer.detected = true
		return true
	end

	local function control(key, peer, body, minor)
		if not session then
			return false
		end
		local target = body:match("^R:([0-9a-f]+)$")
		if target and minor >= 3 and targeted and Sync.session(target) then
			if target == session then
				log("DEBUG", "sync", "Received targeted snapshot request", { sender = key })
				options.onTargetedRequest()
			end
			return true
		end
		local announcedSession = body:match("^C:([0-9a-f]+):q1$")
		if announcedSession and Sync.session(announcedSession) then
			local changed = peer.deltaSession ~= announcedSession
			if acceptSession(key, peer, announcedSession) then
				if changed and options.development then
					peer.debugRecoveryReason, peer.debugRecoveryAt = "session needs baseline", now()
				end
				peer.contactAt = now()
				if peer.silent then
					peer.silent = nil
					recover(key, peer, "state verification unavailable")
				end
				if peer.fullOnly then
					peer.deltaSeen = now()
				end
			end
			return true
		end
		local advertisedText = body:match("^V:(.+)$")
		if not advertisedText then
			return false
		end
		local advertised = Sync.identity(advertisedText)
		if not advertised then
			return true
		end
		if not acceptSession(key, peer, advertised.session) then
			return true
		end
		peer.deltaSeen = now()
		local wasSilent = peer.silent
		peer.silent = nil
		if not peer.state then
			if not peer.pending then
				recover(key, peer, "missing baseline")
			end
		elseif advertised.sequence == peer.state.sequence and advertised.digest ~= peer.state.digest then
			recover(key, peer, "state digest mismatch")
		elseif advertised.sequence > peer.state.sequence then
			local pendingSequence = math.max(
				peer.partialPending and peer.partialPending.serial or 0,
				peer.pending and peer.pending.serial or 0
			)
			if pendingSequence < advertised.sequence then
				recover(key, peer, "missed update")
			end
		elseif advertised.sequence == peer.state.sequence and not peer.pending and not peer.partialPending then
			if peer.explicitRefresh then
				if wasSilent then
					recover(key, peer, "explicit refresh pending")
				end
			elseif wasSilent or peer.status == "stale" then
				peer.status, peer.watch = nil, nil
				peer.repairPending, peer.repairAfter, peer.repairDelay = nil, nil, nil
				notify("heartbeat_confirmed")
			end
		end
		if wasSilent and (peer.pending or peer.partialPending) then
			watchPeer(key, peer)
		end
		return true
	end

	local function ignoreTransfer(peer, pending)
		if
			peer.state
			and peer.status == "updating"
			and pending.previousStatus == nil
			and not peer.pending
			and not peer.partialPending
		then
			peer.status, peer.watch = nil, nil
			notify("obsolete_transfer")
		end
	end

	local function startTimer()
		if not session or timer then
			return
		end
		local token = {}
		timer = token
		local function tick()
			if timer ~= token or not inParty() then
				return
			end
			for key, peer in pairs(peers) do
				if
					peer.connected
					and peer.deltaSession
					and peer.status ~= "oversized"
					and peer.status ~= "incompatible"
					and now() - math.max(peer.deltaSeen, peer.deltaProgressAt or 0) > 45
				then
					if now() - math.max(peer.deltaSeen, peer.deltaProgressAt or 0, peer.contactAt or 0) > 45 then
						silence(key, peer)
					else
						recover(key, peer, "state verification unavailable")
					end
				end
			end
			options.announce()
			after(15 + tonumber(session:sub(1, 2), 16) % 4, tick)
		end
		after(15 + tonumber(session:sub(1, 2), 16) % 4, tick)
	end

	function api.setRoster(nextMembers, connections, party)
		local nextPeers, nextKeys = {}, {}
		local changed = rosterInParty ~= party
		for _, member in ipairs(nextMembers) do
			local connected = connections[member.key]
			local peer = peers[member.key]
			changed = changed or not peer or peer.connected ~= connected
			peer = peer or {}
			if peer.connected ~= connected then
				peer.watch, peer.repairPending, peer.silent = nil, nil, nil
				peer.pending, peer.partialPending, peer.state, peer.deltaSession = nil, nil, nil, nil
				peer.status = peer.quests and "stale" or nil
			end
			peer.connected = connected
			nextPeers[member.key] = peer
			nextKeys[#nextKeys + 1] = member.key
		end
		for key, peer in pairs(peers) do
			if not nextPeers[key] then
				changed = true
				peer.watch = nil
			end
		end
		peers, members, rosterInParty = nextPeers, nextKeys, party
		return changed
	end

	function api.resetRecovery(party)
		for _, peer in pairs(peers) do
			peer.repairPending, peer.repairAfter, peer.repairDelay = nil, nil, nil
		end
		fallbackAt = nil
		if not party then
			timer = nil
		end
	end

	function api.expectFullSnapshots()
		startTimer()
		for key, peer in pairs(peers) do
			if peer.connected and peer.detected and peer.status ~= "incompatible" then
				peer.revision = nil
				peer.allowReset = true
				awaitingSnapshot(key, peer, true)
			end
		end
	end

	local function status(peer)
		return not peer.connected and "offline" or peer.status or (peer.quests and "healthy" or "unknown")
	end

	function api.view(key)
		local peer = peers[key]
		if peer then
			return { connected = peer.connected, status = status(peer), quests = peer.quests }
		end
	end

	function api.allSupportPartial()
		local found = false
		for _, peer in pairs(peers) do
			if peer.connected then
				if not peer.deltaSession or not peer.capabilityAt or now() - peer.capabilityAt > 45 then
					return false
				end
				found = true
			end
		end
		return found
	end

	function api.clearDiagnostics()
		for _, peer in pairs(peers) do
			peer.diagnosticPayload = nil
		end
	end

	local function assemblySummary(pending)
		return pending and { revision = pending.serial, received = pending.received, parts = pending.total }
	end

	function api.diagnostics(key)
		local peer = peers[key]
		if not peer then
			return nil
		end
		local currentTime = now()
		local function age(value)
			return value and math.max(0, currentTime - value)
		end
		local state = peer.state
		local count = 0
		for _ in pairs(peer.quests or {}) do
			count = count + 1
		end
		return {
			status = status(peer),
			questCount = peer.quests and count,
			connected = peer.connected,
			detected = peer.detected == true,
			protocol = peer.debugProtocol,
			messageAge = age(peer.debugMessageAt),
			hasSnapshot = peer.quests ~= nil,
			revision = peer.snapshotRevision,
			snapshotAge = age(peer.snapshotAt),
			session = peer.deltaSession,
			capabilityAge = age(peer.capabilityAt),
			state = state and { session = state.session, sequence = state.sequence, digest = state.digest },
			stateAge = age(peer.deltaSeen and math.max(peer.deltaSeen, peer.deltaProgressAt or 0)),
			fullOnly = peer.fullOnly,
			pending = assemblySummary(peer.pending),
			partialPending = assemblySummary(peer.partialPending),
			targetedRepair = targetable(peer) == true,
			repairPending = peer.repairPending == true,
			repairIn = peer.repairAfter and math.max(0, peer.repairAfter - currentTime),
			recoveryReason = peer.debugRecoveryReason,
			recoveryAge = age(peer.debugRecoveryAt),
		}
	end

	function api.receive(key, sender, message)
		local peer = key and peers[key]
		if not peer then
			log(
				"DEBUG",
				"sync",
				"Ignored addon message",
				{ sender = sender, key = key, reason = "sender not in roster" }
			)
			return
		end
		if #message > Codec.MAX_MESSAGE_BYTES then
			log("DEBUG", "sync", "Ignored addon message", { sender = key, reason = "message exceeds wire limit" })
			return
		end
		local version, body = message:match("^(%d+%.%d+):(.+)$")
		local major, minor = Codec.parseProtocolVersion(version)
		if options.development then
			peer.debugProtocol = major and version or "unversioned / malformed"
			peer.debugMessageAt = now()
		end
		if not major or major ~= Codec.PROTOCOL_MAJOR then
			peer.detected = true
			peer.status = "incompatible"
			peer.pending, peer.watch, peer.revision = nil, nil, nil
			peer.state, peer.partialPending, peer.deltaSession = nil, nil, nil
			peer.repairPending = nil
			peer.allowReset = true
			log("WARN", "sync", "Unsupported addon protocol", {
				sender = key,
				protocol = version or "unversioned",
				expected = localVersion,
			})
			notify("unsupported_protocol")
			return
		end
		if minor >= 2 and control(key, peer, body, minor) then
			return
		end
		if body == "X" then
			peer.detected = true
			peer.status = "oversized"
			peer.pending, peer.watch, peer.partialPending = nil, nil, nil
			peer.state, peer.repairPending = nil, nil
			notify("peer_snapshot_oversized")
			return
		end
		if body == "H" then
			peer.contactAt, peer.silent = now(), nil
			log("DEBUG", "sync", "Received snapshot request", { sender = key, protocol = version })
			-- Refresh requests allow revision counters to restart after reloads,
			-- without discarding the last snapshot or an assembly in progress.
			peer.revision = nil
			peer.allowReset = true
			if minor < 2 then
				peer.state, peer.deltaSession = nil, nil
			end
			if session then
				peer.capabilityAt = nil
				options.requireBaseline()
			end
			awaitingSnapshot(key, peer, true)
			notify("snapshot_requested")
			options.requestFull("snapshot_requested")
			return
		end
		local kind, serialText, partText, totalText, data = body:match("^([DP]):(%d+):(%d+):(%d+):(.+)$")
		if kind == "P" and (not session or minor < 2) then
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
			or total > Codec.MAX_PARTS
			or part < 1
			or part > total
			or #data > Codec.CHUNK_SIZE
		then
			log("DEBUG", "sync", "Ignored addon message", { sender = key, reason = "invalid chunk header" })
			return
		end
		if kind == "P" and peer.state and serial <= peer.state.sequence then
			return
		end
		if peer.revision and serial <= peer.revision then
			log(
				"DEBUG",
				"sync",
				"Ignored addon message",
				{ sender = key, reason = "stale revision", revision = serial }
			)
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
				startedAt = debugMode() and timestamp() or nil,
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
			recover(key, peer, "conflicting fragment")
			return
		end
		if not pending.parts[part] then
			pending.parts[part] = data
			pending.received = pending.received + 1
			peer.progress = (peer.progress or 0) + 1
			if session then
				peer.deltaProgressAt = now()
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
				local target = Sync.patchTarget(payload)
				if target and peer.retiredSessions and peer.retiredSessions[target.session] then
					ignoreTransfer(peer, pending)
					return
				end
				state = Sync.apply(peer.state, payload, pending.version, codec)
				if not state or state.sequence ~= serial or state.session ~= peer.deltaSession then
					recover(key, peer, "invalid partial update or base mismatch")
					return
				end
				quests = state.quests
			elseif session and minor >= 2 then
				state = Sync.readSnapshot(payload, pending.version, codec)
				if state then
					quests = state.quests
					if state.session then
						if state.sequence ~= serial then
							recover(key, peer, "snapshot identity revision mismatch")
							return
						end
						if not acceptSession(key, peer, state.session) then
							ignoreTransfer(peer, pending)
							return
						end
						if peer.state and state.sequence < peer.state.sequence then
							ignoreTransfer(peer, pending)
							return
						end
					else
						state = nil
						if peer.state and serial <= peer.state.sequence then
							ignoreTransfer(peer, pending)
							return
						end
					end
				end
			else
				quests = codec.decode(payload, pending.version)
			end
			if quests then
				local previous, previousContent = peer.quests, options.getContent()
				peer.state = state
				peer.fullOnly = peer.deltaSession and not state or nil
				if peer.deltaSession then
					peer.deltaSeen = now()
				end
				peer.revision = serial
				peer.quests = quests
				peer.snapshotAt = timestamp()
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
				options.logSnapshot("Received quest snapshot", diagnosticPayload, peer.diagnosticPayload, {
					kind = kind,
					sender = key,
					parts = total,
					protocol = pending.version,
					revision = serial,
					bytes = #payload,
					assemblyDuration = debugMode() and pending.startedAt and (now() - pending.startedAt) or nil,
				})
				if debugMode() then
					peer.diagnosticPayload = diagnosticPayload
				end
				options.onCommit(key, previous, quests, previousContent)
			else
				if peer.status ~= "stale" then
					peer.status = peer.quests and "refreshing" or "waiting"
				end
				if options.development then
					peer.debugRecoveryReason, peer.debugRecoveryAt = "invalid snapshot rejected", now()
				end
				log("WARN", "sync", "Rejected invalid quest snapshot", { sender = key })
				notify("snapshot_rejected")
			end
		else
			notify("snapshot_chunk_received")
		end
	end

	return api
end
