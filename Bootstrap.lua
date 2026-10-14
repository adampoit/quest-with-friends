local addonName, QWF = ...
addonName = addonName or "QuestWithFriends"
QWF = QWF or {}

-- Only one installation may own the shared UI, commands and transport per session.
if QuestWithFriends then
	QWF.disabled = true
	print(
		addonName
			.. ": Not started because "
			.. (QuestWithFriends.name or "QuestWithFriends")
			.. " is already active. Enable only one copy, then reload."
	)
	return
end

QuestWithFriends = QWF
QWF.name = addonName
QWF.isDevelopment = addonName == "QuestWithFriendsDev"
QWF.title = QWF.isDevelopment and "Quest With Friends (Dev)" or "Quest With Friends"
QWF.savedVariables = QWF.isDevelopment and "QuestWithFriendsDevDB" or "QuestWithFriendsDB"
QWF.assetPath = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
