# Changelog

## Unreleased

- Skip already-outdated routine snapshots before their first successful chunk, avoiding unnecessary full updates for brief item locks and other transient changes. Preserve explicit refresh/recovery requests and finish transfers already underway.
- Add Debug-mode snapshot fingerprints, encoded-content change summaries, coalesced event/force reasons, queue/assembly timing, and deduplicated suppression/cancellation evidence to trace redundant sync traffic without logging raw payloads or changing the protocol.
- Keep routine quest updates quiet: retain the last-known comparison with a muted Updating indicator instead of repeatedly showing incomplete-party warnings and moving quest rows. Initial loading, explicit refreshes and genuine recovery remain clearly signaled.
- Add deduplicated Debug-mode diagnostics for objective matching and rejection reasons, fresh inventory counts, submitted/received stock metadata, filtering, and exact rendered or collapsed objective-row text. Requires AddonKit; normal logging is unchanged.
- Keep showing confirmed spare tradeable items after turning in a quest during the current session, while a friend still needs them. Recheck carried stock and reserve other logged quest requirements; retain the Completed label and omit stock when identity or tradeability is uncertain.
- Record deduplicated UI status and visibility transitions with AddonKit, including stale/offline notices, recovery timing, snapshot age and triggering events. Requires Debug mode; preview and screenshot views are labeled separately.
- Right-click an abandonable quest heading and choose **Abandon quest…** to open WoW's normal confirmation, including quest-item removal warnings when applicable. Left-click still expands or collapses details. Abandonment uses your actual logged quest variant, rechecks eligibility when chosen, and is unavailable for preview or screenshot samples.

## 0.1.8

- Show finished members' identifiable tradeable item objectives while someone still needs them, with capped progress and positive surplus such as **10/10 · 2 spare**. Count only unbound, unlocked carried stacks after reserving logged quest requirements, including filtered quests; uncertain matches retain the normal display. Protocol 1.1 shares optional item stock while preserving baseline comparisons with 1.0 peers. Preview includes spare-item examples.
- Keep one-click quest sharing and add AddonKit diagnostics for sharing attempts and blocked actions, including the quest, client build, combat state and API taint information. Sharing diagnostics are recorded even with Debug mode off.
- Fix duplicated objective counts when quest text starts with progress such as `0/1`; display progress once using the structured quest data.
- Support a separate **Quest With Friends (Dev)** installation with independent settings and diagnostics. Enable only one copy at a time; a duplicate copy reports that it did not start. Both keep the normal solo preview and can exchange compatible party data.
- Keep promotional screenshot tools and AddonKit in-game test helpers exclusive to development installations, excluding their files from release packages. Dev screenshot settings offer quest differences, collapsed headings and a synchronized party; samples are never shared or synchronized.
- Improve sample quests with multiple grouped objectives and remaining progress alongside ready-to-turn-in and completed party members.

## 0.1.7

- Move quest status icons and objective bullets up two UI units to align more closely with their text.
- Group the sample-data notice beside **End preview** in the pinned footer, leaving the preview header focused on the selected scope.
- Resize the panel with a saved width and maximum-height ceiling shared across characters. All quest differences are reachable by scrolling, while the heading, status, scope, and connection notices remain pinned. The panel starts locked; use the lock icon beside **View** to move or resize it at its full height allowance, then click it again to restore compact automatic sizing. The icon shows closed/open state with action tooltips and stays in sync with **Lock panel** in addon settings. Saved layouts are validated and kept on screen after display or UI-scale changes.
- Balance the View dropdown's top and right padding, center the header controls, and align the scroll controls with the same right inset. Move End preview to the bottom-left footer, clear of the resize handle. Give the addon title more emphasis and make the preview notice secondary, keeping the header compact and live status prominent.
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
