local _, QWF = ...
QWF = QWF or QuestWithFriends
if QWF.disabled then
	return
end
QWF.ItemStock = {}

function QWF.ItemStock.annotate(objectives, completedObjectives, diagnose)
	completedObjectives = completedObjectives or {}
	for _, objective in ipairs(objectives) do
		objective.itemID, objective.spare = nil, nil
	end
	local retainedIDs = {}
	for _, objective in ipairs(completedObjectives) do
		retainedIDs[objective] = objective.itemID
		objective.itemID, objective.spare = nil, nil
	end
	if #objectives == 0 and #completedObjectives == 0 then
		return
	end
	local function unavailable(reason)
		if diagnose then
			for _, list in ipairs({ objectives, completedObjectives }) do
				for _, objective in ipairs(list) do
					diagnose(objective, { result = reason, retainedItemID = retainedIDs[objective] })
				end
			end
		end
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
		unavailable("inventory_api_unavailable")
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
					unavailable("unnamed_bag_item")
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
				if diagnose then
					local function count(key, condition)
						stock[key] = (stock[key] or 0) + (condition and info.stackCount or 0)
					end
					count("uncachedBinding", binding == nil)
					count("restrictedBinding", binding ~= nil and binding ~= 0)
					count("bound", info.isBound == true)
					count("locked", info.isLocked == true)
					count("unknownFlags", info.isBound == nil or info.isLocked == nil)
				end
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
	local function annotate(objective, retainedID)
		local stock = byName[objective.text]
		-- Turned-in requirements no longer reserve stock; only reuse an already verified identity.
		local agrees = stock
			and (
				retainedID and retainedID == stock.itemID
				or not retainedID
					and math.min(objective.have, objective.need) == math.min(stock.total, objective.need)
			)
		local result
		if not stock then
			result = "no_exact_name_match"
		elseif stock.ambiguous then
			result = "ambiguous_item_name"
		elseif objective.need <= 0 then
			result = "non_counted_objective"
		elseif stock.available <= 0 then
			result = "no_tradeable_stock"
		elseif not agrees then
			result = retainedID and "retained_identity_mismatch" or "progress_stock_mismatch"
		else
			objective.itemID = stock.itemID
			objective.spare = math.max(0, stock.available - stock.reserved)
			result = "matched"
		end
		if diagnose then
			diagnose(objective, {
				result = result,
				retainedItemID = retainedID,
				candidateItemID = stock and stock.itemID,
				total = stock and stock.total,
				available = stock and stock.available,
				reserved = stock and stock.reserved,
				uncachedBinding = stock and stock.uncachedBinding,
				restrictedBinding = stock and stock.restrictedBinding,
				bound = stock and stock.bound,
				locked = stock and stock.locked,
				unknownFlags = stock and stock.unknownFlags,
				itemID = objective.itemID,
				spare = objective.spare,
			})
		end
	end
	for _, objective in ipairs(objectives) do
		annotate(objective)
	end
	for _, objective in ipairs(completedObjectives) do
		if retainedIDs[objective] then
			annotate(objective, retainedIDs[objective])
		end
	end
end
