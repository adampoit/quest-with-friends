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

`tests/simulator.lua` covers solo appearance preview (sample rendering, filters, disabled sharing, settings and automatic exit on joining), party join/leave, unknown members, snapshot assembly, stale/invalid messages, filter clicks, native sorting choices and activity ordering, scope summaries, scrolling and row reuse, persistent quest-heading toggles, collapsed summaries, sharing, locked/unlocked layout controls, saved panel dimensions and position, and refresh coalescing. It captures outgoing messages and injects peer messages, rather than emulating a second client. Timer delays are compressed to zero while retaining the callback queue: use the clocked unit tests for real-time pacing assertions.

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

The TOC version determines `dist/QuestWithFriends-<version>.zip`. Packaging uses an allowlist: the TOC, its listed runtime files, assets in `tools/bundle_addon.py`'s `RUNTIME_ASSETS`, `README.md`, and `LICENSE`. Tests, tools, caches, previews, version-control metadata, and game assets are excluded. The script works from any directory; an optional positional argument selects a different output ZIP. Failed packaging leaves any previous ZIP intact.

To validate a proposed release tag, pass it to the bundler with `--tag`. The tag must equal `v` followed by the TOC version; a mismatch fails before writing a ZIP.

## GitHub CI and releases

`.github/workflows/test.yml` runs on branch pushes, pull requests, manual dispatch, and calls from the release workflow. It runs all Lua unit tests, the Python tooling suite on Python 3.10 and 3.13, a packaging smoke check, and simulator integration tests. Docker layers are cached. Only read permissions are granted to test jobs.

Add player-facing changes to the **Unreleased** section of `CHANGELOG.md`. Before a release, update `## Version` in `QuestWithFriends.toc`, finalize the changelog, run the suites, and repeat relevant live-client checks.

Maintainers manually dispatch `.github/workflows/release.yml` to prepare a release. It derives the `v<TOC version>` tag, validates packaging, and runs the complete test workflow before creating the tag and a draft GitHub Release titled `v<version>`, with the installable ZIP and generated notes. The workflow creates the tag; contributors do not need to create or push it. Existing tags are never overwritten.

After a maintainer reviews and publishes the draft, `.github/workflows/curseforge.yml` and `.github/workflows/wago.yml` independently upload the attached ZIP and reviewed release notes without rebuilding. Supported Retail and Forever versions are resolved from every TOC interface number in the ZIP against each site's version catalog; Wago's project ID also comes from the ZIP's `X-Wago-ID` field. Unmatched or ambiguous versions fail publication rather than selecting a newer version or silently omitting a client. Versions containing `-` are GitHub prereleases; tags containing `alpha` upload as alpha, other prereleases as beta, and stable releases as release (CurseForge) or stable (Wago).
