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

The TOC version determines `dist/QuestWithFriends-<version>.zip`. Packaging uses an allowlist: the TOC, its listed runtime files (including XML `Script` and `Include` dependencies), assets in `tools/bundle_addon.py`'s `RUNTIME_ASSETS`, `README.md`, and `LICENSE`. Unlisted files are not bundled, even under `src/`. Release manifests cannot reference `dev/`, `Development.lua` or `InGameTests.lua`, even through XML; the bundler rejects them. `--dev` derives a separate manifest and adds those files, without distribution-site project IDs. `--tag` is reserved for release packages. Tests, tools, caches, previews, version-control metadata, and game assets are excluded. The script works from any directory; an optional positional argument selects a different output ZIP. Failed packaging leaves any previous ZIP intact.

To validate a proposed release tag, pass it to the bundler with `--tag`. The tag must equal `v` followed by the TOC version; a mismatch fails before writing a ZIP.

## Upcoming-client compatibility reviews

`.github/workflows/compatibility.yml` checks CurseForge's game-version catalog daily at 08:23 UTC (GitHub may delay scheduled runs), or on manual dispatch from the default branch. It considers only numeric `major.minor.patch` versions in the supported Retail and Forever version types. CurseForge listings are distribution metadata: they do not guarantee PTR availability or advance notice before a patch launches. Labeled beta/PTR entries are not converted into guessed interface numbers.

`tools/compatibility_versions.json` records reviewed baselines and must stay aligned with the TOC. Only the newest numeric catalog version per client is selected. Each affected client gets an independent `compatibility/<client>-<version>` branch and PR proposing the baseline and TOC update; intermediate versions do not generate extra PRs. Version comparisons are numeric, not based on catalog IDs. The PR mentions and requests review from `COMPATIBILITY_REVIEWER` (repository variable), defaulting to the repository owner, and includes checkout instructions and a two-client smoke-test checklist. For organization-owned repositories, set the variable to a user login.

Before enabling the workflow:

- Install the **not-adam** GitHub App on this repository with **Contents: write** and **Pull requests: write** access.
- Add repository secret `NOT_ADAM_APP_PRIVATE_KEY`; authentication uses `adampoit/not-adam@v1`.
- Keep `CURSEFORGE_API_TOKEN` configured, as for publication.

Branches and PRs use the App token so the existing push/PR test workflow runs normally, unlike PRs created with `GITHUB_TOKEN`. The monitor does not merge PRs, tag releases, or upload packages. A TOC bump is only a proposal: confirm the actual interface with `/dump GetBuildInfo()`, test the matching PTR/beta or live client, record the client build and addon revision, and fix regressions before merging. Merging marks the new baseline as reviewed; prepare a release separately. The pinned simulator and mocked tests do not certify new-client compatibility.

Open, closed, and merged PRs all suppress further notifications for the same client/version. Close an unwanted or superseded PR to dismiss it, and reopen it to resume testing. Existing branches are never force-pushed; a branch left by a failed PR-creation attempt is reused on the next run. Multiple candidate PRs are independent: after merging one, rebase/reconcile the others against the new baseline and close older candidates rather than downgrading it.

For a read-only local plan using a downloaded catalog:

```sh
python3 tools/check_game_versions.py /path/to/curseforge-versions.json
```

`--create-prs --base <default-branch> --reviewer <login>` is reserved for the workflow's clean Git checkout, not a local Jujutsu working copy. The tooling tests use temporary local Git repositories when Git is available and run the Lua suite against generated Retail, Forever, and combined TOC updates when Busted is available; no network or GitHub credentials are needed.

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

Maintainers manually dispatch `.github/workflows/release.yml` to prepare a release. It derives the `v<TOC version>` tag, validates packaging, and runs the complete test workflow before creating the tag and a draft GitHub Release titled `v<version>`, with the installable ZIP and generated notes. The workflow creates the tag; contributors do not need to create or push it. Existing tags are never overwritten.

After a maintainer reviews and publishes the draft, `.github/workflows/curseforge.yml` and `.github/workflows/wago.yml` independently upload the attached ZIP and reviewed release notes without rebuilding. Supported Retail and Forever versions are resolved from every TOC interface number in the ZIP against each site's version catalog; Wago's project ID also comes from the ZIP's `X-Wago-ID` field. Unmatched or ambiguous versions fail publication rather than selecting a newer version or silently omitting a client. Versions containing `-` are GitHub prereleases; tags containing `alpha` upload as alpha, other prereleases as beta, and stable releases as release (CurseForge) or stable (Wago).
