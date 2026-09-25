-- GuildKarma: Tracks guild member karma through ++ mentions

-- Initialize addon
local addonName, ns = ...

-- Database initialization
GuildKarmaDB = GuildKarmaDB or {}
-- Per guild: rev[name] = server time of the guild leader's last edit to that entry,
-- resetRev = server time of the last guild-wide reset. Newer revisions win on sync.
GuildKarmaMetaDB = GuildKarmaMetaDB or {}

-- Sync control variables
local SYNC_PREFIX = "GuildKarmaSync"
local MAX_ADDON_MSG = 255 -- Hard limit on addon message length (bytes)
local CHUNK_INTERVAL = 1 -- Seconds between data chunks, to stay under the addon message throttle
local SYNC_WINDOW = 5 -- Seconds of silence before a sync is considered complete
local EDIT_FLUSH_DELAY = 1 -- Seconds to batch leader edits before broadcasting them
local isSyncing = false
local syncTimeout = nil

-- Leader edits waiting to be broadcast, keyed by player name
local pendingEdits = {}
local editFlushTimer = nil

-- Lowercased short names of guild members seen running the addon this session
local addonUsers = {}

-- Frame for event handling
local frame = CreateFrame("Frame")

-- Print helper function
local function Print(msg)
	print("|cff00ff00[GuildKarma]|r " .. msg)
end

-- Send a chat message, using whichever API this client provides.
-- Skipped during retail's chat lockdown (boss encounters), where sending fails.
local function SendChat(msg, chatType)
	if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
		return
	end
	if C_ChatInfo.SendChatMessage then
		C_ChatInfo.SendChatMessage(msg, chatType)
	else
		SendChatMessage(msg, chatType)
	end
end

-- Request a guild roster update, using whichever API this client provides
local function RequestGuildRoster()
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	else
		GuildRoster()
	end
end

-- Initialize the database for the current guild
local function InitializeGuildDB()
	local guildName = GetGuildInfo("player")
	if not guildName then
		return nil
	end

	GuildKarmaDB[guildName] = GuildKarmaDB[guildName] or {}
	GuildKarmaMetaDB[guildName] = GuildKarmaMetaDB[guildName] or {}
	GuildKarmaMetaDB[guildName].rev = GuildKarmaMetaDB[guildName].rev or {}
	GuildKarmaMetaDB[guildName].resetRev = GuildKarmaMetaDB[guildName].resetRev or 0
	return guildName
end

-- Normalize a player name: remove server name, capitalize first letter
local function NormalizeName(playerName)
	playerName = playerName:gsub("%-.*", "")
	return playerName:sub(1, 1):upper() .. playerName:sub(2):lower()
end

-- Let the UI know karma data or the roster changed
local function NotifyChanged()
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
end

-- Add karma to a player
local function AddKarma(playerName, shouldAnnounce)
	local guildName = InitializeGuildDB()
	if not guildName then
		return
	end

	playerName = NormalizeName(playerName)

	-- Initialize player if not exists. New entries date from the last reset,
	-- so they survive it if the reset reaches us again.
	if not GuildKarmaDB[guildName][playerName] then
		GuildKarmaDB[guildName][playerName] = 0
		local meta = GuildKarmaMetaDB[guildName]
		if meta.resetRev > 0 then
			meta.rev[playerName] = meta.resetRev
		end
	end

	-- Add karma
	GuildKarmaDB[guildName][playerName] = GuildKarmaDB[guildName][playerName] + 1

	local newKarma = GuildKarmaDB[guildName][playerName]

	-- Only announce if this is OUR character receiving karma
	if shouldAnnounce then
		SendChat("I now have " .. newKarma .. " karma!", "GUILD")
	end

	NotifyChanged()
end

-- Check if a player is in the guild
local function IsGuildMember(playerName)
	local numMembers = GetNumGuildMembers()
	playerName = playerName:lower()

	for i = 1, numMembers do
		local name = GetGuildRosterInfo(i)
		if name then
			-- Remove server name and compare
			local guildMemberName = name:gsub("%-.*", ""):lower()
			if guildMemberName == playerName then
				-- Return the properly capitalized name from the roster
				return true, name:gsub("%-.*", "")
			end
		end
	end

	return false, nil
end

-- Report karma to guild chat
local function ReportKarma(playerName)
	local guildName = InitializeGuildDB()
	if not guildName then
		return
	end

	playerName = NormalizeName(playerName)

	local karma = GuildKarmaDB[guildName][playerName] or 0
	SendChat(playerName .. " has " .. karma .. " karma!", "GUILD")
end

-- Strip the server name from a player name
local function ShortName(name)
	return (name:gsub("%-.*", ""))
end

-- Check whether a guild member (lowercased short name) is currently online
local function IsOnline(key)
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
		if name and ShortName(name):lower() == key then
			return online
		end
	end
	return false
end

-- Decide whether this client should handle a guild chat trigger, so only one
-- addon user responds. If the sender runs the addon, their own client responds;
-- otherwise the online addon user whose name sorts first responds.
local function IsResponder(sender)
	local senderKey = ShortName(sender):lower()
	local myKey = UnitName("player"):lower()

	if addonUsers[senderKey] then
		return senderKey == myKey
	end

	local leader = myKey
	for key in pairs(addonUsers) do
		if key < leader and IsOnline(key) then
			leader = key
		end
	end
	return leader == myKey
end

-- Split karma data into "name:karma[:rev],..." chunks that fit in one addon message.
-- Older clients read only "name:karma" and ignore the revision.
local function SerializeKarmaChunks(names)
	local guildName = InitializeGuildDB()
	if not guildName then
		return {}
	end

	local db = GuildKarmaDB[guildName]
	local revs = GuildKarmaMetaDB[guildName].rev
	local chunks = {}
	local current = ""
	local maxPayload = MAX_ADDON_MSG - #"DATA:"
	for name in pairs(names or db) do
		local entry = name .. ":" .. (db[name] or 0)
		if revs[name] then
			entry = entry .. ":" .. revs[name]
		end
		if current == "" then
			current = entry
		elseif #current + 1 + #entry > maxPayload then
			table.insert(chunks, current)
			current = entry
		else
			current = current .. "," .. entry
		end
	end
	if current ~= "" then
		table.insert(chunks, current)
	end

	return chunks
end

-- Merge received karma data with local data. The entry with the newer leader
-- revision wins; with equal revisions the highest karma wins. Entries older than
-- the last guild-wide reset are dropped.
local function MergeKarmaData(receivedData)
	local guildName = InitializeGuildDB()
	if not guildName then
		return 0
	end

	local db = GuildKarmaDB[guildName]
	local meta = GuildKarmaMetaDB[guildName]
	local updatedCount = 0

	-- Parse received data
	for entry in receivedData:gmatch("[^,]+") do
		local name, karma, rev = entry:match("^([^:]+):(%d+):?(%d*)$")
		if name then
			karma = tonumber(karma)
			rev = tonumber(rev) or 0
			local currentKarma = db[name]
			local currentRev = meta.rev[name] or 0

			if rev >= meta.resetRev then
				if currentKarma == nil or rev > currentRev or (rev == currentRev and karma > currentKarma) then
					if karma ~= currentKarma then
						updatedCount = updatedCount + 1
					end
					db[name] = karma
					meta.rev[name] = rev > 0 and rev or nil
				end
			end
		end
	end

	if updatedCount > 0 then
		NotifyChanged()
	end
	return updatedCount
end

-- Apply a guild-wide reset made at server time resetRev, dropping every entry
-- the guild leader hasn't edited since. Returns true if it was new to us.
local function ApplyReset(resetRev)
	local guildName = InitializeGuildDB()
	if not guildName then
		return false
	end

	local db = GuildKarmaDB[guildName]
	local meta = GuildKarmaMetaDB[guildName]
	if resetRev <= meta.resetRev then
		return false
	end

	for name in pairs(db) do
		if (meta.rev[name] or 0) < resetRev then
			db[name] = nil
			meta.rev[name] = nil
		end
	end
	meta.resetRev = resetRev

	NotifyChanged()
	return true
end

-- A revision newer than both the clock and the last one, so edits always win
local function NextRev(lastRev)
	return math.max(GetServerTime(), (lastRev or 0) + 1)
end

-- Only the guild leader can manage karma
local function CanManage()
	return IsInGuild() and IsGuildLeader()
end

-- Send batched leader edits to other addon users
local function FlushEdits()
	editFlushTimer = nil
	local chunks = SerializeKarmaChunks(pendingEdits)
	pendingEdits = {}
	for i, chunk in ipairs(chunks) do
		C_Timer.After((i - 1) * CHUNK_INTERVAL, function()
			C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "DATA:" .. chunk, "GUILD")
		end)
	end
end

-- Guild leader: set a player's karma to an exact value
local function SetKarma(playerName, value)
	local guildName = InitializeGuildDB()
	if not guildName or not CanManage() then
		return
	end

	playerName = NormalizeName(playerName)
	value = math.max(0, math.floor(value))

	local meta = GuildKarmaMetaDB[guildName]
	GuildKarmaDB[guildName][playerName] = value
	meta.rev[playerName] = NextRev(meta.rev[playerName])

	-- Batch rapid edits (e.g. clicking + repeatedly) to stay under the message throttle
	pendingEdits[playerName] = true
	if not editFlushTimer then
		editFlushTimer = C_Timer.NewTimer(EDIT_FLUSH_DELAY, FlushEdits)
	end

	NotifyChanged()
end

-- Guild leader: reset karma for the whole guild
local function ResetAllKarma()
	local guildName = InitializeGuildDB()
	if not guildName or not CanManage() then
		return
	end

	local resetRev = NextRev(GuildKarmaMetaDB[guildName].resetRev)
	ApplyReset(resetRev)
	pendingEdits = {}
	C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "RESET:" .. resetRev, "GUILD")
	Print("All karma has been reset!")
end

-- (Re)start the timer that ends the sync window once data stops arriving
local function ExtendSyncWindow()
	if syncTimeout then
		syncTimeout:Cancel()
	end
	syncTimeout = C_Timer.NewTimer(SYNC_WINDOW, function()
		isSyncing = false
		syncTimeout = nil
		Print("Sync complete!")
	end)
end

-- Start a karma sync. When sendRequest is false, only listen for the data
-- that another addon user's request will trigger.
local function RequestSync(sendRequest)
	if isSyncing then
		Print("Sync already in progress...")
		return
	end

	isSyncing = true
	Print("Requesting karma data from guild members...")

	if sendRequest ~= false then
		C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "REQUEST", "GUILD")
	end

	ExtendSyncWindow()
end

-- Respond to sync request by sending our karma data, spread over several
-- messages if needed. Always send something so the requester learns we run the addon.
local function RespondToSyncRequest()
	local guildName = InitializeGuildDB()
	if not guildName then
		return
	end

	-- Pass on the last reset first, so peers drop stale entries
	local resetRev = GuildKarmaMetaDB[guildName].resetRev
	if resetRev > 0 then
		C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "RESET:" .. resetRev, "GUILD")
	end

	local chunks = SerializeKarmaChunks()
	if #chunks == 0 then
		if resetRev == 0 then
			C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "HELLO", "GUILD")
		end
		return
	end

	for i, chunk in ipairs(chunks) do
		C_Timer.After((resetRev > 0 and i or i - 1) * CHUNK_INTERVAL, function()
			C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "DATA:" .. chunk, "GUILD")
		end)
	end
end

-- Parse guild chat message for karma
local function ParseMessage(message, sender)
	-- Check if someone is requesting a sync
	local lowerMessage = message:lower()
	if lowerMessage == "gk update" or lowerMessage == "!gk update" then
		-- One client sends the request; everyone merges the responses
		RequestSync(IsResponder(sender))
		return
	end

	-- Check if someone is asking for their karma
	if
		lowerMessage == "guildkarma"
		or lowerMessage == "!guildkarma"
		or lowerMessage == "!karma"
		or lowerMessage == "karma"
	then
		if IsResponder(sender) then
			ReportKarma(ShortName(sender))
		end
		return
	end

	-- Normalize sender name for comparison
	local normalizedSender = sender:gsub("%-.*", ""):lower()

	-- Get current player name
	local myName = UnitName("player")

	-- Split message into words and check each for ++
	for word in message:gmatch("%S+") do
		-- Check if this word ends with ++
		-- Updated pattern to match any non-whitespace characters followed by ++
		local playerName = word:match("^([^%s%+]+)%+%+$")

		if playerName then
			-- Check if player is trying to give karma to themselves
			if playerName:lower() == normalizedSender then
				-- Silently ignore self-karma attempts
				return
			end

			-- Check if the mentioned player is in the guild
			local isInGuild, properName = IsGuildMember(playerName)

			if isInGuild and properName then
				-- Only announce if this is OUR character receiving karma
				local shouldAnnounce = (properName:lower() == myName:lower())
				AddKarma(properName, shouldAnnounce)
			end
		end
	end
end

-- Event handler
local function OnEvent(self, event, ...)
	if event == "ADDON_LOADED" then
		local loadedAddon = ...
		if loadedAddon == addonName then
			Print("Loaded! Use /gk or /guildkarma for commands.")
			addonUsers[UnitName("player"):lower()] = true
			RequestGuildRoster()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isLogin, isReload = ...
		-- Only sync on actual login, not on reload or zone changes
		if isLogin then
			-- Delay sync by 3 seconds to ensure guild roster is loaded
			C_Timer.After(3, function()
				local guildName = GetGuildInfo("player")
				if guildName then
					Print("Auto-syncing karma data...")
					RequestSync()
				end
			end)
		end
	elseif event == "CHAT_MSG_GUILD" then
		local message, sender = ...
		-- Retail can hide chat contents from addons; skip what we can't read
		if issecretvalue and (issecretvalue(message) or issecretvalue(sender)) then
			return
		end
		ParseMessage(message, sender)
	elseif event == "GUILD_ROSTER_UPDATE" then
		NotifyChanged()
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = ...

		if prefix == SYNC_PREFIX and channel == "GUILD" then
			addonUsers[ShortName(sender):lower()] = true

			if message == "REQUEST" then
				-- Someone is requesting karma data
				RespondToSyncRequest()
			elseif message:match("^DATA:") then
				-- Received karma data from another guild member. Merging is
				-- always safe (newest revision wins), so do it even outside our own sync.
				local data = message:match("^DATA:(.+)$")
				if data then
					local updates = MergeKarmaData(data)
					if isSyncing then
						if updates > 0 then
							Print("Updated " .. updates .. " karma entries from " .. sender)
						end
						ExtendSyncWindow()
					end
				end
			elseif message:match("^RESET:%d+$") then
				-- The guild leader reset all karma
				if ApplyReset(tonumber(message:match("^RESET:(%d+)$"))) then
					Print("All karma was reset by the guild leader.")
				end
			end
		end
	end
end

-- Register events
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", OnEvent)

-- Register addon message prefix for syncing
C_ChatInfo.RegisterAddonMessagePrefix(SYNC_PREFIX)

-- Slash command to show karma
local function ShowKarma(playerName)
	local guildName = InitializeGuildDB()
	if not guildName then
		Print("You must be in a guild to use this addon.")
		return
	end

	if playerName and playerName ~= "" then
		-- Show specific player's karma
		playerName = NormalizeName(playerName)
		local karma = GuildKarmaDB[guildName][playerName] or 0
		Print(playerName .. " has " .. karma .. " karma.")
	else
		-- Show top 10 karma holders
		local karmaList = {}
		for name, karma in pairs(GuildKarmaDB[guildName]) do
			table.insert(karmaList, { name = name, karma = karma })
		end

		-- Sort by karma (descending)
		table.sort(karmaList, function(a, b)
			return a.karma > b.karma
		end)

		Print("Top Karma Holders:")
		for i = 1, math.min(10, #karmaList) do
			print("  " .. i .. ". " .. karmaList[i].name .. ": " .. karmaList[i].karma)
		end

		if #karmaList == 0 then
			Print("No karma recorded yet!")
		end
	end
end

-- Slash command handler
local function SlashCommandHandler(msg)
	msg = msg:trim()

	if msg == "help" then
		Print("Commands:")
		print("  /gk ui - Open the karma window")
		print("  /gk minimap - Show or hide the minimap button")
		print("  /gk - Show top 10 karma holders")
		print("  /gk <playername> - Show karma for specific player")
		print("  /gk report - Report top 10 to guild chat")
		print("  /gk report <playername> - Report specific player's karma to guild chat")
		print("  /gk sync - Sync karma data with other guild members")
		print("  /gk debug <name> - Test if a name is found in guild roster")
		print("  /gk reset - Reset all karma for the guild (guild leader only)")
		print("Guild members can type 'guildkarma' in guild chat to check their karma")
		print("Guild members can type 'gk update' in guild chat to trigger a sync")
	elseif msg == "ui" then
		ns.ToggleUI()
	elseif msg == "minimap" then
		ns.ToggleMinimapButton()
	elseif msg == "reset" then
		if CanManage() then
			ResetAllKarma()
		else
			Print("Only the guild leader can reset karma.")
		end
	elseif msg == "sync" then
		RequestSync()
	elseif msg:match("^debug%s+") then
		local testName = msg:match("^debug%s+(.+)$")
		if testName then
			Print("Testing name: '" .. testName .. "'")
			local isInGuild, properName = IsGuildMember(testName)
			if isInGuild then
				Print("SUCCESS: Found as '" .. properName .. "' in guild roster")
			else
				Print("FAILED: Not found in guild roster")
				Print("Total guild members: " .. GetNumGuildMembers())
				Print("Try typing: /gk debug YourExactCharacterName")
			end
		end
	elseif msg:match("^report") then
		local playerName = msg:match("^report%s+(.+)$")
		if playerName and playerName ~= "" then
			-- Report specific player to guild chat
			ReportKarma(playerName)
		else
			-- Report top 10 to guild chat with delays
			local guildName = InitializeGuildDB()
			if not guildName then
				Print("You must be in a guild to use this addon.")
				return
			end

			local karmaList = {}
			for name, karma in pairs(GuildKarmaDB[guildName]) do
				table.insert(karmaList, { name = name, karma = karma })
			end

			-- Sort by karma (descending)
			table.sort(karmaList, function(a, b)
				return a.karma > b.karma
			end)

			if #karmaList == 0 then
				SendChat("No karma recorded yet!", "GUILD")
				return
			end

			-- Send header immediately
			SendChat("=== Top 10 Karma Holders ===", "GUILD")

			-- Send each entry with a 0.5 second delay
			local delay = 0.5
			for i = 1, math.min(10, #karmaList) do
				C_Timer.After(delay * i, function()
					SendChat(i .. ". " .. karmaList[i].name .. ": " .. karmaList[i].karma, "GUILD")
				end)
			end
		end
	else
		ShowKarma(msg)
	end
end

-- Register slash commands
SLASH_GUILDKARMA1 = "/guildkarma"
SLASH_GUILDKARMA2 = "/gk"
SlashCmdList["GUILDKARMA"] = SlashCommandHandler

-- Shared with GuildKarmaUI.lua
ns.Print = Print
ns.NormalizeName = NormalizeName
ns.ShortName = ShortName
ns.RequestGuildRoster = RequestGuildRoster
ns.RequestSync = RequestSync
ns.CanManage = CanManage
ns.SetKarma = SetKarma
ns.ResetAllKarma = ResetAllKarma

-- Karma table for the current guild, or nil when not in a guild
function ns.GetGuildDB()
	local guildName = InitializeGuildDB()
	return guildName and GuildKarmaDB[guildName]
end
