-- GuildKarmaEvents: Schedule dungeons and raids, and sign up by role.
-- Anyone can schedule an event; its leader and officers can change or cancel it.

local addonName, ns = ...

local KEEP_DAYS = 2 -- Days after an event starts that it's kept, so cancellations still sync
local SHOW_AFTER_START = 3 * 3600 -- Events stay in the list this long after they start
local REMINDER_TIME = 15 * 60 -- Remind signed-up players this long before the start
local SYNC_BACKOFF = 4 -- Up to this many seconds before answering an events sync
local MAX_TITLE = 40
local MAX_NOTE = 60
local MAX_SLOTS = 40
local DAY = 86400

local KINDS = {
	dungeon = { label = "Dungeon", tanks = 1, healers = 1, dps = 3 },
	raid = { label = "Raid", tanks = 2, healers = 4, dps = 14 },
}

local ROLES = { "tank", "healer", "dps" }
local ROLE_LABELS = { tank = "Tank", healer = "Healer", dps = "DPS" }
local ROLE_SLOTS = { tank = "tanks", healer = "healers", dps = "dps" }

local STATUS_LABELS = {
	going = "|cff00ff00Going|r",
	maybe = "|cffffd100Maybe|r",
	no = "|cffff4040Can't go|r",
}

local idCounter = 0
local syncResponseTimer = nil
local reminded = {}

-- events[id] = { rev, t, kind, title, note, tanks, healers, dps, leader, deleted }
-- signups[eventId .. "/" .. player] = { rev, eventId, player, role, status, t }
local function GetCalendar()
	local meta = ns.GetGuildMeta()
	if not meta then
		return nil
	end
	meta.calEvents = meta.calEvents or {}
	meta.calSignups = meta.calSignups or {}
	return meta
end

local function Me()
	return ns.NormalizeName(ns.PlayerName())
end

local function NewId()
	idCounter = idCounter + 1
	return Me() .. "-" .. GetServerTime() .. "-" .. idCounter
end

local function Clean(text, maxLength)
	text = (ns.PlainText(text or "") or ""):gsub("[~\n]", " "):trim()
	return text:sub(1, maxLength)
end

-- "Fri Nov 14, 8:00 PM", or "Today, 8:00 PM" / "Tomorrow, 8:00 PM"
local function FormatWhen(t)
	local d = date("*t", t)
	local hour = d.hour % 12 == 0 and 12 or d.hour % 12
	local clock = string.format("%d:%02d %s", hour, d.min, d.hour < 12 and "AM" or "PM")
	local today = date("*t", GetServerTime())
	local tomorrow = date("*t", GetServerTime() + DAY)
	if d.year == today.year and d.yday == today.yday then
		return "Today, " .. clock
	elseif d.year == tomorrow.year and d.yday == tomorrow.yday then
		return "Tomorrow, " .. clock
	end
	return date("%a %b ", t) .. d.day .. ", " .. clock
end
ns.FormatEventTime = FormatWhen

-- The event's leader and officers can change or cancel it
local function CanEdit(event)
	return event.leader == Me() or ns.CanManageShop()
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

-- "CALEVT:id~rev~t~kind~tanks~healers~dps~deleted~leader~title~note"
local function SendEvent(id)
	local e = GetCalendar().calEvents[id]
	ns.QueueAddonMessage(
		("CALEVT:%s~%d~%d~%s~%d~%d~%d~%d~%s~%s~%s"):format(
			id, e.rev, e.t, e.kind, e.tanks, e.healers, e.dps, e.deleted and 1 or 0, e.leader, e.title, e.note
		)
	)
end

-- "CALSIGN:eventId~player~rev~role~status~t"
local function SendSignup(key)
	local s = GetCalendar().calSignups[key]
	ns.QueueAddonMessage(("CALSIGN:%s~%s~%d~%s~%s~%d"):format(s.eventId, s.player, s.rev, s.role, s.status, s.t))
end

-- Events this old are dropped, so they aren't stored or shared
local function IsExpired(t)
	return t < GetServerTime() - KEEP_DAYS * DAY
end

local function CancelSyncResponse(sender)
	if syncResponseTimer and not ns.IsMe(sender) then
		syncResponseTimer:Cancel()
		syncResponseTimer = nil
	end
end

ns.RegisterMessageHandler("CALEVT", function(body, sender)
	local cal = GetCalendar()
	local id, rev, t, kind, tanks, healers, dps, deleted, leader, title, note =
		body:match("^([^~]+)~(%d+)~(%d+)~(%a+)~(%d+)~(%d+)~(%d+)~([01])~([^~]+)~([^~]*)~(.*)$")
	if not cal or not id or not KINDS[kind] or IsExpired(tonumber(t)) then
		return
	end
	CancelSyncResponse(sender)
	rev = tonumber(rev)
	local current = cal.calEvents[id]
	if current and rev <= current.rev then
		return
	end
	local event = {
		rev = rev,
		t = tonumber(t),
		kind = kind,
		tanks = math.min(tonumber(tanks), MAX_SLOTS),
		healers = math.min(tonumber(healers), MAX_SLOTS),
		dps = math.min(tonumber(dps), MAX_SLOTS),
		deleted = deleted == "1" or nil,
		leader = leader,
		title = title,
		note = note,
	}
	cal.calEvents[id] = event

	if not current and not event.deleted and leader ~= Me() and event.t > GetServerTime() then
		ns.Print(leader .. " scheduled " .. title .. " (" .. KINDS[kind].label:lower() .. ") for "
			.. FormatWhen(event.t) .. ". Type /gk events to sign up.")
	elseif current and event.deleted and not current.deleted and leader ~= Me() then
		local mine = cal.calSignups[id .. "/" .. Me()]
		if mine and mine.status ~= "no" then
			ns.Print(title .. " on " .. FormatWhen(event.t) .. " was cancelled.")
		end
	end
	ns.NotifyChanged()
end)

ns.RegisterMessageHandler("CALSIGN", function(body, sender)
	local cal = GetCalendar()
	local eventId, player, rev, role, status, t = body:match("^([^~]+)~([^~]+)~(%d+)~(%a+)~(%a+)~(%d+)$")
	local known = cal and cal.calEvents[eventId]
	if not cal or not eventId or not ROLE_LABELS[role] or not STATUS_LABELS[status] or (known and IsExpired(known.t)) then
		return
	end
	CancelSyncResponse(sender)
	rev = tonumber(rev)
	local key = eventId .. "/" .. player
	local current = cal.calSignups[key]
	if current and rev <= current.rev then
		return
	end
	cal.calSignups[key] = { rev = rev, eventId = eventId, player = player, role = role, status = status, t = tonumber(t) }

	-- Tell the event's leader who's coming
	local event = cal.calEvents[eventId]
	if event and not event.deleted and event.leader == Me() and player ~= Me()
		and (not current or current.status ~= status or current.role ~= role) then
		local what = status == "going" and ("signed up as " .. ROLE_LABELS[role])
			or status == "maybe" and ("might come as " .. ROLE_LABELS[role])
			or "can't make it"
		ns.Print(player .. " " .. what .. " for " .. event.title .. ".")
	end
	ns.NotifyChanged()
end)

-- Answer an events sync with everything we know, unless another client answers first
ns.RegisterMessageHandler("CALSYNC", function(_, sender)
	local cal = GetCalendar()
	if not cal or ns.IsMe(sender) or syncResponseTimer then
		return
	end
	syncResponseTimer = C_Timer.NewTimer(math.random() * SYNC_BACKOFF, function()
		syncResponseTimer = nil
		for id, event in pairs(cal.calEvents) do
			if not IsExpired(event.t) then
				SendEvent(id)
			end
		end
		for key, signup in pairs(cal.calSignups) do
			local event = cal.calEvents[signup.eventId]
			if event and not IsExpired(event.t) then
				SendSignup(key)
			end
		end
	end)
end)

-- Events we lead and our signups may have changed with nobody else online, so
-- share the ones that haven't happened yet whenever we sync
ns.OnSyncRequest(function()
	C_ChatInfo.SendAddonMessage("GuildKarmaSync", "CALSYNC", "GUILD")

	local cal = GetCalendar()
	if not cal then
		return
	end
	local me, now = Me(), GetServerTime()
	for id, event in pairs(cal.calEvents) do
		if event.leader == me and event.t > now then
			SendEvent(id)
		end
	end
	for key, signup in pairs(cal.calSignups) do
		local event = cal.calEvents[signup.eventId]
		if signup.player == me and event and event.t > now then
			SendSignup(key)
		end
	end
end)

-- Drop events (and their signups) a couple of days after they start
local function PruneEvents()
	local cal = GetCalendar()
	if not cal then
		return
	end
	for id, event in pairs(cal.calEvents) do
		if IsExpired(event.t) then
			cal.calEvents[id] = nil
		end
	end
	for key, signup in pairs(cal.calSignups) do
		if not cal.calEvents[signup.eventId] then
			cal.calSignups[key] = nil
		end
	end
end

-- Remind players shortly before events they're going to or leading
local function CheckReminders()
	local cal = GetCalendar()
	if not cal then
		return
	end
	local me, now = Me(), GetServerTime()
	for id, event in pairs(cal.calEvents) do
		local untilStart = event.t - now
		if not event.deleted and not reminded[id] and untilStart > 0 and untilStart <= REMINDER_TIME then
			local signup = cal.calSignups[id .. "/" .. me]
			if event.leader == me or (signup and signup.status == "going") then
				reminded[id] = true
				ns.Print(event.title .. " starts in " .. math.ceil(untilStart / 60) .. " minutes!")
				if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
					PlaySound(SOUNDKIT.READY_CHECK)
				end
			end
		end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(self, event, isLogin, isReload)
	if isLogin or isReload then
		C_Timer.After(2, PruneEvents)
		if not ns.eventReminderTicker then
			ns.eventReminderTicker = C_Timer.NewTicker(30, CheckReminders)
		end
	end
end)

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Schedule an event (id nil) or change one. fields: title, kind, t, tanks, healers, dps, note
function ns.SaveEvent(id, fields)
	local cal = GetCalendar()
	if not cal then
		return
	end
	local current = id and cal.calEvents[id]
	if current and not CanEdit(current) then
		return
	end

	local title = Clean(fields.title, MAX_TITLE)
	local kind = KINDS[fields.kind] and fields.kind or "dungeon"
	local t = math.floor(tonumber(fields.t) or 0)
	if title == "" then
		ns.Print("Give the event a name, e.g. Deadmines.")
		return
	end
	if t < GetServerTime() - 300 then
		ns.Print("Pick a time that hasn't passed yet.")
		return
	end
	local function Slots(value, default)
		value = math.floor(tonumber(value) or default)
		return math.max(0, math.min(MAX_SLOTS, value))
	end

	id = id or NewId()
	cal.calEvents[id] = {
		rev = ns.NextRev(current and current.rev),
		t = t,
		kind = kind,
		title = title,
		note = Clean(fields.note, MAX_NOTE),
		tanks = Slots(fields.tanks, KINDS[kind].tanks),
		healers = Slots(fields.healers, KINDS[kind].healers),
		dps = Slots(fields.dps, KINDS[kind].dps),
		leader = current and current.leader or Me(),
	}
	SendEvent(id)
	ns.NotifyChanged()
	return id
end

-- Cancel an event (kept until it would have happened, so the cancellation syncs)
function ns.DeleteEvent(id)
	local cal = GetCalendar()
	local event = cal and cal.calEvents[id]
	if not event or event.deleted or not CanEdit(event) then
		return
	end
	event.deleted = true
	event.rev = ns.NextRev(event.rev)
	SendEvent(id)
	ns.NotifyChanged()
end

-- Sign up for an event as a role, or say you might come or can't
function ns.SignUp(eventId, role, status)
	local cal = GetCalendar()
	local event = cal and cal.calEvents[eventId]
	if not event or event.deleted or not ROLE_LABELS[role] or not STATUS_LABELS[status] then
		return
	end
	local me = Me()
	local key = eventId .. "/" .. me
	local current = cal.calSignups[key]
	local now = GetServerTime()
	-- Keep our place in line unless we change role or start going
	local keepPlace = current and current.role == role and (current.status == "going") == (status == "going")
	cal.calSignups[key] = {
		rev = ns.NextRev(current and current.rev),
		eventId = eventId,
		player = me,
		role = role,
		status = status,
		t = keepPlace and current.t or now,
	}
	SendSignup(key)
	ns.NotifyChanged()
end

-- One event with its roster: roles filled in signup order, then the bench
function ns.GetEvent(id)
	local cal = GetCalendar()
	local stored = cal and cal.calEvents[id]
	if not stored or stored.deleted then
		return nil
	end
	local event = { id = id, canEdit = CanEdit(stored) }
	for k, v in pairs(stored) do
		event[k] = v
	end
	event.kindLabel = KINDS[event.kind].label
	event.roles = { tank = {}, healer = {}, dps = {} }
	event.bench, event.maybe, event.no = {}, {}, {}

	local signups = {}
	for _, signup in pairs(cal.calSignups) do
		if signup.eventId == id then
			table.insert(signups, signup)
		end
	end
	table.sort(signups, function(a, b)
		if a.t ~= b.t then
			return a.t < b.t
		end
		return a.player < b.player
	end)

	local me = Me()
	for _, signup in ipairs(signups) do
		local entry = { name = signup.player, role = signup.role }
		if signup.player == me then
			event.mine = signup
		end
		if signup.status == "going" then
			local filled = event.roles[signup.role]
			if #filled < event[ROLE_SLOTS[signup.role]] then
				table.insert(filled, entry)
			else
				table.insert(event.bench, entry)
			end
		elseif signup.status == "maybe" then
			table.insert(event.maybe, entry)
		else
			table.insert(event.no, entry)
		end
	end

	if event.mine then
		event.myStatus = event.mine.status
		if event.mine.status == "going" then
			for _, entry in ipairs(event.bench) do
				if entry.name == me then
					event.myStatus = "bench"
				end
			end
		end
	end
	return event
end

-- Upcoming events, soonest first
function ns.GetEvents()
	local cal = GetCalendar()
	local list = {}
	if not cal then
		return list
	end
	local since = GetServerTime() - SHOW_AFTER_START
	for id, event in pairs(cal.calEvents) do
		if not event.deleted and event.t >= since then
			table.insert(list, ns.GetEvent(id))
		end
	end
	table.sort(list, function(a, b)
		if a.t ~= b.t then
			return a.t < b.t
		end
		return a.id < b.id
	end)
	return list
end

---------------------------------------------------------------------------
-- Events tab
---------------------------------------------------------------------------

local W = ns.Widgets
local EVENT_ROW_HEIGHT = 40
local ROSTER_ROW_HEIGHT = 18
local eventRows, rosterRows = {}, {}
local dialog
local page
local selectedId = nil
local selectedRole = "dps"

local MY_STATUS_TEXT = {
	going = "|cff00ff00You're going|r",
	bench = "|cffff9900You're on the bench|r",
	maybe = "|cffffd100You might go|r",
	no = "|cff888888You can't go|r",
}

-- "1/1" in green when the role is full
local function SlotText(filled, slots)
	local color = filled >= slots and "|cff00ff00" or "|cffffffff"
	return color .. filled .. "/" .. slots .. "|r"
end

local function RoleSummary(event)
	return "Tank " .. SlotText(#event.roles.tank, event.tanks)
		.. "   Healer " .. SlotText(#event.roles.healer, event.healers)
		.. "   DPS " .. SlotText(#event.roles.dps, event.dps)
end

-- A toggle button group: the selected one is highlighted
local function SetSelected(button, selected)
	W.SetColor(button.bg, selected and { 0.35, 0.28, 0.05, 1 } or W.COLOR_BUTTON)
end

-- Dialog to schedule or change an event
local function TimeFromDialog()
	local today = date("*t", GetServerTime())
	return time({
		year = today.year,
		month = today.month,
		day = today.day + dialog.dayOffset,
		hour = math.floor(dialog.minutes / 60),
		min = dialog.minutes % 60,
		sec = 0,
	})
end

local function UpdateDialogTime()
	dialog.dayText:SetText(FormatWhen(TimeFromDialog()):match("^(.-),") or "")
	local hour = math.floor(dialog.minutes / 60)
	dialog.timeText:SetText(string.format("%d:%02d %s", hour % 12 == 0 and 12 or hour % 12, dialog.minutes % 60, hour < 12 and "AM" or "PM"))
end

local function SetDialogKind(kind, fillSlots)
	dialog.kind = kind
	SetSelected(dialog.dungeonButton, kind == "dungeon")
	SetSelected(dialog.raidButton, kind == "raid")
	if fillSlots then
		dialog.tankBox:SetText(tostring(KINDS[kind].tanks))
		dialog.healerBox:SetText(tostring(KINDS[kind].healers))
		dialog.dpsBox:SetText(tostring(KINDS[kind].dps))
	end
end

-- A "<  text  >" stepper; step(direction) changes the value
local function CreateStepper(parent, width, step)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(width, 22)
	local back = W.CreateFlatButton(holder, "<", 22, 22)
	back:SetPoint("LEFT")
	back:SetScript("OnClick", function()
		step(-1)
	end)
	local forward = W.CreateFlatButton(holder, ">", 22, 22)
	forward:SetPoint("RIGHT")
	forward:SetScript("OnClick", function()
		step(1)
	end)
	local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("CENTER")
	return holder, text
end

local function AddLabel(parent, text, x, y)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", x, y)
	label:SetText(text)
	return label
end

local function SlotBox(parent, label, x, y)
	AddLabel(parent, label, x, y - 4)
	local box = W.CreateEditBox(parent, 40, "")
	box:SetPoint("TOPLEFT", x + 46, y)
	box:SetNumeric(true)
	box:SetMaxLetters(2)
	return box
end

local function OpenEventDialog(event)
	if not dialog then
		dialog = CreateFrame("Frame", "GuildKarmaEventDialog", GuildKarmaFrame)
		dialog:SetSize(340, 262)
		dialog:SetPoint("CENTER")
		dialog:SetFrameStrata("DIALOG")
		dialog:EnableMouse(true)
		local bg = dialog:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.08, 0.08, 0.1, 0.98)
		W.AddBorder(dialog, W.COLOR_ACCENT)

		dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		dialog.title:SetPoint("TOPLEFT", 12, -12)

		dialog.nameBox = W.CreateEditBox(dialog, 316, "Name, e.g. Deadmines or Molten Core")
		dialog.nameBox:SetPoint("TOPLEFT", 12, -34)
		dialog.nameBox:SetMaxLetters(MAX_TITLE)

		dialog.dungeonButton = W.CreateFlatButton(dialog, "Dungeon", 80, 22)
		dialog.dungeonButton:SetPoint("TOPLEFT", 12, -64)
		dialog.dungeonButton:SetScript("OnClick", function()
			SetDialogKind("dungeon", true)
		end)
		dialog.raidButton = W.CreateFlatButton(dialog, "Raid", 80, 22)
		dialog.raidButton:SetPoint("LEFT", dialog.dungeonButton, "RIGHT", 4, 0)
		dialog.raidButton:SetScript("OnClick", function()
			SetDialogKind("raid", true)
		end)

		AddLabel(dialog, "Day", 12, -100)
		local dayStepper
		dayStepper, dialog.dayText = CreateStepper(dialog, 170, function(direction)
			dialog.dayOffset = math.max(0, math.min(27, dialog.dayOffset + direction))
			UpdateDialogTime()
		end)
		dayStepper:SetPoint("TOPLEFT", 58, -96)

		AddLabel(dialog, "Time", 12, -128)
		local timeStepper
		timeStepper, dialog.timeText = CreateStepper(dialog, 170, function(direction)
			dialog.minutes = (dialog.minutes + direction * 15) % (24 * 60)
			UpdateDialogTime()
		end)
		timeStepper:SetPoint("TOPLEFT", 58, -124)

		dialog.tankBox = SlotBox(dialog, "Tanks", 12, -156)
		dialog.healerBox = SlotBox(dialog, "Healers", 112, -156)
		dialog.dpsBox = SlotBox(dialog, "DPS", 222, -156)

		dialog.noteBox = W.CreateEditBox(dialog, 316, "Note (optional), e.g. meet at the summoning stone")
		dialog.noteBox:SetPoint("TOPLEFT", 12, -188)
		dialog.noteBox:SetMaxLetters(MAX_NOTE)

		local save = W.CreateFlatButton(dialog, "Save", 90, 24)
		save:SetPoint("BOTTOMRIGHT", -12, 12)
		save:SetScript("OnClick", function()
			local id = ns.SaveEvent(dialog.eventId, {
				title = dialog.nameBox:GetText(),
				kind = dialog.kind,
				t = TimeFromDialog(),
				tanks = dialog.tankBox:GetText(),
				healers = dialog.healerBox:GetText(),
				dps = dialog.dpsBox:GetText(),
				note = dialog.noteBox:GetText(),
			})
			if id then
				dialog:Hide()
				selectedId = id
				ns.NotifyChanged()
			end
		end)
		local cancel = W.CreateFlatButton(dialog, "Cancel", 90, 24)
		cancel:SetPoint("RIGHT", save, "LEFT", -6, 0)
		cancel:SetScript("OnClick", function()
			dialog:Hide()
		end)
	end

	dialog.eventId = event and event.id
	dialog.title:SetText(event and "Edit event" or "Schedule a dungeon or raid")
	dialog.nameBox:SetText(event and event.title or "")
	dialog.noteBox:SetText(event and event.note or "")

	-- New events default to the next full hour at least 30 minutes away
	local t = event and event.t or (math.ceil((GetServerTime() + 30 * 60) / 3600) * 3600)
	local d, today = date("*t", t), date("*t", GetServerTime())
	local midnight = time({ year = today.year, month = today.month, day = today.day, hour = 0 })
	local dayStart = time({ year = d.year, month = d.month, day = d.day, hour = 0 })
	dialog.dayOffset = math.max(0, math.floor((dayStart - midnight) / DAY + 0.5))
	dialog.minutes = d.hour * 60 + d.min
	if event then
		SetDialogKind(event.kind, false)
		dialog.tankBox:SetText(tostring(event.tanks))
		dialog.healerBox:SetText(tostring(event.healers))
		dialog.dpsBox:SetText(tostring(event.dps))
	else
		SetDialogKind("dungeon", true)
	end
	UpdateDialogTime()
	dialog:Show()
	dialog.nameBox:SetFocus()
end

local function GetEventRow(content, index)
	if eventRows[index] then
		return eventRows[index]
	end

	local row = CreateFrame("Button", nil, content)
	row:SetSize(W.CONTENT_WIDTH, EVENT_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * EVENT_ROW_HEIGHT)
	local stripe = row:CreateTexture(nil, "BACKGROUND")
	stripe:SetAllPoints()
	stripe:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.03 or 0)
	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.06)
	row:SetScript("OnClick", function(self)
		selectedId = self.eventId
		ns.NotifyChanged()
	end)

	row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.title:SetPoint("TOPLEFT", 8, -5)
	row.title:SetPoint("RIGHT", -150, 0)
	row.title:SetJustifyH("LEFT")
	row.title:SetWordWrap(false)

	row.when = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.when:SetPoint("TOPRIGHT", -8, -6)

	row.roles = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.roles:SetPoint("TOPLEFT", 8, -23)

	row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.status:SetPoint("TOPRIGHT", -8, -23)

	eventRows[index] = row
	return row
end

local function GetRosterRow(content, index)
	if rosterRows[index] then
		return rosterRows[index]
	end
	local row = CreateFrame("Frame", nil, content)
	row:SetSize(W.CONTENT_WIDTH, ROSTER_ROW_HEIGHT)
	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", 8, 0)
	row.text:SetJustifyH("LEFT")
	rosterRows[index] = row
	return row
end

local function RefreshList()
	local events = ns.GetEvents()
	for i, event in ipairs(events) do
		local row = GetEventRow(page.listContent, i)
		row.eventId = event.id
		local kindColor = event.kind == "raid" and "|cffff8040" or "|cff40c0ff"
		row.title:SetText(event.title .. "  " .. kindColor .. event.kindLabel .. "|r")
		row.when:SetText(FormatWhen(event.t))
		row.roles:SetText(RoleSummary(event) .. "   |cff888888Led by|r " .. W.ColoredName(event.leader))
		row.status:SetText(event.myStatus and MY_STATUS_TEXT[event.myStatus] or "")
		row:Show()
	end
	for i = #events + 1, #eventRows do
		eventRows[i]:Hide()
	end
	page.listContent:SetHeight(math.max(1, #events * EVENT_ROW_HEIGHT))
	page.noEvents:SetShown(#events == 0)
end

local function RefreshDetail(event)
	page.detailTitle:SetText(event.title .. "  |cff888888" .. event.kindLabel .. "|r")
	page.detailWhen:SetText(FormatWhen(event.t) .. "   |cff888888Led by|r " .. W.ColoredName(event.leader))
	page.detailNote:SetText(event.note ~= "" and event.note or "")
	page.editButton:SetShown(event.canEdit)
	page.deleteButton:SetShown(event.canEdit)

	if event.mine then
		selectedRole = event.mine.role
	end
	for role, button in pairs(page.roleButtons) do
		SetSelected(button, role == selectedRole)
	end
	for status, button in pairs(page.statusButtons) do
		SetSelected(button, event.mine and event.mine.status == status)
	end
	page.myStatus:SetText(event.myStatus and MY_STATUS_TEXT[event.myStatus] or "Pick a role, then sign up")

	-- Roster: each role with its open slots, then bench, maybe and can't go
	local lines = {}
	local function Section(title, entries, showRole)
		if #entries == 0 and not title:find("/") then
			return
		end
		table.insert(lines, "|cffffd100" .. title .. "|r")
		for _, entry in ipairs(entries) do
			table.insert(lines, "    " .. W.ColoredName(entry.name) .. (showRole and ("  |cff888888" .. ROLE_LABELS[entry.role] .. "|r") or ""))
		end
	end
	for _, role in ipairs(ROLES) do
		local slots = event[ROLE_SLOTS[role]]
		if slots > 0 or #event.roles[role] > 0 then
			Section(ROLE_LABELS[role] .. (role == "dps" and "" or "s") .. "  " .. SlotText(#event.roles[role], slots), event.roles[role])
		end
	end
	Section("Bench (full roles)", event.bench, true)
	Section("Maybe", event.maybe, true)
	Section("Can't go", event.no)

	for i, text in ipairs(lines) do
		local row = GetRosterRow(page.rosterContent, i)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ROSTER_ROW_HEIGHT)
		row.text:SetText(text)
		row:Show()
	end
	for i = #lines + 1, #rosterRows do
		rosterRows[i]:Hide()
	end
	page.rosterContent:SetHeight(math.max(1, #lines * ROSTER_ROW_HEIGHT))
end

local function RefreshEvents()
	local event = selectedId and ns.GetEvent(selectedId)
	if not event then
		selectedId = nil
	end
	page.listView:SetShown(event == nil)
	page.detailView:SetShown(event ~= nil)
	if event then
		RefreshDetail(event)
	else
		RefreshList()
	end
end

StaticPopupDialogs["GUILDKARMA_DELETE_EVENT"] = {
	text = "Cancel %s? Everyone signed up will be told.",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self, data)
		ns.DeleteEvent(data or self.data)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

ns.AddTab("Events", function(parent)
	page = CreateFrame("Frame", nil, parent)

	-- List of upcoming events
	page.listView = CreateFrame("Frame", nil, page)
	page.listView:SetAllPoints()

	local heading = page.listView:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	heading:SetPoint("TOPLEFT", 14, -12)
	heading:SetText("Upcoming dungeons and raids")

	local schedule = W.CreateFlatButton(page.listView, "Schedule", 90, 24)
	schedule:SetPoint("TOPRIGHT", -12, -6)
	schedule:SetScript("OnClick", function()
		OpenEventDialog(nil)
	end)
	W.SetTooltip(schedule, "Schedule", "Plan a dungeon or raid. Guild members running the addon can sign up by role.")

	local listScroll
	listScroll, page.listContent = W.CreateScrollList(page.listView, "GuildKarmaEventsScroll")
	listScroll:SetPoint("TOPLEFT", 10, -36)
	listScroll:SetPoint("BOTTOMRIGHT", -24, 4)
	page.noEvents = page.listView:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	page.noEvents:SetPoint("TOP", listScroll, "TOP", 0, -40)
	page.noEvents:SetText("Nothing scheduled. Use Schedule to plan a run.")

	-- One event: details, signup buttons and roster
	page.detailView = CreateFrame("Frame", nil, page)
	page.detailView:SetAllPoints()
	local view = page.detailView

	local back = W.CreateFlatButton(view, "< Back", 60, 22)
	back:SetPoint("TOPLEFT", 10, -6)
	back:SetScript("OnClick", function()
		selectedId = nil
		ns.NotifyChanged()
	end)

	page.deleteButton = W.CreateFlatButton(view, "Cancel event", 90, 22)
	page.deleteButton:SetPoint("TOPRIGHT", -12, -6)
	page.deleteButton:SetScript("OnClick", function()
		local event = ns.GetEvent(selectedId)
		if event then
			StaticPopup_Show("GUILDKARMA_DELETE_EVENT", event.title, nil, event.id)
		end
	end)
	page.editButton = W.CreateFlatButton(view, "Edit", 50, 22)
	page.editButton:SetPoint("RIGHT", page.deleteButton, "LEFT", -4, 0)
	page.editButton:SetScript("OnClick", function()
		OpenEventDialog(ns.GetEvent(selectedId))
	end)

	page.detailTitle = view:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	page.detailTitle:SetPoint("TOPLEFT", 14, -38)
	page.detailWhen = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	page.detailWhen:SetPoint("TOPLEFT", 14, -60)
	page.detailNote = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	page.detailNote:SetPoint("TOPLEFT", 14, -76)
	page.detailNote:SetPoint("RIGHT", -14, 0)
	page.detailNote:SetJustifyH("LEFT")

	AddLabel(view, "Role", 14, -102)
	page.roleButtons = {}
	local previous
	for _, role in ipairs(ROLES) do
		local button = W.CreateFlatButton(view, ROLE_LABELS[role], 70, 22)
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
		else
			button:SetPoint("TOPLEFT", 60, -98)
		end
		button:SetScript("OnClick", function()
			selectedRole = role
			local event = ns.GetEvent(selectedId)
			-- Already signed up: switch role straight away
			if event and event.mine then
				ns.SignUp(selectedId, role, event.mine.status)
			else
				ns.NotifyChanged()
			end
		end)
		page.roleButtons[role] = button
		previous = button
	end

	AddLabel(view, "I'm", 14, -130)
	page.statusButtons = {}
	previous = nil
	for _, status in ipairs({ "going", "maybe", "no" }) do
		local label = status == "going" and "Going" or status == "maybe" and "Maybe" or "Can't go"
		local button = W.CreateFlatButton(view, label, 70, 22)
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
		else
			button:SetPoint("TOPLEFT", 60, -126)
		end
		button:SetScript("OnClick", function()
			ns.SignUp(selectedId, selectedRole, status)
		end)
		page.statusButtons[status] = button
		previous = button
	end
	page.myStatus = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	page.myStatus:SetPoint("LEFT", previous, "RIGHT", 10, 0)

	local divider = view:CreateTexture(nil, "ARTWORK")
	W.SetColor(divider, W.COLOR_BORDER)
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", 10, -158)
	divider:SetPoint("TOPRIGHT", -10, -158)

	local rosterScroll
	rosterScroll, page.rosterContent = W.CreateScrollList(view, "GuildKarmaEventRosterScroll")
	rosterScroll:SetPoint("TOPLEFT", 10, -164)
	rosterScroll:SetPoint("BOTTOMRIGHT", -24, 4)

	page.Refresh = RefreshEvents
	return page
end)
