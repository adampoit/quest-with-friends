-- Synthetic family for policy tests; never loaded by the addon TOC.
local QWF = QuestWithFriends
local ids = { 71001, 71002, 71003 }
QWF.QuestEquivalencesGame = "retail"
QWF.QuestEquivalences = {}
for _, id in ipairs(ids) do
	QWF.QuestEquivalences[id] = ids
end
