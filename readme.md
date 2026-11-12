# Guild Karma Tracker

Track and celebrate your guild members' contributions with a simple karma system!

## What is Guild Karma?

Guild Karma is a fun, lightweight addon that lets guild members give recognition to each other through a simple "++" system. When someone does something awesome, just type their name followed by ++ in guild chat and they'll earn karma!

## Features

✨ **Simple Recognition System**
- Type `PlayerName++` in guild chat to give karma
- Add a reason: `PlayerName++ for the heals`
- Works even if not everyone has the addon installed
- Supports special characters in names (Kaós, José, François, etc.)
- Supports two-word names on WoW Forever (`Cut Loss++`)

🛡️ **Smart Protections**
- Prevents self-karma (no cheating!)
- Spam protection: the same player can give the same person karma once every 5 minutes
- Only guild members can receive karma
- Validates all names against the guild roster

📊 **Karma Tracking & Leaderboards**
- All-time, last 30 days and last 7 days leaderboards
- View top 10 karma holders with `/gk` or `/gk report` (add `week` or `month`)
- Check specific player karma with `/gk PlayerName`, and why they got it with `/gk history PlayerName`
- See a guild member's karma in their tooltip and in the Guild & Communities roster
- Type `guildkarma` in guild chat to see your own karma

🔄 **Multi-User Sync**
- Karma and its history sync automatically when you log in
- Type `gk update` in guild chat to sync everyone's data
- Catch up on everything you missed while offline
- Guild leader edits and resets always win over old data

🪟 **Karma Window**
- Open with the minimap button or `/gk ui`
- Your own karma and weekly gain at a glance
- **Leaderboard tab**: search, sort, class icons, guild ranks, and gold, silver and bronze for the top three; tied karma shares a place
- **Activity tab**: a feed of who gave karma to whom, and why
- Hover a member to see their recent karma and the reasons given
- Hide members with 0 karma, and post the top 10 to guild chat with one click
- Drag the minimap button around the minimap; right-click it to sync

🛒 **Karma Shop**
- Spend karma on guild bank items with `/gk shop`
- The guild master and officers list items and prices
- Request an item and an officer approves it, then hands it over
- Spending never lowers the leaderboard: your balance is karma earned minus karma spent

🛠️ **Guild Professions**
- See who has which main profession or Cooking, and their skill, with `/gk professions`
- Search by profession or member name
- Shared automatically by members running the addon, including offline members

👑 **Guild Leader Management**
- The guild leader can raise, lower, or set any member's karma from the window
- Reset karma for the whole guild with one click
- Leader edits and resets sync to every addon user, including those who were offline

💬 **Clean Chat Integration**
- Recipients automatically announce their new karma total
- Only one addon answers chat triggers, so there's no wall of replies
- Report leaderboards to guild chat with proper delays

## Commands

**Slash Commands:**
- `/gk ui` - Open the karma window
- `/gk shop` - Spend karma on guild bank items
- `/gk professions` - See who in the guild has which profession
- `/gk minimap` - Show or hide the minimap button
- `/gk` - View top 10 karma holders (private)
- `/gk PlayerName` - Check specific player's karma (private)
- `/gk report` - Post top 10 to guild chat (public)
- `/gk report week` / `/gk report month` - Post the top 10 for the last 7 or 30 days (public)
- `/gk report PlayerName` - Post specific player's karma to guild chat (public)
- `/gk history [PlayerName]` - Show recent karma and the reasons given (private)
- `/gk sync` - Request karma sync from other addon users
- `/gk debug PlayerName` - Test if a name is in guild roster
- `/gk simulate Sender Name: message` - Test a guild chat line on your client only, without posting it
- `/gk reset` - Reset all karma for the guild (guild leader only)
- `/gk help` - Show all commands

**Guild Chat Triggers:**
- `PlayerName++` - Give karma to a player
- `PlayerName++ reason` - Give karma with a reason
- `guildkarma` or `karma` - Check your own karma
- `gk update` - Trigger a sync for everyone

## How It Works

1. **Anyone** (with or without the addon) can type `PlayerName++` in guild chat
2. **Everyone with the addon** automatically tracks the karma
3. **Only the recipient** announces their new total to avoid spam
4. **Players can sync** their data anytime to stay up-to-date

## Perfect For

- Recognizing helpful guild members
- Thanking raiders who performed well
- Acknowledging crafters who help with gear
- Building positive guild culture
- Having fun and friendly competition

## Installation

1. Download and extract to your `Interface/AddOns` folder
2. Restart WoW or type `/reload`
3. Share with guildmates for best experience!

## Notes

- Works on Retail (Midnight), Mists of Pandaria Classic, Cataclysm Classic, Titan Reforged, Burning Crusade Anniversary, Forever, and Classic Era / Season of Discovery
- Data is stored per-guild (multi-guild support)
- Sync feature requires at least 2 people with the addon
- More users = better coverage and more accurate karma tracking
- Karma history is kept for 35 days; all-time totals are kept forever
- On Retail, karma given during boss encounters may not be counted, because the game hides chat from addons during fights

## Development

End-to-end tests run several simulated players in a fake guild. Run them from the repository root with Lua 5.1:

```
lua tests/run.lua
```

Pushing a version tag (e.g. `1.3.0`) runs the tests, then packages the addon and uploads it to CurseForge and GitHub Releases. This needs a `CF_API_KEY` repository secret holding a CurseForge API token.

## Support

Found a bug or have a suggestion? Leave a comment below!

---

*Give karma. Get karma. Build community.* 💚
