# Quest-data tools

Generate reproducible quest metadata from **local ATT and QuestieDB checkouts** using `generate_quest_equivalences.py`. The pipeline inventories source records, finds review candidates, validates approved groups and emits Lua tables.

Requires Python 3.10+. QuestieDB export also uses Lua 5.1 or LuaJIT.

| Source    | Import method                                                                 | Current use                      |
| --------- | ----------------------------------------------------------------------------- | -------------------------------- |
| ATT       | Static scan of contributor quest constructors and the Retail reward catalog   | Reviewed Retail variant families |
| QuestieDB | Forever TOC/emulator export with Static Corrections and active Derived passes | Forever Camping classification   |

## Inventory and discovery

Use a contributor checkout for ATT, including `.contrib/.db/standard` for Retail or `.contrib/.db/forever` for Forever. The importer retains raw constructor blocks, paths, lines, title comments and duplicate definitions for review.

For QuestieDB, use a trusted checkout: the exporter executes upstream Lua with a Forever persona. It materializes corrected English fields before public getter normalization, retaining field presence, positional holes and large race masks. `--lua` selects the interpreter.

```sh
python3 tools/generate_quest_equivalences.py \
  --game retail --att-source /path/to/AllTheThings \
  --revision c269971e856a1da16883cc94cba33d2ec5a90b02

python3 tools/generate_quest_equivalences.py \
  --game forever --questiedb-source /path/to/QuestieDB \
  --revision e0a6eaa86f181ac99262e34126bcd2ed1a1712d6
```

`--revision` is the operator-supplied full upstream SHA. Local file hashes and a deterministic inventory SHA256 capture the actual imported contents, including local modifications. Source directories are read-only inputs; choose output paths outside them.

The default output is `.cache/quest-sources/<game>/report.json`; `--report` selects another path. Reports include provenance, quest records, title/exclusion candidates, reviewed families and category leads. [QUEST_DATA.md](QUEST_DATA.md) collects source-field interpretation, shipped coverage and variant decisions.

## Review a family

1. Select candidates from the report and inspect their source context.
2. Record per-member evidence and the inventory SHA256 in the matching registry:
   - `reviewed_quest_groups.json`: Retail / ATT.
   - `reviewed_quest_groups.forever.json`: Forever / QuestieDB.
3. Choose the comparison policy explicitly:
   - `progress = "objectives"`: matching ordered targets and positive quantities.
   - `progress = "state"`: reviewed same-task/transition identity and readiness comparison.
   - `history`: a boolean selecting completion sharing.
4. Generate a preview, review the diff, then promote the reviewed table.

Every family supplies sorted, unique, nonoverlapping IDs, an equivalence rationale, evidence references and a source snapshot pin. Review applicability, restrictions and one-time quest status for each member. A changed source pin triggers re-review.

### ATT branch reviews

`basis = "att-reviewed-branches"` validates sibling Retail quests using shared starters, differing symbolic restrictions and named predecessor/successor witnesses. Every member and witness has a `{path, line, sha256}` constructor pin. The replayer checks that witnesses cover the family in the same contributor context and verifies timelines, recurrence and prerequisite direction.

The `att_review` object records `applicability`, `recurrence`, `relationship`, `direction` and `witnesses`. It also records the evidence status: `turn_in = "unknown"` and `live_client = false`.

Each `quests[id]` row includes the pinned `record`, starter, `end = null`, symbolic restrictions and reviewed recurrence. For objective comparison, supply `objectives_complete = true` and ordered objective rows. The replayer matches them against contiguous source slot indices, explicit `0/N` quantities and literal providers. For state comparison, supply a positive `state_only_reason` describing the shared branch role.

Completion sharing uses a separate review. Set `history = true` and add:

```json
{
  "completion": {
    "scope": "party-comparison",
    "rationale": "Completing any member finishes this same reviewed task or story step."
  }
}
```

Place this object inside `att_review`. The existing record, applicability, recurrence and witness checks apply to completion reviews too. Use `history = false` for active-quest comparison alone. The [variant reference](QUEST_DATA.md#retail-variants) records the six approved Northshire families and their completion decisions.

### Endpoint-based reviews

The default `endpoints` basis uses supplemental reviewed facts: a global common starter, identical finishers, differing class/race/faction restrictions and affirmative nonrepeatability. Objective policies additionally require matching ordered, counted schemas. This basis uses `history = false`.

Synthetic registry example:

```json
{
  "schema": 1,
  "game": "retail",
  "source": "att",
  "groups": [
    {
      "ids": [1, 2],
      "source_sha256": "<source_sha256 from the report>",
      "rationale": "Reviewed class variants of the same task",
      "evidence": ["<source permalink or client capture>"],
      "progress": "objectives",
      "history": false,
      "quests": {
        "1": {
          "start": [["npc", 10]],
          "end": [["npc", 20]],
          "restrictions": [["class", 1]],
          "repeatable": false,
          "objectives_complete": true,
          "objectives": [
            { "kind": "monster", "targets": [["npc", 30]], "count": 6 }
          ]
        },
        "2": {
          "start": [["npc", 10]],
          "end": [["npc", 20]],
          "restrictions": [["class", 2]],
          "repeatable": false,
          "objectives_complete": true,
          "objectives": [
            { "kind": "monster", "targets": [["npc", 30]], "count": 6 }
          ]
        }
      }
    }
  ]
}
```

## Generate and promote

Add `--reviews tools/reviewed_quest_groups.json --output QuestEquivalences.generated.lua` to the Retail inventory command to emit a preview. Validation completes before replacing Lua. `--allow-empty` explicitly permits an empty preview; otherwise an empty registry preserves the existing output.

Generation replaces the table, so review additions and removals together. Keep previews in ignored files, then promote approved output to `src/QuestEquivalences.lua`.

To reproduce the shipped Retail table from the pinned contributor checkout:

```sh
python3 tools/generate_quest_equivalences.py \
  --game retail --att-source /path/to/AllTheThings \
  --revision c269971e856a1da16883cc94cba33d2ec5a90b02 \
  --reviews tools/reviewed_quest_groups.json \
  --output src/QuestEquivalences.lua
```

Retain the local checkouts and reports for reproduction. Local changes or extra Lua files alter source hashes.

## Forever Camping classifications

The category review selects 94 IDs with `zoneOrSort = -666` from effective QuestieDB source. Reproduce the shipped table and evidence manifest together:

```sh
python3 tools/generate_quest_equivalences.py \
  --game forever --questiedb-source /path/to/QuestieDB \
  --revision e0a6eaa86f181ac99262e34126bcd2ed1a1712d6 \
  --category-review tools/reviewed_quest_categories.forever.json \
  --categories-output src/QuestCategories.lua \
  --categories-manifest tests/fixtures/forever_camping_quests.json
```

The generator validates category membership for every selected ID and reports additional Camping leads for review. The manifest records revision/snapshot pins and per-record hashes. For a preview, choose output paths under `.cache/quest-sources/forever/`.

## Synchronization benchmark

[Measured results and limitations](SYNC_BENCHMARK.md) compare a four-player party using 1.1 full snapshots and 1.2 partial updates. Each character has 20 logged quests and the addon's maximum 30 retained turn-ins. The benchmark runs the actual runtime, not a byte-count-only transport model; instrumentation does not modify production code. The checked-in measurements predate removal of scheduled full checkpoints; rerunning measures the current runtime.

Requires LuaJIT and a **trusted QuestieDB checkout** at `e0a6eaa86f181ac99262e34126bcd2ed1a1712d6`. From the repository root:

```sh
root="$PWD"
source=/absolute/path/to/QuestieDB
mkdir -p .cache/benchmark-source
(cd "$source" && luajit "$root/tools/export_sync_benchmark.lua" \
  "$root/.cache/benchmark-source/fixture.lua")

# Five repeats, native bit operations, JIT disabled to avoid measuring JIT-only speedups.
luajit -joff tools/benchmark_sync.lua .cache/benchmark-source/fixture.lua 5 native \
  > .cache/benchmark-source/after-results.json

# Optional sensitivity runs: arithmetic-only bits, or 50 ms one-way delivery delay.
luajit -joff tools/benchmark_sync.lua .cache/benchmark-source/fixture.lua 3 portable single_player \
  > .cache/benchmark-source/after-portable.json
luajit -joff tools/benchmark_sync.lua .cache/benchmark-source/fixture.lua 3 native single_player 0.05 \
  > .cache/benchmark-source/after-latency50.json
```

Arguments after the fixture are repeat count, `native`/`portable` bit mode, optional scenario name, and optional one-way link latency in seconds. Scenarios: `cold_party`, `single_player`, `all_players`, `four_quests`, `during_checkpoint`, `idle_300s`, `adventure_300s`, `rapid_61s`. A mixed-party update is also measured. Progress is printed to stderr; JSON results go to stdout. The runtime fixture and full results remain ignored cache files, not redistributed upstream data.

## Live addon development

Install or symlink this checkout as `Interface/AddOns/QuestWithFriendsDev` alongside your release installation. The checked-in `QuestWithFriendsDev.toc` loads the shared `src/Load.xml` plus screenshot tools and in-game tests, using separate SavedVariables. No manifest generation is needed; add runtime files to `src/Load.xml` and reload WoW.

Enable only one copy at a time. If both are enabled, the release loads first and the dev copy stays inactive. The dev version is always `dev`; keep Interface compatibility metadata aligned in both TOCs (checked by tests and updated together by compatibility-branch automation).

To build a separate development ZIP:

```sh
python3 tools/bundle_addon.py --dev
```

## Tests

```sh
python3 -m unittest discover -s tools/tests -v
busted tests -v
```
