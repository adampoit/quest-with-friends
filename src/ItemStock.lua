local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
QWF.ItemStock = {}

function QWF.ItemStock.annotate(objectives)
	if #objectives == 0 then
		return
	end
	local containers, items = _G.C_Container, _G.C_Item
	local lastBag = _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS or _G.NUM_BAG_SLOTS
	if
		not containers
		or not containers.GetContainerNumSlots
		or not containers.GetContainerItemInfo
		or not items
		or not items.GetItemInfo
		or type(lastBag) ~= "number"
	then
		return
	end
	local byName = {}
	for bag = 0, lastBag do
		for slot = 1, containers.GetContainerNumSlots(bag) do
			local info = containers.GetContainerItemInfo(bag, slot)
			if info then
				local name, _, _, _, _, _, _, _, _, _, _, _, _, binding = items.GetItemInfo(info.itemID)
				name = name or info.itemName
				-- An unnamed occupied slot could conceal a duplicate localized name.
				if not name or name == "" then
					return
				end
				local stock = byName[name]
				if not stock then
					stock = { itemID = info.itemID, total = 0, available = 0, reserved = 0 }
					byName[name] = stock
				elseif stock.itemID ~= info.itemID then
					stock.ambiguous = true
				end
				stock.total = stock.total + info.stackCount
				-- Restrict this feature to never-binding items; no soulbound loot exceptions.
				if binding == 0 and info.isBound == false and info.isLocked == false then
					stock.available = stock.available + info.stackCount
				end
			end
		end
	end
	for _, objective in ipairs(objectives) do
		local stock = byName[objective.text]
		if stock then
			stock.reserved = stock.reserved + objective.need
		end
	end
	for _, objective in ipairs(objectives) do
		local stock = byName[objective.text]
		-- Exact names and agreeing counts only; never fuzzy-match objective descriptions.
		if
			stock
			and not stock.ambiguous
			and stock.available > 0
			and objective.need > 0
			and math.min(objective.have, objective.need) == math.min(stock.total, objective.need)
		then
			objective.itemID = stock.itemID
			objective.spare = math.max(0, stock.available - stock.reserved)
		end
	end
end
