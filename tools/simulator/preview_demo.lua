A_Admin.SetPartySize(0)
SlashCmdList.QUESTWITHFRIENDS("preview on")
local panel = QuestWithFriendsPanel
assert(panel:IsShown(), "Appearance preview did not show the panel")
assert(panel.status:GetText() == "Preview · Sample party data", "Appearance preview did not start")
panel:ClearAllPoints()
panel:SetScale(1.5)
panel:SetPoint("CENTER", UIParent, "CENTER")
