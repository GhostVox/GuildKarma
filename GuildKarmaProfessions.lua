-- GuildKarmaProfessions: Shares each member's professions and lists who can craft what

local addonName, ns = ...

local BROADCAST_DELAY = 5 -- Seconds to wait for skill changes to settle before sharing them

-- English profession names, for clients without GetProfessions (Classic Era, Forever, TBC, Wrath)
local PROFESSION_NAMES = {
	Alchemy = true,
	Blacksmithing = true,
	Enchanting = true,
	Engineering = true,
	Herbalism = true,
	Inscription = true,
	Jewelcrafting = true,
	Leatherworking = true,
	Mining = true,
	Skinning = true,
	Tailoring = true,
	Cooking = true,
	["First Aid"] = true,
	Fishing = true,
}

local broadcastTimer = nil

-- Known professions per player: { updated = server time, list = { { name, rank, max }, ... } }
local function GetProfessionDB()
	local meta = ns.GetGuildMeta()
	if not meta then
		return nil
	end
	meta.professions = meta.professions or {}
	return meta.professions
end

-- Read the player's own professions, sorted by name
local function ReadOwnProfessions()
	local list = {}
	if GetProfessions and GetProfessionInfo then
		local indexes = { GetProfessions() }
		for i = 1, 5 do
			if indexes[i] then
				local name, _, rank, maxRank = GetProfessionInfo(indexes[i])
				if name then
					table.insert(list, { name = name, rank = rank or 0, max = maxRank or 0 })
				end
			end
		end
	elseif GetNumSkillLines and GetSkillLineInfo then
		-- Professions sit under the "Professions" and "Secondary Skills" headers
		local header
		for i = 1, GetNumSkillLines() do
			local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
			if isHeader then
				header = name
			elseif name and (PROFESSION_NAMES[name] or (header and (header == TRADE_SKILLS or header == SECONDARY_SKILLS))) then
				table.insert(list, { name = name, rank = rank or 0, max = maxRank or 0 })
			end
		end
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	return list
end

-- "Alchemy:250:300,Herbalism:300:300"
local function SerializeList(list)
	local parts = {}
	for _, profession in ipairs(list) do
		table.insert(parts, profession.name .. ":" .. profession.rank .. ":" .. profession.max)
	end
	return table.concat(parts, ",")
end

local function ParseList(text)
	local list = {}
	for entry in text:gmatch("[^,]+") do
		local name, rank, max = entry:match("^(.-):(%d+):(%d+)$")
		if name and name ~= "" then
			table.insert(list, { name = name, rank = tonumber(rank), max = tonumber(max) })
		end
	end
	return list
end

-- "PROF:name~updated~list"
local function SendRecord(name, record)
	ns.QueueAddonMessage("PROF:" .. name .. "~" .. record.updated .. "~" .. SerializeList(record.list))
end

-- Store a player's professions if newer than what we have. Returns true if stored.
local function StoreRecord(name, updated, list)
	local db = GetProfessionDB()
	if not db then
		return false
	end
	local current = db[name]
	if current and current.updated >= updated then
		return false
	end
	db[name] = { updated = updated, list = list }
	ns.NotifyChanged()
	return true
end

-- Re-read our professions and share them if they changed (or always, when forced)
local function UpdateOwnProfessions(forceSend)
	local db = GetProfessionDB()
	if not db then
		return
	end

	local me = ns.NormalizeName(UnitName("player"))
	local list = ReadOwnProfessions()
	local current = db[me]
	if not current or SerializeList(current.list) ~= SerializeList(list) then
		db[me] = { updated = ns.NextRev(current and current.updated), list = list }
		ns.NotifyChanged()
		forceSend = true
	end
	if forceSend then
		SendRecord(me, db[me])
	end
end

-- Share our professions shortly after skills change, batching bursts of updates
local function ScheduleUpdate()
	if broadcastTimer then
		broadcastTimer:Cancel()
	end
	broadcastTimer = C_Timer.NewTimer(BROADCAST_DELAY, function()
		broadcastTimer = nil
		UpdateOwnProfessions(false)
	end)
end

ns.RegisterMessageHandler("PROF", function(body)
	local name, updated, list = body:match("^([^~]+)~(%d+)~(.*)$")
	if name then
		StoreRecord(name, tonumber(updated), ParseList(list))
	end
end)

-- Answer a sync with our own professions, plus those of offline members, who
-- can't answer for themselves
ns.RegisterMessageHandler("PROFREQ", function(_, sender)
	local db = GetProfessionDB()
	if not db or sender:lower() == UnitName("player"):lower() then
		return
	end
	UpdateOwnProfessions(true)
	local me = ns.NormalizeName(UnitName("player"))
	for name, record in pairs(db) do
		if name ~= me and not ns.IsOnline(name:lower()) then
			SendRecord(name, record)
		end
	end
end)

ns.OnSyncRequest(function()
	UpdateOwnProfessions(true)
	C_ChatInfo.SendAddonMessage("GuildKarmaSync", "PROFREQ", "GUILD")
end)

-- Guild members with professions, grouped by profession: { { name, members = { ... } }, ... }
function ns.GetProfessionGroups()
	local db = GetProfessionDB()
	if not db then
		return {}
	end

	local groups, byName = {}, {}
	for i = 1, GetNumGuildMembers() do
		local fullName, _, _, _, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
		local name = fullName and ns.NormalizeName(fullName)
		local record = name and db[name]
		if record then
			for _, profession in ipairs(record.list) do
				local group = byName[profession.name]
				if not group then
					group = { name = profession.name, members = {} }
					byName[profession.name] = group
					table.insert(groups, group)
				end
				table.insert(group.members, {
					name = ns.ShortName(fullName),
					rank = profession.rank,
					max = profession.max,
					online = online,
					classFile = classFile,
					updated = record.updated,
				})
			end
		end
	end

	table.sort(groups, function(a, b)
		return a.name < b.name
	end)
	for _, group in ipairs(groups) do
		table.sort(group.members, function(a, b)
			if a.rank ~= b.rank then
				return a.rank > b.rank
			end
			return a.name < b.name
		end)
	end
	return groups
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:SetScript("OnEvent", function(self, event, isLogin)
	if event == "SKILL_LINES_CHANGED" or isLogin then
		ScheduleUpdate()
	end
end)

---------------------------------------------------------------------------
-- Professions tab
---------------------------------------------------------------------------

local W = ns.Widgets
local HEADER_HEIGHT = 26
local rows = {}
local filterText = ""

local function GetRow(content, index)
	if rows[index] then
		return rows[index]
	end

	local row = CreateFrame("Frame", nil, content)
	row:SetSize(W.CONTENT_WIDTH, W.ROW_HEIGHT)

	row.headerBg = row:CreateTexture(nil, "BACKGROUND")
	row.headerBg:SetAllPoints()
	row.headerBg:SetColorTexture(1, 0.82, 0, 0.08)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 20, 0)
	row.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")

	row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.label:SetJustifyH("LEFT")

	row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.value:SetPoint("RIGHT", -10, 0)

	rows[index] = row
	return row
end

local function RefreshProfessions(page)
	local lines = {}
	for _, group in ipairs(ns.GetProfessionGroups()) do
		local groupMatches = group.name:lower():find(filterText, 1, true)
		local members = {}
		for _, member in ipairs(group.members) do
			if groupMatches or member.name:lower():find(filterText, 1, true) then
				table.insert(members, member)
			end
		end
		if #members > 0 then
			table.insert(lines, { header = group.name, count = #members })
			for _, member in ipairs(members) do
				table.insert(lines, { member = member })
			end
		end
	end

	local y = 0
	for i, line in ipairs(lines) do
		local row = GetRow(page.content, i)
		local height = line.header and HEADER_HEIGHT or W.ROW_HEIGHT
		row:SetHeight(height)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -y)
		y = y + height

		row.label:ClearAllPoints()
		if line.header then
			row.headerBg:Show()
			row.icon:Hide()
			row.label:SetFontObject(GameFontNormal)
			row.label:SetPoint("LEFT", 8, 0)
			row.label:SetText(line.header)
			row.label:SetTextColor(1, 0.82, 0)
			row.value:SetText(line.count .. (line.count == 1 and " member" or " members"))
			row.value:SetTextColor(0.6, 0.6, 0.6)
		else
			local member = line.member
			row.headerBg:Hide()
			W.SetClassIcon(row.icon, member.classFile)
			row.icon:SetDesaturated(not member.online)
			row.label:SetFontObject(GameFontHighlight)
			row.label:SetPoint("LEFT", 42, 0)
			row.label:SetText(member.name)
			local color = member.classFile and RAID_CLASS_COLORS[member.classFile]
			if not member.online then
				row.label:SetTextColor(0.5, 0.5, 0.5)
			elseif color then
				row.label:SetTextColor(color.r, color.g, color.b)
			else
				row.label:SetTextColor(1, 1, 1)
			end
			row.value:SetText(member.max > 0 and (member.rank .. " / " .. member.max) or tostring(member.rank))
			row.value:SetTextColor(1, 1, 1)
		end
		row:Show()
	end
	for i = #lines + 1, #rows do
		rows[i]:Hide()
	end
	page.content:SetHeight(math.max(1, y))
	page.empty:SetShown(#lines == 0)
end

ns.AddTab("Professions", function(parent)
	local page = CreateFrame("Frame", nil, parent)

	local search = W.CreateSearchBox(page, "Search professions or members", function(text)
		filterText = text
		ns.OnDataChanged()
	end)
	search:SetPoint("TOPLEFT", 12, -6)
	search:SetWidth(220)

	local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPRIGHT", -14, -12)
	hint:SetText("Shared by members running the addon")

	local scroll
	scroll, page.content = W.CreateScrollList(page, "GuildKarmaProfessionsScroll")
	scroll:SetPoint("TOPLEFT", 10, -36)
	scroll:SetPoint("BOTTOMRIGHT", -24, 4)

	page.empty = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	page.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
	page.empty:SetText("No professions shared yet.")

	page.Refresh = RefreshProfessions
	return page
end)
