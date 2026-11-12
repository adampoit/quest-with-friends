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
Quest With Friends

The Lost Supplies                    [Share]
  ! Julia: Missing
  ! Bob: Missing

Gnoll Hunt
  • Julia: Gnolls slain 5/8

The Missing Scout
  • You: Still in progress
  ✓ Julia: Ready to turn in
```

Left-click a quest heading to collapse or expand its player details. Collapsed headings retain a compact summary counting distinct affected players and any **Share** button. Collapse choices persist across sessions and do not change comparison status. For abandonable quests in your own log, right-click opens a quest-actions menu with **Abandon quest…**; a tooltip advertises the menu. Choosing it opens Blizzard's confirmation, including quest-item removal warnings when applicable. Actions use the real logged quest ID, not a comparison-family ID, and revalidate it before opening confirmation. Preview and screenshot samples never offer abandonment.

When everyone is caught up, the panel shows **Party in sync**. The panel is locked by default. A small lock toggle beside **View** shows a muted closed lock when locked and a highlighted open lock when unlocked, with action tooltips. Click it to unlock the panel, drag its header or resize from the bottom-right corner, then click it again when finished. An unlocked-only hint explains dragging. **Lock panel** in addon settings controls the same preference. Width and a maximum-height ceiling are user-controlled; fonts and controls do not scale. While unlocked, the full height allowance is visible. While locked, the panel shrinks to content and scrolls all quest differences beyond the ceiling, keeping the heading, status, scope and connection notices pinned. Pinned notices can temporarily raise the minimum usable height without changing the saved ceiling. Position, dimensions, lock preference and filters persist account-wide; saved layout is validated and kept on screen after display or UI-scale changes.

While solo, **Preview appearance** in addon settings or `/qwf preview` shows plausible sample differences through the same panel. Filters, heading toggles, scrolling and unlocked layout controls work normally; sample sharing is disabled. The brighter, title-case addon heading leads the panel; live synchronization status remains prominent in the header, while preview shows the scope directly beneath the heading. The muted **Preview · Sample party data** notice sits beside **End preview** in the pinned bottom-left footer, distinguishing samples from live data and keeping both clear of the bottom-right resize handle. The notice wraps at narrow widths, with footer space reserved for all its lines. Preview is session-only and ends on joining a group or reloading. Sample quests never enter synchronization or saved collapse preferences.

A hidden **Screenshot tools** section in addon settings offers quest-difference, collapsed-heading and party-in-sync scenarios. A maintainer slash command reveals or hides the section without changing the active view. Scenario buttons close settings and reuse isolated samples with the live header/status and no preview footer. Samples demonstrate multiple remaining objectives and progress alongside ready/completed friends. Share buttons look live but remain inert. Tool visibility and sample views are session-only; sample views end on joining a group or reloading, and normal appearance preview remains clearly labeled. Use [tools/capture_preview.sh](tools/capture_preview.sh) for promotional captures; `--help` lists the available options.

### Focus the view

A **View** dropdown groups visibility and ordering controls. Its **Show** section contains three independent choices:

- **Current zone only**, enabled by default.
- **Show profession quests**, hidden by default.
- **Show class quests**, hidden by default.

A muted scope label, such as **Current zone · Standard quests**, summarizes the selection. The synchronization status applies to that scope. WoW Forever's Camping quests use the profession filter.

The same dropdown has a **Sort by** section with two radio choices:

- **Smart** (default): missing quests first, with most recently active quests first within both groups.
- **Title A–Z**: alphabetical, without missing-first priority.

An **Objective progress** section offers three radio choices, saved account-wide:

- **When anyone finishes** (default): retain the actionable comparison described below.
- **When I finish**: show objective counts, including your own, only after you finish that particular objective. Missing/readiness/completion notices remain visible. Ready-to-turn-in or known-completed local quests qualify where comparisons are reliable. Remove hidden objective rows entirely without substituting **Still in progress**. Omit empty quest groups; preserve independently generated quest-state notices and existing state-only fallbacks when usable counts are unavailable.
- **Always**: add everyone's known counts on comparable shared objectives while anyone still needs them, including equal counts and objectives nobody has finished. Do not fabricate missing counts or compare state-only variants numerically. Keep fully finished objectives quiet.

Extra tracking rows are informational, not actionable differences. Party status is computed from visible non-informational rows after the objective-progress rule, filters and ignores. Hidden objective rows in When I finish do not count toward status; independent quest-state differences remain actionable. Informational counts use muted styling. Collapsed headings count affected players without including informational-only participants; purely informational headings say **N tracking**. The progress choice applies to appearance preview and screenshot samples as well, with unfinished sample objectives demonstrating Always.

Smart activity comes from actual pickups, objective changes, readiness, completion or abandonment by you or a party member, not refreshes or unchanged snapshots. Initial snapshots establish a baseline. Activity is session-only and tracked even for filtered or currently synchronized quests. Equal or unknown activity uses title and quest ID as tie-breakers. The sort choice persists across sessions; preview demonstrates the same choices using fixed sample activity.

### Ignore existing differences for a party session

When you join a party or a new member joins, offer a native **Start fresh together?** popup after the available initial snapshots settle. **Ignore quests** suppresses existing missing-quest rows across all zones and quest categories, regardless of current filters; **Keep showing** leaves them visible. Preserve shared objective and readiness rows. Only missing quests newly introduced by that group change are offered, not previously tracked mismatches. Initial local data and each new member's first snapshot establish the baseline; later pickups do not enter the offer. Wait at most eight seconds for initial data and combine simultaneous joins; unknown members never imply missing quests. Refreshes, reconnects and reloads do not repeat the offer.

A native setting, **Existing quests when the party changes**, selects **Ask what to ignore** (default), **Automatically ignore existing missing quests**, or **Keep showing all differences**. Automatic ignores use exactly the same baseline and never continuously ignore new pickups.

Right-click live quest headings for **Ignore quest**, which hides the whole quest comparison. **View → Ignore current missing quests** manually suppresses all currently known missing rows, across filters. Every ignore is personal and lasts only for the current party session. Save session state separately per character so reloads and disconnects retain it; other members leaving or reconnecting do not reset it. Clear it when the local player leaves the group. If an originally missing player picks up an ignored quest, restore its comparison automatically. Whole-quest ignores without missing players remain until restored or the session ends. Sample views never offer ignore actions or alter session state.

**View → Ignored quests (N)** opens a separate all-zone, all-category list with **Restore** beside each quest and **Restore all** beside the ignored-count heading. Omit scope and personal-ignore explanatory labels in this view. Empty lists say **No ignored quests**, not Party in sync. Live scope text includes the ignored count. A pinned **Undo** action reverses the latest ignore batch without affecting earlier ignores; its notice disappears after 15 seconds, pausing dismissal while the button is hovered or focused. Another ignore batch restarts the timer; routine refreshes and partial restores do not. Expiry removes only the notice, not the ignores or access to restoration through **View → Ignored quests (N)**. **Restore all** in the ignored view never times out. Restoring quests does not re-trigger join offers. Party status reflects only visible, non-ignored differences.

### Make differences actionable

Compare missing, active, ready-to-turn-in and known-completed states across all known party snapshots, including differences between friends when you are missing or still working on a quest. Highlight objective progress when any comparable party member has finished and another still needs it. When a player is ready to turn in or has already completed a quest, show unfinished players' remaining objectives alongside that readiness or completion status. Fall back to quest states when no usable remaining objective counts are available or variant comparisons are state-only. Deduplicate each player's status and objective rows, preserve objective order, and keep related differences together under the same quest heading. Unknown members receive connection notices, not assumed quest differences; cached snapshots remain comparable with their connection status.

For identifiable tradeable item objectives, also show finished members' counts while someone else still needs the objective. Cap displayed progress at the target and append positive surplus as **10/10 · 2 spare**. Reserve the player's logged quest requirements, including filtered quests, before counting spare carried items; exclude banks, bound and locked stacks. Keep readiness/completion labels distinct and do not add noise when everyone is finished. Unknown item identity or tradeability retains the baseline display. Exact localized-name matching and agreeing carried/progress counts provide conservative coverage, not a quest-API guarantee of item identity.

Reviewed Retail variant families let friends on different class/race versions of the same task compare progress and completion. Sharing always uses the real active quest ID.

### Show connection health

Connection notices appear separately above quest groups. Distinguish offline members, addon detection, waiting for a snapshot, explicit refreshing, stale data and protocol incompatibility. Routine updates with a healthy cached snapshot retain the last-known comparison and header, with a muted **Updating** indicator beside the scope; its tooltip explains that the comparison uses the last complete snapshots. Reserve the indicator's space even while idle so updates do not reflow the panel. Initial loading, explicit refreshes, roster/reconnect recovery and stalled or invalid transfers keep prominent notices. Keep the last comparison visible during recovery or disconnection, with a clear status. Offline members keep party status incomplete; syncing resumes automatically when they reconnect. `/qwf` requests a fresh comparison for online members.

## Synchronization

Addon-enabled members establish complete quest snapshots through WoW's addon communication channel. Each snapshot carries actual quest IDs, titles, states, objective counts, locations and classifications. Filters apply to the local presentation.

When all connected members advertise support, routine changes send only added, replaced or removed quests. Session identities, exact-base checks and atomic result-digest validation prevent applying partial updates to the wrong state. Periodic state announcements detect missed final updates and stale connections; full snapshots repair gaps when needed rather than on a timer. Mixed-version or capability-unknown parties retain normal full-snapshot updates without removing newer optional data.

Party changes and quest events drive updates. Paced messages, coalesced changes, automatic retries and stalled-transfer recovery keep synchronization responsive. Routine updates that become outdated before transmission are skipped in favor of the latest state, while explicit refreshes and transfers already underway remain protected. Small partial updates can overtake an ongoing full snapshot without older data rolling back the comparison. See [PROTOCOL.md](PROTOCOL.md) for the wire format.

## Design principles

- **Readable at a glance:** lead with the quest and the player who needs attention.
- **Actionable:** put sharing beside a missing quest and progress beside an unfinished objective.
- **Quiet when caught up:** use a simple synchronization status for the selected scope.
- **Familiar:** work alongside Blizzard's quest tracker and normal quest-sharing flow.
- **Clear status:** distinguish fresh comparisons from data still arriving or recovering.

## Future opportunities

[TODO.md](TODO.md) tracks catch-up explanations, quest-chain relationships and compact panel options. An optional secondary line in Blizzard's tracker could surface a friend's remaining progress beside a tracked quest.

[README.md](./README.md) describes the shipped experience; this brief guides future design decisions.
