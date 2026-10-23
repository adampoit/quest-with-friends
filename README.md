# Quest With Friends

**Know when everyone is ready to move on.**

<p align="center">
  <img src="https://raw.githubusercontent.com/adampoit/quest-with-friends/main/screenshots/main.png" alt="Quest With Friends panel showing missing quests, objective progress, and party members ready to turn in." width="440" />
</p>

Quest With Friends shows the differences that matter while questing together: who missed a quest, who still needs an objective, and who is ready to turn in. When your party is caught up, it says **Party in sync**.

Built for **World of Warcraft Retail** and **WoW Forever**. The addon is self-contained and works alongside Blizzard's quest tracker. Everyone in the party needs the addon to share their progress.

## Why use it?

- **Catch missed quests before leaving town.** See which friends are missing a quest, with a **Share** button when WoW allows you to offer it.
- **Avoid leaving someone behind.** See remaining objectives when another party member has finished, with readiness and completion differences grouped under one quest title.
- **Put spare quest items to use.** For identifiable tradeable item objectives, finished members can show counts such as **10/10 · 2 spare** while a friend still needs items. Spare counts exclude items needed for the player's own logged quests and bank stock.
- **Keep the view relevant.** Focus on the current zone and optionally include profession or class quests. On Forever, Camping quests count as profession quests too.
- **See connection health at a glance.** Notices distinguish offline members from waiting, refreshing, stale, or incompatible data. Last-known differences stay visible during recovery.

## Get started

1. Install Quest With Friends for your client. For manual installation, download `QuestWithFriends-<version>.zip` from [GitHub Releases](https://github.com/adampoit/quest-with-friends/releases) and extract it so the addon manifest is at `Interface/AddOns/QuestWithFriends/QuestWithFriends.toc`.
2. Enable **Quest With Friends** in the character-selection AddOns menu, then log in or `/reload`.
3. Have your friends install the same release, then join a party. The panel appears and updates automatically as you quest.

Install a separate copy in each client if you play both Retail and Forever.

**Try it solo:** use `/qwf preview`, or enable **Preview appearance** in the addon's settings, to explore sample party data and arrange the panel. Sharing is disabled in preview. Click **End preview** or use `/qwf preview off` to stop; joining a group or reloading also ends it.

## How it works

The panel highlights **missing quests**, **unfinished objectives**, and **ready-to-turn-in or completed quests** when party members differ. Comparisons include differences between your friends, even when you are missing or still working on the quest yourself.

Click **Share** beside a quest to offer it through WoW's normal party-wide sharing flow. WoW checks eligibility, and recipients accept the offer. Right-click a quest heading and choose **Abandon quest…** to open WoW's confirmation, including its quest-item removal warning when applicable. This action is available only for abandonable quests in your own log and is disabled for sample data. Most comparisons use exact quest IDs; a small set of reviewed Retail Northshire quest variants also compare across class and race versions.

### Focus the view

Open **View** in the panel header to choose:

- **Current zone only** — on by default.
- **Show profession quests** and **Show class quests** — off by default.
- **Smart** sorting — missing quests first, then most recent quest activity within each group — or **Title A–Z**.

**Party in sync** reflects these filters. Click a quest heading to collapse or expand its details; collapsed quests still count toward party status. Long lists scroll.

### Arrange the panel

Click the lock icon beside **View** to unlock the panel. Drag the header to move it and the bottom-right corner to resize it, then lock it again. The locked panel shrinks to fit its content, scrolling when needed. Layout, filters, sorting, and collapse choices are saved across reloads and characters.

The panel hides when you leave the party. Use `/qwf` to request a fresh party comparison if something looks out of date. **Party status incomplete** means a member is offline or the addon is waiting for fresh, compatible data—not that everyone is caught up.

## Feedback and links

[Report a problem on GitHub](https://github.com/adampoit/quest-with-friends/issues) with your client (Retail or Forever), addon version, and reproduction steps. For sync issues, mention whether everyone used the same release and whether `/qwf` helped. Redact player identities from screenshots and keep account files and SavedVariables private.

- [Changelog](https://github.com/adampoit/quest-with-friends/blob/main/CHANGELOG.md)
- [Development and releases](https://github.com/adampoit/quest-with-friends/blob/main/DEVELOPING.md)
- [Quest-data sources and tooling](https://github.com/adampoit/quest-with-friends/blob/main/tools/README.md)

Original code and documentation are [MIT licensed](https://github.com/adampoit/quest-with-friends/blob/main/LICENSE). Quest data uses ATT and QuestieDB.
