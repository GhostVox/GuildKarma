-- GuildKarmaMinimap: Draggable minimap button that toggles the karma window

local addonName, ns = ...

local ICON = "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings"
local DEFAULT_ANGLE = 225 -- Degrees around the minimap, 0 = right, counter-clockwise

local button

-- Account-wide settings, loaded from SavedVariables
local function GetSettings()
	GuildKarmaSettings = GuildKarmaSettings or {}
	GuildKarmaSettings.minimap = GuildKarmaSettings.minimap or { angle = DEFAULT_ANGLE, hide = false }
	return GuildKarmaSettings.minimap
end

-- Place the button on the minimap's edge at the saved angle
local function UpdatePosition()
	local angle = math.rad(GetSettings().angle)
	local radius = Minimap:GetWidth() / 2 + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- While dragging, follow the cursor around the minimap
local function OnDragUpdate()
	local centerX, centerY = Minimap:GetCenter()
	local cursorX, cursorY = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	cursorX, cursorY = cursorX / scale, cursorY / scale
	GetSettings().angle = math.deg(math.atan2(cursorY - centerY, cursorX - centerX))
	UpdatePosition()
end

local function CreateButton()
	button = CreateFrame("Button", "GuildKarmaMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			ns.RequestSync()
		else
			ns.ToggleUI()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", OnDragUpdate)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Guild Karma")
		GameTooltip:AddLine("Left-click: Open karma window", 1, 1, 1)
		GameTooltip:AddLine("Right-click: Sync karma", 1, 1, 1)
		GameTooltip:AddLine("Drag: Move button", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)

	UpdatePosition()
	button:SetShown(not GetSettings().hide)
end

-- Show or hide the minimap button, remembering the choice
function ns.ToggleMinimapButton()
	local settings = GetSettings()
	settings.hide = not settings.hide
	button:SetShown(not settings.hide)
	ns.Print(settings.hide and "Minimap button hidden. Type /gk minimap to show it again." or "Minimap button shown.")
end

-- Create the button once SavedVariables have loaded
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, loadedAddon)
	if loadedAddon == addonName then
		CreateButton()
		self:UnregisterEvent("ADDON_LOADED")
	end
end)
