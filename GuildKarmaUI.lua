-- GuildKarmaUI: Window for viewing karma and, for the guild leader, managing it

local addonName, ns = ...

local FRAME_WIDTH = 460
local FRAME_HEIGHT = 540
local ROW_HEIGHT = 22
local EVENT_ROW_HEIGHT = 34
local SCROLLBAR_WIDTH = 6
local CONTENT_WIDTH = FRAME_WIDTH - 34
local MAX_KARMA = 999999
local REPORT_COOLDOWN = 10 -- Seconds before "Post Top 10" can be used again
local HISTORY_TOOLTIP_LINES = 5
local ACTIVITY_LIMIT = 100 -- Most events shown on the Activity tab

-- Gold, silver, and bronze for the top three places
local PLACE_COLORS = {
	{ 1, 0.82, 0 },
	{ 0.78, 0.8, 0.86 },
	{ 0.8, 0.5, 0.2 },
}

-- Window colors
local COLOR_BG = { 0.06, 0.06, 0.08, 0.96 }
local COLOR_TITLE = { 0.1, 0.1, 0.13, 1 }
local COLOR_BORDER = { 0.25, 0.25, 0.3, 1 }
local COLOR_BUTTON = { 0.14, 0.14, 0.17, 1 }
local COLOR_ACCENT = { 1, 0.82, 0 }

-- Window tabs: { label, create = function(parent) returning a page with :Refresh() }.
-- Feature files add theirs with ns.AddTab before the window is first opened.
local tabs = {}

local sortByName = false
local filterText = ""
local leaderboardRows = {}
local activityRows = {}
local classByName = {}
local ui, pages, tabButtons

-- Account-wide settings, loaded from SavedVariables
local function GetSettings()
	GuildKarmaSettings = GuildKarmaSettings or {}
	GuildKarmaSettings.period = GuildKarmaSettings.period or 1
	GuildKarmaSettings.tab = GuildKarmaSettings.tab or 1
	return GuildKarmaSettings
end

local function GetPeriod()
	return ns.PERIODS[GetSettings().period] or ns.PERIODS[1]
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

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local function SetColor(texture, color)
	texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
end

-- A 1px border drawn inside a frame's edges
local function AddBorder(frame, color)
	local edges = {
		{ "TOPLEFT", "TOPRIGHT", nil, 1 },
		{ "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
		{ "TOPLEFT", "BOTTOMLEFT", 1, nil },
		{ "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
	}
	for _, edge in ipairs(edges) do
		local line = frame:CreateTexture(nil, "BORDER")
		SetColor(line, color)
		line:SetPoint(edge[1])
		line:SetPoint(edge[2])
		if edge[3] then
			line:SetWidth(edge[3])
		else
			line:SetHeight(edge[4])
		end
	end
end

-- A flat dark button with a hover highlight
local function CreateFlatButton(parent, text, width, height)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(width, height or 22)

	button.bg = button:CreateTexture(nil, "BACKGROUND")
	button.bg:SetAllPoints()
	SetColor(button.bg, COLOR_BUTTON)
	AddBorder(button, COLOR_BORDER)

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.08)

	button:SetNormalFontObject(GameFontHighlightSmall)
	button:SetHighlightFontObject(GameFontHighlightSmall)
	button:SetDisabledFontObject(GameFontDisableSmall)
	button:SetText(text)
	return button
end

-- Show a short tooltip on a widget
local function SetTooltip(widget, title, text)
	widget:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(title)
		if text then
			GameTooltip:AddLine(text, 1, 1, 1, true)
		end
		GameTooltip:Show()
	end)
	widget:SetScript("OnLeave", GameTooltip_Hide)
end

-- A scrolling list area with a slim scroll bar that only shows when the list
-- is taller than the view; returns the scroll frame and its content frame
local function CreateScrollList(parent, name)
	local scroll = CreateFrame("ScrollFrame", name, parent)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(CONTENT_WIDTH, 1)
	scroll:SetScrollChild(content)

	local bar = CreateFrame("Frame", nil, parent)
	bar:SetWidth(SCROLLBAR_WIDTH)
	bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(1, 1, 1, 0.04)

	local thumb = CreateFrame("Frame", nil, bar)
	thumb:SetWidth(SCROLLBAR_WIDTH)
	thumb:EnableMouse(true)
	local thumbTexture = thumb:CreateTexture(nil, "ARTWORK")
	thumbTexture:SetAllPoints()
	SetColor(thumbTexture, COLOR_BORDER)

	-- Size and place the thumb to match the scroll position
	local function UpdateBar()
		local range = scroll:GetVerticalScrollRange()
		bar:SetShown(range > 0)
		if range <= 0 then
			return
		end
		local viewHeight = scroll:GetHeight()
		local barHeight = bar:GetHeight()
		local thumbHeight = math.max(24, barHeight * viewHeight / (viewHeight + range))
		thumb:SetHeight(thumbHeight)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", bar, "TOP", 0, -(barHeight - thumbHeight) * scroll:GetVerticalScroll() / range)
	end

	local function ScrollTo(offset)
		scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScrollRange(), offset)))
		UpdateBar()
	end

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		ScrollTo(self:GetVerticalScroll() - delta * ROW_HEIGHT * 3)
	end)
	scroll:SetScript("OnScrollRangeChanged", function(self)
		ScrollTo(self:GetVerticalScroll())
	end)
	scroll:SetScript("OnSizeChanged", UpdateBar)

	-- Drag the thumb to scroll
	thumb:SetScript("OnEnter", function()
		thumbTexture:SetColorTexture(COLOR_ACCENT[1], COLOR_ACCENT[2], COLOR_ACCENT[3], 0.6)
	end)
	thumb:SetScript("OnLeave", function()
		SetColor(thumbTexture, COLOR_BORDER)
	end)
	thumb:SetScript("OnMouseDown", function(self)
		local _, startY = GetCursorPosition()
		local startOffset = scroll:GetVerticalScroll()
		local scale = self:GetEffectiveScale()
		self:SetScript("OnUpdate", function()
			local _, cursorY = GetCursorPosition()
			local travel = bar:GetHeight() - self:GetHeight()
			if travel > 0 then
				ScrollTo(startOffset + (startY - cursorY) / scale * scroll:GetVerticalScrollRange() / travel)
			end
		end)
	end)
	thumb:SetScript("OnMouseUp", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	UpdateBar()
	return scroll, content
end

-- A flat text box. With a placeholder it acts as a search box, calling
-- onChange with the lowercased text.
local function CreateEditBox(parent, width, placeholder, onChange)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(width, 22)
	box:SetFontObject(ChatFontNormal)
	box:SetTextInsets(8, 8, 0, 0)
	box:SetAutoFocus(false)
	local bg = box:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	SetColor(bg, COLOR_BUTTON)
	AddBorder(box, COLOR_BORDER)
	box.placeholder = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	box.placeholder:SetPoint("LEFT", 8, 0)
	box.placeholder:SetText(placeholder or "")
	box:SetScript("OnTextChanged", function(self)
		self.placeholder:SetShown(self:GetText() == "")
		if onChange then
			onChange(self:GetText():lower())
		end
	end)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnEnterPressed", box.ClearFocus)
	return box
end

local function CreateSearchBox(parent, placeholder, onChange)
	return CreateEditBox(parent, 170, placeholder, onChange)
end

-- Set a class icon texture, hiding it when the class is unknown
local function SetClassIcon(texture, classFile)
	local coords = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
	if coords then
		texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
		texture:Show()
	else
		texture:Hide()
	end
end

-- A player name wrapped in their class color, when known
local function ColoredName(name)
	local color = classByName[name] and RAID_CLASS_COLORS[classByName[name]]
	if color then
		return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
	end
	return name
end

---------------------------------------------------------------------------
-- Leaderboard tab
---------------------------------------------------------------------------

-- Collect guild members (plus former members who still have karma), filtered and sorted
local function BuildEntries()
	local db = ns.GetGuildDB()
	if not db then
		return {}
	end

	local period = GetPeriod()
	local counts = ns.GetKarmaCounts(period.days)
	local monthCounts = ns.GetKarmaCounts(30)
	local weekCounts = ns.GetKarmaCounts(7)

	-- Places come from the whole guild, so they stay put while searching or sorting by name
	local places = {}
	for _, entry in ipairs(ns.BuildLeaderboard(period.days)) do
		places[entry.name] = entry.place
	end

	local entries = {}
	local seen = {}
	local function AddEntry(entry)
		entry.karma = counts[entry.key] or 0
		entry.allTime = db[entry.key] or 0
		entry.month = monthCounts[entry.key] or 0
		entry.week = weekCounts[entry.key] or 0
		entry.place = places[entry.key]
		table.insert(entries, entry)
	end

	for i = 1, GetNumGuildMembers() do
		local fullName, rankName, _, _, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
		if fullName then
			local name = ns.NormalizeName(fullName)
			classByName[name] = classFile
			if not seen[name] then
				seen[name] = true
				AddEntry({
					name = ns.ShortName(fullName),
					key = name,
					rank = rankName,
					online = online,
					classFile = classFile,
					inGuild = true,
				})
			end
		end
	end
	for name, karma in pairs(counts) do
		if not seen[name] and karma > 0 then
			AddEntry({ name = name, key = name, inGuild = false })
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

local function ShowLeaderboardTooltip(row)
	local entry = row.entry
	if not entry then
		return
	end

	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(ColoredName(entry.name))
	if entry.inGuild then
		GameTooltip:AddLine((entry.rank or "") .. (entry.online and "  |cff00ff00Online|r" or "  |cff888888Offline|r"), 1, 1, 1)
	else
		GameTooltip:AddLine("No longer in the guild", 0.7, 0.7, 0.7)
	end
	if entry.place then
		GameTooltip:AddLine(GetPeriod().label .. " place: " .. entry.place, 1, 0.82, 0)
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("All time", entry.allTime, 0.8, 0.8, 0.8, 1, 1, 1)
	GameTooltip:AddDoubleLine("Last 30 days", entry.month, 0.8, 0.8, 0.8, 1, 1, 1)
	GameTooltip:AddDoubleLine("Last 7 days", entry.week, 0.8, 0.8, 0.8, 1, 1, 1)

	local history = ns.GetHistory(entry.key, HISTORY_TOOLTIP_LINES)
	if #history > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Recent karma", 1, 0.82, 0)
		for _, event in ipairs(history) do
			GameTooltip:AddDoubleLine("from " .. ColoredName(event.from), ns.FormatAgo(event.t) .. " ago", 1, 1, 1, 0.6, 0.6, 0.6)
			if event.reason then
				GameTooltip:AddLine("   " .. event.reason, 0.7, 0.7, 0.7, true)
			end
		end
	end
	GameTooltip:Show()
end

local function GetLeaderboardRow(content, index)
	if leaderboardRows[index] then
		return leaderboardRows[index]
	end

	local row = CreateFrame("Frame", nil, content)
	row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		self.hover:Show()
		ShowLeaderboardTooltip(self)
	end)
	row:SetScript("OnLeave", function(self)
		self.hover:Hide()
		GameTooltip:Hide()
	end)

	if index % 2 == 0 then
		local stripe = row:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, 0.03)
	end
	row.hover = row:CreateTexture(nil, "BACKGROUND")
	row.hover:SetAllPoints()
	row.hover:SetColorTexture(1, 0.82, 0, 0.08)
	row.hover:Hide()

	row.position = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.position:SetPoint("LEFT", 0, 0)
	row.position:SetWidth(26)
	row.position:SetJustifyH("RIGHT")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 32, 0)
	row.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", 54, 0)
	row.name:SetWidth(150)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.rank:SetPoint("LEFT", 208, 0)
	row.rank:SetWidth(84)
	row.rank:SetJustifyH("LEFT")
	row.rank:SetWordWrap(false)

	row.karma = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.karma:SetJustifyH("RIGHT")

	-- Guild leader controls
	row.set = CreateFlatButton(row, "Set", 34, ROW_HEIGHT - 4)
	row.set:SetPoint("RIGHT", -2, 0)
	row.set:SetScript("OnClick", function()
		StaticPopup_Show("GUILDKARMA_SET", row.entry.name, nil, row.entry.key)
	end)

	row.plus = CreateFlatButton(row, "+", 20, ROW_HEIGHT - 4)
	row.plus:SetPoint("RIGHT", row.set, "LEFT", -2, 0)
	row.plus:SetScript("OnClick", function()
		ns.SetKarma(row.entry.key, math.min(row.entry.allTime + 1, MAX_KARMA))
	end)

	row.minus = CreateFlatButton(row, "-", 20, ROW_HEIGHT - 4)
	row.minus:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
	row.minus:SetScript("OnClick", function()
		ns.SetKarma(row.entry.key, row.entry.allTime - 1)
	end)

	leaderboardRows[index] = row
	return row
end

local function RefreshLeaderboard(page)
	-- Karma can only be edited as an all-time total
	local canEdit = ns.CanManage() and not GetPeriod().days
	local entries = BuildEntries()
	local totalKarma = 0

	for i, entry in ipairs(entries) do
		local row = GetLeaderboardRow(page.content, i)
		row.entry = entry
		totalKarma = totalKarma + entry.karma

		row.position:SetText(entry.place and entry.place .. "." or "")
		local placeColor = entry.place and PLACE_COLORS[entry.place]
		if placeColor then
			row.position:SetTextColor(placeColor[1], placeColor[2], placeColor[3])
			row.karma:SetTextColor(placeColor[1], placeColor[2], placeColor[3])
		else
			row.position:SetTextColor(0.5, 0.5, 0.5)
			row.karma:SetTextColor(1, 1, 1)
		end

		SetClassIcon(row.icon, entry.classFile)
		row.icon:SetDesaturated(not entry.online)
		row.name:SetText(entry.inGuild and entry.name or entry.name .. " (left)")
		local color = entry.classFile and RAID_CLASS_COLORS[entry.classFile]
		if not entry.inGuild or not entry.online then
			row.name:SetTextColor(0.5, 0.5, 0.5)
		elseif color then
			row.name:SetTextColor(color.r, color.g, color.b)
		else
			row.name:SetTextColor(1, 1, 1)
		end
		row.rank:SetText(entry.rank or "")

		row.karma:SetText(entry.karma)
		row.karma:ClearAllPoints()
		if canEdit then
			row.karma:SetPoint("RIGHT", row.minus, "LEFT", -8, 0)
		else
			row.karma:SetPoint("RIGHT", -10, 0)
		end
		row.minus:SetShown(canEdit)
		row.plus:SetShown(canEdit)
		row.set:SetShown(canEdit)
		row.minus:SetEnabled(entry.allTime > 0)

		row:Show()
	end
	for i = #entries + 1, #leaderboardRows do
		leaderboardRows[i]:Hide()
		leaderboardRows[i].entry = nil
	end
	page.content:SetHeight(math.max(1, #entries * ROW_HEIGHT))

	page.empty:SetShown(#entries == 0)
	page.status:SetText(#entries .. " shown  |  " .. totalKarma .. " karma")
	page.periodButton:SetText(GetPeriod().label)
	page.sortButton:SetText(sortByName and "Sort: Name" or "Sort: Karma")
end

local function CreateLeaderboardPage(parent)
	local page = CreateFrame("Frame", nil, parent)

	local search = CreateSearchBox(page, "Search members", function(text)
		filterText = text
		ns.OnDataChanged()
	end)
	search:SetPoint("TOPLEFT", 12, -6)

	page.sortButton = CreateFlatButton(page, "", 96)
	page.sortButton:SetPoint("TOPRIGHT", -12, -6)
	page.sortButton:SetScript("OnClick", function()
		sortByName = not sortByName
		ns.OnDataChanged()
	end)

	page.periodButton = CreateFlatButton(page, "", 96)
	page.periodButton:SetPoint("RIGHT", page.sortButton, "LEFT", -6, 0)
	page.periodButton:SetScript("OnClick", function()
		local settings = GetSettings()
		settings.period = settings.period % #ns.PERIODS + 1
		ns.OnDataChanged()
	end)
	SetTooltip(page.periodButton, "Leaderboard period", "Click to switch between all-time karma and karma received in the last 30 or 7 days.")

	local hideZero = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
	hideZero:SetSize(22, 22)
	hideZero:SetPoint("TOPLEFT", 8, -32)
	hideZero:SetChecked(GetSettings().hideZeroKarma)
	hideZero:SetScript("OnClick", function(self)
		GetSettings().hideZeroKarma = self:GetChecked() and true or false
		ns.OnDataChanged()
	end)
	local hideZeroLabel = hideZero:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hideZeroLabel:SetPoint("LEFT", hideZero, "RIGHT", 2, 0)
	hideZeroLabel:SetText("Hide 0 karma")

	page.status = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	page.status:SetPoint("TOPRIGHT", -14, -38)

	-- Column headers
	local headers = {
		{ "#", 14 },
		{ "Name", 58 },
		{ "Rank", 212 },
	}
	for _, header in ipairs(headers) do
		local label = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", header[2], -60)
		label:SetText(header[1])
	end
	local karmaHeader = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	karmaHeader:SetPoint("TOPRIGHT", -28, -60)
	karmaHeader:SetText("Karma")
	local divider = page:CreateTexture(nil, "ARTWORK")
	SetColor(divider, COLOR_BORDER)
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", 10, -74)
	divider:SetPoint("TOPRIGHT", -10, -74)

	local scroll
	scroll, page.content = CreateScrollList(page, "GuildKarmaLeaderboardScroll")
	scroll:SetPoint("TOPLEFT", 10, -78)
	scroll:SetPoint("BOTTOMRIGHT", -24, 4)

	page.empty = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	page.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
	page.empty:SetText("No one matches.")

	page.Refresh = RefreshLeaderboard
	return page
end

---------------------------------------------------------------------------
-- Activity tab
---------------------------------------------------------------------------

local function GetActivityRow(content, index)
	if activityRows[index] then
		return activityRows[index]
	end

	local row = CreateFrame("Frame", nil, content)
	row:SetSize(CONTENT_WIDTH, EVENT_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * EVENT_ROW_HEIGHT)

	if index % 2 == 0 then
		local stripe = row:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, 0.03)
	end

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(14, 14)
	row.icon:SetPoint("TOPLEFT", 6, -4)
	row.icon:SetTexture("Interface\\Icons\\Spell_Holy_GreaterBlessingofKings")
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.text:SetPoint("TOPLEFT", 26, -4)
	row.text:SetPoint("RIGHT", -60, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)

	row.ago = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.ago:SetPoint("TOPRIGHT", -8, -6)

	row.reason = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.reason:SetPoint("TOPLEFT", 26, -19)
	row.reason:SetPoint("RIGHT", -8, 0)
	row.reason:SetJustifyH("LEFT")
	row.reason:SetWordWrap(false)

	activityRows[index] = row
	return row
end

local function RefreshActivity(page)
	local history = ns.GetHistory(nil, ACTIVITY_LIMIT)

	for i, event in ipairs(history) do
		local row = GetActivityRow(page.content, i)
		row.text:SetText(ColoredName(event.from) .. " |cff888888gave karma to|r " .. ColoredName(event.to))
		row.ago:SetText(ns.FormatAgo(event.t) .. " ago")
		row.reason:SetText(event.reason and ("\"" .. event.reason .. "\"") or "|cff555555no reason given|r")
		row:Show()
	end
	for i = #history + 1, #activityRows do
		activityRows[i]:Hide()
	end
	page.content:SetHeight(math.max(1, #history * EVENT_ROW_HEIGHT))
	page.empty:SetShown(#history == 0)
end

local function CreateActivityPage(parent)
	local page = CreateFrame("Frame", nil, parent)

	local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", 14, -10)
	hint:SetText("Recent karma in your guild. Add a reason in chat: Name++ for the heals")

	local scroll
	scroll, page.content = CreateScrollList(page, "GuildKarmaActivityScroll")
	scroll:SetPoint("TOPLEFT", 10, -28)
	scroll:SetPoint("BOTTOMRIGHT", -24, 4)

	page.empty = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	page.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
	page.empty:SetText("No karma given in the last few weeks.")

	page.Refresh = RefreshActivity
	return page
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

-- Header line with the player's own karma
local function RefreshSummary()
	local db = ns.GetGuildDB()
	if not db then
		ui.summary:SetText("You are not in a guild.")
		ui.summaryDetail:SetText("")
		return
	end

	local me = ns.NormalizeName(ns.PlayerName())
	local place
	for _, entry in ipairs(ns.BuildLeaderboard()) do
		if entry.name == me then
			place = entry.place
		end
	end
	ui.summary:SetText("Your karma: |cffffd100" .. (db[me] or 0) .. "|r")
	ui.summaryDetail:SetText(
		(place and "#" .. place .. " all time  |  " or "")
			.. "+" .. (ns.GetKarmaCounts(7)[me] or 0) .. " this week"
	)
end

local function Refresh()
	if not ui or not ui:IsShown() then
		return
	end

	local tab = GetSettings().tab
	for i, page in ipairs(pages) do
		page:SetShown(i == tab)
		tabButtons[i].selected:SetShown(i == tab)
		tabButtons[i]:GetFontString():SetTextColor(i == tab and 1 or 0.6, i == tab and 0.82 or 0.6, i == tab and 0 or 0.6)
	end

	RefreshSummary()
	pages[tab]:Refresh()

	ui.report:SetShown(tab == 1)
	ui.report:SetText("Post Top 10")
	-- Reset All clears karma, so keep it with the leaderboard, not the other tabs
	ui.resetAll:SetShown(tab == 1 and ns.CanManage())
end

tabs[1] = { label = "Leaderboard", create = CreateLeaderboardPage }
tabs[2] = { label = "Activity", create = CreateActivityPage }

local function CreateUI()
	ui = CreateFrame("Frame", "GuildKarmaFrame", UIParent)
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

	local bg = ui:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	SetColor(bg, COLOR_BG)
	AddBorder(ui, COLOR_BORDER)

	-- Title bar
	local titleBar = ui:CreateTexture(nil, "ARTWORK")
	SetColor(titleBar, COLOR_TITLE)
	titleBar:SetPoint("TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", -1, -1)
	titleBar:SetHeight(28)

	local icon = ui:CreateTexture(nil, "OVERLAY")
	icon:SetSize(18, 18)
	icon:SetPoint("TOPLEFT", 8, -6)
	icon:SetTexture("Interface\\Icons\\Spell_Holy_GreaterBlessingofKings")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local title = ui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	title:SetText("Guild Karma")

	local close = CreateFrame("Button", nil, ui, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	-- Summary of the player's own karma
	ui.summary = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	ui.summary:SetPoint("TOPLEFT", 14, -40)
	ui.summaryDetail = ui:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.summaryDetail:SetPoint("BOTTOMLEFT", ui.summary, "BOTTOMRIGHT", 10, 1)

	-- Tabs
	tabButtons = {}
	local tabWidth = math.min(110, (FRAME_WIDTH - 24 - (#tabs - 1) * 4) / #tabs)
	for i, tabInfo in ipairs(tabs) do
		local tab = CreateFlatButton(ui, tabInfo.label, tabWidth, 24)
		tab:SetPoint("TOPLEFT", 12 + (i - 1) * (tabWidth + 4), -68)
		tab.selected = tab:CreateTexture(nil, "OVERLAY")
		tab.selected:SetColorTexture(COLOR_ACCENT[1], COLOR_ACCENT[2], COLOR_ACCENT[3], 1)
		tab.selected:SetHeight(2)
		tab.selected:SetPoint("BOTTOMLEFT", 1, 1)
		tab.selected:SetPoint("BOTTOMRIGHT", -1, 1)
		tab:SetScript("OnClick", function()
			GetSettings().tab = i
			Refresh()
		end)
		tabButtons[i] = tab
	end

	local tabDivider = ui:CreateTexture(nil, "ARTWORK")
	SetColor(tabDivider, COLOR_BORDER)
	tabDivider:SetHeight(1)
	tabDivider:SetPoint("TOPLEFT", 1, -92)
	tabDivider:SetPoint("TOPRIGHT", -1, -92)

	pages = {}
	for i, tabInfo in ipairs(tabs) do
		pages[i] = tabInfo.create(ui)
	end
	for _, page in ipairs(pages) do
		page:SetPoint("TOPLEFT", 0, -94)
		page:SetPoint("BOTTOMRIGHT", 0, 42)
	end
	if not pages[GetSettings().tab] then
		GetSettings().tab = 1
	end

	-- Footer
	local footer = ui:CreateTexture(nil, "ARTWORK")
	SetColor(footer, COLOR_BORDER)
	footer:SetHeight(1)
	footer:SetPoint("BOTTOMLEFT", 1, 42)
	footer:SetPoint("BOTTOMRIGHT", -1, 42)

	local sync = CreateFlatButton(ui, "Sync", 80, 24)
	sync:SetPoint("BOTTOMLEFT", 12, 10)
	sync:SetScript("OnClick", function()
		ns.RequestSync()
	end)
	SetTooltip(sync, "Sync", "Get the latest karma and history from other guild members running the addon.")

	ui.report = CreateFlatButton(ui, "Post Top 10", 100, 24)
	ui.report:SetPoint("LEFT", sync, "RIGHT", 6, 0)
	ui.report:SetScript("OnClick", function(self)
		ns.ReportTop10(GetPeriod().days)
		-- Brief cooldown so the leaderboard can't be spammed into guild chat
		self:Disable()
		C_Timer.After(REPORT_COOLDOWN, function()
			self:Enable()
		end)
	end)
	SetTooltip(ui.report, "Post Top 10", "Post the top 10 for the selected period to guild chat.")

	ui.resetAll = CreateFlatButton(ui, "Reset All", 90, 24)
	ui.resetAll:SetPoint("BOTTOMRIGHT", -12, 10)
	ui.resetAll:SetScript("OnClick", function()
		StaticPopup_Show("GUILDKARMA_RESET_ALL")
	end)
	SetTooltip(ui.resetAll, "Reset All", "Guild leader only: clear karma and history for the whole guild.")
end

function ns.ToggleUI()
	if not ui then
		CreateUI()
	end
	ui:SetShown(not ui:IsShown())
end

-- Add a tab to the karma window
function ns.AddTab(label, create)
	table.insert(tabs, { label = label, create = create })
end

-- Open the karma window on a tab, by label
function ns.ShowTab(label)
	for i, tabInfo in ipairs(tabs) do
		if tabInfo.label == label then
			GetSettings().tab = i
		end
	end
	if not ui then
		CreateUI()
	end
	ui:Show()
	Refresh()
end

-- Widgets and colors shared with the feature tabs
ns.Widgets = {
	SetColor = SetColor,
	AddBorder = AddBorder,
	CreateFlatButton = CreateFlatButton,
	CreateScrollList = CreateScrollList,
	CreateSearchBox = CreateSearchBox,
	CreateEditBox = CreateEditBox,
	SetTooltip = SetTooltip,
	SetClassIcon = SetClassIcon,
	ColoredName = ColoredName,
	ROW_HEIGHT = ROW_HEIGHT,
	CONTENT_WIDTH = CONTENT_WIDTH,
	COLOR_BUTTON = COLOR_BUTTON,
	COLOR_BORDER = COLOR_BORDER,
	COLOR_ACCENT = COLOR_ACCENT,
}

ns.OnDataChanged = Refresh
