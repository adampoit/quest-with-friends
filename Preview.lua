local QWF = QuestWithFriends
QWF.Preview = {}
QWF.Preview.activity = { [-1] = 3, [-2] = 2, [-3] = 1 }

local function quest(title, state, objective, category, mapID)
	return {
		title = title,
		state = state,
		objectives = objective and { objective } or {},
		category = category,
		mapID = mapID or 1,
	}
end

-- Negative IDs keep sample quests separate from real quests and saved collapse choices.
local mine = {
	[-1] = quest("The Lost Supplies", "active"),
	[-2] = quest("Gnoll Hunt", "active", { text = "Gnolls slain", have = 8, need = 8 }),
	[-3] = quest("The Missing Scout", "active"),
	[-4] = quest("A Bridge to Safety", "completed"),
	[-5] = quest("Fresh Fish for the Camp", "active", nil, "profession"),
	[-6] = quest("A Lesson in Courage", "active", nil, "class"),
}
local members = {
	{
		name = "Alex",
		quests = {
			[-2] = quest("Gnoll Hunt", "active", { text = "Gnolls slain", have = 5, need = 8 }),
			[-3] = quest("The Missing Scout", "ready"),
			[-4] = quest("A Bridge to Safety", "active"),
			[-7] = quest("Delivery to the Next Town", "active", nil, nil, 2),
		},
	},
	{
		name = "Sam",
		quests = {
			[-2] = mine[-2],
			[-3] = mine[-3],
			[-4] = mine[-4],
			[-7] = quest("Delivery to the Next Town", "active", nil, nil, 2),
		},
	},
}

function QWF.Preview.compare(zoneFilter, professions, classes)
	local groups, complete, notices = QWF.Core.compare(mine, members, zoneFilter and 1 or nil)
	local visible = {}
	for _, group in ipairs(groups) do
		local category = mine[group.questID] and mine[group.questID].category
		if (category ~= "profession" or professions) and (category ~= "class" or classes) then
			visible[#visible + 1] = group
		end
	end
	return visible, complete, notices
end
