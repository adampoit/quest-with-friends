describe("sync engine", function()
	local namespace = {}
	for _, name in ipairs({ "SnapshotCodec", "State", "Sender", "Peers", "Sync" }) do
		assert(loadfile("src/sync/" .. name .. ".lua"))("Sync test", namespace)
	end

	local function makeParty(leftMinor, rightMinor)
		local time, timers = 0, {}
		local function after(delay, fn)
			timers[#timers + 1] = { at = time + delay, run = fn }
		end
		local party = {}
		local function newClient(key, other, minor)
			local client = { quests = {}, messages = {} }
			for id = 1, 8 do
				client.quests[id] = {
					title = key .. "'s quest " .. id,
					state = "active",
					objectives = { { text = "Cloth", have = 1, need = 10, itemID = 2589, spare = 0 } },
				}
			end
			client.sync = namespace.Sync.new({
				minor = minor,
				session = string.rep(key, 32),
				now = function()
					return time
				end,
				after = after,
				getLocalQuests = function()
					return client.quests
				end,
				send = function(message)
					local kind = message:match(":([A-Z])")
					local rejected = client.reject == kind
					client.messages[#client.messages + 1] = { at = time, kind = kind, rejected = rejected }
					if rejected then
						client.reject = nil
						return false
					end
					if client.drop ~= kind then
						after(0, function()
							party[other].sync.receive(key, message)
						end)
					end
					return true
				end,
			})
			party[key] = client
			client.sync.setRoster({ { key = other } }, { [other] = true }, true, "join")
			return client
		end
		local function advance(seconds)
			local limit = time + seconds
			for _ = 1, 1000 do
				local first
				for i, timer in ipairs(timers) do
					if timer.at <= limit and (not first or timer.at < timers[first].at) then
						first = i
					end
				end
				if not first then
					time = limit
					return
				end
				local nextTimer = table.remove(timers, first)
				time = nextTimer.at
				nextTimer.run()
			end
			error("timer did not settle")
		end
		return newClient("a", "b", leftMinor), newClient("b", "a", rightMinor), advance
	end

	it("converges, retries a failed send, and repairs a lost update without a WoW runtime", function()
		local a, b, advance = makeParty(3, 3)
		advance(10)
		assert.same(a.quests, b.sync.peer("a").quests)
		assert.same(b.quests, a.sync.peer("b").quests)
		local view = b.sync.peer("a")
		view.status, view.quests = "offline", nil
		assert.equal("healthy", b.sync.peer("a").status)
		assert.is_not_nil(b.sync.peer("a").quests)
		assert.is_nil(view.pending)

		a.messages, a.reject = {}, "P"
		a.quests[1].objectives[1].have = 2
		a.sync.localChanged("quest")
		advance(0.5)
		assert.is_true(a.messages[1].rejected)
		assert.equal(1, b.sync.peer("a").quests[1].objectives[1].have)
		advance(2)
		assert.equal("P", a.messages[2].kind)
		assert.equal(1, a.messages[2].at - a.messages[1].at)
		assert.equal(2, b.sync.peer("a").quests[1].objectives[1].have)

		a.drop, b.messages = "P", {}
		a.quests[1].objectives[1].have = 3
		a.sync.localChanged("quest")
		advance(1)
		assert.equal(2, b.sync.peer("a").quests[1].objectives[1].have)
		advance(45)
		local repairs = 0
		for _, message in ipairs(b.messages) do
			if message.kind == "R" then
				repairs = repairs + 1
			end
		end
		assert.equal(1, repairs)
		assert.equal("healthy", b.sync.peer("a").status)
		assert.same(a.quests, b.sync.peer("a").quests)
	end)

	it("uses independent protocol settings for modern and legacy engines in one namespace", function()
		local a, b, advance = makeParty(3, 0)
		advance(10)
		assert.is_true(a.sync.diagnostics().partialEnabled)
		assert.is_false(b.sync.diagnostics().partialEnabled)
		assert.equal("healthy", a.sync.peer("b").status)
		assert.equal("healthy", b.sync.peer("a").status)
		assert.is_nil(a.sync.peer("b").quests[1].objectives[1].itemID)
		assert.is_nil(b.sync.peer("a").quests[1].objectives[1].itemID)
		a.messages = {}
		a.quests[1].objectives[1].have = 2
		a.sync.localChanged("quest")
		advance(5)
		assert.equal("D", a.messages[1].kind)
		assert.equal(2, b.sync.peer("a").quests[1].objectives[1].have)
	end)
end)
