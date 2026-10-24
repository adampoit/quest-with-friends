# Developing Quest With Friends

The runtime is Lua; build-time quest-data tools and packaging use Python 3.10+ with only the standard library. Work from the repository root unless noted otherwise. The addon has been validated in game; automated tests complement, rather than replace, live checks after changes to game APIs, synchronization, or visuals.

## Release and development installations

Keep the release in `Interface/AddOns/QuestWithFriends/` and the development copy in `Interface/AddOns/QuestWithFriendsDev/`. Enable only one in WoW's AddOns menu, then reload. Both use `/qwf` and the same party protocol, so a dev build can exchange compatible data with friends using the release.

For a live checkout, place or link the repository at `QuestWithFriendsDev` and generate its manifest:

```sh
python3 tools/bundle_addon.py --dev-toc
```

The ignored `QuestWithFriendsDev.toc` is derived from the release TOC; regenerate it after changing the release's interface, version, dependencies or TOC entries. Runtime Lua lives in `src/`, and dev-only tools live in `dev/`. Both manifests load `src/Load.xml`: add new runtime files there in dependency order, not to either TOC. Changes to that shared list take effect in both installations on reload, with no dev TOC regeneration. `src/Bootstrap.lua` stays first in both TOCs so the dev tools can load before the shared runtime. A checkout loaded from a folder named `QuestWithFriends` intentionally behaves as the release, without development tools. Keep addon managers pointed only at the release folder, never the checkout. Moving an existing checkout or creating a filesystem link is a separate local setup step; packaging does not change installed folders.

Alternatively, build an installable development ZIP:

```sh
python3 tools/bundle_addon.py --dev
```

This creates `dist/QuestWithFriendsDev-<version>-dev.zip`, containing only the development installation identity. Its AddOns/settings title is **Quest With Friends (Dev)** and its SavedVariables are `QuestWithFriendsDevDB`, separate from `QuestWithFriendsDB`. Settings are not copied automatically. AddonKit diagnostics are registered under `QuestWithFriendsDev` for this copy. Appearance preview and troubleshooting diagnostics remain available in both versions; screenshot tools and AddonKit in-game tests are dev-only files and are omitted from release packages.

If both installations are enabled, the dev manifest's optional dependency loads the enabled release first. The dev copy reports that it did not start, before registering UI, settings, commands, tests or synchronization. The runtime guard also protects against reversed load order between new builds. An older release without the guard must load first; the optional dependency provides that order. Disable the unwanted copy and reload to switch.

## Unit tests

Install Lua 5.1 (or LuaJIT), [Busted](https://lunarmodules.github.io/busted/), and Python 3.10+, then run:

```sh
busted tests -v
python3 -m unittest discover -s tools/tests -v
```

The Python suite is network-free. Its emitted-Lua smoke test requires `lua` on PATH. The Lua suite covers protocol validation, quest comparison, panel behavior, settings, and mocked Retail/Forever event flows. Clocked recovery tests cover four-client exchanges, event storms, throttling, lost chunks, reloads, and leaving/rejoining a party. Isolated Forever instances exercise First Last sender names, snapshots, objective updates, refreshes, and self echoes.

Keep Busted specs in `tests/unit/` with the `_spec.lua` suffix. Simulator tests live directly in `tests/` using filenames such as `simulator.lua`.

## UI status diagnostics

With AddonKit installed and Debug mode enabled, DEBUG `ui` entries record the initial displayed state and subsequent transitions:

- **Panel visibility changed** records show/hide changes.
- **Panel status changed** records `in_sync`, `out_of_sync`, `incomplete`, `preview` or `hidden`, with live/preview/screenshot mode, screenshot scenario, visible quest-group/notice counts, quiet `updating` activity and active quest filters. During routine transfers the header describes the last-known comparison; `updating` means it is not yet fully current.
- **Displayed sync status changed** records each party member's previous/next displayed status, including `unknown`, `waiting`, `updating`, `refreshing`, `stale`, `offline`, `oversized`, `incompatible` and recovery to `healthy`. Routine `updating` activity uses a quiet indicator, not a warning row, and does not count toward recovery timing. Healthy means no pending transfer or connection notice, not that their quests match. `not_displayed` marks removal or hiding. Local oversized warnings use player **You**.

Entries include the triggering event/action and session uptime. When the clock and a successful remote snapshot are available, peer entries include the last snapshot's age and revision, plus pending revision and chunk progress. `duration` measures time in the previous displayed state; `recoveryDuration` measures the continuous non-healthy displayed interval ending in recovery. Timing starts over after removal/hiding, reload or toggling Debug mode. Missing clock APIs omit timing fields. Snapshot age is diagnostic only: idle snapshots do not expire, and the recovery watchdog's lack of progress—not age alone—causes stale status.

Repeated renders, duplicate chunks and retries without a displayed status change do not produce more `ui` entries. Objective and collapse evidence is recorded separately under `item_stock`, below; layout changes are not logged. Sample modes are explicitly labeled and never report live peer recovery. Debug mode also adds detailed transport logs. UI status logging is disabled in normal mode; existing sync warnings remain available.

To reproduce, keep AddonKit enabled and use `/qwf debug on` (or enable **Debug mode** in settings) before reproducing. Use `/qwf debug off` afterward to return to normal logging. Log out or `/reload` afterward to persist diagnostics in the active client's `WTF/Account/<account>/SavedVariables/AddonKit.lua`. Logs contain player identities; share only redacted relevant entries, not full SavedVariables.

## Snapshot traffic diagnostics

With AddonKit and Debug mode enabled, `sync` entries explain why complete snapshots are sent and whether their contents really changed:

- **Quest snapshot queued** includes revision, size/chunks, `forced`, sorted coalesced event `triggers`, `forceReasons` (such as `manual_refresh`, `snapshot_requested`, `snapshot_timeout` or roster/world events), and active/replaced revisions. Causes survive coalescing and queued-snapshot replacement. `forceReasons` records requests folded into the snapshot even when an already-queued update satisfied them.
- **Submitted quest snapshot** carries the same causes plus `queueToSubmit` seconds when a clock is available. Failed chunk submissions include revision, fingerprint and retry delay; a submitted snapshot still is not proof of delivery.
- **Received quest snapshot** adds accepted revision, exact payload size and `assemblyDuration` seconds when available. Its sender-side event causes are unknown; they are not transmitted.
- **Quest snapshot suppressed** explains `matches_active`, `matches_queued` or `matches_submitted`. Consecutive identical payload/reason/event combinations are deduplicated. **Quest snapshot canceled** identifies superseded, roster-canceled or oversized transfers, including the next unsent part. `obsolete_before_start` means a routine revision was outdated before any chunk succeeded (possibly after a rejected first submission); a pending refresh supplies the latest state. `matches_submitted` can also cancel an unsent routine copy when the current state has returned to the last fully submitted payload. These checks never discard partially submitted revisions or explicit refresh/recovery obligations.

Queued, submitted and accepted snapshots include `fingerprint` and `previousFingerprint` in the form `adler32:<8 hex digits>:<byte length>`. These cover the exact complete wire payload, excluding revision/chunk envelopes, so equal payloads can be correlated across clients. Adler-32 is a non-cryptographic diagnostic checksum, not an anonymization or security mechanism. `payloadChanged` uses exact byte equality, not checksum equality, and is absent without a baseline.

`changeReason` is `baseline`, `unchanged`, or a sorted list of changed categories: `added`, `removed`, `title`, `state`, `mapID`, `category`, `objectives` or `item_stock`. `changes` counts affected quests per category; `changedQuests` counts distinct quests and `changedQuestIDs` contains the first 12 sorted actual IDs. Comparisons decode the transmitted payload, not unencoded local inventory or omitted extension entries. `wire_only` means bytes changed without a decoded known-field difference (for example a protocol minor or unknown extension).

Each stage has its own baseline: previous queued payload (even if later canceled), previous fully submitted payload, or previous accepted payload from that peer. Local baselines survive roster changes; removed peers lose their receive baseline. Reloads and Debug-mode toggles reset diagnostic baselines. No raw payloads are logged or added to SavedVariables; Debug-only in-memory payload references permit exact comparisons and are cleared when Debug mode is turned off. Fingerprints, quest IDs and existing identity/objective diagnostics remain private session evidence. Persist and redact logs as described above.

## Objective and spare-item diagnostics

With AddonKit and Debug mode enabled, DEBUG `item_stock` entries trace why a count or spare-item row is present or missing:

- **Quest objective scan changed:** quest ID/title/state, objective index, raw API text/type, normalized text, fulfilled/required counts, matching result, item ID and spare count. Matching inventory evidence includes total carried, tradeable available, reserved requirements, and counts with uncached/restricted binding, bound/locked stacks or unknown flags. These counts can overlap. Only objective-related aggregates are logged, not a bag dump.
- **Submitted objective stock changed:** objective data decoded from the actual fully submitted payload, with revision and protocol. This exposes stock omitted by extension limits. Successful submission is not proof of delivery.
- **Peer objective stock changed:** the peer's accepted snapshot counts and item metadata, including `no_stock_metadata` or `no_objectives`. It cannot establish why the sender omitted metadata.
- **Quest comparison selection changed:** `included`, `zone_filter`, `profession_filter`, `class_filter` or `no_difference`. The last means no comparison group was produced, not that every peer has supplied a healthy snapshot.
- **Objective row changed:** the exact formatted row text, player, counts and surplus, with `rendered` or `quest_collapsed`. Removed rows produce `removed`. `rendered` means the panel laid out the row, not proof that it was inside the scrolled viewport or unobscured on screen. Preview/screenshot rows are explicitly labeled; scan and transport evidence is live-only.

Matching results distinguish `matched`, `not_item_objective`, `no_exact_name_match`, `ambiguous_item_name`, `progress_stock_mismatch`, `retained_identity_mismatch`, `non_counted_objective`, `no_tradeable_stock`, `inventory_api_unavailable`, `unnamed_bag_item`, and `completed_identity_unavailable`. For completed quests, retained identity is historical but inventory totals and reservations are fresh.

Entries record initial observations, changes and removals, not every render, bag event or identical snapshot. Timing, triggers and submission revisions do not defeat deduplication. Current-state caches reset on reload or a Debug-mode toggle and discard removed entries. No new diagnostic messages are sent to peers or saved in the addon's own settings. Objective text and player identities are private data: share only relevant redacted entries. Persist logs via logout or `/reload` as described above.

## Quest-sharing diagnostics

One-click sharing remains a direct call from the Share button. With AddonKit installed, each eligible click records an INFO `share` entry, **Quest sharing attempted**, even with Debug mode off. It includes the quest ID/title and current log index, client/addon versions, combat and group state, secure execution state, any taint reported for `QuestLogPushQuest`, and a bounded click stack. An attempt is not confirmation that anyone received or accepted the quest.

`ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN` events attributed to the active installation (`QuestWithFriends` or `QuestWithFriendsDev`) calling `QuestLogPushQuest` record a WARN **Quest sharing blocked** entry. It includes the event-time context and the latest eligible click only if it occurred within five seconds; other security events are ignored. The API's taint source is evidence about that global, not proof of the underlying cause.

After reproducing, log out or `/reload` to persist diagnostics in the active client's `WTF/Account/<account>/SavedVariables/AddonKit.lua`. Compare the `share` entries with BugGrabber's original stack, especially combat versus non-combat attempts and minimal-addon versus normal setups. Keep full SavedVariables private; share only redacted relevant entries. No API hooks, automatic retries, or security-error suppression are added.

## Quest-abandonment validation

Quest headings offer **Abandon quest…** through a native right-click menu only when the local logged quest is abandonable and not session-disabled. The runtime resolves real variant IDs from the current quest log and revalidates the exact captured ID when the menu action is chosen. It calls `QuestMapQuestOptions_AbandonQuest` to preserve Blizzard's confirmation and item-removal warnings; it never calls `C_QuestLog.AbandonQuest` directly or overrides Blizzard's dialogs. Samples never offer the action.

Unit tests verify eligibility, variant resolution, retained menu callbacks, preview safety and refresh after `QUEST_REMOVED`. The existing simulator suite exercises the real quest-heading handler, native context menu, Blizzard abandonment helper and confirmation dialogs: expanded/collapsed headings, cancel/accept, selection restoration, the item-removal warning and preview safety. Missing simulator game-API behavior (eligibility, selection, the pending target and quest items) is supplied by scoped fixtures; acceptance is spied at the game-API boundary rather than removing a quest. These tests require no screenshot renderer, image baselines or extra CI job. They do not certify live quest removal, protected actions or combat behavior. Before release, validate on both Retail and Forever and record `/dump GetBuildInfo()` and the addon revision:

- Right-click expanded and collapsed headings; cancel, press Escape, and confirm abandonment. Left-click and Share must remain unchanged.
- Confirm a quest with removable quest items and verify the native warning.
- Check non-abandonable, session-disabled, friends-only and completed-history quests; samples must never offer abandonment.
- Remove or turn in the quest while its menu is open; an old action must not target another quest or replacement variant.
- Open another quest or abandonment prompt while confirmation is pending; verify the displayed title and actual abandoned quest remain consistent. The native API's pending abandonment target is shared state.
- Repeat with the quest log closed/open, in combat and out of combat, and with minimal/normal addon configurations; check for Lua and security errors. Include controller mode on Forever, whose native helper includes gamepad-specific handling.
- Verify both party panels refresh after confirmed abandonment. Canceling must not change either quest log.

## Simulator integration tests

[**wow-ui-sim**](https://github.com/Osso/wow-ui-sim) loads the shipped TOC and exercises simulated frames, party APIs, event dispatch, and timer callbacks. With Docker running:

```sh
bash tools/build_simulator_image.sh

docker run --rm \
  -e WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1 \
  -v "$PWD:/app/Interface/AddOns/QuestWithFriends:ro" \
  wow-ui-sim:0.1.32-portable run-tests QuestWithFriends
```

The first build downloads dependencies and compiles Rust, requiring several minutes and several GiB of disk space and memory. Subsequent builds reuse Docker's cache. The build script works from any directory and forwards Docker options such as `--progress=plain` or `--no-cache`.

`tools/simulator/Dockerfile` pins the Rust toolchain image, simulator v0.1.32 source revision, and runtime image. It rebuilds the executable with `target-cpu=x86-64`: the upstream native build can contain AMD-only SSE4a instructions and crash with `SIGILL` on Intel CPUs. The portable image targets **Linux amd64** and runs against the simulator's game-API fixtures.

When upgrading the simulator, update the source revision, runtime image digest, and versioned image tags in the build script, workflows, and these instructions together. The interface override loads our TOC in the simulator.

To run the same simulator suite against the dev identity (including screenshot tools):

```sh
python3 tools/bundle_addon.py --dev-toc
docker run --rm \
  -e WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1 \
  -v "$PWD:/app/Interface/AddOns/QuestWithFriendsDev:ro" \
  wow-ui-sim:0.1.32-portable run-tests QuestWithFriendsDev
```

`tests/simulator.lua` covers solo appearance preview (sample rendering, filters, disabled sharing, settings and automatic exit on joining), hidden screenshot-tool visibility and native scenario buttons, party join/leave, unknown members, snapshot assembly, stale/invalid messages, filter clicks, native sorting choices and activity ordering, scope summaries, scrolling and row reuse, persistent quest-heading toggles, collapsed summaries, sharing, native abandonment menus and confirmation dialogs, locked/unlocked layout controls, saved panel dimensions and position, and refresh coalescing. It captures outgoing messages and injects peer messages, rather than emulating a second client. Timer delays are compressed to zero while retaining the callback queue: use the clocked unit tests for real-time pacing assertions.

## In-game promotional screenshots

With **Quest With Friends (Dev)** enabled, the maintainer-only `/qwf screenshot` command reveals or hides the **Screenshot tools** section in **Settings → AddOns → Quest With Friends (Dev)**. `/qwf screenshot on` and `/qwf screenshot off` explicitly show or hide the section; they do not start or stop a sample view, open settings, or change normal settings. The tools start hidden on each reload, and the command is intentionally absent from player-facing help.

While solo, choose **Show scenario** beside:

- **Quest differences:** missing quests, grouped multiple objectives, and remaining progress alongside ready/completed friends.
- **Collapsed headings:** the same differences with compact affected-player summaries.
- **Party in sync:** a genuinely synchronized sample party with no differences under any filter.

Choosing a scenario closes settings and uses the live panel appearance: normal synchronization status, no sample-data notice or **End preview** button, and normal-looking **Share** buttons. Compose it with the usual filters and layout tools, then lock the panel before capturing. Scenario selection resets only the temporary sample collapse choices, not saved layout or filters.

**End screenshot view** in the tools section or `/qwf preview off` ends the sample view. `/qwf preview on` returns to the labeled appearance preview. Sharing remains inert, samples never enter synchronization or saved collapse choices, and the sample view ends on joining a party or raid or reloading.

## Simulator screenshots

The normal test image omits the renderer. Build the separate preview target for actual simulator screenshots:

```sh
bash tools/build_simulator_image.sh --preview
bash tools/capture_preview.sh
```

This builds `wow-ui-sim:0.1.32-preview` with the upstream `gui` feature and Mesa software Vulkan renderer. It runs headlessly with software rendering. The heavier build limits compilation to two jobs for memory-constrained environments; CI uses only the lightweight test target.

The preview-only `tools/simulator/preview-color.patch` disables the upstream shader's artificial brightness boost by default and converts display RGB tints to linear light for its sRGB render target. This keeps dark panel backgrounds and status colors closer to the addon's requested colors without changing the addon itself.

`tools/simulator/preview-text-alignment.patch` moves the painted glyphs of top-aligned FontStrings up two UI units, scaled with their effective scale. This visual calibration makes small quest-title text align more closely with the collapse arrows verified in game. Anchors, textures, measured text sizes, line spacing, and centered button labels are unchanged. It is not a native font-metrics implementation; other fonts and sizes remain unverified.

The lightweight test image remains unpatched. Revalidate both patches when upgrading the pinned simulator revision; previews are still approximations, not substitutes for in-game screenshots.

The pinned simulator can report changed vertical scroll offsets without moving the rendered quest list, and its scrollbar rendering is incomplete. Tests verify the panel's range, offsets and pinned notices, but live-client checks must cover wheel scrolling, scrollbar dragging, and clipping of quest text and clickable controls.

For inspecting dark borders or translucent elements, opt into the debug-only boost:

```sh
bash tools/capture_preview.sh --visibility-boost
```

Both modes keep the sRGB correction and text calibration. The flag selects a shader override at runtime (`WOW_SIM_VISIBILITY_BOOST=1` inside the preview container), so switching modes does not require rebuilding. Rebuild the preview image once after updating the renderer patches. Do not use boosted captures to judge the addon's actual colors.

To compare against the simulator's original text position without rebuilding:

```sh
bash tools/capture_preview.sh --stock-text-position
```

This appends `-stock-text-position` to the output name, preserving the calibrated capture. The log identifies whether the image contains the text calibration; older color-corrected images continue to work but report stock text positioning.

The capture runner discovers a local WoW installation by checking the addon directory's ancestors for `Data` and `.build.info`. Discovery does not depend on the caller's working directory. Override it with `WOW_INSTALL_PATH="/path/to/World of Warcraft"`, or use `--no-game-assets` to disable asset loading. Invalid explicit installation paths fail with an actionable error; when discovery finds nothing, the runner logs that it is using fallback assets, which may be incomplete.

Both installation and addon mounts are **read-only**. Extracted assets are cached under `$XDG_CACHE_HOME/quest-with-friends/simulator-preview/` or `~/.cache/quest-with-friends/simulator-preview/`; set `QWF_SIMULATOR_CACHE_DIR` to override it. Prefer the Linux filesystem for SQLite-heavy caches when using WSL. Keep extracted game assets local and excluded from version control and release bundles.

The default scene in `tools/simulator/preview_demo.lua` uses the addon's real `/qwf preview` at 1.5× scale, fitting the default 800×600 canvas. Sharing is disabled, as in the normal solo preview. Output goes to `.cache/simulator-previews/preview.webp` and `preview.log`; `--visibility-boost` appends `-visibility-boost` to both names, preserving the faithful capture. An optional output-directory argument selects another directory. Failed captures preserve the previous screenshot and retain the log; interrupts clean up the container.

For scenes using development-only screenshot controls, add `--dev`. It generates the dev TOC and mounts the checkout as `QuestWithFriendsDev`; normal captures continue to load the release identity. Screenshot scenes hide the Dev suffix in the panel heading, while ordinary dev preview and live play retain it.

For arbitrary scenes, pass a Lua setup script and choose the canvas and output name:

```sh
bash tools/capture_preview.sh --lua .cache/simulator-previews/scene.lua \
  --name my-scene --width 1000 --height 750
```

With `--lua`, no frame filter is applied unless explicitly requested. This lets scenes include menus and other independent frames. `--filter FRAME` restricts rendering to that frame hierarchy; `--filter none` renders all visible UI. The runner does not choose which menus to open, collapse quests, or adjust scene scaling. See [Screenshot scenes](tools/simulator/SCREENSHOTS.md) for optional composition recipes, popup/scaling gotchas and validation guidance. `--help` lists all options. Label captures as simulator previews.

## Quest data and protocol

[tools/README.md](tools/README.md) describes the local ATT/QuestieDB pipeline: inventory, review, preview generation and promotion. [tools/QUEST_DATA.md](tools/QUEST_DATA.md) collects current coverage, source findings and approved comparisons.

CI exercises synthetic source imports and review policies. Shipped tables are regenerated explicitly from pinned contributor checkouts, with previews kept in ignored files for inspection.

[PROTOCOL.md](PROTOCOL.md) specifies versioned messages, atomic snapshots, pacing and recovery. Use the clocked synchronization tests when changing transport behavior.

## Package locally

```sh
python3 tools/bundle_addon.py
```

The TOC version determines `dist/QuestWithFriends-<version>.zip`. Packaging uses an allowlist: the TOC, its listed runtime files (including XML `Script` and `Include` dependencies), assets in `tools/bundle_addon.py`'s `RUNTIME_ASSETS`, `README.md`, and `LICENSE`. Unlisted files are not bundled, even under `src/`. Release manifests cannot reference `dev/`, `Development.lua` or `InGameTests.lua`, even through XML; the bundler rejects them. `--dev` derives a separate manifest and adds those files, without distribution-site project IDs. `--preview-version <version>` overrides only the packaged release TOC with a filename-safe prerelease version, leaving the source unchanged; it cannot be used with development builds. `--tag` is reserved for release-identity packages. Tests, tools, caches, previews, version-control metadata, and game assets are excluded. The script works from any directory; an optional positional argument selects a different output ZIP. Failed packaging leaves any previous ZIP intact.

To validate a proposed release tag, pass it to the bundler with `--tag`. The tag must equal `v` followed by the TOC version; a mismatch fails before writing a ZIP.

## Upcoming-client compatibility branches

`main` stays compatible with supported live clients and is the source of stable releases. Each upcoming game version gets a long-lived integration branch and an assigned tracking issue, not a long-lived PR:

```text
main                          -> stable ZIPs on GitHub, CurseForge, and Wago
  + compatibility/retail-12.1.7 -> optional GitHub-only preview ZIPs
      ^ focused PRs target this branch; main is merged in automatically
```

### Detection and tracking

`.github/workflows/compatibility.yml` checks CurseForge's catalog daily at 08:23 UTC (GitHub may delay scheduled runs), or on manual dispatch from the default branch. It selects only the newest numeric `major.minor.patch` candidate per supported client (Retail and Forever), using numeric comparisons rather than catalog IDs. Intermediate versions do not generate extra branches.

Catalog entries are distribution metadata: they do not prove that a PTR exists, that a version is live, or that an inferred interface number is correct. Labeled beta/PTR entries are not converted into guessed interface numbers. The new branch proposes a TOC bump; confirm the actual interface with `/dump GetBuildInfo()` before claiming support.

`tools/compatibility_versions.json` must match the TOC. On `main` it records supported live targets; on a compatibility branch it records prospective targets. Detection changes only the integration branch, never the live baseline on `main`.

The issue is assigned to `COMPATIBILITY_REVIEWER` (repository variable), defaulting to the repository owner. For organization-owned repositories, set this to a user login. It contains the candidate's catalog details, checkout commands, testing checklist, preview instructions, and promotion checklist. Keep its `<!-- qwf-compatibility:... -->` marker intact: the tooling uses it to identify the branch. Only issues authored by `not-adam[bot]` or an owner, member, or collaborator are recognized; public issue bodies cannot register branches for privileged automation. Existing issues prevent duplicate notifications. Closing an issue stops syncing, preview publication, and branch recreation; reopening resumes them. If an upcoming target's issue is open but its branch is missing, rerunning detection recreates it from current `main`, reusing the same issue—even if a newer catalog candidate has since appeared. A newer candidate does not retire older branches automatically: explicitly close superseded issues and delete unwanted branches.

Before enabling these workflows:

- Install the **not-adam** GitHub App with **Contents: write** and **Issues: write** access. Existing installations must approve the added Issues permission.
- Configure `NOT_ADAM_APP_PRIVATE_KEY`; authentication uses `adampoit/not-adam@v1`.
- Keep `CURSEFORGE_API_TOKEN` configured for catalog discovery and stable publication.

The issue is created first. The detector uploads the complete candidate tree and commit, then uses GitHub's `createLinkedBranch` mutation to create the branch at that commit and associate it with the issue's **Development** section. A failed request cannot leave a visible branch missing its metadata; rerunning recovers partial failures without duplicating issues. Branch creation and upstream merges use the App token. Compatibility branch creation has an explicit `create` test trigger, so it does not depend on GitHub emitting a push event for API-created refs. Detection also immediately syncs active branches with `main`, rather than waiting for another push or the daily schedule. No release is created by detection or syncing.

Existing branches (including those created by the former PR monitor) are reused without resetting, rebasing, or force-pushing. GitHub's native association is established at creation, so legacy branches are not retroactively linked. If a legacy branch contains only generated metadata, explicitly delete it and rerun detection to recreate it with a native link; preserve any real compatibility work before deleting a branch.

### Working on a candidate

For example, with Jujutsu:

```sh
jj git fetch
jj new 'compatibility/retail-12.1.7@origin'
python3 tools/bundle_addon.py --dev
```

Install the resulting development ZIP in the matching PTR client's AddOns directory. For a linked `QuestWithFriendsDev` checkout, use `--dev-toc` instead. Record the actual client build/interface and tested addon revision in the tracking issue. Target short-lived functionality and compatibility PRs at the integration branch. Shared changes may go to `main` first if they are safe for live clients.

`.github/workflows/compatibility-sync.yml` automatically merges `main` into all open tracked branches after pushes to `main`, on manual dispatch, and daily at 08:43 UTC for retries. Server-side merges use a pinned source commit and the current destination tip; concurrent changes cannot be overwritten. Clean updates trigger the existing test workflow. Conflicts or missing branches are reported on the issue without altering history. To restore a deliberately deleted upcoming branch, rerun detection while its tracking issue is open. Failures in push- or creation-triggered branch tests are also reported, ignoring obsolete revisions. Repeated reports for the same main commit/tested revision are deduplicated. Resolve conflicts with a normal merge, not a force push; preview publication requires the latest default-branch commit to be included and fresh tests to pass.

### Optional GitHub previews

Run **Publish compatibility preview** from the default branch, with the integration branch as its `branch` input:

```sh
gh workflow run compatibility-preview.yml --ref main \
  -f branch=compatibility/retail-12.1.7
```

The workflow requires an open tracking issue, consistent branch target/TOC metadata, and an up-to-date branch. It pins the source SHA, runs the full reusable test suite against that SHA, and rechecks readiness before publication. If the branch or default branch moves incompatibly while tests run, rerun rather than publishing stale code.

The generated prerelease version looks like `0.1.9-ptr.retail.12.1.7.<run-id>.<attempt>`. Its base is the stable addon version on `main`; it is a unique preview identifier, not a promise about the next stable addon version. Only the ZIP's TOC is overridden: no preview version is committed or later merged into `main`.

Previews use the normal `QuestWithFriends` folder/settings identity, omit development tools, and are published directly as explicitly non-latest GitHub prereleases. Notes link the tracking issue and exact tested revision. Automated tests do not certify in-game compatibility. CurseForge and Wago publication explicitly skip prereleases and tags containing `-`; previews never require their version catalogs or upload tokens. No preview is published automatically on branch updates.

### Promotion when the patch goes live

1. Confirm the actual live client build/interface and rerun relevant in-game checks, including the other supported client after shared-code changes.
2. Ensure the integration branch includes current `main`, then open a short-lived promotion PR targeting `main`.
3. Review the complete diff, supported interfaces and baseline metadata; choose the next stable addon version and finalize the changelog. Include `Closes #<tracking-issue-number>` in the PR body.
4. Merge, publish a stable release using the normal workflow, and delete the integration branch. The closed issue prevents its recreation.

Promotion, branch deletion, and stable publication remain manual. Neither a catalog change nor a date automatically promotes a candidate. Candidates at or below the live baseline no longer sync or publish previews; close and clean them up explicitly.

### Local tooling and migration

For a read-only plan from a downloaded catalog:

```sh
python3 tools/check_game_versions.py /path/to/curseforge-versions.json
```

`--create-tracking --base <default-branch> --reviewer <login>` is reserved for a clean CI Git checkout, not a local Jujutsu working copy. `tools/compatibility_branches.py sync` mutates GitHub branches/issues and is also CI-only. Network-free tests cover detection, temporary local Git branches, issue recovery, sync/reporting, preview gating, and packaging.

After adopting this workflow, rerun detection to create tracking issues for existing candidate branches. Close the old compatibility PRs without merging, linking their replacement issues and copying any validation evidence. Either reconcile old branches with current `main` before publishing, or—only after verifying that no real work would be lost—delete and recreate them through detection. Recreated branches retain their existing issues and appear under **Development**; migration never rewrites a branch automatically.

## CurseForge description

`README.md` is the source for the project description. Its centered, width-controlled HTML screenshot is kept for GitHub; the local exporter converts that block to a Markdown image and preserves the rest of the text, including absolute links:

```sh
python3 tools/export_curseforge.py > /tmp/quest-with-friends-curseforge.md
```

Paste the generated file's contents into CurseForge's description editor in **Markdown** mode, not WYSIWYG. On macOS, copy directly to the clipboard with `python3 tools/export_curseforge.py | pbcopy`. The exported screenshot uses the host's default sizing and alignment. No separately maintained description or automatic upload is involved.

The exporter expects exactly one screenshot block in the README's current HTML format and fails if that format changes. Update its conversion and tests alongside any screenshot markup changes.

## GitHub CI and releases

`.github/workflows/test.yml` runs on branch pushes, pull requests, manual dispatch, and calls from the release workflow. It runs all Lua unit tests, the Python tooling suite on Python 3.10 and 3.13, release/dev packaging smoke checks, and simulator integration tests for both identities. Docker layers are cached. Only read permissions are granted to test jobs.

Add player-facing changes to the **Unreleased** section of `CHANGELOG.md`. Before a release, update `## Version` in `QuestWithFriends.toc`, finalize the changelog, run the suites, and repeat relevant live-client checks.

Maintainers manually dispatch `.github/workflows/release.yml` from the default branch to prepare a stable release. It requires a stable numeric TOC version, derives the `v<TOC version>` tag, validates packaging, and runs the complete test workflow before creating the tag and a draft GitHub Release titled `v<version>`, with the installable ZIP and generated notes. The workflow creates the tag; contributors do not need to create or push it. Existing tags are never overwritten. Use the separate compatibility preview workflow for upcoming-client builds.

After a maintainer reviews and publishes the stable draft, `.github/workflows/curseforge.yml` and `.github/workflows/wago.yml` independently upload the attached ZIP and reviewed release notes without rebuilding. Both skip GitHub prereleases and tags containing `-`. Supported Retail and Forever versions are resolved from every TOC interface number in the ZIP against each site's version catalog; Wago's project ID also comes from the ZIP's `X-Wago-ID` field. Unmatched or ambiguous versions fail publication rather than selecting a newer version or silently omitting a client. Stable releases upload as release (CurseForge) or stable (Wago).
