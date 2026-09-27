# Developing Quest With Friends

The runtime is Lua; build-time quest-data tools and packaging use Python 3.10+ with only the standard library. Work from the repository root unless noted otherwise. The addon has been validated in game; automated tests complement, rather than replace, live checks after changes to game APIs, synchronization, or visuals.

## Unit tests

Install Lua 5.1 (or LuaJIT), [Busted](https://lunarmodules.github.io/busted/), and Python 3.10+, then run:

```sh
busted tests -v
python3 -m unittest discover -s tools/tests -v
```

The Python suite is network-free. Its emitted-Lua smoke test requires `lua` on PATH. The Lua suite covers protocol validation, quest comparison, panel behavior, settings, and mocked Retail/Forever event flows. Clocked recovery tests cover four-client exchanges, event storms, throttling, lost chunks, reloads, and leaving/rejoining a party. Isolated Forever instances exercise First Last sender names, snapshots, objective updates, refreshes, and self echoes.

Keep Busted specs in `tests/unit/` with the `_spec.lua` suffix. Simulator tests live directly in `tests/` using filenames such as `simulator.lua`.

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

`tests/simulator.lua` covers party join/leave, unknown members, snapshot assembly, stale/invalid messages, filter clicks, scope summaries, row truncation/reuse, sharing, panel position persistence, and refresh coalescing. It captures outgoing messages and injects peer messages, rather than emulating a second client. Timer delays are compressed to zero while retaining the callback queue: use the clocked unit tests for real-time pacing assertions.

## Simulator screenshots

The normal test image omits the renderer. Build the separate preview target for actual simulator screenshots:

```sh
bash tools/build_simulator_image.sh --preview
bash tools/capture_share_preview.sh
```

This builds `wow-ui-sim:0.1.32-preview` with the upstream `gui` feature and Mesa software Vulkan renderer. It runs headlessly with software rendering. The heavier build limits compilation to two jobs for memory-constrained environments; CI uses only the lightweight test target.

To supply real game fonts and textures, point to your local installation root (the directory with `Data` and `.build.info`):

```sh
WOW_INSTALL_PATH="/path/to/World of Warcraft" bash tools/capture_share_preview.sh
```

Both installation and addon mounts are **read-only**. Without an installation, CASC is disabled and missing assets can use fallbacks or remain blank. Extracted assets are cached under `$XDG_CACHE_HOME/quest-with-friends/simulator-preview/` or `~/.cache/quest-with-friends/simulator-preview/`; set `QWF_SIMULATOR_CACHE_DIR` to override it. Prefer the Linux filesystem for SQLite-heavy caches when using WSL. Keep extracted game assets local and excluded from version control and release bundles.

Output goes to `.cache/simulator-previews/share.webp` and `share.log`; an optional first argument selects another directory. Failed captures preserve the previous screenshot, and interrupts clean up the container. The demo runs the real comparison and panel code with synthetic quests at 2× scale. Its Share callback logs a demonstration message. Label captures as simulator previews.

## Quest data and protocol

[tools/README.md](tools/README.md) describes the local ATT/QuestieDB pipeline: inventory, review, preview generation and promotion. [tools/QUEST_DATA.md](tools/QUEST_DATA.md) collects current coverage, source findings and approved comparisons.

CI exercises synthetic source imports and review policies. Shipped tables are regenerated explicitly from pinned contributor checkouts, with previews kept in ignored files for inspection.

[PROTOCOL.md](PROTOCOL.md) specifies versioned messages, atomic snapshots, pacing and recovery. Use the clocked synchronization tests when changing transport behavior.

## Package locally

```sh
python3 tools/bundle_addon.py
```

The TOC version determines `dist/QuestWithFriends-<version>.zip`. Packaging uses an allowlist: the TOC, its listed runtime files, `README.md`, and `LICENSE`. Tests, tools, caches, previews, version-control metadata, and game assets are excluded. The script works from any directory; an optional positional argument selects a different output ZIP. Failed packaging leaves any previous ZIP intact.

For a release, also validate the tag:

```sh
python3 tools/bundle_addon.py --tag v0.1.5
```

A tag must equal `v` followed by the TOC version. A mismatch fails before writing a ZIP.

## GitHub CI and releases

`.github/workflows/test.yml` runs on branch pushes, pull requests, manual dispatch, and calls from the release workflow. It runs all Lua unit tests, the Python tooling suite on Python 3.10 and 3.13, a packaging smoke check, and simulator integration tests. Docker layers are cached. Only read permissions are granted to test jobs.

To prepare a release:

1. Update `## Version` in `QuestWithFriends.toc` and add player-facing notes to `CHANGELOG.md`.
2. Run the suites and package locally; repeat relevant live-client checks.
3. Create and push a Git tag matching the TOC version, such as `v0.1.5`. With a recent Jujutsu version that supports tags and a configured `origin`, use `jj tag set v0.1.5 -r <release-revision>` followed by `jj git push --remote origin --tag v0.1.5`. Select the finalized, described release revision.
4. `.github/workflows/release.yml` validates the tag, runs the same complete test workflow, then creates a **draft GitHub Release** with the installable ZIP and generated notes. Only the final release job receives `contents: write`.
5. Review/edit the draft notes, confirm the license/notices and ZIP layout, then publish it in GitHub. Tags whose versions contain `-` are marked as prereleases.

The release workflow uses GitHub's built-in token. Enable Actions for the repository. Update an existing draft and its assets manually. Direct players to the versioned addon ZIP on the Releases page.
