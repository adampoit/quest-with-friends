local network = require("tests.support.sync_network")

local function sentState(client)
	local pending, state, latest = {}, nil, 0
	local Sync = client.env.QuestWithFriends.Sync
	for _, attempt in ipairs(client.attempts) do
		local kind, revision, part, total, data = attempt.message:match("^1%.%d+:([DP]):(%d+):(%d+):(%d+):(.+)$")
		if kind and attempt.result == 0 then
			local key = kind .. revision
			local assembly = pending[key] or { parts = {}, received = 0 }
			pending[key] = assembly
			part, total, revision = assert(tonumber(part)), assert(tonumber(total)), assert(tonumber(revision))
			if not assembly.parts[part] then
				assembly.parts[part] = data
				assembly.received = assembly.received + 1
			end
			if assembly.received == total and revision > latest then
				local payload = table.concat(assembly.parts)
				if kind == "D" then
					state = assert(Sync.readSnapshot(payload))
				else
					state = assert(Sync.apply(state, payload))
				end
				latest = revision
			end
		end
	end
	return assert(state).quests
end

local function transferCount(client)
	local count = 0
	for _, attempt in ipairs(client.attempts) do
		if attempt.message:match("^1%.%d+:[DP]:") then
			count = count + 1
		end
	end
	return count
end

for _, game in ipairs({ "retail", "forever" }) do
	describe("relevant completion synchronization on " .. game, function()
		for _, versions in ipairs({ { 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 }, { 3, 3, 3 }, { 3, 1, 2 } }) do
			it("converges and cleans up without echoing history with minors " .. table.concat(versions, "/"), function()
				local n = network(game, 3, versions, {
					instrument = function(c, env)
						env.C_QuestLog.IsQuestFlaggedCompleted = function(id)
							return c.history and c.history[id] == true or false
						end
					end,
				})
				local first, completed, third = unpack(n.clients)
				completed.history = { [42] = true, [999] = true }
				for _, c in ipairs(n.clients) do
					for id = 1, 15 do
						c.quests[id] = { title = "Shared quest " .. id, state = "active", objectives = {} }
					end
				end
				first.quests[42] = { title = "Errand", state = "active", objectives = {} }
				third.quests[42] = { title = "Errand", state = "ready", objectives = {} }
				n:join()
				n:advance(30)

				local snapshot = sentState(completed)
				assert.same({ title = "Errand", state = "completed", objectives = {} }, snapshot[42])
				assert.is_nil(snapshot[999])
				for _, c in ipairs(n.clients) do
					assert.is_true(c.view.complete)
					assert.are.equal(1, #c.view.groups)
					local found = false
					for _, difference in ipairs(c.view.groups[1].differences) do
						assert.is_not.equal("missing", difference.reason)
						found = found or difference.reason == "completed"
					end
					assert.is_true(found)
				end
				if versions[1] >= 2 and versions[2] >= 2 and versions[3] >= 2 then
					assert.is_true(completed:count("1." .. versions[2] .. ":P:") > 0)
				end

				local counts = {}
				for i, c in ipairs(n.clients) do
					counts[i] = transferCount(c)
				end
				n:advance(90)
				for i, c in ipairs(n.clients) do
					assert.are.equal(counts[i], transferCount(c))
				end

				first.quests[42], third.quests[42] = nil, nil
				first:fire("QUEST_REMOVED", 42)
				third:fire("QUEST_REMOVED", 42)
				n:advance(30)
				for _, c in ipairs(n.clients) do
					assert.is_nil(sentState(c)[42])
					assert.same({}, c.view.groups)
					assert.is_true(c.view.complete)
				end
			end)
		end

		it("keeps completion differences visible when the join offer automatically ignores missing quests", function()
			local n = network(game, 2, { 3, 3 }, {
				instrument = function(c, env)
					env.QuestWithFriends.db.joinQuestBehavior = "auto"
					env.C_QuestLog.IsQuestFlaggedCompleted = function(id)
						return c.history and c.history[id] == true or false
					end
				end,
			})
			n.clients[2].history = { [42] = true }
			n.clients[1].quests[42] = { title = "Completed earlier", state = "active", objectives = {} }
			n.clients[1].quests[43] = { title = "Unrelated quest", state = "active", objectives = {} }
			n:join()
			n:advance(20)
			for _, c in ipairs(n.clients) do
				assert.are.equal(1, #c.view.groups)
				local group = c.view.groups[1]
				assert.are.equal(42, group.questID)
				assert.is_nil(group.shareQuestID)
				local completed = false
				for _, difference in ipairs(group.differences) do
					assert.is_not.equal("missing", difference.reason)
					completed = completed or difference.reason == "completed"
				end
				assert.is_true(completed)
			end
		end)

		it("relearns historical completion after reload and retains it while the holder is offline", function()
			local n = network(game, 2, { 3, 3 }, {
				instrument = function(c, env)
					env.C_QuestLog.IsQuestFlaggedCompleted = function(id)
						return c.history and c.history[id] == true or false
					end
				end,
			})
			local holder, completed = unpack(n.clients)
			holder.quests[42] = { title = "Errand", state = "active", objectives = {} }
			completed.history = { [42] = true }
			n:join()
			n:advance(20)
			n:reload(2)
			n:advance(20)
			assert.are.equal("completed", sentState(completed)[42].state)
			assert.is_true(holder.view.complete)
			completed.offline[1] = true
			completed:fire("UNIT_CONNECTION", "party1")
			n:advance(10)
			assert.are.equal("completed", sentState(completed)[42].state)
			assert.is_false(completed.view.complete)
			assert.are.equal("offline", completed.view.notices[1].reason)
		end)
	end)
end
