-- GuildKarma: Tracks guild member karma through ++ mentions

-- Initialize addon
local addonName = "GuildKarma"
local GuildKarma = {}

-- Database initialization
GuildKarmaDB = GuildKarmaDB or {}

-- Sync control variables
local SYNC_PREFIX = "GuildKarmaSync"
local isSyncing = false
local syncTimeout = nil

-- Frame for event handling
local frame = CreateFrame("Frame")

-- Print helper function
local function Print(msg)
	print("|cff00ff00[GuildKarma]|r " .. msg)
end

-- Initialize the database for the current guild
local function InitializeGuildDB()
	local guildName = GetGuildInfo("player")
	if not guildName then
		return nil
	end

	GuildKarmaDB[guildName] = GuildKarmaDB[guildName] or {}
	return guildName
end

-- Add karma to a player
local function AddKarma(playerName, shouldAnnounce)
	local guildName = InitializeGuildDB()
	if not guildName then
		return
	end

	-- Normalize the player name (remove server name if present, capitalize first letter)
	playerName = playerName:gsub("%-.*", "") -- Remove server name
	playerName = playerName:sub(1, 1):upper() .. playerName:sub(2):lower()

	-- Initialize player if not exists
	GuildKarmaDB[guildName][playerName] = GuildKarmaDB[guildName][playerName] or 0

	-- Add karma
	GuildKarmaDB[guildName][playerName] = GuildKarmaDB[guildName][playerName] + 1

	local newKarma = GuildKarmaDB[guildName][playerName]

	-- Only announce if this is OUR character receiving karma
	if shouldAnnounce then
		SendChatMessage("I now have " .. newKarma .. " karma!", "GUILD")
	end
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

	-- Normalize the player name
	playerName = playerName:gsub("%-.*", "")
	playerName = playerName:sub(1, 1):upper() .. playerName:sub(2):lower()

	local karma = GuildKarmaDB[guildName][playerName] or 0
	SendChatMessage(playerName .. " has " .. karma .. " karma!", "GUILD")
end

-- Serialize karma data for transmission
local function SerializeKarmaData()
	local guildName = InitializeGuildDB()
	if not guildName then
		return ""
	end

	local data = {}
	for name, karma in pairs(GuildKarmaDB[guildName]) do
		table.insert(data, name .. ":" .. karma)
	end

	return table.concat(data, ",")
end

-- Merge received karma data with local data (keeping highest values)
local function MergeKarmaData(receivedData)
	local guildName = InitializeGuildDB()
	if not guildName then
		return
	end

	local updatedCount = 0

	-- Parse received data
	for entry in receivedData:gmatch("[^,]+") do
		local name, karma = entry:match("([^:]+):(%d+)")
		if name and karma then
			karma = tonumber(karma)
			local currentKarma = GuildKarmaDB[guildName][name] or 0

			-- Keep the highest karma value
			if karma > currentKarma then
				GuildKarmaDB[guildName][name] = karma
				updatedCount = updatedCount + 1
			end
		end
	end

	return updatedCount
end

-- Request karma sync from guild members
local function RequestSync()
	if isSyncing then
		Print("Sync already in progress...")
		return
	end

	isSyncing = true
	Print("Requesting karma data from guild members...")

	-- Send sync request to guild
	C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "REQUEST", "GUILD")

	-- Set timeout to end sync after 5 seconds
	syncTimeout = C_Timer.NewTimer(5, function()
		isSyncing = false
		Print("Sync complete!")
	end)
end

-- Respond to sync request by sending our karma data
local function RespondToSyncRequest()
	local data = SerializeKarmaData()
	if data ~= "" then
		C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "DATA:" .. data, "GUILD")
	end
end

-- Parse guild chat message for karma
local function ParseMessage(message, sender)
	-- Check if someone is requesting a sync
	local lowerMessage = message:lower()
	if lowerMessage == "gk update" or lowerMessage == "!gk update" then
		RequestSync()
		return
	end

	-- Check if someone is asking for their karma
	if
		lowerMessage == "guildkarma"
		or lowerMessage == "!guildkarma"
		or lowerMessage == "!karma"
		or lowerMessage == "karma"
	then
		-- Remove server name from sender if present
		local senderName = sender:gsub("%-.*", "")
		ReportKarma(senderName)
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
			GuildRoster() -- Request guild roster update
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
		ParseMessage(message, sender)
	elseif event == "GUILD_ROSTER_UPDATE" then
		-- Guild roster has been updated
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = ...

		if prefix == SYNC_PREFIX and channel == "GUILD" then
			if message == "REQUEST" then
				-- Someone is requesting karma data
				RespondToSyncRequest()
			elseif message:match("^DATA:") then
				-- Received karma data from another guild member
				if isSyncing then
					local data = message:match("^DATA:(.+)$")
					if data then
						local updates = MergeKarmaData(data)
						if updates > 0 then
							Print("Updated " .. updates .. " karma entries from " .. sender)
						end
					end
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
		playerName = playerName:sub(1, 1):upper() .. playerName:sub(2):lower()
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
		print("  /gk - Show top 10 karma holders")
		print("  /gk <playername> - Show karma for specific player")
		print("  /gk report - Report top 10 to guild chat")
		print("  /gk report <playername> - Report specific player's karma to guild chat")
		print("  /gk sync - Sync karma data with other guild members")
		print("  /gk debug <name> - Test if a name is found in guild roster")
		print("  /gk reset - Reset all karma (use with caution!)")
		print("Guild members can type 'guildkarma' in guild chat to check their karma")
		print("Guild members can type 'gk update' in guild chat to trigger a sync")
	elseif msg == "reset" then
		local guildName = InitializeGuildDB()
		if guildName then
			GuildKarmaDB[guildName] = {}
			Print("All karma has been reset!")
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
				SendChatMessage("No karma recorded yet!", "GUILD")
				return
			end

			-- Send header immediately
			SendChatMessage("=== Top 10 Karma Holders ===", "GUILD")

			-- Send each entry with a 0.5 second delay
			local delay = 0.5
			for i = 1, math.min(10, #karmaList) do
				C_Timer.After(delay * i, function()
					SendChatMessage(i .. ". " .. karmaList[i].name .. ": " .. karmaList[i].karma, "GUILD")
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
