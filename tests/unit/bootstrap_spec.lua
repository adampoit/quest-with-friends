describe("Quest With Friends installation identity", function()
	local function environment()
		local notices = {}
		local env = setmetatable({
			QuestWithFriends = false,
			print = function(message)
				notices[#notices + 1] = message
			end,
		}, { __index = _G })
		env._G = env
		return env, notices
	end

	local function load(env, file, name, namespace)
		setfenv(assert(loadfile(file)), env)(name, namespace)
	end

	it("does not start beside an older release without bootstrap identity", function()
		local env, notices = environment()
		local release = { Core = {} }
		env.QuestWithFriends = release
		local dev = {}
		load(env, "src/Bootstrap.lua", "QuestWithFriendsDev", dev)
		assert.is_true(dev.disabled)
		assert.are.equal(release, env.QuestWithFriends)
		assert.are.equal(1, #notices)
	end)

	for _, name in ipairs({ "QuestWithFriends", "QuestWithFriendsDev" }) do
		it("sets explicit identity and asset paths for " .. name, function()
			local env = environment()
			local namespace = {}
			load(env, "src/Bootstrap.lua", name, namespace)
			assert.are.equal(namespace, env.QuestWithFriends)
			assert.are.equal(name, namespace.name)
			assert.are.equal(name .. "DB", namespace.savedVariables)
			assert.are.equal("Interface\\AddOns\\" .. name .. "\\Media\\", namespace.assetPath)
			assert.are.equal(name == "QuestWithFriendsDev", namespace.isDevelopment)
		end)

		it("leaves the first copy untouched when " .. name .. " loads second", function()
			local env, notices = environment()
			local firstName = name == "QuestWithFriends" and "QuestWithFriendsDev" or "QuestWithFriends"
			local first, second = {}, {}
			load(env, "src/Bootstrap.lua", firstName, first)
			load(env, "src/QuestEquivalences.lua", firstName, first)
			load(env, "src/Client.lua", firstName, first)
			load(env, "src/QuestCategories.lua", firstName, first)
			load(env, "src/Core.lua", firstName, first)
			load(env, "src/Preview.lua", firstName, first)
			local core, preview, equivalences, categories =
				first.Core, first.Preview, first.QuestEquivalences, first.QuestCategories
			load(env, "src/Bootstrap.lua", name, second)
			for _, file in ipairs({
				"src/QuestEquivalences.lua",
				"src/Client.lua",
				"src/QuestCategories.lua",
				"src/Core.lua",
				"src/ItemStock.lua",
				"src/Preview.lua",
				"dev/Development.lua",
				"src/QuestWithFriends.lua",
				"src/Panel.lua",
				"dev/InGameTests.lua",
			}) do
				load(env, file, name, second)
			end
			assert.is_true(second.disabled)
			assert.are.equal(first, env.QuestWithFriends)
			assert.are.equal(core, first.Core)
			assert.are.equal(preview, first.Preview)
			assert.are.equal(equivalences, first.QuestEquivalences)
			assert.are.equal(categories, first.QuestCategories)
			assert.is_nil(first.Panel)
			assert.is_nil(first.Development)
			assert.are.equal(1, #notices)
			assert.is_truthy(notices[1]:find(firstName, 1, true))
		end)
	end
end)
