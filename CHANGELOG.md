# Changelog

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
