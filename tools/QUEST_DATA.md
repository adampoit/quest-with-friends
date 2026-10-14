# Quest-data reference

This page collects shipped coverage, source-field interpretation and approved variant decisions.

## Shipped coverage

| Measurement               | Retail / ATT | Forever / QuestieDB |
| ------------------------- | -----------: | ------------------: |
| Inventory IDs             |       56,637 |               5,010 |
| Approved variant families |            6 |                   0 |
| Approved variant IDs      |           54 |                   0 |
| Camping classifications   |            0 |                  94 |
| Additional Camping leads  |            0 |                   7 |

`src/QuestEquivalences.lua` defines the Retail families below. Other quests and Forever compare by exact ID. `src/QuestCategories.lua` classifies the 94 reviewed Forever Camping IDs; `tests/fixtures/forever_camping_quests.json` records revision/snapshot pins and hashes each ID/title/category tuple.

## All The Things

Pinned contributor revision: [`c269971e856a1da16883cc94cba33d2ec5a90b02`](https://github.com/ATTWoWAddon/AllTheThings/tree/c269971e856a1da16883cc94cba33d2ec5a90b02).

The static inventory reads `.contrib/.db/standard/` for Retail or `.contrib/.db/forever/`, plus the Retail reward catalog. Its source IDs include historical and conditional definitions. Raw constructor blocks, paths, lines, titles and duplicates preserve the context for reviewing wrappers, constants, inherited fields and timelines.

| Evidence                                        | Interpretation                                                                                     |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `classes`, `races`, wrappers and conditions     | Select the character branches in their contributor context                                         |
| `qg`, `qgs`, NPC/item/object providers          | Establish quest givers; branch reviews record turn-ins as unknown                                  |
| `objective(...)` children                       | The first argument is the slot's `objectiveID`; explicit `0/N` comments supply reviewed quantities |
| Item providers and costs                        | Review each item's role as helper, cost or required target                                         |
| `sourceQuest(s)` and `altQuests`                | Review progression, alternate branches and lockouts                                                |
| Repeatable/daily/weekly/monthly/yearly metadata | Establish one-time status for family approval                                                      |

Pinned examples:

- [Northshire mage variant](https://github.com/ATTWoWAddon/AllTheThings/blob/c269971e856a1da16883cc94cba33d2ec5a90b02/.contrib/.db/standard/02%20-%20Outdoor%20Zones/02%20Eastern%20Kingdoms/Elwynn%20Forest.lua#L184-L205) and [objective shortcut](https://github.com/ATTWoWAddon/AllTheThings/blob/c269971e856a1da16883cc94cba33d2ec5a90b02/.contrib/.db/shared/functions/Shortcuts.lua#L2537-L2553): starter, restrictions, target, quantity comment and slot encoding.
- [Provider processing](https://github.com/ATTWoWAddon/AllTheThings/blob/c269971e856a1da16883cc94cba33d2ec5a90b02/.contrib/src/Parser/Framework/Framework.Processing.cs#L2422-L2443): NPC providers become quest givers.
- [Ruby Feast](https://github.com/ATTWoWAddon/AllTheThings/blob/c269971e856a1da16883cc94cba33d2ec5a90b02/.contrib/.db/standard/02%20-%20Outdoor%20Zones/14%20Dragon%20Isles/1%20-%20Valdrakken/Quests.lua#L66-L90) and [The Weave of a Tale](https://github.com/ATTWoWAddon/AllTheThings/blob/c269971e856a1da16883cc94cba33d2ec5a90b02/.contrib/.db/standard/02%20-%20Outdoor%20Zones/14%20Dragon%20Isles/The%20Azure%20Span/Quests.lua#L2415-L2429): alternates represent daily lockouts or hidden answer-choice flags.
- [Objectives build option](https://github.com/ATTWoWAddon/AllTheThings/blob/c269971e856a1da16883cc94cba33d2ec5a90b02/.contrib/.db/standard/.config/options/objectives.config): preserves available rows in generated databases; our importer reads contributor rows directly.

### Retail variants

Each approved Northshire family contains nine variants in the standard `QUESTS` context, with a shared starter and reviewed class/race branches. `reviewed_quest_groups.json` pins each member and witness and records source lines, permalinks and rationales.

| Family              | Progress policy | Source evidence                                                                                                              |
| ------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Beating Them Back!  | objectives      | Six Blackrock Worgs (49871), Marshal McBride (197), matching Lions for Lambs successors                                      |
| Lions for Lambs     | objectives      | Eight Blackrock Spies (49874), Marshal McBride (197), matching Join the Battle! successors                                   |
| Join the Battle!    | state           | Transition from Lions for Lambs to They Sent Assassins, Marshal McBride (197), corresponding successors                      |
| They Sent Assassins | objectives      | Eight Goblin Assassins (50039), Sergeant Willem (823), matching The Rear is Clear successors                                 |
| Fear No Evil        | objectives      | Four infantry revivals (50047), Brother Paxton (951), prayer-book helper 65733, corresponding Join the Battle! prerequisites |
| The Rear is Clear   | state           | Transition after They Sent Assassins, Sergeant Willem (823), all nine listed as Blackrock Invasion source alternatives       |

Four families compare objective progress; two compare readiness across variants. Identical IDs compare their own objectives normally. All six share completed-step status through `history = true` and a separate `att_review.completion` rationale scoped to `party-comparison`. Fear No Evil represents the specific aid task, independently of the main chain; its generic and Kul Tiran variants share prerequisite 29080 and the revival target/helper.

An active variant takes precedence over a completed variant, and sharing retains the real active ID. WoW completion flags remain per quest ID.

The source review records one contiguous counted slot per objective family, symbolic class/race selectors and one-time status inferred from ordinary constructors, addition timelines and finite story progression. Some generic/Kul Tiran selectors overlap or leave eligibility details for further review. Evidence status is `turn_in = "unknown"` and `live_client = false`.

`att_reviews.py` replays the constructor pins, starters, restrictions, objective rows and adjacent-step witnesses. Source changes trigger re-review through the workflow in [tools/README.md](./README.md#review-a-family).

## QuestieDB

Pinned revision: [`e0a6eaa86f181ac99262e34126bcd2ed1a1712d6`](https://github.com/Questie/QuestieDB/tree/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6).

The Forever exporter executes trusted upstream Lua through its TOC/emulator. [Source materialization](https://github.com/Questie/QuestieDB/blob/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6/src/read/source.lua#L90-L143) applies Static Corrections and active Derived passes, yielding 5,010 quests versus 4,244 in the raw Forever payload. It captures corrected English fields before getter normalization; consumer Dynamic Corrections and Baked releases are separate layers.

The [quest schema](https://github.com/Questie/QuestieDB/blob/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6/src/meta/questMeta.lua#L20-L93) supplies starters, finishers, restrictions, objective summaries, target groups, relationships and recurrence flags:

- Objective tuples are `{targetID, text, iconFile}`. Family reviews add required quantities and global client slot order.
- Materialized field presence distinguishes authored values from missing data normalized by getters.
- [Derived race restrictions](https://github.com/Questie/QuestieDB/blob/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6/src/derived/requiredRaces.lua#L24-L83) can be inferred from starter faction; the importer marks that provenance.
- Skyborne [mask bits 32/33](https://github.com/Questie/QuestieDB/blob/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6/src/corrections/enum/expansions.lua#L7-L39) are retained at full width.

**Field Duty: 8507 / 8731** carries the repeatable special flag and stays exact-ID. **The Great Cat Spirit: 98342 / 98396** has three target rows in its [source records](https://github.com/Questie/QuestieDB/blob/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6/src/corrections/Forever/generated/foreverBaseQuest.lua#L7365-L7377); a family review would add quantities and slot order.

### Camping

QuestieDB defines [Camping as `zoneOrSort = -666`](https://github.com/Questie/QuestieDB/blob/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6/src/corrections/enum/quests.lua#L107-L110). The effective source has 101 Camping records; the reviewed category registry selects 94. Seven **The Adventurer** records are queued in [TODO.md](../TODO.md#quest-data-updates).

**98287, Camping 101: Engineering**, has an [authored correction](https://github.com/Questie/QuestieDB/blob/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6/src/corrections/Forever/foreverQuestFixes.lua#L1277-L1283) supplying the category, interaction target and profession/spell restrictions. Its `??` marker and partial endpoints are recorded for any later equivalence review.
