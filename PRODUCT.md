# Product direction

**Quest With Friends** helps parties answer one question:

> **“Are we good to move on?”**

The product centers on actionable quest differences. A player should see who needs help and what to do next in roughly one second.

## Player goals

- Catch missing quests while the party can still share or pick them up.
- See who needs an objective another player has finished.
- Recognize readiness and completion differences.
- Know when everyone is caught up within the selected view.
- Understand when a party member's information is still arriving.

## Party Quest Status

The primary interface is a compact panel with one heading per quest and affected players underneath. **You** identifies the local player. A **Share** button on a quest heading offers it through WoW's party-wide sharing flow.

```text
QUEST WITH FRIENDS

The Lost Supplies                    [Share]
  ! Julia: Missing
  ! Bob: Missing

Gnoll Hunt
  • Julia: Gnolls slain 5/8

The Missing Scout
  • You: Still in progress
  ✓ Julia: Ready to turn in
```

Click a quest heading to collapse or expand its player details. Collapsed headings retain a compact summary counting distinct affected players and any **Share** button. Collapse choices persist across sessions and do not change comparison status.

When everyone is caught up, the panel shows **Party in sync**. The panel is locked by default. Uncheck **Lock panel** in addon settings to drag its header or resize from the bottom-right corner, then click **Unlocked · Lock** on the panel when finished. Width and a maximum-height ceiling are user-controlled; fonts and controls do not scale. While unlocked, the full height allowance is visible. While locked, the panel shrinks to content and scrolls all quest differences beyond the ceiling, keeping the heading, status, scope and connection notices pinned. Pinned notices can temporarily raise the minimum usable height without changing the saved ceiling. Position, dimensions, lock preference and filters persist account-wide; saved layout is validated and kept on screen after display or UI-scale changes.

While solo, **Preview appearance** in addon settings or `/qwf preview` shows plausible sample differences through the same panel. Filters, heading toggles, scrolling and unlocked layout controls work normally; sample sharing is disabled. A clear preview label and **End preview** button distinguish it from live data. Preview is session-only and ends on joining a group or reloading. Sample quests never enter synchronization or saved collapse preferences.

### Focus the view

A **View** dropdown groups visibility and ordering controls. Its **Show** section contains three independent choices:

- **Current zone only**, enabled by default.
- **Show profession quests**, hidden by default.
- **Show class quests**, hidden by default.

A muted scope label, such as **Current zone · Standard quests**, summarizes the selection. The synchronization status applies to that scope. WoW Forever's Camping quests use the profession filter.

The same dropdown has a **Sort by** section with two radio choices:

- **Smart** (default): missing quests first, with most recently active quests first within both groups.
- **Title A–Z**: alphabetical, without missing-first priority.

Smart activity comes from actual pickups, objective changes, readiness, completion or abandonment by you or a party member, not refreshes or unchanged snapshots. Initial snapshots establish a baseline. Activity is session-only and tracked even for filtered or currently synchronized quests. Equal or unknown activity uses title and quest ID as tie-breakers. The sort choice persists across sessions; preview demonstrates the same choices using fixed sample activity.

### Make differences actionable

Compare missing, active, ready-to-turn-in and known-completed states across all known party snapshots, including differences between friends when you are missing or still working on a quest. Highlight objective progress when any comparable party member has finished and another still needs it. When a player is ready to turn in or has already completed a quest, show unfinished players' remaining objectives alongside that readiness or completion status. Fall back to quest states when no usable remaining objective counts are available or variant comparisons are state-only. Deduplicate each player's status and objective rows, preserve objective order, and keep related differences together under the same quest heading. Unknown members receive connection notices, not assumed quest differences; cached snapshots remain comparable with their connection status.

Reviewed Retail variant families let friends on different class/race versions of the same task compare progress and completion. Sharing always uses the real active quest ID.

### Show connection health

Connection notices appear separately above quest groups. Distinguish offline members, addon detection, waiting for a snapshot, refreshing, stale data and protocol incompatibility. Keep the last comparison visible during recovery or disconnection, with a clear status. Offline members keep party status incomplete; syncing resumes automatically when they reconnect. `/qwf` requests a fresh comparison for online members.

## Synchronization

Addon-enabled members exchange complete quest snapshots through WoW's addon communication channel. Each snapshot carries actual quest IDs, titles, states, objective counts, locations and classifications. Filters apply to the local presentation.

Party changes and quest events drive updates. Paced messages, coalesced changes, automatic retries and stalled-transfer recovery keep synchronization responsive. See [PROTOCOL.md](PROTOCOL.md) for the wire format.

## Design principles

- **Readable at a glance:** lead with the quest and the player who needs attention.
- **Actionable:** put sharing beside a missing quest and progress beside an unfinished objective.
- **Quiet when caught up:** use a simple synchronization status for the selected scope.
- **Familiar:** work alongside Blizzard's quest tracker and normal quest-sharing flow.
- **Clear status:** distinguish fresh comparisons from data still arriving or recovering.

## Future opportunities

[TODO.md](TODO.md) tracks catch-up explanations, quest-chain relationships, per-quest filters and compact panel options. An optional secondary line in Blizzard's tracker could surface a friend's remaining progress beside a tracked quest.

[README.md](./README.md) describes the shipped experience; this brief guides future design decisions.
