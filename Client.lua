local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
local interfaceVersion = GetBuildInfo and select(4, GetBuildInfo())
local isForever = type(interfaceVersion) == "number" and interfaceVersion >= 16000 and interfaceVersion < 20000
local game = isForever and "forever" or "retail"

-- Legacy tables without explicit game metadata default to Retail.
-- Quest IDs shared by the two games do not imply equivalent quest families.
if (QWF.QuestEquivalencesGame or "retail") ~= game then
	QWF.QuestEquivalences = {}
end
QWF.QuestEquivalencesGame = game
