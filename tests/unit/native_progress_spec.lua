local TYPES = { QuestTitle = 17, QuestPlayer = 18, QuestObjective = 8 }
local function heading(guid)
	return { type = TYPES.QuestPlayer, guid = guid, leftText = "Same name" }
end
local function objective(label, have, need)
	return { type = TYPES.QuestObjective, leftText = label, numFulfilled = have, numRequired = need }
end
local function title(id, label)
	return { type = TYPES.QuestTitle, id = id, leftText = label or "Hunt" }
end
local function quest()
	return {
		title = "Hunt",
		state = "ready",
		mapID = 101,
		objectives = { { text = "Wolves slain", have = 8, need = 8 }, { text = "Paws", have = 6, need = 6 } },
	}
end

describe("Blizzard quest progress fallback", function()
	local env, native, templates, members, data, units, calls, onQuest
	before_each(function()
		data, units, calls, onQuest = {}, {}, {}, {}
		env = setmetatable({
			QuestWithFriends = {},
			Enum = { TooltipDataLineType = TYPES },
			UnitGUID = function(unit)
				return unit == "party1" and "guid-a" or "guid-b"
			end,
			issecretvalue = function()
				return false
			end,
			C_TooltipInfo = {
				GetQuestPartyProgress = function(id, omitTitle, ignorePlayer)
					assert.is_false(omitTitle)
					assert.is_true(ignorePlayer)
					calls[id] = (calls[id] or 0) + 1
					return data[id]
				end,
				GetUnit = function(unit)
					return units[unit]
				end,
			},
			C_QuestLog = {
				IsUnitOnQuest = function(unit, id)
					return onQuest[unit .. ":" .. id]
				end,
			},
		}, { __index = _G })
		env._G = env
		for _, path in ipairs({ "src/Core.lua", "src/NativeProgress.lua", "src/QuestIgnores.lua" }) do
			setfenv(assert(loadfile(path)), env)()
		end
		native = env.QuestWithFriends.NativeProgress.new()
		templates = { [42] = quest() }
		members = {
			{ key = "a", name = "Same name", unit = "party1", nativeEligible = true },
			{ key = "b", name = "Same name", unit = "party2", nativeEligible = true },
		}
	end)

	it("reads structured counters and attributes same-named members by GUID", function()
		data[42] = {
			lines = {
				title(42),
				heading("player"),
				objective("Wolves slain", 7, 8),
				heading("guid-a"),
				objective("Wolves slain: 3/8", 3, 8),
				heading("guid-b"),
				objective("8/8 Wolves slain", 8, 8),
			},
		}
		local result = native:collect(templates, members, 0)
		assert.are.equal(3, result.a[42].objectives[1].have)
		assert.are.equal(8, result.b[42].objectives[1].have)
		assert.are.equal(0, result.a[42].objectives[2].need)
		assert.is_true(result.a[42].stateUnknown)
		assert.is_nil(result.a[42].objectives[1].spare)
	end)

	it("matches objective text and targets rather than the order of visible rows", function()
		data[42] = { lines = { heading("guid-a"), objective("Paws", 2, 6), objective("Wolves slain", 4, 8) } }
		local result = native:collect(templates, members, 0).a[42]
		assert.are.equal(4, result.objectives[1].have)
		assert.are.equal(2, result.objectives[2].have)
		assert.are.equal(8, templates[42].objectives[1].have)
	end)

	it("refuses ambiguous, mismatched, missing and percentage counters", function()
		data[42] = {
			lines = {
				heading("guid-a"),
				objective("Wolves slain", 3, 8),
				objective("Wolves slain", 4, 8),
				objective("Paws", 2, 99),
				objective("Paws: 50%", 0, 1),
			},
		}
		local result = native:collect(templates, members, 0).a[42]
		assert.are.equal(0, result.objectives[1].need)
		assert.are.equal(0, result.objectives[2].need)
		templates[42].objectives[2] = templates[42].objectives[1]
		data[42].lines = { heading("guid-a"), objective("Wolves slain", 3, 8) }
		native:invalidate()
		result = native:collect(templates, members, 0).a[42]
		assert.are.equal(0, result.objectives[1].need)
		assert.are.equal(0, result.objectives[2].need)
	end)

	it("does not turn progress bars into synthetic binary counts", function()
		templates[42].objectives = { { text = "Area cleared", have = 1, need = 1 } }
		local bar = objective("Area cleared", 0, 1)
		bar.progressBarPercent = 50
		data[42] = { lines = { heading("guid-a"), bar } }
		onQuest["party1:42"] = true
		assert.are.equal(0, native:collect(templates, members, 0).a[42].objectives[1].need)
	end)

	it("keeps GUID ownership correct when party unit slots change", function()
		data[42] = {
			lines = {
				heading("guid-a"),
				objective("Wolves slain", 3, 8),
				heading("guid-b"),
				objective("Wolves slain", 6, 8),
			},
		}
		assert.are.equal(3, native:collect(templates, members, 0).a[42].objectives[1].have)
		members[1].unit, members[2].unit = "party2", "party1"
		local result = native:collect(templates, members, 1)
		assert.are.equal(6, result.a[42].objectives[1].have)
		assert.are.equal(3, result.b[42].objectives[1].have)
	end)

	it("keeps discovered quests while fresh party queries continue confirming them", function()
		units.target = { lines = { title(99), heading("guid-a"), objective("Wolves slain", 3, 8) } }
		data[99] = units.target
		native:observeUnit("target", 0)
		for now = 0, 20, 2 do
			assert.are.equal(3, native:collect({}, members, now).a[99].objectives[1].have)
		end
		data[99] = nil
		assert.is_nil(native:collect({}, members, 36).a[99])
	end)

	it("uses positive quest membership without inventing counts or interpreting false as missing", function()
		onQuest["party1:42"], onQuest["party2:42"] = true, false
		local result = native:collect(templates, members, 0)
		assert.is_not_nil(result.a[42])
		assert.are.equal(0, result.a[42].objectives[1].need)
		assert.is_nil(result.b[42])
	end)

	it("does not infer readiness even if every visible objective is complete", function()
		data[42] = { lines = { heading("guid-a"), objective("Wolves slain", 8, 8), objective("Paws", 6, 6) } }
		local result = native:collect(templates, members, 0)
		local groups, complete, notices = env.QuestWithFriends.Core.compare(templates, {
			{ name = "Friend", quests = result.a, partial = true },
		})
		assert.same({}, groups)
		assert.is_false(complete)
		assert.are.equal("native", notices[1].reason)
	end)

	it("shows known differences but never missing quests for gaps in partial snapshots", function()
		data[42] = { lines = { heading("guid-a"), objective("Wolves slain", 3, 8) } }
		local result = native:collect(templates, members, 0)
		templates[43] = quest()
		local groups, complete = env.QuestWithFriends.Core.compare(templates, {
			{ name = "Friend", quests = result.a, partial = true },
			{ name = "Other", quests = {}, partial = true },
		})
		assert.is_false(complete)
		assert.are.equal(1, #groups)
		assert.are.equal(42, groups[1].questID)
		assert.are.equal(1, #groups[1].differences)
		assert.are.equal(3, groups[1].differences[1].objective.have)
		assert.are.equal("objective", groups[1].differences[1].reason)
	end)

	it("keeps the existing objective visibility modes with partial data", function()
		data[42] = { lines = { heading("guid-a"), objective("Wolves slain", 3, 8) } }
		templates[42].state, templates[42].objectives[1].have = "active", 2
		local result = native:collect(templates, members, 0)
		local roster = { { name = "Friend", quests = result.a, partial = true } }
		assert.same({}, env.QuestWithFriends.Core.compare(templates, roster, nil, "self"))
		assert.same({}, env.QuestWithFriends.Core.compare(templates, roster, nil, "anyone"))
		local groups = env.QuestWithFriends.Core.compare(templates, roster, nil, "always")
		assert.are.equal(2, #groups[1].differences)
		assert.is_false(env.QuestWithFriends.Core.hasDifferences(groups))
	end)

	it("ignores secret containers, headers, GUIDs, text and counters without misattribution", function()
		local secret = setmetatable({}, {
			__index = function()
				error("secret accessed")
			end,
		})
		env.issecretvalue = function(value)
			return value == secret
		end
		data[42] = {
			lines = {
				heading("guid-a"),
				objective("Wolves slain", secret, 8),
				objective(secret, 2, 6),
				heading(secret),
				objective("Wolves slain", 4, 8),
				heading("guid-a"),
				secret,
				objective("Wolves slain", 5, 8),
				title(42),
				heading("guid-b"),
				objective("Wolves slain", 6, 8),
			},
		}
		local result = native:collect(templates, members, 0)
		assert.is_nil(result.a[42])
		assert.are.equal(6, result.b[42].objectives[1].have)
		data[42] = secret
		native:invalidate()
		assert.same({}, native:collect(templates, members, 0).b)
	end)

	it("tolerates missing APIs, absent data and API errors", function()
		env.C_TooltipInfo = {
			GetQuestPartyProgress = function()
				error("unavailable")
			end,
		}
		env.C_QuestLog.IsUnitOnQuest = function()
			error("unavailable")
		end
		assert.same({ a = {}, b = {} }, native:collect(templates, members, 0))
		env.C_TooltipInfo = {}
		assert.same({}, native:collect(templates, members, 0))
	end)

	it("caches party queries briefly and invalidates them on demand", function()
		native:collect(templates, members, 0)
		native:collect(templates, members, 1)
		assert.are.equal(1, calls[42])
		native:collect(templates, members, 2)
		assert.are.equal(2, calls[42])
		native:invalidate()
		native:collect(templates, members, 2)
		assert.are.equal(3, calls[42])
	end)

	it("discovers quests from unit tooltips, aligns partial rows and expires observations", function()
		units.target = {
			lines = {
				title(99, "Other hunt"),
				heading("guid-a"),
				objective("Wolves slain", 8, 8),
				heading("guid-b"),
				objective("Paws", 2, 6),
			},
		}
		assert.is_true(native:observeUnit("target", 0))
		local result = native:collect({}, members, 0)
		assert.are.equal("Other hunt", result.a[99].title)
		local byText = {}
		for index, row in ipairs(result.a[99].objectives) do
			byText[row.text] = { row, result.b[99].objectives[index] }
		end
		assert.are.equal(8, byText["Wolves slain"][1].have)
		assert.are.equal(0, byText["Wolves slain"][2].need)
		assert.are.equal(0, byText.Paws[1].need)
		assert.are.equal(2, byText.Paws[2].have)
		assert.same({ a = {}, b = {} }, native:collect({}, members, 15))
	end)

	it("prefers full quest queries to unit observations and never substitutes for addon snapshots", function()
		units.mouseover = { lines = { title(42), heading("guid-a"), objective("Wolves slain", 1, 8) } }
		native:observeUnit("mouseover", 0)
		data[42] = { lines = { heading("guid-a"), objective("Wolves slain", 5, 8) } }
		assert.are.equal(5, native:collect(templates, members, 0).a[42].objectives[1].have)
		members[1].nativeEligible = false
		assert.is_nil(native:collect(templates, members, 1).a)
		assert.is_nil(native.observed[42])
	end)

	it("does not settle the join baseline on partial data, but confirmed pickups undo ignores", function()
		local ignores = env.QuestWithFriends.QuestIgnores.new()
		ignores:roster({ a = true })
		ignores.saved.ignored[42] = { title = "Hunt", missing = { a = true } }
		ignores:observe({}, {}, templates, { { key = "a", quests = templates, partial = true } }, "me")
		assert.is_true(ignores.saved.pending.a)
		assert.is_nil(ignores.saved.ignored[42])
		ignores:observe({}, {}, templates, { { key = "a", quests = templates } }, "me")
		assert.is_nil(ignores.saved.pending.a)
	end)
end)
