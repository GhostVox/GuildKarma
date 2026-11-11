# Changelog

## 1.4.0

### New
- **Karma shop** (`/gk shop`): spend karma on guild bank items
  - The guild master and officers list items and prices (shift-click an item to link it)
  - Members request an item; the karma is held until an officer approves or denies it
  - Officers approve, then hand the item over and mark it delivered
  - Spending never lowers the leaderboard: your balance is karma earned minus karma spent
  - Officers are told about new requests, and members about decisions on theirs
- **Professions tab** (`/gk professions`): see who in the guild has which profession and their skill, searchable by profession or name. Members running the addon share theirs automatically, and offline members' professions are passed along by whoever is online.

## 1.3.0

### New
- **Redesigned karma window**: a cleaner dark look, your own karma and weekly gain at the top, class icons and guild ranks on the leaderboard
- **Activity tab**: a feed of who gave karma to whom, when, and why
- **Reasons**: add a reason after `++`, e.g. `Cut Loss++ for the heals`. Reasons show in the Activity tab, leaderboard tooltips and `/gk history`
- **Weekly and monthly leaderboards**: switch between All time, Last 30 days and Last 7 days in the window, or post them with `/gk report week` and `/gk report month`
- **Karma in tooltips**: a guild member's karma and place show in their player tooltip and in the Guild & Communities roster
- `/gk history [name]`: print recent karma and the reasons given

### Changes
- **Spam protection**: the same player can give the same person karma once every 5 minutes
- Karma history syncs between addon users, including what you missed while offline
- Guild-wide resets also clear karma history

## 1.2.0

### New
- **Karma window** (`/gk ui`): a searchable, sortable list of guild members with class colors, online status and tooltips
- **Leaderboard places:** tied karma shares a place (1, 2, 2, 4), and players with no karma aren't ranked
- **Top 3 colors:** gold, silver and bronze for the top three places
- **"Hide 0 karma" filter**, remembered between sessions
- **"Post Top 10" button** that posts the leaderboard to guild chat
- **Minimap button:** left-click opens the karma window, right-click syncs, and you can drag it around the minimap. Use `/gk minimap` to show or hide it.
- **Guild leader tools:** raise, lower, set or reset any member's karma from the window. Changes sync to every addon user, including players who were offline when the change was made.

### Changes
- `/gk reset` now resets karma for the whole guild, and only the guild leader can use it
- `/gk` and `/gk report` use the same leaderboard as the window

### Fixes
- WoW Forever: karma now works for two-word character names (e.g. `Cut Loss++`), and names keep their capital letters
- Retail: updated for patch 12.1.5, so the addon no longer shows as out of date

## 1.1.0

### New
- Supports Retail, Mists, Cataclysm, Titan Reforged, TBC Anniversary, Forever and Classic Era

### Fixes
- Large guilds no longer break syncing: data is sent in chunks under the addon message size limit
- Only one player's addon answers `karma` / `guildkarma` in guild chat, instead of everyone's
- `gk update` sends a single sync request instead of one from each addon user
- No more errors on Retail during boss fights, when chat is locked
