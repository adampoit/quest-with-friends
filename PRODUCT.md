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

When everyone is caught up, the panel shows **Party in sync**. Its draggable position and filter choices persist across sessions.

### Focus the view

A **Filters** dropdown contains three independent choices:

- **Current zone only**, enabled by default.
- **Show profession quests**, hidden by default.
- **Show class quests**, hidden by default.

A muted scope label, such as **Current zone · Standard quests**, summarizes the selection. The synchronization status applies to that scope. WoW Forever's Camping quests use the profession filter.

### Make differences actionable

Compare missing, active, ready-to-turn-in and known-completed states. Highlight objective progress when one player has finished and another still needs it. Keep related differences together under the same quest heading.

Reviewed Retail variant families let friends on different class/race versions of the same task compare progress and completion. Sharing always uses the real active quest ID.

### Show connection health

Connection notices appear separately above quest groups. Distinguish addon detection, waiting for a snapshot, refreshing, stale data and protocol incompatibility. Keep the last comparison visible during recovery, with a clear status. `/qwf` requests a fresh comparison.

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
