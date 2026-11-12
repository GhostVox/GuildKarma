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
local KARMA_COOLDOWN = 300 -- Seconds before the same player can give the same person karma again
local HISTORY_DAYS = 35 -- Days of karma history kept for recent leaderboards and tooltips
local MAX_REASON = 60 -- Longest reason kept with a karma event (bytes)
local DAY = 86400
local isSyncing = false
local syncTimeout = nil

-- Leader edits waiting to be broadcast, keyed by player name
local pendingEdits = {}
local editFlushTimer = nil

-- Lowercased short names of guild members seen running the addon this session
local addonUsers = {}

-- Addon message handlers registered by feature files, keyed by message type
-- ("PROF" handles "PROF:..."), and functions run when we request a sync
local messageHandlers = {}
local syncHooks = {}

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
	-- Karma history: { t = server time, from = giver, to = receiver, reason = optional text }, oldest first
	GuildKarmaMetaDB[guildName].events = GuildKarmaMetaDB[guildName].events or {}
	return guildName
end

-- Normalize a player name: remove server name, capitalize the first letter of
-- each word (Forever names can have several words, e.g. "Cut Loss")
local function NormalizeName(playerName)
	playerName = playerName:gsub("%-.*", ""):lower()
	return (playerName:gsub("(%S)(%S*)", function(first, rest)
		return first:upper() .. rest
	end))
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

-- Find an event from one player to another within the cooldown of time t. Every addon
-- user records the same chat message, so this also spots duplicates during sync.
local function FindNearbyEvent(events, from, to, t)
	for i = #events, 1, -1 do
		local event = events[i]
		if event.from == from and event.to == to and math.abs(event.t - t) < KARMA_COOLDOWN then
			return event
		end
	end
	return nil
end

-- Record a karma event, keeping the history sorted by time. Repeats within the
-- cooldown, and events older than the history window or the last reset, are skipped.
-- Returns true if the event was recorded.
local function RecordEvent(from, to, t, reason)
	local guildName = InitializeGuildDB()
	if not guildName then
		return false
	end

	local meta = GuildKarmaMetaDB[guildName]
	local events = meta.events
	if t < meta.resetRev or t < GetServerTime() - HISTORY_DAYS * DAY or FindNearbyEvent(events, from, to, t) then
		return false
	end

	local index = #events
	while index > 0 and events[index].t > t do
		index = index - 1
	end
	table.insert(events, index + 1, { t = t, from = from, to = to, reason = reason })
	return true
end

-- Drop events that have aged out of the history window
local function PruneEvents()
	local guildName = InitializeGuildDB()
	if not guildName then
		return
	end

	local meta = GuildKarmaMetaDB[guildName]
	local cutoff = GetServerTime() - HISTORY_DAYS * DAY
	local kept = {}
	for _, event in ipairs(meta.events) do
		if event.t >= cutoff then
			table.insert(kept, event)
		end
	end
	meta.events = kept
end

-- Karma per player: all-time totals, or karma received in the last `days` days
local function GetKarmaCounts(days)
	local guildName = InitializeGuildDB()
	if not guildName then
		return {}
	end
	if not days then
		return GuildKarmaDB[guildName]
	end

	local counts = {}
	local cutoff = GetServerTime() - days * DAY
	for _, event in ipairs(GuildKarmaMetaDB[guildName].events) do
		if event.t >= cutoff then
			counts[event.to] = (counts[event.to] or 0) + 1
		end
	end
	return counts
end

-- Recent karma events, newest first: all of them, or only those received by `name`
local function GetHistory(name, limit)
	local guildName = InitializeGuildDB()
	if not guildName then
		return {}
	end

	local events = GuildKarmaMetaDB[guildName].events
	local history = {}
	for i = #events, 1, -1 do
		if not name or events[i].to == name then
			table.insert(history, events[i])
			if limit and #history >= limit then
				break
			end
		end
	end
	return history
end

-- Turn the text after a ++ into a short plain reason: strip colors, textures and
-- link markup (keeping link text), and characters the sync format uses as separators
local function CleanReason(text)
	text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
		:gsub("|r", "")
		:gsub("|H.-|h(.-)|h", "%1")
		:gsub("|T.-|t", "")
		:gsub("[~%^]", "")
	text = text:match("^%s*(.-)%s*$")
	if #text > MAX_REASON then
		-- Cut on a character boundary so multi-byte letters aren't split
		text = text:sub(1, MAX_REASON):gsub("[\192-\255][\128-\191]*$", "")
	end
	return text ~= "" and text or nil
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

-- Most words a player name can have (Forever names have a first and last name)
local MAX_NAME_WORDS = 3

-- Find the guild member named at the end of some text, trying the longest run of
-- trailing words first so "thanks Cut Loss" matches "Cut Loss" rather than "Loss"
local function FindMentionedMember(text)
	local words = {}
	for word in text:gmatch("%S+") do
		table.insert(words, word)
	end

	for count = math.min(MAX_NAME_WORDS, #words), 1, -1 do
		local candidate = table.concat(words, " ", #words - count + 1, #words)
		local isInGuild, properName = IsGuildMember(candidate)
		if isInGuild then
			return properName
		end
	end

	return nil
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

-- A unit's name as the guild roster shows it. On Forever, UnitName can return just
-- the first word of a two-word name ("Lunä" for "Lunä Atrix").
local function UnitRosterName(unit)
	local unitName = UnitName(unit)
	local guid = UnitGUID and UnitGUID(unit)
	local lower = unitName:lower()
	local firstWordMatch
	for i = 1, GetNumGuildMembers() do
		local fullName, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, memberGuid = GetGuildRosterInfo(i)
		if fullName then
			local name = ShortName(fullName)
			if (guid and memberGuid == guid) or name:lower() == lower then
				return name
			elseif not firstWordMatch and name:lower():sub(1, #lower + 1) == lower .. " " then
				firstWordMatch = name
			end
		end
	end
	return firstWordMatch or unitName
end

-- Our own name as the guild roster shows it
local function PlayerName()
	return UnitRosterName("player")
end

-- Whether a name (with or without realm) is our own character
local function IsMe(name)
	local key = ShortName(name):lower()
	return key == UnitName("player"):lower() or key == PlayerName():lower()
end

-- Decide whether this client should handle a guild chat trigger, so only one
-- addon user responds. If the sender runs the addon, their own client responds;
-- otherwise the online addon user whose name sorts first responds.
local function IsResponder(sender)
	local myKey = PlayerName():lower()
	local senderKey = IsMe(sender) and myKey or ShortName(sender):lower()
	addonUsers[myKey] = true

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

-- Bulk sync messages wait here and go out one per CHUNK_INTERVAL, to stay under
-- the addon message throttle
local sendQueue = {}
local sendTicker = nil

local function QueueAddonMessage(message)
	table.insert(sendQueue, message)
	if sendTicker then
		return
	end

	C_ChatInfo.SendAddonMessage(SYNC_PREFIX, table.remove(sendQueue, 1), "GUILD")
	sendTicker = C_Timer.NewTicker(CHUNK_INTERVAL, function()
		local nextMessage = table.remove(sendQueue, 1)
		if nextMessage then
			C_ChatInfo.SendAddonMessage(SYNC_PREFIX, nextMessage, "GUILD")
		else
			sendTicker:Cancel()
			sendTicker = nil
		end
	end)
end

-- Join entries with a separator into chunks no longer than maxPayload bytes
local function JoinInChunks(entries, separator, maxPayload)
	local chunks = {}
	local current = ""
	for _, entry in ipairs(entries) do
		if current == "" then
			current = entry
		elseif #current + #separator + #entry > maxPayload then
			table.insert(chunks, current)
			current = entry
		else
			current = current .. separator .. entry
		end
	end
	if current ~= "" then
		table.insert(chunks, current)
	end
	return chunks
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
	local entries = {}
	for name in pairs(names or db) do
		local entry = name .. ":" .. (db[name] or 0)
		if revs[name] then
			entry = entry .. ":" .. revs[name]
		end
		table.insert(entries, entry)
	end

	return JoinInChunks(entries, ",", MAX_ADDON_MSG - #"DATA:")
end

-- Split karma history since a server time into "t~from~to~reason^..." chunks
local function SerializeEventChunks(since)
	local entries = {}
	for _, event in ipairs(GetHistory()) do
		if event.t >= since then
			table.insert(entries, event.t .. "~" .. event.from .. "~" .. event.to .. "~" .. (event.reason or ""))
		end
	end

	return JoinInChunks(entries, "^", MAX_ADDON_MSG - #"EVENTS:")
end

-- Merge karma history received from another addon user. Returns how many events were new.
local function MergeEvents(data)
	local added = 0
	for record in data:gmatch("[^%^]+") do
		local t, from, to, reason = record:match("^(%d+)~([^~]+)~([^~]+)~(.*)$")
		if t and RecordEvent(from, to, tonumber(t), reason ~= "" and reason or nil) then
			added = added + 1
		end
	end

	if added > 0 then
		NotifyChanged()
	end
	return added
end

-- Ask other addon users for karma history from around when we were last online
local function RequestEvents()
	local guildName = InitializeGuildDB()
	if not guildName then
		return
	end

	local oldest = GetServerTime() - HISTORY_DAYS * DAY
	local since = math.max(oldest, (GuildKarmaMetaDB[guildName].lastOnline or 0) - KARMA_COOLDOWN)
	C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "EVENTREQ:" .. since, "GUILD")
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
	local keptEvents = {}
	for _, event in ipairs(meta.events) do
		if event.t >= resetRev then
			table.insert(keptEvents, event)
		end
	end
	meta.events = keptEvents
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
	for _, chunk in ipairs(chunks) do
		QueueAddonMessage("DATA:" .. chunk)
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
		RequestEvents()
		for _, hook in ipairs(syncHooks) do
			hook()
		end
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
		QueueAddonMessage("RESET:" .. resetRev)
	end

	local chunks = SerializeKarmaChunks()
	if #chunks == 0 and resetRev == 0 then
		QueueAddonMessage("HELLO")
	end
	for _, chunk in ipairs(chunks) do
		QueueAddonMessage("DATA:" .. chunk)
	end
end

-- Parse guild chat message for karma. A simulated message (from /gk simulate) only
-- gives karma: it never sends anything to guild chat.
local function ParseMessage(message, sender, isSimulated)
	-- Check if someone is requesting a sync
	local lowerMessage = message:lower()
	if isSimulated then
		lowerMessage = ""
	end
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

	-- Find each "++" that ends a word and the guild member named just before it
	local mentions = {}
	local reasonStart = nil
	local searchFrom = 1
	while true do
		local plusStart, plusEnd = message:find("%+%+", searchFrom)
		if not plusStart then
			break
		end

		local before = message:sub(searchFrom, plusStart - 1)
		local after = message:sub(plusEnd + 1, plusEnd + 1)
		searchFrom = plusEnd + 1

		if before:match("[^%s%+]$") and (after == "" or after:match("%s")) then
			local properName = FindMentionedMember(before)

			if properName then
				-- Check if player is trying to give karma to themselves
				if properName:lower() == normalizedSender then
					-- Silently ignore self-karma attempts
					return
				end

				table.insert(mentions, properName)
				reasonStart = plusEnd + 1
			end
		end
	end

	-- Text after the last mention is the reason, e.g. "Cut Loss++ for the heals"
	local reason = reasonStart and CleanReason(message:sub(reasonStart))
	local giver = NormalizeName(sender)
	local now = GetServerTime()

	for _, properName in ipairs(mentions) do
		-- Skip repeats within the cooldown so karma can't be spammed
		if RecordEvent(giver, NormalizeName(properName), now, reason) then
			-- Only announce if this is OUR character receiving karma
			local shouldAnnounce = not isSimulated and IsMe(properName)
			AddKarma(properName, shouldAnnounce)
		end
	end
end

-- Event handler
local function OnEvent(self, event, ...)
	if event == "ADDON_LOADED" then
		local loadedAddon = ...
		if loadedAddon == addonName then
			Print("Loaded! Use /gk or /guildkarma for commands.")
			addonUsers[PlayerName():lower()] = true
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
					PruneEvents()
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
	elseif event == "PLAYER_LOGOUT" then
		-- Remember when we left, so next login only asks for history we missed
		local guildName = InitializeGuildDB()
		if guildName then
			GuildKarmaMetaDB[guildName].lastOnline = GetServerTime()
		end
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
			elseif message:match("^EVENTREQ:%d+$") then
				-- Someone wants karma history since a time; our own request echoes back too
				if not IsMe(sender) then
					for _, chunk in ipairs(SerializeEventChunks(tonumber(message:match("^EVENTREQ:(%d+)$")))) do
						QueueAddonMessage("EVENTS:" .. chunk)
					end
				end
			elseif message:match("^EVENTS:") then
				local data = message:match("^EVENTS:(.+)$")
				if data then
					MergeEvents(data)
					if isSyncing then
						ExtendSyncWindow()
					end
				end
			elseif message:match("^RESET:%d+$") then
				-- The guild leader reset all karma
				if ApplyReset(tonumber(message:match("^RESET:(%d+)$"))) then
					Print("All karma was reset by the guild leader.")
				end
			else
				local kind, body = message:match("^(%u+):?(.*)$")
				local handler = kind and messageHandlers[kind]
				if handler then
					handler(body, ShortName(sender))
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
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", OnEvent)

-- Register addon message prefix for syncing
C_ChatInfo.RegisterAddonMessagePrefix(SYNC_PREFIX)

-- Leaderboard periods, shown in the karma window and accepted by /gk report
local PERIODS = {
	{ label = "All time" },
	{ label = "Last 30 days", key = "month", days = 30 },
	{ label = "Last 7 days", key = "week", days = 7 },
}

-- Karma holders (all time, or over the last `days` days) sorted highest first, each
-- with a place. Tied karma shares a place (1, 2, 2, 4); players with no karma aren't ranked.
local function BuildLeaderboard(days)
	local leaderboard = {}
	for name, karma in pairs(GetKarmaCounts(days)) do
		if karma > 0 then
			table.insert(leaderboard, { name = name, karma = karma })
		end
	end

	table.sort(leaderboard, function(a, b)
		if a.karma ~= b.karma then
			return a.karma > b.karma
		end
		return a.name < b.name
	end)

	for i, entry in ipairs(leaderboard) do
		local previous = leaderboard[i - 1]
		entry.place = (previous and previous.karma == entry.karma) and previous.place or i
	end

	return leaderboard
end

-- Post the top 10 karma holders (all time, or over the last `days` days) to guild chat
local function ReportTop10(days)
	if not InitializeGuildDB() then
		Print("You must be in a guild to use this addon.")
		return
	end

	local leaderboard = BuildLeaderboard(days)
	if #leaderboard == 0 then
		SendChat(days and "No karma in the last " .. days .. " days!" or "No karma recorded yet!", "GUILD")
		return
	end

	-- Send header immediately
	SendChat(days and "=== Top 10 Karma: Last " .. days .. " Days ===" or "=== Top 10 Karma Holders ===", "GUILD")

	-- Send each entry with a 0.5 second delay
	local delay = 0.5
	for i = 1, math.min(10, #leaderboard) do
		local entry = leaderboard[i]
		C_Timer.After(delay * i, function()
			SendChat(entry.place .. ". " .. entry.name .. ": " .. entry.karma, "GUILD")
		end)
	end
end

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
		local leaderboard = BuildLeaderboard()

		Print("Top Karma Holders:")
		for i = 1, math.min(10, #leaderboard) do
			local entry = leaderboard[i]
			print("  " .. entry.place .. ". " .. entry.name .. ": " .. entry.karma)
		end

		if #leaderboard == 0 then
			Print("No karma recorded yet!")
		end
	end
end

-- How long ago a server time was, e.g. "5m", "3h", "2d"
local function FormatAgo(t)
	local seconds = math.max(0, GetServerTime() - t)
	if seconds < 3600 then
		return math.max(1, math.floor(seconds / 60)) .. "m"
	elseif seconds < DAY then
		return math.floor(seconds / 3600) .. "h"
	end
	return math.floor(seconds / DAY) .. "d"
end

-- One line describing a karma event, e.g. "Bob -> Cut Loss (2h ago): for the heals"
local function DescribeEvent(event)
	local line = event.from .. " -> " .. event.to .. " (" .. FormatAgo(event.t) .. " ago)"
	if event.reason then
		line = line .. ": " .. event.reason
	end
	return line
end

-- Print recent karma events for the guild or one player
local function ShowHistory(playerName)
	if not InitializeGuildDB() then
		Print("You must be in a guild to use this addon.")
		return
	end

	local name = playerName and NormalizeName(playerName)
	local history = GetHistory(name, 10)
	if #history == 0 then
		Print(name and "No recent karma for " .. name .. "." or "No recent karma.")
		return
	end

	Print(name and "Recent karma for " .. name .. ":" or "Recent karma:")
	for _, event in ipairs(history) do
		print("  " .. DescribeEvent(event))
	end
end

-- Slash command handler
local function SlashCommandHandler(msg)
	msg = msg:trim()

	if msg == "help" then
		Print("Commands:")
		print("  /gk ui - Open the karma window")
		print("  /gk shop - Spend karma on guild bank items")
		print("  /gk professions - See who in the guild has which profession")
		print("  /gk events - Schedule dungeons and raids, and sign up")
		print("  /gk minimap - Show or hide the minimap button")
		print("  /gk - Show top 10 karma holders")
		print("  /gk <playername> - Show karma for specific player")
		print("  /gk report - Report top 10 to guild chat")
		print("  /gk report week | month - Report the top 10 for the last 7 or 30 days")
		print("  /gk report <playername> - Report specific player's karma to guild chat")
		print("  /gk history [playername] - Show recent karma and the reasons given")
		print("  /gk sync - Sync karma data with other guild members")
		print("  /gk debug <name> - Test if a name is found in guild roster")
		print("  /gk simulate <sender>: <message> - Test a guild chat line on your client only")
		print("  /gk reset - Reset all karma for the guild (guild leader only)")
		print("Add a reason after ++, e.g. 'Name++ for the heals'. The same person can")
		print("  give the same player karma once every " .. KARMA_COOLDOWN / 60 .. " minutes")
		print("Guild members can type 'guildkarma' in guild chat to check their karma")
		print("Guild members can type 'gk update' in guild chat to trigger a sync")
	elseif msg == "ui" then
		ns.ToggleUI()
	elseif msg == "shop" then
		ns.ShowTab("Shop")
	elseif msg == "professions" or msg == "prof" then
		ns.ShowTab("Professions")
	elseif msg == "events" or msg == "calendar" then
		ns.ShowTab("Events")
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
	elseif msg:match("^simulate%s+") then
		-- Solo testing: run a guild chat line from another member through the addon locally
		local senderName, text = msg:match("^simulate%s+(.-):%s*(.+)$")
		local isInGuild, properName = IsGuildMember(senderName or "")
		if not text then
			Print("Usage: /gk simulate Sender Name: Someone++ reason")
		elseif not isInGuild then
			Print("'" .. senderName .. "' isn't in your guild.")
		else
			Print("Simulating guild chat from " .. properName .. ": " .. text)
			ParseMessage(text, properName, true)
		end
	elseif msg == "history" or msg:match("^history%s+") then
		ShowHistory(msg:match("^history%s+(.+)$"))
	elseif msg:match("^report") then
		local playerName = msg:match("^report%s+(.+)$")
		local period = nil
		for _, p in ipairs(PERIODS) do
			if p.key and playerName == p.key then
				period = p
			end
		end
		if period then
			ReportTop10(period.days)
		elseif playerName and playerName ~= "" then
			-- Report specific player to guild chat
			ReportKarma(playerName)
		else
			ReportTop10()
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
ns.BuildLeaderboard = BuildLeaderboard
ns.ReportTop10 = ReportTop10
ns.PERIODS = PERIODS
ns.GetKarmaCounts = GetKarmaCounts
ns.GetHistory = GetHistory
ns.FormatAgo = FormatAgo
ns.IsGuildMember = IsGuildMember
ns.IsOnline = IsOnline
ns.PlayerName = PlayerName
ns.UnitRosterName = UnitRosterName
ns.IsMe = IsMe
ns.NotifyChanged = NotifyChanged
ns.NextRev = NextRev
ns.QueueAddonMessage = QueueAddonMessage
ns.PlainText = CleanReason

-- Handle addon messages of a type, e.g. "PROF" for "PROF:...". The handler gets
-- the text after the colon and the sender's short name.
function ns.RegisterMessageHandler(kind, handler)
	messageHandlers[kind] = handler
end

-- Run a function whenever we ask the guild for a sync
function ns.OnSyncRequest(hook)
	table.insert(syncHooks, hook)
end

-- Shared per-guild data that isn't karma totals, or nil when not in a guild
function ns.GetGuildMeta()
	local guildName = InitializeGuildDB()
	return guildName and GuildKarmaMetaDB[guildName]
end

-- Karma table for the current guild, or nil when not in a guild
function ns.GetGuildDB()
	local guildName = InitializeGuildDB()
	return guildName and GuildKarmaDB[guildName]
end
