-- GuildKarmaShop: Spend karma on guild bank items. Officers list items and prices;
-- members request them; officers approve and hand the items over in game.
-- Spending never lowers the leaderboard: balance = karma earned - spent - pending.

local addonName, ns = ...

local HISTORY_DAYS = 60 -- Days finished requests and removed items are kept
local MAX_PRICE = 999999
local MAX_ITEM_TEXT = 200 -- Longest item name or link kept (bytes)
local SYNC_BACKOFF = 4 -- Up to this many seconds before answering a shop sync
local DAY = 86400

local STATUS_LABELS = {
	pending = "|cffffd100Pending|r",
	approved = "|cff00ff00Approved|r",
	delivered = "|cff88aa88Delivered|r",
	denied = "|cffff4040Denied|r",
	cancelled = "|cff888888Cancelled|r",
}

local idCounter = 0
local syncResponseTimer = nil

-- items[id] = { rev, price, name, deleted }
-- requests[id] = { rev, status, t, player, itemId, itemName, price, by }
local function GetShop()
	local meta = ns.GetGuildMeta()
	if not meta then
		return nil
	end
	meta.shopItems = meta.shopItems or {}
	meta.shopRequests = meta.shopRequests or {}
	return meta
end

local function Me()
	return ns.NormalizeName(ns.PlayerName())
end

-- A new id that no other client will make: our name, the time, and a counter
local function NewId()
	idCounter = idCounter + 1
	return Me() .. "-" .. GetServerTime() .. "-" .. idCounter
end

-- The guild leader and officers (ranks that can edit officer notes) run the shop
function ns.CanManageShop()
	if not IsInGuild() then
		return false
	end
	if IsGuildLeader() then
		return true
	end
	if C_GuildInfo and C_GuildInfo.CanEditOfficerNote then
		return C_GuildInfo.CanEditOfficerNote() and true or false
	end
	return CanEditOfficerNote and CanEditOfficerNote() and true or false
end

-- A player's karma balance. Purchases before the last guild-wide reset don't count.
function ns.GetBalance(name)
	local balance = { earned = 0, spent = 0, pending = 0, available = 0 }
	local db, shop = ns.GetGuildDB(), GetShop()
	if not db or not shop then
		return balance
	end

	balance.earned = db[name] or 0
	for _, request in pairs(shop.shopRequests) do
		if request.player == name and request.t >= shop.resetRev then
			if request.status == "approved" or request.status == "delivered" then
				balance.spent = balance.spent + request.price
			elseif request.status == "pending" then
				balance.pending = balance.pending + request.price
			end
		end
	end
	balance.available = balance.earned - balance.spent - balance.pending
	return balance
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

local function Clean(text)
	return (text:gsub("~", ""))
end

-- "SHOPITEM:id~rev~price~deleted~name"
local function SendItem(id)
	local item = GetShop().shopItems[id]
	ns.QueueAddonMessage("SHOPITEM:" .. id .. "~" .. item.rev .. "~" .. item.price .. "~" .. (item.deleted and 1 or 0) .. "~" .. item.name)
end

-- "SHOPREQ:id~rev~status~t~player~itemId~price~by~itemName"
local function SendRequest(id)
	local r = GetShop().shopRequests[id]
	ns.QueueAddonMessage(
		"SHOPREQ:" .. id .. "~" .. r.rev .. "~" .. r.status .. "~" .. r.t .. "~" .. r.player .. "~" .. r.itemId
			.. "~" .. r.price .. "~" .. r.by .. "~" .. r.itemName
	)
end

-- Tell officers about new requests, and players about decisions on theirs
local function Announce(request, previous)
	if request.status == (previous and previous.status) then
		return
	end
	local me = Me()
	if request.status == "pending" and request.player ~= me and ns.CanManageShop() then
		ns.Print(request.player .. " requested " .. request.itemName .. " for " .. request.price .. " karma. Type /gk shop to review.")
	elseif request.player == me and request.by ~= me then
		if request.status == "approved" then
			ns.Print(request.by .. " approved your request for " .. request.itemName .. "!")
		elseif request.status == "denied" then
			ns.Print(request.by .. " denied your request for " .. request.itemName .. ". Your karma was returned.")
		elseif request.status == "delivered" then
			ns.Print(request.itemName .. " was marked as delivered. Check your mail!")
		end
	end
end

-- Another client is answering the shop sync, so we don't need to
local function CancelSyncResponse(sender)
	if syncResponseTimer and not ns.IsMe(sender) then
		syncResponseTimer:Cancel()
		syncResponseTimer = nil
	end
end

ns.RegisterMessageHandler("SHOPITEM", function(body, sender)
	local shop = GetShop()
	local id, rev, price, deleted, name = body:match("^([^~]+)~(%d+)~(%d+)~([01])~(.*)$")
	if not shop or not id then
		return
	end
	CancelSyncResponse(sender)
	rev = tonumber(rev)
	local current = shop.shopItems[id]
	if not current or rev > current.rev then
		shop.shopItems[id] = { rev = rev, price = tonumber(price), name = name, deleted = deleted == "1" or nil }
		ns.NotifyChanged()
	end
end)

ns.RegisterMessageHandler("SHOPREQ", function(body, sender)
	local shop = GetShop()
	local id, rev, status, t, player, itemId, price, by, itemName =
		body:match("^([^~]+)~(%d+)~(%a+)~(%d+)~([^~]+)~([^~]+)~(%d+)~([^~]+)~(.*)$")
	if not shop or not id or not STATUS_LABELS[status] then
		return
	end
	CancelSyncResponse(sender)
	rev = tonumber(rev)
	local current = shop.shopRequests[id]
	if not current or rev > current.rev then
		local request = {
			rev = rev,
			status = status,
			t = tonumber(t),
			player = player,
			itemId = itemId,
			price = tonumber(price),
			by = by,
			itemName = itemName,
		}
		shop.shopRequests[id] = request
		Announce(request, current)
		ns.NotifyChanged()
	end
end)

-- Answer a shop sync with everything we know, unless another client answers first
ns.RegisterMessageHandler("SHOPSYNC", function(_, sender)
	local shop = GetShop()
	if not shop or ns.IsMe(sender) or syncResponseTimer then
		return
	end
	syncResponseTimer = C_Timer.NewTimer(math.random() * SYNC_BACKOFF, function()
		syncResponseTimer = nil
		for id in pairs(shop.shopItems) do
			SendItem(id)
		end
		for id in pairs(shop.shopRequests) do
			SendRequest(id)
		end
	end)
end)

-- Requests we made or decided may have happened with nobody else online, so
-- share recent ones ourselves whenever we sync
local RESEND_DAYS = 7

ns.OnSyncRequest(function()
	C_ChatInfo.SendAddonMessage("GuildKarmaSync", "SHOPSYNC", "GUILD")

	local shop = GetShop()
	if not shop then
		return
	end
	local me = Me()
	local cutoff = GetServerTime() - RESEND_DAYS * DAY
	for id, request in pairs(shop.shopRequests) do
		if (request.player == me or request.by == me) and request.rev >= cutoff then
			SendRequest(id)
		end
	end
end)

-- Drop finished requests and removed items once they're old
local function PruneShop()
	local shop = GetShop()
	if not shop then
		return
	end
	local cutoff = GetServerTime() - HISTORY_DAYS * DAY
	for id, request in pairs(shop.shopRequests) do
		if request.status ~= "pending" and request.status ~= "approved" and request.rev < cutoff then
			shop.shopRequests[id] = nil
		end
	end
	for id, item in pairs(shop.shopItems) do
		if item.deleted and item.rev < cutoff then
			shop.shopItems[id] = nil
		end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(self, event, isLogin)
	if isLogin then
		C_Timer.After(2, PruneShop)
	end
end)

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Officers: add an item (id nil) or change one
function ns.SaveShopItem(id, name, price)
	local shop = GetShop()
	if not shop or not ns.CanManageShop() then
		return
	end
	name = Clean(name:trim())
	if #name > MAX_ITEM_TEXT then
		name = ns.PlainText(name) or name:sub(1, MAX_ITEM_TEXT)
	end
	price = math.floor(tonumber(price) or 0)
	if name == "" or price < 1 or price > MAX_PRICE then
		ns.Print("Enter an item and a price from 1 to " .. MAX_PRICE .. ".")
		return
	end

	id = id or NewId()
	local current = shop.shopItems[id]
	shop.shopItems[id] = { rev = ns.NextRev(current and current.rev), price = price, name = name }
	SendItem(id)
	ns.NotifyChanged()
end

-- Officers: take an item off the list (kept briefly so the removal syncs)
function ns.RemoveShopItem(id)
	local shop = GetShop()
	local item = shop and shop.shopItems[id]
	if not item or not ns.CanManageShop() then
		return
	end
	item.deleted = true
	item.rev = ns.NextRev(item.rev)
	SendItem(id)
	ns.NotifyChanged()
end

-- Spend karma on an item; the karma is held until an officer decides
function ns.RequestShopItem(itemId)
	local shop = GetShop()
	local item = shop and shop.shopItems[itemId]
	if not item or item.deleted then
		return
	end
	local me = Me()
	if ns.GetBalance(me).available < item.price then
		ns.Print("You don't have enough karma for " .. item.name .. ".")
		return
	end

	local id = NewId()
	local now = GetServerTime()
	shop.shopRequests[id] = {
		rev = now,
		status = "pending",
		t = now,
		player = me,
		itemId = itemId,
		price = item.price,
		by = me,
		itemName = ns.PlainText(item.name) or item.name,
	}
	SendRequest(id)
	ns.Print("Requested " .. item.name .. " for " .. item.price .. " karma. An officer will review it.")
	ns.NotifyChanged()
end

-- Change a request's status: officers approve, deny or mark delivered; the
-- requester can cancel while it's pending
function ns.SetShopRequestStatus(id, status)
	local shop = GetShop()
	local request = shop and shop.shopRequests[id]
	if not request then
		return
	end
	local me = Me()
	local allowed = (status == "cancelled" and request.player == me and request.status == "pending")
		or ((status == "approved" or status == "denied") and ns.CanManageShop() and request.status == "pending")
		or (status == "delivered" and ns.CanManageShop() and request.status == "approved")
	if not allowed then
		return
	end
	-- The pending request already counts against the balance, so approving needs it to stay >= 0
	if status == "approved" and ns.GetBalance(request.player).available < 0 then
		ns.Print(request.player .. " no longer has enough karma for " .. request.itemName .. ".")
		return
	end

	request.status = status
	request.by = me
	request.rev = ns.NextRev(request.rev)
	SendRequest(id)
	ns.NotifyChanged()
end

-- Items for sale, cheapest first
function ns.GetShopItems()
	local shop = GetShop()
	local items = {}
	if not shop then
		return items
	end
	for id, item in pairs(shop.shopItems) do
		if not item.deleted then
			table.insert(items, { id = id, name = item.name, price = item.price })
		end
	end
	table.sort(items, function(a, b)
		if a.price ~= b.price then
			return a.price < b.price
		end
		return a.name < b.name
	end)
	return items
end

-- Requests to show: officers see everyone's, members their own. Open ones come
-- first (pending, then approved), then the rest, newest first.
local STATUS_ORDER = { pending = 1, approved = 2 }

function ns.GetShopRequests()
	local shop = GetShop()
	local list = {}
	if not shop then
		return list
	end
	local me, manage = Me(), ns.CanManageShop()
	for id, request in pairs(shop.shopRequests) do
		if manage or request.player == me then
			local entry = { id = id }
			for k, v in pairs(request) do
				entry[k] = v
			end
			table.insert(list, entry)
		end
	end
	table.sort(list, function(a, b)
		local orderA, orderB = STATUS_ORDER[a.status] or 3, STATUS_ORDER[b.status] or 3
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a.t > b.t
	end)
	return list
end

---------------------------------------------------------------------------
-- Shop tab
---------------------------------------------------------------------------

local W = ns.Widgets
local REQUEST_ROW_HEIGHT = 34
local itemRows, requestRows = {}, {}
local dialog

StaticPopupDialogs["GUILDKARMA_SHOP_REQUEST"] = {
	text = "Spend %s karma on %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self, data)
		ns.RequestShopItem(data or self.data)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Show an item's game tooltip when its name is a link
local function ShowItemTooltip(owner, name)
	local link = name:match("|H(.-)|h")
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	if link then
		GameTooltip:SetHyperlink(link)
	else
		GameTooltip:AddLine(name)
	end
	GameTooltip:Show()
end

-- Officers: dialog to add or edit an item. Shift-click an item to link it.
local function OpenItemDialog(item)
	if not dialog then
		dialog = CreateFrame("Frame", "GuildKarmaShopDialog", GuildKarmaFrame)
		dialog:SetSize(320, 150)
		dialog:SetPoint("CENTER")
		dialog:SetFrameStrata("DIALOG")
		dialog:EnableMouse(true)
		local bg = dialog:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.08, 0.08, 0.1, 0.98)
		W.AddBorder(dialog, W.COLOR_ACCENT)

		dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		dialog.title:SetPoint("TOPLEFT", 12, -12)

		dialog.itemBox = W.CreateEditBox(dialog, 296, "Item name, or shift-click an item")
		dialog.itemBox:SetPoint("TOPLEFT", 12, -36)

		local priceLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		priceLabel:SetPoint("TOPLEFT", 12, -72)
		priceLabel:SetText("Price (karma)")
		dialog.priceBox = W.CreateEditBox(dialog, 90, "")
		dialog.priceBox:SetPoint("LEFT", priceLabel, "RIGHT", 10, 0)
		dialog.priceBox:SetNumeric(true)
		dialog.priceBox:SetMaxLetters(6)

		local save = W.CreateFlatButton(dialog, "Save", 90, 24)
		save:SetPoint("BOTTOMRIGHT", -12, 12)
		save:SetScript("OnClick", function()
			ns.SaveShopItem(dialog.itemId, dialog.itemBox:GetText(), dialog.priceBox:GetText())
			dialog:Hide()
		end)
		local cancel = W.CreateFlatButton(dialog, "Cancel", 90, 24)
		cancel:SetPoint("RIGHT", save, "LEFT", -6, 0)
		cancel:SetScript("OnClick", function()
			dialog:Hide()
		end)

		-- Shift-clicking an item inserts its link into the focused item box
		local function InsertLink(link)
			if link and dialog:IsShown() and dialog.itemBox:HasFocus() then
				dialog.itemBox:SetText(link)
			end
		end
		if ChatEdit_InsertLink then
			hooksecurefunc("ChatEdit_InsertLink", InsertLink)
		elseif ChatFrameUtil and ChatFrameUtil.InsertLink then
			hooksecurefunc(ChatFrameUtil, "InsertLink", InsertLink)
		end
	end

	dialog.itemId = item and item.id
	dialog.title:SetText(item and "Edit item" or "Add item")
	dialog.itemBox:SetText(item and item.name or "")
	dialog.priceBox:SetText(item and tostring(item.price) or "")
	dialog:Show()
	dialog.itemBox:SetFocus()
end

local function GetItemRow(content, index)
	if itemRows[index] then
		return itemRows[index]
	end

	local row = CreateFrame("Frame", nil, content)
	row:SetSize(W.CONTENT_WIDTH, W.ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * W.ROW_HEIGHT)
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		ShowItemTooltip(self, self.item.name)
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	if index % 2 == 0 then
		local stripe = row:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, 0.03)
	end

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", 8, 0)
	row.name:SetWidth(210)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.request = W.CreateFlatButton(row, "Request", 62, W.ROW_HEIGHT - 4)
	row.request:SetPoint("RIGHT", -2, 0)
	row.request:SetScript("OnClick", function()
		StaticPopup_Show("GUILDKARMA_SHOP_REQUEST", row.item.price, row.item.name, row.item.id)
	end)

	row.remove = W.CreateFlatButton(row, "x", 20, W.ROW_HEIGHT - 4)
	row.remove:SetPoint("RIGHT", row.request, "LEFT", -2, 0)
	row.remove:SetScript("OnClick", function()
		ns.RemoveShopItem(row.item.id)
	end)
	W.SetTooltip(row.remove, "Remove item")

	row.edit = W.CreateFlatButton(row, "Edit", 36, W.ROW_HEIGHT - 4)
	row.edit:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
	row.edit:SetScript("OnClick", function()
		OpenItemDialog(row.item)
	end)

	row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.price:SetJustifyH("RIGHT")

	itemRows[index] = row
	return row
end

local function GetRequestRow(content, index)
	if requestRows[index] then
		return requestRows[index]
	end

	local row = CreateFrame("Frame", nil, content)
	row:SetSize(W.CONTENT_WIDTH, REQUEST_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * REQUEST_ROW_HEIGHT)
	if index % 2 == 0 then
		local stripe = row:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, 0.03)
	end

	row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.title:SetPoint("TOPLEFT", 8, -4)
	row.title:SetPoint("RIGHT", -150, 0)
	row.title:SetJustifyH("LEFT")
	row.title:SetWordWrap(false)

	row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.detail:SetPoint("TOPLEFT", 8, -19)
	row.detail:SetPoint("RIGHT", -150, 0)
	row.detail:SetJustifyH("LEFT")

	row.primary = W.CreateFlatButton(row, "", 70, 22)
	row.primary:SetPoint("RIGHT", -2, 0)
	row.secondary = W.CreateFlatButton(row, "", 70, 22)
	row.secondary:SetPoint("RIGHT", row.primary, "LEFT", -4, 0)

	requestRows[index] = row
	return row
end

-- Set up a request row button, or hide it when label is nil
local function SetAction(button, label, requestId, status)
	button:SetShown(label ~= nil)
	if label then
		button:SetText(label)
		button:SetScript("OnClick", function()
			ns.SetShopRequestStatus(requestId, status)
		end)
	end
end

local function RefreshShop(page)
	local me, manage = Me(), ns.CanManageShop()
	local balance = ns.GetBalance(me)
	page.balance:SetText("Balance: |cffffd100" .. balance.available .. "|r karma to spend")
	page.balanceDetail:SetText(balance.earned .. " earned  |  " .. balance.spent .. " spent  |  " .. balance.pending .. " pending")
	page.addItem:SetShown(manage)
	page.requestsLabel:SetText(manage and "Requests" or "Your requests")

	local items = ns.GetShopItems()
	for i, item in ipairs(items) do
		local row = GetItemRow(page.itemContent, i)
		row.item = item
		row.name:SetText(item.name)
		row.price:SetText("|cffffd100" .. item.price .. "|r karma")
		row.edit:SetShown(manage)
		row.remove:SetShown(manage)
		row.request:SetEnabled(balance.available >= item.price)
		row.price:ClearAllPoints()
		row.price:SetPoint("RIGHT", manage and row.edit or row.request, "LEFT", -8, 0)
		row:Show()
	end
	for i = #items + 1, #itemRows do
		itemRows[i]:Hide()
	end
	page.itemContent:SetHeight(math.max(1, #items * W.ROW_HEIGHT))
	page.noItems:SetShown(#items == 0)
	page.noItems:SetText(manage and "No items yet. Use Add item to list guild bank items." or "No items for sale yet.")

	local requests = ns.GetShopRequests()
	for i, request in ipairs(requests) do
		local row = GetRequestRow(page.requestContent, i)
		local who = request.player == me and "You" or W.ColoredName(request.player)
		row.title:SetText(who .. "  |cff888888-|r  " .. request.itemName)
		row.detail:SetText(STATUS_LABELS[request.status] .. "  |  " .. request.price .. " karma  |  " .. ns.FormatAgo(request.t) .. " ago")

		local primary, primaryStatus, secondary, secondaryStatus
		if manage and request.status == "pending" then
			primary, primaryStatus, secondary, secondaryStatus = "Approve", "approved", "Deny", "denied"
		elseif manage and request.status == "approved" then
			primary, primaryStatus = "Delivered", "delivered"
		elseif request.player == me and request.status == "pending" then
			primary, primaryStatus = "Cancel", "cancelled"
		end
		SetAction(row.primary, primary, request.id, primaryStatus)
		SetAction(row.secondary, secondary, request.id, secondaryStatus)
		row:Show()
	end
	for i = #requests + 1, #requestRows do
		requestRows[i]:Hide()
	end
	page.requestContent:SetHeight(math.max(1, #requests * REQUEST_ROW_HEIGHT))
	page.noRequests:SetShown(#requests == 0)
end

local function AddSectionLabel(page, text, y)
	local label = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", 14, y)
	label:SetText(text)
	local divider = page:CreateTexture(nil, "ARTWORK")
	W.SetColor(divider, W.COLOR_BORDER)
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", 10, y - 14)
	divider:SetPoint("TOPRIGHT", -10, y - 14)
	return label
end

ns.AddTab("Shop", function(parent)
	local page = CreateFrame("Frame", nil, parent)

	page.balance = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	page.balance:SetPoint("TOPLEFT", 14, -8)
	page.balanceDetail = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	page.balanceDetail:SetPoint("TOPLEFT", 14, -24)

	page.addItem = W.CreateFlatButton(page, "Add item", 90, 24)
	page.addItem:SetPoint("TOPRIGHT", -12, -8)
	page.addItem:SetScript("OnClick", function()
		OpenItemDialog(nil)
	end)
	W.SetTooltip(page.addItem, "Add item", "List a guild bank item and its price in karma. Shift-click an item to link it.")

	AddSectionLabel(page, "Items for sale", -44)
	local itemScroll
	itemScroll, page.itemContent = W.CreateScrollList(page, "GuildKarmaShopItemScroll")
	itemScroll:SetPoint("TOPLEFT", 10, -62)
	itemScroll:SetPoint("TOPRIGHT", -24, -62)
	itemScroll:SetHeight(140)
	page.noItems = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	page.noItems:SetPoint("TOP", itemScroll, "TOP", 0, -30)

	page.requestsLabel = AddSectionLabel(page, "Requests", -212)
	local requestScroll
	requestScroll, page.requestContent = W.CreateScrollList(page, "GuildKarmaShopRequestScroll")
	requestScroll:SetPoint("TOPLEFT", 10, -230)
	requestScroll:SetPoint("BOTTOMRIGHT", -24, 4)
	page.noRequests = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	page.noRequests:SetPoint("TOP", requestScroll, "TOP", 0, -30)
	page.noRequests:SetText("No requests yet.")

	page.Refresh = RefreshShop
	return page
end)
