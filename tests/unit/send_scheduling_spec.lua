local network = require("tests.support.sync_network")

for _, game in ipairs({ "retail", "forever" }) do
	for _, minor in ipairs({ 1, 2 }) do
		describe("bounded send scheduling on " .. game .. " protocol 1." .. minor, function()
			local function ready()
				local n = network(game, 2, { minor, minor })
				local a, b = unpack(n.clients)
				a.quests[42] = { title = "Initial", state = "active", objectives = {} }
				n:join()
				n:advance(8)
				a.attempts = {}
				return n, a, b
			end
			local function change(c, title)
				c.quests[42].title = title
				c:fire("QUEST_LOG_UPDATE")
			end
			local function paced(c)
				for i = 2, #c.attempts do
					assert.is_true(c.attempts[i].time - c.attempts[i - 1].time >= 0.5 - 0.000001)
				end
			end

			it("sends after a fixed 200 ms window without adding an idle pacing delay", function()
				local n, a, b = ready()
				local start = n.time
				change(a, "First")
				n:advance(0.1)
				change(a, "Latest in window")
				n:advance(0.09)
				assert.equal(0, #a.attempts)
				n:advance(0.02)
				assert.equal(1, #a.attempts)
				assert.is_true(math.abs(a.attempts[1].time - start - 0.2) < 0.000001)
				assert.equal("Latest in window", b.view.groups[1].title)
			end)

			it("refreshes stale unsent data at the existing eligible send slot", function()
				local n, a, b = ready()
				local start = n.time
				change(a, "First")
				n:advance(0.21)
				change(a, "Queued")
				n:advance(0.39)
				change(a, "Latest before slot")
				n:advance(0.11)
				assert.equal(2, #a.attempts)
				assert.is_true(math.abs(a.attempts[2].time - start - 0.7) < 0.000001)
				assert.equal("Latest before slot", b.view.groups[1].title)
				n:advance(1)
				assert.equal(2, #a.attempts)
				paced(a)
			end)

			it("makes progress while events arrive faster than both batching and pacing", function()
				local n, a, b = ready()
				local beforePause
				for i = 1, 60 do
					change(a, "Continuous " .. i)
					n:advance(0.05)
					if i == 50 then
						beforePause = #a.attempts
					end
				end
				assert.is_true(beforePause >= 4)
				assert.is_true(#a.attempts <= 7)
				n:advance(1)
				assert.equal("Continuous 60", b.view.groups[1].title)
				paced(a)
			end)

			it("does not let new events bypass exponential retry backoff", function()
				local n, a, b = ready()
				a.sendResult = function()
					return #a.attempts < 2 and 5 or 0
				end
				for i = 1, 70 do
					change(a, "Retry latest " .. i)
					n:advance(0.05)
				end
				n:advance(2)
				assert.equal(5, a.attempts[1].result)
				assert.equal(5, a.attempts[2].result)
				assert.equal(0, a.attempts[3].result)
				assert.is_true(math.abs(a.attempts[2].time - a.attempts[1].time - 1) < 0.000001)
				assert.is_true(math.abs(a.attempts[3].time - a.attempts[2].time - 2) < 0.000001)
				assert.equal("Retry latest 70", b.view.groups[1].title)
				paced(a)
			end)

			it("does not latch the pump guard after an unexpected preparation error", function()
				local n, a, b = ready()
				change(a, "First")
				n:advance(0.21)
				change(a, "Queued")
				n:advance(0.25)
				local core = a.env.QuestWithFriends.Core
				local encode = core.encode
				core.encode = function()
					error("injected encoding failure", 0)
				end
				assert.has_error(function()
					n:advance(0.25)
				end, "injected encoding failure")
				core.encode = encode
				change(a, "Recovered")
				n:advance(0.3)
				assert.equal("Recovered", b.view.groups[1].title)
				paced(a)
			end)

			it("shares the pacing budget between data and refresh control messages", function()
				local n, a = ready()
				change(a, "Before refresh")
				n:advance(0.21)
				assert.equal(1, #a.attempts)
				a.env.SlashCmdList.QUESTWITHFRIENDS("")
				n:advance(0.48)
				assert.equal(1, #a.attempts)
				n:advance(0.02)
				assert.equal(2, #a.attempts)
				assert.is_truthy(a.attempts[2].message:match(":H$"))
				n:advance(3)
				paced(a)
			end)
		end)
	end
end
