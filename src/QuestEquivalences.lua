local _, QWF = ...
QWF = QWF or QuestWithFriends or {}
if QWF.disabled then
	return
end
QuestWithFriends = QWF

-- Generated from local source and explicit reviews; do not edit groups by hand.
-- Source: att c269971e856a1da16883cc94cba33d2ec5a90b02; game: retail
-- Snapshot SHA256: eea2369fd97d7f9d546916b987bfbc74defcecf3d6ff40b24b2e39b717f66180
local groups = {
	-- Beating Them Back!
	-- ATT branch review; turn-ins unknown; not live-client verified.
	{ 28757, 28762, 28763, 28764, 28765, 28766, 28767, 29078, 31139, progress = "objectives", history = true },
	-- Lions for Lambs
	-- ATT branch review; turn-ins unknown; not live-client verified.
	{ 28759, 28769, 28770, 28771, 28772, 28773, 28774, 29079, 31140, progress = "objectives", history = true },
	-- Join the Battle!
	-- ATT branch review; turn-ins unknown; not live-client verified.
	{ 28780, 28784, 28785, 28786, 28787, 28788, 28789, 29080, 31143, progress = "state", history = true },
	-- They Sent Assassins
	-- ATT branch review; turn-ins unknown; not live-client verified.
	{ 28791, 28792, 28793, 28794, 28795, 28796, 28797, 29081, 31144, progress = "objectives", history = true },
	-- Fear No Evil
	-- ATT branch review; turn-ins unknown; not live-client verified.
	{ 28806, 28808, 28809, 28810, 28811, 28812, 28813, 29082, 63447, progress = "objectives", history = true },
	-- The Rear is Clear
	-- ATT branch review; turn-ins unknown; not live-client verified.
	{ 28817, 28818, 28819, 28820, 28821, 28822, 28823, 29083, 31145, progress = "state", history = true },
}

QWF.QuestEquivalencesGame = "retail"
QWF.QuestEquivalences = {}
for _, ids in ipairs(groups) do
	for _, id in ipairs(ids) do
		assert(not QWF.QuestEquivalences[id], "Duplicate quest equivalence: " .. id)
		QWF.QuestEquivalences[id] = ids
	end
end
