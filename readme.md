# Guild Karma Tracker

Track and celebrate your guild members' contributions with a simple karma system!

## What is Guild Karma?

Guild Karma is a fun, lightweight addon that lets guild members give recognition to each other through a simple "++" system. When someone does something awesome, just type their name followed by ++ in guild chat and they'll earn karma!

## Features

✨ **Simple Recognition System**
- Type `PlayerName++` in guild chat to give karma
- Works even if not everyone has the addon installed
- Supports special characters in names (Kaós, José, François, etc.)

🛡️ **Smart Protections**
- Prevents self-karma (no cheating!)
- Only guild members can receive karma
- Validates all names against the guild roster

📊 **Karma Tracking & Leaderboards**
- View top 10 karma holders with `/gk` or `/gk report`
- Check specific player karma with `/gk PlayerName`
- Type `guildkarma` in guild chat to see your own karma

🔄 **Multi-User Sync**
- Sync karma data between all addon users
- Type `gk update` in guild chat to sync everyone's data
- Keeps the highest karma values to prevent data loss
- Perfect for catching up after being offline

🪟 **Karma Window**
- Open with the minimap button or `/gk ui` to browse every guild member's karma
- Drag the minimap button around the minimap; right-click it to sync
- Search by name, sort by karma or name, class-colored names with online status
- Leaderboard places with gold, silver, and bronze for the top three; tied karma shares a place
- Hide members with 0 karma, and post the top 10 to guild chat with one click

👑 **Guild Leader Management**
- The guild leader can raise, lower, or set any member's karma from the window
- Reset karma for the whole guild with one click
- Leader edits and resets sync to every addon user, including those who were offline

💬 **Clean Chat Integration**
- Recipients automatically announce their new karma total
- No spam - single announcements only
- Report leaderboards to guild chat with proper delays

## Commands

**Slash Commands:**
- `/gk ui` - Open the karma window
- `/gk minimap` - Show or hide the minimap button
- `/gk` - View top 10 karma holders (private)
- `/gk PlayerName` - Check specific player's karma (private)
- `/gk report` - Post top 10 to guild chat (public)
- `/gk report PlayerName` - Post specific player's karma to guild chat (public)
- `/gk sync` - Request karma sync from other addon users
- `/gk debug PlayerName` - Test if a name is in guild roster
- `/gk reset` - Reset all karma for the guild (guild leader only)
- `/gk help` - Show all commands

**Guild Chat Triggers:**
- `PlayerName++` - Give karma to a player
- `guildkarma` - Check your own karma
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

## Support

Found a bug or have a suggestion? Leave a comment below!

---

*Give karma. Get karma. Build community.* 💚
