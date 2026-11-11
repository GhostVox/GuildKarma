-- wowmock: a simulated guild for end-to-end tests. Each logged-in player runs their own
-- copy of the addon in a separate environment, with its own SavedVariables. Guild chat
-- and addon messages travel over a shared bus, and a simulated clock drives timers.

local Mock = {}

local ADDON_NAME = "GuildKarma"
local REALM = "Forever"
local SAVED_VARIABLES = { "GuildKarmaDB", "GuildKarmaMetaDB", "GuildKarmaSettings" }

-- WoW adds string:trim()
function string.trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function noop() end

local function DeepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = DeepCopy(v)
	end
	return copy
end

-- The files the addon loads, in TOC order
local function ReadTocFiles()
	local files = {}
	for line in io.lines(ADDON_NAME .. ".toc") do
		line = line:gsub("\r", "")
		if line:match("%.lua$") then
			table.insert(files, line)
		end
	end
	return files
end

---------------------------------------------------------------------------
-- Frames: enough of the widget API for the addon to build its UI. Methods the
-- addon only calls for looks (SetPoint, SetColorTexture, ...) are no-ops.
---------------------------------------------------------------------------

local Frame = {}
Frame.__index = function(self, key)
	if Frame[key] then
		return Frame[key]
	end
	-- Unknown widget methods are capitalized; plain fields stay nil
	if type(key) == "string" and key:match("^[A-Z]") then
		return noop
	end
	return nil
end

function Frame.New(client, frameType)
	local frame = setmetatable({ client = client, frameType = frameType, shown = true, enabled = true, scripts = {}, events = {} }, Frame)
	if client then
		table.insert(client.frames, frame)
	end
	return frame
end

function Frame:SetScript(name, fn)
	self.scripts[name] = fn
end

function Frame:GetScript(name)
	return self.scripts[name]
end

function Frame:HookScript(name, fn)
	local original = self.scripts[name]
	self.scripts[name] = function(...)
		if original then
			original(...)
		end
		fn(...)
	end
end

function Frame:RunScript(name, ...)
	if self.scripts[name] then
		return self.scripts[name](self, ...)
	end
end

function Frame:RegisterEvent(event)
	self.events[event] = true
end

function Frame:UnregisterEvent(event)
	self.events[event] = nil
end

function Frame:Show()
	if not self.shown then
		self.shown = true
		self:RunScript("OnShow")
	end
end

function Frame:Hide()
	if self.shown then
		self.shown = false
		self:RunScript("OnHide")
	end
end

function Frame:SetShown(shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end

function Frame:IsShown()
	return self.shown
end

function Frame:SetText(text)
	self.text = text
	if self.scripts.OnTextChanged then
		self.scripts.OnTextChanged(self, true)
	end
end

function Frame:GetText()
	return self.text or ""
end

function Frame:SetChecked(checked)
	self.checked = checked
end

function Frame:GetChecked()
	return self.checked
end

function Frame:SetEnabled(enabled)
	self.enabled = enabled and true or false
end

function Frame:Enable()
	self.enabled = true
end

function Frame:Disable()
	self.enabled = false
end

function Frame:IsEnabled()
	return self.enabled
end

function Frame:GetFontString()
	self.fontString = self.fontString or Frame.New(self.client, "FontString")
	return self.fontString
end

function Frame:CreateTexture()
	return Frame.New(self.client, "Texture")
end

function Frame:CreateFontString()
	return Frame.New(self.client, "FontString")
end

function Frame:GetWidth()
	return 140
end

function Frame:SetHeight(height)
	self.height = height
end

function Frame:GetHeight()
	return self.height or 300
end

-- Scroll frames: tests set scrollRange to simulate a list taller than the view
function Frame:GetVerticalScrollRange()
	return self.scrollRange or 0
end

function Frame:GetVerticalScroll()
	return self.verticalScroll or 0
end

function Frame:SetVerticalScroll(offset)
	self.verticalScroll = offset
end

function Frame:GetCenter()
	return 0, 0
end

function Frame:GetEffectiveScale()
	return 1
end

function Frame:IsOwned()
	return true
end

-- Simulate a click on a button
function Frame:Click(mouseButton)
	if self.enabled then
		self:RunScript("OnClick", mouseButton or "LeftButton")
	end
end

-- GameTooltip records the lines added to it
local function NewTooltip(client)
	local tooltip = Frame.New(client, "GameTooltip")
	tooltip.lines = {}
	function tooltip:SetOwner()
		self.lines = {}
	end
	function tooltip:AddLine(text)
		table.insert(self.lines, tostring(text))
	end
	function tooltip:AddDoubleLine(left, right)
		table.insert(self.lines, tostring(left) .. " " .. tostring(right))
	end
	function tooltip:GetUnit()
		return client.tooltipUnitName, client.tooltipUnit
	end
	function tooltip:Text()
		return table.concat(self.lines, "\n")
	end
	return tooltip
end

---------------------------------------------------------------------------
-- World: the guild, the clock, and the message bus
---------------------------------------------------------------------------

local World = {}
World.__index = World

function Mock.NewWorld(options)
	options = options or {}
	local world = setmetatable({
		time = 1800000000,
		seq = 0,
		timers = {},
		guildName = options.guildName or "Ghosts of Forever",
		leader = options.leader,
		members = {},
		memberOrder = {},
		clients = {},
		saved = {},
		chat = {},
		addonLog = {},
	}, World)
	for _, member in ipairs(options.members or {}) do
		world:AddMember(member)
	end
	return world
end

-- Add a guild member; they're online if `online` is set or they log in with the addon
function World:AddMember(member)
	if type(member) == "string" then
		member = { name = member }
	end
	member.rank = member.rank or (member.name == self.leader and "Guild Master" or "Member")
	member.classFile = member.classFile or "WARRIOR"
	self.members[member.name] = member
	table.insert(self.memberOrder, member)
end

function World:IsOnline(name)
	local member = self.members[name]
	return (self.clients[name] ~= nil) or (member and member.online) or false
end

-- Schedule fn after delay seconds; returns a handle with :Cancel()
function World:Schedule(delay, fn, interval, client)
	self.seq = self.seq + 1
	local timer = { at = self.time + delay, seq = self.seq, fn = fn, interval = interval, client = client }
	function timer:Cancel()
		self.cancelled = true
	end
	function timer:IsCancelled()
		return self.cancelled
	end
	table.insert(self.timers, timer)
	return timer
end

-- Run everything due in the next `seconds`, in time order
function World:Advance(seconds)
	local target = self.time + (seconds or 0)
	while true do
		local nextTimer, nextIndex
		for i, timer in ipairs(self.timers) do
			if timer.at <= target and (not nextTimer or timer.at < nextTimer.at or (timer.at == nextTimer.at and timer.seq < nextTimer.seq)) then
				nextTimer, nextIndex = timer, i
			end
		end
		if not nextTimer then
			break
		end

		self.time = nextTimer.at
		if nextTimer.interval and not nextTimer.cancelled then
			self.seq = self.seq + 1
			nextTimer.at = nextTimer.at + nextTimer.interval
			nextTimer.seq = self.seq
		else
			table.remove(self.timers, nextIndex)
		end
		-- Timers of a client that logged out die with it
		local alive = not nextTimer.client or self.clients[nextTimer.client.name] == nextTimer.client
		if not nextTimer.cancelled and alive then
			nextTimer.fn(nextTimer)
		end
	end
	self.time = target
end

-- Deliver everything already sent
function World:Flush()
	self:Advance(0)
end

-- Fire an event on a client's frames
function World:Fire(client, event, ...)
	for _, frame in ipairs(client.frames) do
		if frame.events[event] and frame.scripts.OnEvent then
			frame.scripts.OnEvent(frame, event, ...)
		end
	end
end

-- Guild chat from any member, with or without the addon
function World:Say(name, message)
	table.insert(self.chat, { from = name, message = message })
	for _, client in pairs(self.clients) do
		self:Schedule(0, function()
			self:Fire(client, "CHAT_MSG_GUILD", message, name .. "-" .. REALM)
		end)
	end
end

function World:SendAddon(sender, prefix, message, channel)
	assert(#message <= 255, "addon message over 255 bytes: " .. message)
	assert(channel == "GUILD", "unexpected addon channel " .. tostring(channel))
	table.insert(self.addonLog, { from = sender.name, message = message, time = self.time })
	for _, client in pairs(self.clients) do
		self:Schedule(0, function()
			self:Fire(client, "CHAT_MSG_ADDON", prefix, message, channel, sender.name .. "-" .. REALM)
		end)
	end
end

-- Guild chat lines sent by a member, optionally only those matching a pattern
function World:ChatFrom(name, pattern)
	local lines = {}
	for _, line in ipairs(self.chat) do
		if line.from == name and (not pattern or line.message:find(pattern)) then
			table.insert(lines, line.message)
		end
	end
	return lines
end

-- Guild chat lines matching a pattern, from anyone
function World:ChatMatching(pattern)
	local lines = {}
	for _, line in ipairs(self.chat) do
		if line.message:find(pattern) then
			table.insert(lines, line)
		end
	end
	return lines
end

---------------------------------------------------------------------------
-- Clients: one player running the addon
---------------------------------------------------------------------------

local function BuildEnvironment(world, client)
	local env = setmetatable({}, { __index = _G })
	local name = client.name

	env._G = env
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		table.insert(client.log, table.concat(parts, " "))
	end

	env.CreateFrame = function(frameType, frameName)
		local frame = Frame.New(client, frameType)
		if frameName then
			env[frameName] = frame
		end
		return frame
	end
	env.UIParent = Frame.New(client, "Frame")
	env.Minimap = Frame.New(client, "Frame")
	env.GameTooltip = NewTooltip(client)
	env.GameTooltip_Hide = noop
	env.UISpecialFrames = {}
	env.SlashCmdList = {}
	env.StaticPopupDialogs = {}
	env.StaticPopup_Show = function(which, text1, text2, data)
		client.popups = client.popups or {}
		table.insert(client.popups, { which = which, text = text1, data = data })
	end
	env.ACCEPT, env.CANCEL, env.YES, env.NO = "Accept", "Cancel", "Yes", "No"
	env.RAID_CLASS_COLORS = setmetatable({}, {
		__index = function()
			return { r = 1, g = 1, b = 1 }
		end,
	})
	env.CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.5, 0, 0.25 } }
	env.hooksecurefunc = function(target, method, hook)
		if type(target) == "string" then
			target, method, hook = env, target, method
		end
		local original = target[method]
		target[method] = function(...)
			local results = { original(...) }
			hook(...)
			return unpack(results)
		end
	end
	env.GetCursorPosition = function()
		return 0, 0
	end

	env.C_Timer = {
		After = function(delay, fn)
			world:Schedule(delay, fn, nil, client)
		end,
		NewTimer = function(delay, fn)
			return world:Schedule(delay, fn, nil, client)
		end,
		NewTicker = function(interval, fn)
			return world:Schedule(interval, fn, interval, client)
		end,
	}
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = noop,
		SendAddonMessage = function(prefix, message, channel)
			world:SendAddon(client, prefix, message, channel)
		end,
		SendChatMessage = function(message, channel)
			assert(channel == "GUILD", "unexpected chat channel " .. tostring(channel))
			world:Say(name, message)
		end,
	}
	env.C_GuildInfo = { GuildRoster = noop }

	env.GetServerTime = function()
		return world.time
	end
	env.GetGuildInfo = function()
		return world.guildName
	end
	env.IsInGuild = function()
		return true
	end
	env.IsGuildLeader = function()
		return world.leader == name
	end
	env.CanEditOfficerNote = function()
		return world.members[name].officer or world.leader == name
	end

	-- Professions, the way Classic Era and Forever list them: skill lines under headers.
	-- Set member.professions = { { "Alchemy", 250, 300 }, ... }
	local function SkillLines()
		local lines = { { "Class Skills", true } }
		local professions = world.members[name].professions or {}
		if #professions > 0 then
			table.insert(lines, { "Professions", true })
			for _, p in ipairs(professions) do
				table.insert(lines, { p[1], false, p[2], p[3] })
			end
		end
		table.insert(lines, { "Weapon Skills", true })
		table.insert(lines, { "Swords", false, 100, 300 })
		return lines
	end
	env.GetNumSkillLines = function()
		return #SkillLines()
	end
	env.GetSkillLineInfo = function(index)
		local line = SkillLines()[index]
		return line[1], line[2], true, line[3] or 0, 0, 0, line[4] or 0
	end
	env.GetNumGuildMembers = function()
		return #world.memberOrder
	end
	env.GetGuildRosterInfo = function(index)
		local member = world.memberOrder[index]
		if not member then
			return nil
		end
		local online = world:IsOnline(member.name)
		return member.name .. "-" .. REALM, member.rank, 0, 60, "Warrior", "", "", "", online, 0, member.classFile
	end
	env.UnitName = function(unit)
		if unit == "player" then
			return name
		end
		return client.tooltipUnitName
	end
	env.UnitIsPlayer = function()
		return true
	end
	env.UnitIsInMyGuild = function(unit)
		return world.members[env.UnitName(unit)] ~= nil
	end

	return env
end

-- Log a member in with the addon: load the files, restore SavedVariables, fire login events
function World:Login(name)
	assert(self.members[name], name .. " is not in the guild")
	assert(not self.clients[name], name .. " is already logged in")

	local client = { name = name, world = self, frames = {}, log = {} }
	local env = BuildEnvironment(self, client)
	local ns = {}
	client.env, client.ns = env, ns

	for _, file in ipairs(ReadTocFiles()) do
		local chunk = assert(loadfile(file))
		setfenv(chunk, env)
		chunk(ADDON_NAME, ns)
	end

	-- Like WoW, SavedVariables load after the files run and before ADDON_LOADED
	for key, value in pairs(self.saved[name] or {}) do
		env[key] = DeepCopy(value)
	end

	self.clients[name] = client
	self:Fire(client, "ADDON_LOADED", ADDON_NAME)
	self:Fire(client, "PLAYER_ENTERING_WORLD", true, false)
	return client
end

-- Log a member out, saving their SavedVariables for next login
function World:Logout(name)
	local client = assert(self.clients[name], name .. " is not logged in")
	self:Fire(client, "PLAYER_LOGOUT")
	local saved = {}
	for _, key in ipairs(SAVED_VARIABLES) do
		saved[key] = DeepCopy(client.env[key])
	end
	self.saved[name] = saved
	self.clients[name] = nil
end

-- Run a slash command on a client
function World:Slash(name, text)
	local client = assert(self.clients[name], name .. " is not logged in")
	client.env.SlashCmdList.GUILDKARMA(text)
end

-- A client's karma for a player (0 if none)
function World:Karma(name, player)
	local db = self.clients[name].env.GuildKarmaDB[self.guildName]
	return db and db[player] or 0
end

-- A client's karma history, oldest first
function World:Events(name)
	local meta = self.clients[name].env.GuildKarmaMetaDB[self.guildName]
	return meta and meta.events or {}
end

-- The frames a client created, optionally only those whose text matches
function World:FindFrames(name, predicate)
	local found = {}
	for _, frame in ipairs(self.clients[name].frames) do
		if predicate(frame) then
			table.insert(found, frame)
		end
	end
	return found
end

-- The button a client shows with this exact text
function World:FindButton(name, text)
	local buttons = self:FindFrames(name, function(frame)
		return frame.frameType == "Button" and frame.text == text
	end)
	return assert(buttons[1], "no button with text " .. text)
end

return Mock
