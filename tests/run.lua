-- End-to-end tests: several players run the addon in a simulated guild.
-- Run from the repository root with Lua 5.1 (the version WoW uses): lua tests/run.lua

package.path = "tests/?.lua;" .. package.path
local Mock = require("wowmock")

local MINUTE, DAY = 60, 86400
local tests = {}

local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end

local function eq(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function ok(condition, message)
	if not condition then
		error(message or "condition failed", 2)
	end
end

-- A guild where Ghostvox (guild leader), Cut Loss and Vrani run the addon, and
-- Polyphia and Loss are online without it. Everyone with the addon is logged in
-- and has finished the login sync.
local function NewGuild()
	local world = Mock.NewWorld({
		leader = "Ghostvox",
		members = {
			"Ghostvox",
			{ name = "Cut Loss", classFile = "MAGE" },
			"Vrani",
			{ name = "Polyphia", online = true },
			{ name = "Loss", online = true },
			"Offline Ollie",
		},
	})
	for _, name in ipairs({ "Ghostvox", "Cut Loss", "Vrani" }) do
		world:Login(name)
	end
	world:Advance(30)
	return world
end

local ADDON_USERS = { "Ghostvox", "Cut Loss", "Vrani" }

-- Check that every logged-in addon user agrees on a player's karma
local function AllHaveKarma(world, player, expected)
	for name in pairs(world.clients) do
		eq(world:Karma(name, player), expected, name .. "'s karma for " .. player)
	end
end

---------------------------------------------------------------------------
-- Giving karma
---------------------------------------------------------------------------

test("++ in guild chat gives karma on every client, with the reason", function()
	local world = NewGuild()
	world:Say("Vrani", "Cut Loss++ for the heals")
	world:Flush()

	AllHaveKarma(world, "Cut Loss", 1)
	for _, name in ipairs(ADDON_USERS) do
		local events = world:Events(name)
		eq(#events, 1, name .. "'s history size")
		eq(events[1].from, "Vrani")
		eq(events[1].to, "Cut Loss")
		eq(events[1].reason, "for the heals")
	end
end)

test("two-word names beat a one-word name inside them", function()
	local world = NewGuild()
	world:Say("Vrani", "Cut Loss++")
	world:Flush()

	AllHaveKarma(world, "Cut Loss", 1)
	AllHaveKarma(world, "Loss", 0)
end)

test("leading words are ignored and names match case-insensitively", function()
	local world = NewGuild()
	world:Say("Vrani", "great tanking cut loss++")
	world:Flush()

	AllHaveKarma(world, "Cut Loss", 1)
end)

test("the recipient announces their new total exactly once", function()
	local world = NewGuild()
	world:Say("Vrani", "Cut Loss++")
	world:Flush()

	eq(#world:ChatMatching("now have"), 1, "announcements")
	eq(world:ChatFrom("Cut Loss", "I now have 1 karma!")[1], "I now have 1 karma!")
end)

test("several mentions in one message share the trailing reason", function()
	local world = NewGuild()
	world:Say("Ghostvox", "Vrani++ Polyphia++ thanks for the carry")
	world:Flush()

	AllHaveKarma(world, "Vrani", 1)
	AllHaveKarma(world, "Polyphia", 1)
	for _, event in ipairs(world:Events("Cut Loss")) do
		eq(event.reason, "thanks for the carry")
	end
end)

test("chat links in a reason are kept as plain text", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++ for the |cff0070dd|Hitem:1234::::|h[Shiny Sword]|h|r")
	world:Flush()

	eq(world:Events("Ghostvox")[1].reason, "for the [Shiny Sword]")
end)

test("self-karma, non-members and malformed ++ are ignored", function()
	local world = NewGuild()
	world:Say("Vrani", "Vrani++")
	world:Say("Vrani", "Stranger++")
	world:Say("Vrani", "Polyphia++abc")
	world:Say("Vrani", "Polyphia+++")
	world:Flush()

	AllHaveKarma(world, "Vrani", 0)
	AllHaveKarma(world, "Polyphia", 0)
	eq(#world:Events("Ghostvox"), 0, "history size")
end)

test("players without the addon can give karma", function()
	local world = NewGuild()
	world:Say("Polyphia", "Vrani++")
	world:Flush()

	AllHaveKarma(world, "Vrani", 1)
end)

---------------------------------------------------------------------------
-- Spam protection
---------------------------------------------------------------------------

test("the same giver can't give the same player karma again within 5 minutes", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++")
	world:Flush()
	world:Say("Vrani", "Polyphia++ Polyphia++")
	world:Advance(4 * MINUTE)
	world:Say("Vrani", "Polyphia++")
	world:Flush()
	AllHaveKarma(world, "Polyphia", 1)

	-- A different giver isn't blocked
	world:Say("Ghostvox", "Polyphia++")
	world:Flush()
	AllHaveKarma(world, "Polyphia", 2)

	-- And the cooldown runs out
	world:Advance(2 * MINUTE)
	world:Say("Vrani", "Polyphia++")
	world:Flush()
	AllHaveKarma(world, "Polyphia", 3)
end)

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

test("a new addon user gets totals and history from the guild on login", function()
	local world = NewGuild()
	world:Say("Vrani", "Cut Loss++ for the heals")
	world:Say("Ghostvox", "Polyphia++")
	world:Flush()

	world.leader = "Ghostvox"
	world:AddMember("Newbie")
	world:Login("Newbie")
	world:Advance(60)

	eq(world:Karma("Newbie", "Cut Loss"), 1)
	eq(world:Karma("Newbie", "Polyphia"), 1)
	local events = world:Events("Newbie")
	eq(#events, 2, "history size (no duplicates from several responders)")
	for _, event in ipairs(events) do
		if event.to == "Cut Loss" then
			eq(event.reason, "for the heals")
		end
	end
end)

test("a player catches up on history they missed while offline", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++")
	world:Flush()

	world:Logout("Cut Loss")
	world:Advance(DAY)
	world:Say("Vrani", "Ghostvox++ for leading")
	world:Say("Ghostvox", "Vrani++")
	world:Flush()

	world:Advance(DAY)
	world:Login("Cut Loss")
	world:Advance(60)

	eq(world:Karma("Cut Loss", "Ghostvox"), 1)
	eq(world:Karma("Cut Loss", "Vrani"), 1)
	eq(#world:Events("Cut Loss"), 3, "history size")
	eq(#world:Events("Ghostvox"), 3, "others' history isn't duplicated")
end)

test("sync messages are spaced out to respect the addon message throttle", function()
	local world = NewGuild()
	for i = 1, 40 do
		world:AddMember("Raider" .. i)
		world:Say("Vrani", "Raider" .. i .. "++ for showing up to the very long raid tonight")
	end
	world:Flush()

	world.addonLog = {}
	world:AddMember("Newbie")
	world:Login("Newbie")
	world:Advance(120)

	eq(#world:Events("Newbie"), 40, "history size")
	local lastSent = {}
	for _, entry in ipairs(world.addonLog) do
		if lastSent[entry.from] and entry.message:match("^EVENTS:") then
			ok(entry.time - lastSent[entry.from] >= 1, entry.from .. " sent sync messages less than 1s apart")
		end
		if entry.message:match("^EVENTS:") then
			lastSent[entry.from] = entry.time
		end
	end
end)

test("'gk update' in chat sends one sync request for everyone", function()
	local world = NewGuild()
	world.addonLog = {}
	world:Say("Polyphia", "gk update")
	world:Advance(30)

	local requests = 0
	for _, entry in ipairs(world.addonLog) do
		if entry.message == "REQUEST" then
			requests = requests + 1
		end
	end
	eq(requests, 1, "sync requests")
end)

---------------------------------------------------------------------------
-- Guild leader tools
---------------------------------------------------------------------------

test("leader edits reach everyone and beat a stale higher total", function()
	local world = NewGuild()
	for i = 1, 5 do
		world:Say("Vrani", "Polyphia++")
		world:Advance(6 * MINUTE)
	end
	AllHaveKarma(world, "Polyphia", 5)

	world:Logout("Cut Loss")
	world.clients["Ghostvox"].ns.SetKarma("Polyphia", 1)
	world:Advance(10)
	eq(world:Karma("Vrani", "Polyphia"), 1, "online player gets the edit")

	world:Login("Cut Loss")
	world:Advance(60)
	AllHaveKarma(world, "Polyphia", 1)
end)

test("rapid leader edits are batched into one message", function()
	local world = NewGuild()
	world.addonLog = {}
	local ns = world.clients["Ghostvox"].ns
	ns.SetKarma("Vrani", 1)
	ns.SetKarma("Vrani", 2)
	ns.SetKarma("Vrani", 3)
	world:Advance(10)

	local data = 0
	for _, entry in ipairs(world.addonLog) do
		if entry.message:match("^DATA:") then
			data = data + 1
		end
	end
	eq(data, 1, "data messages")
	AllHaveKarma(world, "Vrani", 3)
end)

test("only the guild leader can edit karma", function()
	local world = NewGuild()
	world.clients["Vrani"].ns.SetKarma("Vrani", 100)
	world:Advance(10)
	AllHaveKarma(world, "Vrani", 0)
end)

test("a reset clears karma and history everywhere, including for offline players", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++ for the heals")
	world:Flush()
	world:Logout("Cut Loss")

	world:Advance(10)
	world:Slash("Ghostvox", "reset")
	world:Advance(10)
	AllHaveKarma(world, "Polyphia", 0)
	eq(#world:Events("Vrani"), 0, "history after reset")

	world:Login("Cut Loss")
	world:Advance(60)
	AllHaveKarma(world, "Polyphia", 0)
	eq(#world:Events("Cut Loss"), 0, "offline player's history after reset")
	eq(#world:Events("Vrani"), 0, "stale history doesn't come back")
end)

---------------------------------------------------------------------------
-- Leaderboards and reports
---------------------------------------------------------------------------

test("weekly and monthly leaderboards count recent karma only", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++")
	world:Flush()
	world:Advance(10 * DAY)
	world:Say("Vrani", "Polyphia++")
	world:Say("Vrani", "Cut Loss++")
	world:Flush()

	local ns = world.clients["Ghostvox"].ns
	eq(ns.GetKarmaCounts(7)["Polyphia"], 1, "last 7 days")
	eq(ns.GetKarmaCounts(30)["Polyphia"], 2, "last 30 days")
	eq(ns.GetKarmaCounts()["Polyphia"], 2, "all time")

	local week = ns.BuildLeaderboard(7)
	eq(#week, 2)
	eq(week[1].place, 1)
	eq(week[2].place, 1, "tied karma shares a place")
end)

test("old history is pruned on login but all-time karma stays", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++")
	world:Flush()
	world:Logout("Ghostvox")
	world:Advance(40 * DAY)
	world:Login("Ghostvox")
	world:Advance(60)

	eq(#world:Events("Ghostvox"), 0, "history after 40 days")
	eq(world:Karma("Ghostvox", "Polyphia"), 1, "all-time karma")
end)

test("/gk report week posts the weekly top 10", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++")
	world:Flush()
	world:Slash("Ghostvox", "report week")
	world:Advance(10)

	local lines = world:ChatFrom("Ghostvox")
	eq(lines[1], "=== Top 10 Karma: Last 7 Days ===")
	eq(lines[2], "1. Polyphia: 1")
end)

test("'guildkarma' in chat is answered exactly once", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++")
	world:Flush()
	world:Say("Polyphia", "guildkarma")
	world:Say("Vrani", "karma")
	world:Flush()

	local answers = world:ChatMatching("has %d+ karma!")
	eq(#answers, 2, "answers")
	eq(answers[1].message, "Polyphia has 1 karma!")
	eq(answers[2].from, "Vrani", "addon users answer for themselves")
end)

test("/gk history prints recent karma with reasons", function()
	local world = NewGuild()
	world:Say("Vrani", "Polyphia++ for the heals")
	world:Flush()
	world:Slash("Ghostvox", "history Polyphia")

	local log = table.concat(world.clients["Ghostvox"].log, "\n")
	ok(log:find("Vrani %-> Polyphia %(1m ago%): for the heals"), "history line missing:\n" .. log)
end)

---------------------------------------------------------------------------
-- UI and tooltips
---------------------------------------------------------------------------

test("the karma window shows the leaderboard, periods and activity", function()
	local world = NewGuild()
	world:Say("Vrani", "Cut Loss++ for the heals")
	world:Flush()

	local client = world.clients["Ghostvox"]
	client.ns.ToggleUI()
	ok(client.env.GuildKarmaFrame:IsShown(), "window opens")

	-- Hovering a leaderboard row shows the reason
	local rows = world:FindFrames("Ghostvox", function(frame)
		return frame.entry and frame.entry.key == "Cut Loss"
	end)
	eq(#rows, 1, "Cut Loss rows")
	rows[1]:RunScript("OnEnter")
	ok(client.env.GameTooltip:Text():find("for the heals"), "tooltip shows the reason")

	-- Period button cycles and leader controls hide outside all time
	world:FindButton("Ghostvox", "All time"):Click()
	world:FindButton("Ghostvox", "Last 30 days")
	ok(not rows[1].set:IsShown(), "leader controls hidden for a period")
	world:FindButton("Ghostvox", "Last 30 days"):Click()
	world:FindButton("Ghostvox", "Last 7 days"):Click()
	ok(rows[1].set:IsShown(), "leader controls back for all time")

	-- Leader + button edits karma
	rows[1].plus:Click()
	world:Advance(10)
	AllHaveKarma(world, "Cut Loss", 2)

	-- Activity tab lists the event
	world:FindButton("Ghostvox", "Activity"):Click()
	local activity = world:FindFrames("Ghostvox", function(frame)
		return frame.frameType == "FontString" and type(frame.text) == "string" and frame.text:find("gave karma to")
	end)
	eq(#activity, 1, "activity rows")
end)

test("the scroll bar only shows when the list is taller than the window", function()
	local world = NewGuild()
	local client = world.clients["Ghostvox"]
	client.ns.ToggleUI()

	local scroll = client.env.GuildKarmaLeaderboardScroll

	-- The bar is the one frame that appears when the range grows
	local function VisibleFrames()
		local visible = {}
		for _, frame in ipairs(client.frames) do
			visible[frame] = frame.shown
		end
		return visible
	end
	scroll.scrollRange = 0
	scroll:RunScript("OnScrollRangeChanged")
	local before = VisibleFrames()
	scroll.scrollRange = 200
	scroll:RunScript("OnScrollRangeChanged")
	local changed = 0
	for frame, wasShown in pairs(before) do
		if not wasShown and frame.shown then
			changed = changed + 1
		end
	end
	eq(changed, 1, "one scroll bar appears when the list overflows")

	-- Mouse wheel scrolls, clamped to the range
	scroll:RunScript("OnMouseWheel", -1)
	ok(scroll:GetVerticalScroll() > 0, "wheel scrolls down")
	scroll:RunScript("OnMouseWheel", 100)
	eq(scroll:GetVerticalScroll(), 0, "can't scroll above the top")
	scroll:RunScript("OnMouseWheel", -100)
	eq(scroll:GetVerticalScroll(), 200, "can't scroll past the bottom")
end)

test("guild members' tooltips show their karma", function()
	local world = NewGuild()
	world:Say("Vrani", "Cut Loss++")
	world:Flush()

	local client = world.clients["Ghostvox"]
	client.tooltipUnit, client.tooltipUnitName = "mouseover", "Cut Loss"
	client.env.GameTooltip:SetOwner()
	client.env.GameTooltip:RunScript("OnTooltipSetUnit")
	ok(client.env.GameTooltip:Text():find("Guild Karma 1 karma  %(#1%)"), "tooltip line:\n" .. client.env.GameTooltip:Text())
end)

---------------------------------------------------------------------------

local failures = 0
for _, t in ipairs(tests) do
	local passed, err = xpcall(t.fn, debug.traceback)
	if passed then
		print("ok    " .. t.name)
	else
		failures = failures + 1
		print("FAIL  " .. t.name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
	end
end
print(string.format("\n%d passed, %d failed", #tests - failures, failures))

-- Exit non-zero on failure when run by the standalone interpreter (e.g. in CI)
if arg and failures > 0 then
	os.exit(1)
end
return failures
