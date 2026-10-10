# Quest With Friends

**Know when everyone is ready to move on.**

Quest With Friends shows the differences that matter while questing together: who missed a quest, who still needs an objective, and who is ready to turn in. When your party is caught up, it says **Party in sync**.

Built for **World of Warcraft Retail** and **WoW Forever**. The addon is self-contained and works alongside Blizzard's quest tracker.

## Why use it?

- **Catch missed quests before leaving town.** See which friends are missing a quest, with a **Share** button when WoW allows you to offer it.
- **Avoid leaving someone behind.** See who still needs progress when another party member has finished an objective.
- **Stop asking “Are you done yet?”** Readiness and completion differences appear together under one quest title.
- **Keep the view relevant.** Focus on the current zone and optionally include profession or class quests. On Forever, Camping quests count as profession quests too.
- **Compare Retail quest variants.** Six reviewed Northshire families share completion status; four also compare objective progress, while two compare readiness. Other quests and Forever compare by exact quest ID.
- **See connection health at a glance.** Clear notices identify members whose data is waiting, refreshing, stale, or incompatible.

An illustrative party view:

```text
The Lost Supplies                         [Share]
  ! Alex: Missing

Gnoll Hunt
  • Sam: Gnolls slain 5/8

The Missing Scout
  • You: Still in progress
  ✓ Alex: Ready to turn in
```

The compact, draggable panel remembers its position and hides when you leave the party. Click a quest heading to collapse or expand its details; choices persist across reloads and logins. Collapsed headings retain a short summary and the **Share** button when available.

## Install

1. Open this repository's **Releases** page and download `QuestWithFriends-<version>.zip`, the ready-to-load addon package.
2. Extract it into your client's `Interface/AddOns/` directory. The final layout must be:

   ```text
   Interface/AddOns/QuestWithFriends/QuestWithFriends.toc
   ```

3. Enable **Quest With Friends** in the character-selection AddOns menu, then log in or `/reload`.
4. Have your friends install the same release so everyone can exchange compatible quest data.

Install a separate copy in each client if you play both Retail and Forever. The current TOC targets Retail 12.1 (`120100`) and WoW Forever beta 1.60.1 (`16001`); Forever beta interface numbers may change. Version 0.1.5 uses protocol 1.0. Peers using older development builds or a different protocol major receive an update notice.

## Use it

Join a party and the panel appears automatically. Quest changes update it as you play.

**Try it solo:** use **`/qwf preview`**, or enable **Preview appearance** in the addon's settings, to show sample party data. Try the filters, collapse quest headings, and drag the panel into position. Share buttons are shown but disabled. Click **End preview**, use `/qwf preview` again, or `/qwf preview off` to stop. Preview also ends when you join a group or reload; it never sends sample data. Position and filter changes are saved normally, but sample collapse choices are not.

- **Missing:** a player is missing a quest known to another party member.
- **Still in progress:** someone else has finished an objective or quest that this player still needs.
- **Ready/completed:** highlights a readiness or completion difference.
- **Party status incomplete:** a member is waiting for fresh, compatible data. Cached differences stay visible while refreshing.

Click **Share** beside a quest to offer it through WoW's normal party-wide sharing flow. WoW checks eligibility, and recipients accept the offer.

Open **Filters** in the header:

| Filter                 | Default |
| ---------------------- | ------- |
| Current zone only      | On      |
| Show profession quests | Off     |
| Show class quests      | Off     |

Settings persist across reloads. Collapsing a quest only hides its details—it still contributes to party status. **Party in sync** reflects the selected filters. Quests with an unknown location remain visible; an unknown current zone temporarily expands the view to all zones. Long lists show a count of hidden quests or differences.

Recently completed quests stay available for comparisons during the current login, up to 30 entries. Use **`/qwf`** to request a fresh party comparison. Automatic retries and stalled-transfer recovery keep updates flowing.

## Reporting problems

Open a GitHub issue with your client (Retail or Forever), addon version, reproduction steps, and expected versus actual behavior. For sync issues, include whether everyone used the same release and whether `/qwf` helped. Screenshots are useful with player identities redacted. Keep account files (`WTF` and SavedVariables) private.

## Development and releases

See [DEVELOPING.md](DEVELOPING.md) for tests, packaging, simulator screenshots, and releases; [CHANGELOG.md](CHANGELOG.md) for changes; and [PROTOCOL.md](PROTOCOL.md) for the wire format. Quest-data tooling is documented in [tools/README.md](tools/README.md).

## License and credits

Original code and documentation are [MIT licensed](LICENSE). Quest data uses ATT and QuestieDB.
