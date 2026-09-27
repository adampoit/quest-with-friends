local function quest(title, have)
	return {
		title = title,
		state = "active",
		objectives = { { text = "Gnolls slain", have = have or 0, need = 8 } },
	}
end

local groups, complete, notices = QuestWithFriends.Core.compare({
	[42] = quest("The Lost Supplies"),
	[43] = quest("Gnoll Hunt", 8),
	[44] = { title = "The Missing Scout", state = "active", objectives = {} },
}, {
	{
		name = "Julia",
		quests = {
			[43] = quest("Gnoll Hunt", 5),
			[44] = { title = "The Missing Scout", state = "ready", objectives = {} },
		},
	},
	{
		name = "Bob",
		quests = {
			[43] = quest("Gnoll Hunt", 3),
			[44] = { title = "The Missing Scout", state = "active", objectives = {} },
		},
	},
	{ name = "Charlie" },
})
local zoneFilter, professions, classes = true, false, false
local function show()
	QuestWithFriends.Panel.show(
		groups,
		complete,
		zoneFilter,
		function()
			zoneFilter = not zoneFilter
			show()
		end,
		function(id)
			print("Preview: share clicked for quest " .. id .. " (not sent).")
		end,
		notices,
		{
			professions = professions,
			classes = classes,
			toggleProfessions = function()
				professions = not professions
				show()
			end,
			toggleClasses = function()
				classes = not classes
				show()
			end,
		}
	)
end
show()

local panel = QuestWithFriendsPanel
panel:ClearAllPoints()
panel:SetScale(2)
panel:SetPoint("CENTER", UIParent, "CENTER")

local foundShare = false
for _, child in ipairs({ panel:GetChildren() }) do
	if child:GetObjectType() == "Button" and child:GetText() == "Share" and child:IsShown() then
		foundShare = true
	end
end
assert(foundShare, "Share demo did not create a visible Share button")
