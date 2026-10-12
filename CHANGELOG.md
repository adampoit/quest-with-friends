# Changelog

## Unreleased

- Resize the panel with a saved width and maximum-height ceiling shared across characters. All quest differences are reachable by scrolling, while the heading, status, scope, and connection notices remain pinned. The panel starts locked; uncheck **Lock panel** in addon settings to move or resize it at its full height allowance, then click **Unlocked · Lock** to restore compact automatic sizing. Saved layouts are validated and kept on screen after display or UI-scale changes.
- Compare quests across the whole party, including differences between friends when you are missing or still working on a quest. Deduplicate each player's status and objective rows, retain stable objective ordering, and keep Share tied to your own active quest ID.
- Show remaining objectives for you or a friend when the other player is ready to turn in or has already completed the quest. Keep readiness and completion labels distinct, with status-only fallbacks when progress is unavailable or quest variants cannot be compared.

## 0.1.6

- Offline party members now have a distinct **Offline** notice instead of stale data or addon-not-detected messages. Cached comparisons remain visible and party status stays incomplete until fresh data arrives after reconnection.
- Fixed saved **Debug mode** appearing enabled while AddonKit remained at INFO after login or reload. Logging preferences and setting defaults now reapply after WoW restores saved variables.
- Added **Sort by** choices in the **View** dropdown (formerly **Filters**), grouped into **Show** and **Sort by** sections: **Smart** (default) puts missing quests first, then recently active quests within each group; **Title A–Z** sorts alphabetically. Real quest changes from you or friends count as activity, not refreshes. Sort choices persist across reloads; activity history is session-only.
- Preview the panel while solo with `/qwf preview` or **Preview appearance** in addon settings. Sample data demonstrates missing quests, objective progress, readiness and completion, with working filters and disabled Share buttons. Preview ends on joining a group or reloading; sample data is never sent or saved.
- Click quest headings to collapse or expand details, with choices saved across reloads and logins. Collapsed headings keep an affected-player summary and any **Share** button; party status and connection notices remain unchanged.

## 0.1.5

- Explicit protocol 1.0 for snapshots and control messages. Older development formats and different majors show an **Incompatible addon protocol** notice; compatible minor versions can exchange baseline snapshots.
- Profession/class classifications are applied atomically with complete quest snapshots. Bounded optional extension sections reserve space for future fields.
- Paced messages, automatic retries, stalled-snapshot recovery, and preserved cached comparisons during refresh.
- Unchanged roster events no longer force resynchronization.
- Persistent Debug mode preference in the native addon settings.
- Fixed Forever Camping quests remaining visible when **Show profession quests** is unchecked, including **The Great Outdoors** and **Camping 101** follow-ups.
- Added 94 reviewed Forever Camping quest IDs, independent of quest titles, language, or peer category hints. These classifications are scoped to Forever.
- Added a compact **Filters** menu with independent zone, profession, and class checkboxes and a visible scope summary.
- Profession and class quests are hidden by default; settings persist across reloads. Combined preferences migrate to separate settings.
- Introduced remote category hints. Protocol 1.0 in 0.1.5 supersedes that unreleased development format with snapshot classifications.
- Rebuilt Forever's 94 Camping classifications from pinned QuestieDB source and added reproducible source evidence.
- Reviewed and shipped six Northshire Retail families from ATT (54 IDs): four compare objective progress and two compare readiness only. All share completion status for party comparisons with explicit per-family review.
