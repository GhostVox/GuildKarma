-- GuildKarmaTooltip: Shows guild members' karma in unit and guild roster tooltips

local addonName, ns = ...

-- Retail hides some values from addons (e.g. in instances); treat those as unknown
local function IsSecret(value)
	return issecretvalue and issecretvalue(value)
end

-- Add a "Guild Karma" line for a player, if they have karma in our guild
local function AddKarmaLine(tooltip, playerName)
	local db = ns.GetGuildDB()
	if not db or not playerName then
		return false
	end

	local key = ns.NormalizeName(playerName)
	local karma = db[key]
	if not karma then
		return false
	end

	local text = karma .. " karma"
	for _, entry in ipairs(ns.BuildLeaderboard()) do
		if entry.name == key then
			text = text .. "  (#" .. entry.place .. ")"
			break
		end
	end
	tooltip:AddDoubleLine("Guild Karma", text, 1, 0.82, 0, 1, 1, 1)
	return true
end

-- Unit tooltips: players in our guild
local function OnUnitTooltip(tooltip)
	if tooltip ~= GameTooltip then
		return false
	end
	local _, unit = tooltip:GetUnit()
	if not unit or IsSecret(unit) then
		return false
	end

	local isPlayer = UnitIsPlayer(unit)
	local inGuild = UnitIsInMyGuild(unit)
	local name = UnitName(unit)
	if IsSecret(isPlayer) or IsSecret(inGuild) or IsSecret(name) or not isPlayer or not inGuild then
		return false
	end
	return AddKarmaLine(tooltip, name)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
else
	GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
		if OnUnitTooltip(tooltip) then
			tooltip:Show()
		end
	end)
end

-- Guild & Communities roster: add karma to a member's tooltip
local function HookCommunitiesRoster()
	if ns.communitiesHooked or not CommunitiesMemberListEntryMixin then
		return
	end
	ns.communitiesHooked = true

	hooksecurefunc(CommunitiesMemberListEntryMixin, "OnEnter", function(entry)
		local info = entry.GetMemberInfo and entry:GetMemberInfo()
		if not info or not info.name or IsSecret(info.name) or not GameTooltip:IsOwned(entry) then
			return
		end
		if ns.IsGuildMember(ns.ShortName(info.name)) and AddKarmaLine(GameTooltip, info.name) then
			GameTooltip:Show()
		end
	end)
end

-- The roster UI is load-on-demand, so hook it when it loads (or now, if it already has)
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, loadedAddon)
	if loadedAddon == "Blizzard_Communities" or loadedAddon == addonName then
		HookCommunitiesRoster()
	end
end)
