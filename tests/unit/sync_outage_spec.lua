local network = require("tests.support.sync_network")
local outage = require("tests.support.sync_outage")

local function phase(result, name)
	for _, entry in ipairs(result.phases) do
		if entry.name == name then
			return entry
		end
	end
	error("missing phase: " .. name)
end

local function total(result, phaseName, field, clients)
	local count = 0
	for i = 1, clients or 4 do
		count = count + phase(result, phaseName).clients[i][field]
	end
	return count
end

describe("four-player Forever outage reproduction", function()
	local results = {}
	setup(function()
		for _, variant in ipairs({ "disconnect", "throttle", "combined" }) do
			results[variant] = outage.run(variant)
		end
	end)
	for _, variant in ipairs({ "disconnect", "throttle", "combined" }) do
		it("converges and returns to partial updates after " .. variant, function()
			local result = results[variant]
			assert.is_true(result.converged)
			assert.is_true(result.idleCurrent)
			assert.is_true(result.cachedWhileSilent)
			assert.are.equal(variant ~= "throttle", result.staleWhileSilent)
			assert.are.equal(variant ~= "throttle", result.offlineWhileOffline)
			for _, parts in ipairs(result.baselineParts) do
				assert.is_true(parts >= 10 and parts <= 15)
			end
			assert.is_true(total(result, "update", "partial") > 0)
			assert.are.equal(0, total(result, "update", "full"))
			for _, field in ipairs({ "full", "partial", "requests", "repairs", "rejected", "refreshing", "timeouts" }) do
				assert.are.equal(0, total(result, "idle", field))
			end
			for _, field in ipairs({ "full", "unchanged", "requests", "repairs", "refreshing", "timeouts" }) do
				assert.are.equal(0, total(result, "silent", field))
			end
			assert.are.equal(variant ~= "disconnect", total(result, "silent", "rejected") > 0)
		end)
	end

	it("bounds reconnect traffic even when throttled", function()
		for _, result in pairs(results) do
			assert.is_true(total(result, "reconnect", "full") <= 8)
			assert.is_true(total(result, "reconnect", "requests") <= 8)
			assert.is_true(result.convergenceSeconds <= 60)
		end
	end)

	it("repeats deterministically", function()
		assert.same(results.combined, outage.run("combined"))
	end)
end)

for _, game in ipairs({ "retail", "forever" }) do
	describe("sync network reload on " .. game, function()
		it("starts a fresh session and cancels old timers while preserving client inputs and history", function()
			local n = network(game, 2, { 2, 2 })
			local c = n.clients[1]
			c.quests[42] = { title = "Kept errand", state = "active", objectives = {} }
			n:join()
			n:advance(5)
			local oldEnv, saved, attempts = c.env, c.env.QuestWithFriendsDB, #c.attempts
			local oldSession
			for _, attempt in ipairs(c.attempts) do
				oldSession = attempt.message:match("^1%.2:C:([0-9a-f]+):q1$") or oldSession
			end
			local fired = false
			oldEnv.C_Timer.After(1, function()
				fired = true
			end)
			assert.are.equal(c, n:reload(1))
			assert.is_not.equal(oldEnv, c.env)
			assert.are.equal(saved, c.env.QuestWithFriendsDB)
			assert.are.equal("Kept errand", c.quests[42].title)
			n:advance(90)
			assert.is_false(fired)
			assert.is_true(c.view.complete)
			assert.is_true(n.clients[2].view.complete)
			local newSession
			for i = attempts + 1, #c.attempts do
				local session = c.attempts[i].message:match("^1%.2:C:([0-9a-f]+):q1$")
				if session then
					assert.is_not.equal(oldSession, session)
					newSession = session
				end
			end
			assert.is_not_nil(newSession)
			assert.are.equal(2, c.incarnation)
		end)
	end)
end
