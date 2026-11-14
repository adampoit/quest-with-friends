describe("Quest With Friends development diagnostics", function()
	local env, namespace, frames, providerCalls, data, development

	local function widget(parent)
		local w = { parent = parent, shown = true, fonts = {}, scripts = {} }
		for _, method in ipairs({
			"SetPoint",
			"SetFrameStrata",
			"SetClampedToScreen",
			"SetMovable",
			"EnableMouse",
			"RegisterForDrag",
			"SetResizable",
			"SetResizeBounds",
			"SetJustifyH",
			"SetJustifyV",
			"SetWordWrap",
			"SetNormalTexture",
			"SetHighlightTexture",
			"SetPushedTexture",
		}) do
			w[method] = function() end
		end
		function w:SetScript(event, callback)
			self.scripts[event] = callback
		end
		function w:SetSize(width, height)
			self.width, self.height = width, height
			if self.scripts.OnSizeChanged then
				self.scripts.OnSizeChanged(self)
			end
		end
		function w:SetWidth(width)
			self.width = width
		end
		function w:SetHeight(height)
			self.height = height
		end
		function w:GetWidth()
			return self.width or 640
		end
		function w:GetHeight()
			return self.height or self.parent:GetHeight() - 92
		end
		function w:SetText(value)
			self.text = value
		end
		function w:GetStringHeight()
			return #self.text / (self.width or 640) * 16 + 400
		end
		function w:CreateFontString()
			local font = widget(self)
			self.fonts[#self.fonts + 1] = font
			return font
		end
		function w:SetScrollChild(child)
			self.child = child
		end
		function w:SetVerticalScroll(value)
			self.scroll = value
		end
		function w:GetVerticalScroll()
			return self.scroll or 0
		end
		function w:IsShown()
			return self.shown
		end
		function w:Hide()
			local shown = self.shown
			self.shown = false
			if shown and self.scripts.OnHide then
				self.scripts.OnHide(self)
			end
		end
		function w:SetShown(shown)
			if not shown then
				self:Hide()
			elseif not self.shown then
				self.shown = true
				if self.scripts.OnShow then
					self.scripts.OnShow(self)
				end
			end
		end
		function w:StartMoving()
			self.moving = true
		end
		function w:StartSizing(corner)
			self.sizing = corner
		end
		function w:StopMovingOrSizing()
			self.moving, self.sizing = false, nil
		end
		return w
	end

	before_each(function()
		frames, providerCalls = {}, 0
		namespace = { name = "QuestWithFriendsDev", isDevelopment = true }
		env = setmetatable({ UISpecialFrames = {}, UIParent = widget() }, { __index = _G })
		env._G = env
		env.CreateFrame = function(kind, name, parent, template)
			local frame = widget(parent)
			frame.kind, frame.name, frame.template = kind, name, template
			if template == "BasicFrameTemplateWithInset" then
				frame.TitleText = widget(frame)
			end
			frames[#frames + 1] = frame
			return frame
		end
		setfenv(assert(loadfile("dev/Development.lua")), env)("QuestWithFriendsDev", namespace)
		data = {
			protocol = "1.2",
			game = "Retail",
			view = "live",
			nextSendIn = 0,
			partialEnabled = true,
			baselineNeeded = false,
			published = {},
			peers = {},
		}
		development = namespace.Development.new(function() end, function()
			return false
		end, function()
			providerCalls = providerCalls + 1
			return data
		end)
	end)

	local function contains(report, value)
		assert.is_not_nil(report:find(value, 1, true))
	end

	it("loads no tools for release or disabled installations", function()
		for _, options in ipairs({ { isDevelopment = false }, { isDevelopment = true, disabled = true } }) do
			setfenv(assert(loadfile("dev/Development.lua")), env)("QuestWithFriends", options)
			assert.is_nil(options.Development)
		end
	end)

	it("creates a separate window lazily, reuses it, and supports on/off commands", function()
		assert.same({}, frames)
		assert.is_true(development.command("dev off"))
		assert.same({}, frames)
		assert.are.equal(0, providerCalls)
		assert.is_true(development.command("dev"))
		local window, count = frames[1], #frames
		assert.are.equal("QuestWithFriendsDevDiagnostics", window.name)
		assert.are.equal("BasicFrameTemplateWithInset", window.template)
		assert.same({ window.name }, env.UISpecialFrames)
		assert.is_true(window:IsShown())
		assert.are.equal(1, providerCalls)
		assert.is_true(development.command("dev on"))
		assert.is_true(window:IsShown())
		assert.are.equal(count, #frames)
		assert.is_true(development.command("dev"))
		assert.is_false(window:IsShown())
		assert.is_true(development.command("dev on"))
		assert.is_true(window:IsShown())
		assert.are.equal(2, providerCalls)
		assert.is_true(development.command("dev off"))
		assert.is_false(window:IsShown())
		assert.is_false(development.command("unrelated"))
	end)

	it("updates twice a second while visible and immediately on reopening", function()
		development.command("dev on")
		local window, report = frames[1], frames[3].fonts[1]
		window.scripts.OnUpdate(window, 0.3)
		assert.are.equal(1, providerCalls)
		data.protocol = "1.7"
		window.scripts.OnUpdate(window, 0.2)
		assert.are.equal(2, providerCalls)
		contains(report.text, "Protocol 1.7")
		window:Hide()
		window.scripts.OnUpdate(window, 1)
		assert.are.equal(2, providerCalls)
		development.command("dev on")
		assert.are.equal(3, providerCalls)
	end)

	it("supports moving and resizing, and clamps scrolling after content changes", function()
		development.command("dev on")
		local window, scroll, content, resize = frames[1], frames[2], frames[3], frames[4]
		window.scripts.OnDragStart(window)
		assert.is_true(window.moving)
		window.scripts.OnDragStop(window)
		assert.is_false(window.moving)
		resize.scripts.OnMouseDown(resize, "LeftButton")
		assert.are.equal("BOTTOMRIGHT", window.sizing)
		resize.scripts.OnMouseUp(resize)
		assert.is_nil(window.sizing)
		scroll:SetVerticalScroll(9999)
		window:SetSize(480, 300)
		assert.are.equal(424, content:GetWidth())
		assert.are.equal(math.max(0, content:GetHeight() - scroll:GetHeight()), scroll:GetVerticalScroll())
		resize.scripts.OnMouseDown(resize, "LeftButton")
		window:Hide()
		assert.is_nil(window.sizing)
	end)

	it("explains full-only fallback, ignoring offline peers and expiring capabilities", function()
		data.peers = { { name = "Julia", connected = true } }
		contains(namespace.Development.formatDiagnostics(data), "Julia has no recent q1")
		data.peers[1].session, data.peers[1].capabilityAge = "session", 45
		contains(namespace.Development.formatDiagnostics(data), "Partial updates eligible")
		data.peers[1].capabilityAge = 45.1
		contains(namespace.Development.formatDiagnostics(data), "Julia has no recent q1")
		data.peers[1].connected = false
		contains(namespace.Development.formatDiagnostics(data), "no connected peers")
		data.baselineNeeded = true
		contains(namespace.Development.formatDiagnostics(data), "tagged outgoing baseline")
		data.partialEnabled = false
		contains(namespace.Development.formatDiagnostics(data), "support is disabled")
	end)

	it("formats peers, independent assemblies, recovery and submission backoff", function()
		data.addonVersion, data.clientVersion, data.clientBuild = "0.1.10-dev", "12.1", "1234"
		data.outgoing = { kind = "P", revision = 9, sent = 1, parts = 3, bytes = 500 }
		data.requestPending, data.retryIn, data.nextSendIn = true, 4, 4
		data.peers = {
			{
				name = "Julia|cffff0000",
				detected = true,
				connected = true,
				status = "stale",
				protocol = "1.7",
				hasSnapshot = true,
				questCount = 12,
				revision = 7,
				snapshotAge = 20,
				messageAge = 2,
				state = { session = string.rep("a", 32), sequence = 7, digest = string.rep("b", 32) },
				pending = { revision = 8, received = 2, parts = 5 },
				partialPending = { revision = 9, received = 1, parts = 3 },
				targetedRepair = true,
				repairPending = true,
				repairIn = 12,
				recoveryReason = "missed update",
				recoveryAge = 1,
			},
		}
		local report = namespace.Development.formatDiagnostics(data)
		for _, expected in ipairs({
			"Addon 0.1.10-dev",
			"Client 12.1 · Build 1234",
			"Julia||cffff0000",
			"Observed protocol: 1.7",
			"12 quests · revision 7",
			"seq 7 · session aaaaaaaa · digest bbbbbbbb",
			"Committed: 20.0s ago",
			"Full assembly: revision 8 · 2/5",
			"Partial assembly: revision 9 · 1/3",
			"Repair: r1 targeted · queued · eligible in 12.0s",
			"Last recovery: missed update",
			"Active: partial · revision 9\n  1/3 chunks submitted",
			"Control queue: refresh",
			"Retry backoff active",
		}) do
			contains(report, expected)
		end
	end)

	it("labels empty, unknown, oversized and preview states without inventing peer versions", function()
		data.view, data.snapshotTooLarge, data.prefixRegistered = "preview samples", true, false
		local report = namespace.Development.formatDiagnostics(data)
		contains(report, "No player peers")
		contains(report, "registration failed")
		contains(report, "View: preview samples")
		contains(report, "OVERSIZED")
		data.peers = { { name = "Julia", status = "unknown" } }
		report = namespace.Development.formatDiagnostics(data)
		contains(report, "Observed protocol: unknown")
		contains(report, "addon not detected")
		contains(report, "Repair: H broadcast fallback")
		contains(report, "Cached snapshot: none")
	end)
end)
