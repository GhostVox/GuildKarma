-- GuildKarmaUI: Window for viewing karma and, for the guild leader, managing it

local addonName, ns = ...

local FRAME_WIDTH = 400
local FRAME_HEIGHT = 480
local ROW_HEIGHT = 20
local CONTENT_WIDTH = FRAME_WIDTH - 52
local MAX_KARMA = 999999
local REPORT_COOLDOWN = 10 -- Seconds before "Post Top 10" can be used again

-- Gold, silver, and bronze for the top three places
local PLACE_COLORS = {
	{ 1, 0.82, 0 },
	{ 0.78, 0.8, 0.86 },
	{ 0.8, 0.5, 0.2 },
}

local sortByName = false
local filterText = ""
local rows = {}
local ui, content

-- Account-wide settings, loaded from SavedVariables
local function GetSettings()
	GuildKarmaSettings = GuildKarmaSettings or {}
	return GuildKarmaSettings
end

-- Get the edit box of a StaticPopup across client versions
local function GetPopupEditBox(popup)
	return (popup.GetEditBox and popup:GetEditBox()) or popup.editBox or popup.EditBox
end

-- Apply the value typed into the "Set karma" popup
local function ApplySetKarma(popup, playerName)
	local value = tonumber(GetPopupEditBox(popup):GetText())
	if value then
		ns.SetKarma(playerName, math.min(value, MAX_KARMA))
	end
end

StaticPopupDialogs["GUILDKARMA_SET"] = {
	text = "Set karma for %s:",
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = true,
	maxLetters = 6,
	OnShow = function(self, data)
		local playerName = data or self.data
		local db = ns.GetGuildDB()
		local editBox = GetPopupEditBox(self)
		editBox:SetText(tostring(db and db[playerName] or 0))
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	OnAccept = function(self, data)
		ApplySetKarma(self, data or self.data)
	end,
	EditBoxOnEnterPressed = function(self, data)
		local popup = self:GetParent()
		ApplySetKarma(popup, data or popup.data)
		popup:Hide()
	end,
	EditBoxOnEscapePressed = function(self)
		self:GetParent():Hide()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["GUILDKARMA_RESET_ALL"] = {
	text = "Reset karma for ALL guild members?\n\nThis syncs to every addon user and cannot be undone.",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		ns.ResetAllKarma()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
	preferredIndex = 3,
}

-- Collect guild members (plus former members who still have karma), filtered and sorted
local function BuildEntries()
	local db = ns.GetGuildDB()
	if not db then
		return {}
	end

	-- Places come from the whole guild, so they stay put while searching or sorting by name
	local places = {}
	for _, entry in ipairs(ns.BuildLeaderboard()) do
		places[entry.name] = entry.place
	end

	local entries = {}
	local seen = {}
	for i = 1, GetNumGuildMembers() do
		local fullName, rankName, _, _, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
		if fullName then
			local name = ns.NormalizeName(fullName)
			if not seen[name] then
				seen[name] = true
				table.insert(entries, {
					name = ns.ShortName(fullName),
					key = name,
					karma = db[name] or 0,
					place = places[name],
					rank = rankName,
					online = online,
					classFile = classFile,
					inGuild = true,
				})
			end
		end
	end
	for name, karma in pairs(db) do
		if not seen[name] and karma > 0 then
			table.insert(entries, { name = name, key = name, karma = karma, place = places[name], inGuild = false })
		end
	end

	local hideZero = GetSettings().hideZeroKarma
	if filterText ~= "" or hideZero then
		local filtered = {}
		for _, entry in ipairs(entries) do
			if (not hideZero or entry.karma > 0) and entry.name:lower():find(filterText, 1, true) then
				table.insert(filtered, entry)
			end
		end
		entries = filtered
	end

	table.sort(entries, function(a, b)
		if not sortByName and a.karma ~= b.karma then
			return a.karma > b.karma
		end
		return a.name < b.name
	end)

	return entries
end

local function ShowRowTooltip(row)
	local entry = row.entry
	if not entry then
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(entry.name)
	if entry.place then
		GameTooltip:AddLine("Leaderboard place: " .. entry.place, 1, 0.82, 0)
	end
	if entry.inGuild then
		GameTooltip:AddLine(entry.rank or "", 1, 1, 1)
		GameTooltip:AddLine(entry.online and "Online" or "Offline", 0.7, 0.7, 0.7)
	else
		GameTooltip:AddLine("No longer in the guild", 0.7, 0.7, 0.7)
	end
	GameTooltip:AddLine(entry.karma .. " karma", 0, 1, 0)
	GameTooltip:Show()
end

local function CreateSmallButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, ROW_HEIGHT - 2)
	button:SetText(text)
	return button
end

local function GetRow(index)
	if rows[index] then
		return rows[index]
	end

	local row = CreateFrame("Frame", nil, content)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:EnableMouse(true)
	row:SetScript("OnEnter", ShowRowTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide)

	if index % 2 == 0 then
		local stripe = row:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, 0.05)
	end

	row.position = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.position:SetPoint("LEFT", 2, 0)
	row.position:SetWidth(28)
	row.position:SetJustifyH("RIGHT")

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", 36, 0)
	row.name:SetWidth(150)
	row.name:SetJustifyH("LEFT")

	row.karma = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.karma:SetJustifyH("RIGHT")

	-- Guild leader controls
	row.set = CreateSmallButton(row, "Set", 40)
	row.set:SetPoint("RIGHT", -2, 0)
	row.set:SetScript("OnClick", function()
		StaticPopup_Show("GUILDKARMA_SET", row.entry.name, nil, row.entry.key)
	end)

	row.plus = CreateSmallButton(row, "+", 24)
	row.plus:SetPoint("RIGHT", row.set, "LEFT", -2, 0)
	row.plus:SetScript("OnClick", function()
		ns.SetKarma(row.entry.key, math.min(row.entry.karma + 1, MAX_KARMA))
	end)

	row.minus = CreateSmallButton(row, "-", 24)
	row.minus:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
	row.minus:SetScript("OnClick", function()
		ns.SetKarma(row.entry.key, row.entry.karma - 1)
	end)

	rows[index] = row
	return row
end

local function Refresh()
	if not ui or not ui:IsShown() then
		return
	end

	local inGuild = ns.GetGuildDB() ~= nil
	local canManage = ns.CanManage()
	local entries = BuildEntries()
	local totalKarma = 0

	for i, entry in ipairs(entries) do
		local row = GetRow(i)
		row.entry = entry
		totalKarma = totalKarma + entry.karma

		row.position:SetText(entry.place and entry.place .. "." or "")
		local placeColor = entry.place and PLACE_COLORS[entry.place]
		if placeColor then
			row.position:SetTextColor(placeColor[1], placeColor[2], placeColor[3])
			row.karma:SetTextColor(placeColor[1], placeColor[2], placeColor[3])
		else
			row.position:SetTextColor(0.7, 0.7, 0.7)
			row.karma:SetTextColor(1, 1, 1)
		end
		row.name:SetText(entry.inGuild and entry.name or entry.name .. " (left)")
		local color = entry.classFile and RAID_CLASS_COLORS[entry.classFile]
		if not entry.inGuild or not entry.online then
			row.name:SetTextColor(0.5, 0.5, 0.5)
		elseif color then
			row.name:SetTextColor(color.r, color.g, color.b)
		else
			row.name:SetTextColor(1, 1, 1)
		end

		row.karma:SetText(entry.karma)
		row.karma:ClearAllPoints()
		if canManage then
			row.karma:SetPoint("RIGHT", row.minus, "LEFT", -8, 0)
		else
			row.karma:SetPoint("RIGHT", -8, 0)
		end
		row.minus:SetShown(canManage)
		row.plus:SetShown(canManage)
		row.set:SetShown(canManage)
		row.minus:SetEnabled(entry.karma > 0)

		row:Show()
	end
	for i = #entries + 1, #rows do
		rows[i]:Hide()
		rows[i].entry = nil
	end
	content:SetHeight(math.max(1, #entries * ROW_HEIGHT))

	if not inGuild then
		ui.status:SetText("You are not in a guild.")
	else
		ui.status:SetText(#entries .. " shown  |  " .. totalKarma .. " karma")
	end
	ui.leaderNote:SetShown(canManage)
	ui.resetAll:SetShown(canManage)
	ui.sortButton:SetText(sortByName and "Sort: Name" or "Sort: Karma")
end

local function CreateUI()
	ui = CreateFrame("Frame", "GuildKarmaFrame", UIParent, "BasicFrameTemplateWithInset")
	ui:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	ui:SetPoint("CENTER")
	ui:SetFrameStrata("HIGH")
	ui:SetClampedToScreen(true)
	ui:SetMovable(true)
	ui:EnableMouse(true)
	ui:RegisterForDrag("LeftButton")
	ui:SetScript("OnDragStart", ui.StartMoving)
	ui:SetScript("OnDragStop", ui.StopMovingOrSizing)
	ui:SetScript("OnShow", function()
		ns.RequestGuildRoster()
		Refresh()
	end)
	ui:Hide()
	-- Close with Escape
	table.insert(UISpecialFrames, "GuildKarmaFrame")

	local title = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText("Guild Karma")

	-- Search box
	local search = CreateFrame("EditBox", nil, ui, "InputBoxTemplate")
	search:SetSize(160, 20)
	search:SetPoint("TOPLEFT", 20, -32)
	search:SetAutoFocus(false)
	search:SetScript("OnTextChanged", function(self)
		filterText = self:GetText():lower()
		self.placeholder:SetShown(self:GetText() == "")
		Refresh()
	end)
	search:SetScript("OnEscapePressed", search.ClearFocus)
	search:SetScript("OnEnterPressed", search.ClearFocus)
	search.placeholder = search:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	search.placeholder:SetPoint("LEFT", 2, 0)
	search.placeholder:SetText("Search members")

	ui.sortButton = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
	ui.sortButton:SetSize(100, 22)
	ui.sortButton:SetPoint("TOPRIGHT", -14, -31)
	ui.sortButton:SetScript("OnClick", function()
		sortByName = not sortByName
		Refresh()
	end)

	local hideZero = CreateFrame("CheckButton", nil, ui, "UICheckButtonTemplate")
	hideZero:SetSize(24, 24)
	hideZero:SetPoint("TOPLEFT", 14, -54)
	hideZero:SetChecked(GetSettings().hideZeroKarma)
	hideZero:SetScript("OnClick", function(self)
		GetSettings().hideZeroKarma = self:GetChecked() and true or false
		Refresh()
	end)
	local hideZeroLabel = hideZero:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hideZeroLabel:SetPoint("LEFT", hideZero, "RIGHT", 2, 0)
	hideZeroLabel:SetText("Hide 0 karma")

	ui.status = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.status:SetPoint("TOPRIGHT", -18, -61)

	-- Scrolling member list
	local scroll = CreateFrame("ScrollFrame", "GuildKarmaScrollFrame", ui, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -82)
	scroll:SetPoint("BOTTOMRIGHT", -34, 56)

	ui.leaderNote = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.leaderNote:SetPoint("BOTTOMLEFT", 16, 40)
	ui.leaderNote:SetText("Guild leader: use - / + / Set to edit karma")
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(CONTENT_WIDTH, 1)
	scroll:SetScrollChild(content)

	local sync = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
	sync:SetSize(80, 22)
	sync:SetPoint("BOTTOMLEFT", 12, 12)
	sync:SetText("Sync")
	sync:SetScript("OnClick", function()
		ns.RequestSync()
	end)

	local report = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
	report:SetSize(100, 22)
	report:SetPoint("LEFT", sync, "RIGHT", 6, 0)
	report:SetText("Post Top 10")
	report:SetScript("OnClick", function(self)
		ns.ReportTop10()
		-- Brief cooldown so the leaderboard can't be spammed into guild chat
		self:Disable()
		C_Timer.After(REPORT_COOLDOWN, function()
			self:Enable()
		end)
	end)

	ui.resetAll = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
	ui.resetAll:SetSize(90, 22)
	ui.resetAll:SetPoint("BOTTOMRIGHT", -12, 12)
	ui.resetAll:SetText("Reset All")
	ui.resetAll:SetScript("OnClick", function()
		StaticPopup_Show("GUILDKARMA_RESET_ALL")
	end)
end

function ns.ToggleUI()
	if not ui then
		CreateUI()
	end
	ui:SetShown(not ui:IsShown())
end

ns.OnDataChanged = Refresh
