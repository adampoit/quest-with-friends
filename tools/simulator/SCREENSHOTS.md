# Screenshot scenes

Use `bash tools/capture_preview.sh` from the repository root for the normal `/qwf preview` scene, centered at 1.5× scale on an 800×600 canvas. Build prerequisites, asset discovery and faithful/debug color modes are described in [DEVELOPING.md](../../DEVELOPING.md#simulator-screenshots).

The runner handles capture mechanics; the scene script chooses what to show. It does not automatically open menus or generate a fixed set of screenshots. Keep experimental scenes and captures in ignored `.cache/simulator-previews/`, not in shipped addon files.

## Supply a scene

Create `.cache/simulator-previews/scene.lua` with Lua that runs after the addon has loaded. For example, to show the actual solo appearance preview:

```lua
A_Admin.SetPartySize(0)
SlashCmdList.QUESTWITHFRIENDS("preview on")
local panel = QuestWithFriendsPanel
assert(panel:IsShown(), "Preview panel is not visible")
panel:ClearAllPoints()
panel:SetScale(2)
panel:SetPoint("CENTER", UIParent, "CENTER")
```

Then capture the chosen state:

```sh
bash tools/capture_preview.sh --lua .cache/simulator-previews/scene.lua \
  --name appearance --filter QuestWithFriendsPanel --width 1000 --height 750
```

`--lua` replaces, rather than appends to, the default appearance preview. Paths are relative to the caller's working directory. The script is mounted read-only and runs in the simulator, not the live client. Treat supplied Lua as executable code: use local trusted scripts. Use the real `/qwf preview` when its samples suit the task, or construct synthetic groups and call `QuestWithFriends.Panel.show` for states it does not cover.

## Frames and popups

The renderer's `--filter FRAME` includes only that frame's hierarchy. WoW dropdowns can be independent root frames, not descendants of the panel or even `UIParent`. A menu can be open and still be absent from a panel-filtered screenshot.

With a custom scene, the runner defaults to **no frame filter**. Omit `--filter`, or pass `--filter none`, when capturing popups. Let the scene hide unrelated UI instead. For example, after the scene has created the panel and opened its menu:

```lua
panel.filter:OpenMenu()
assert(panel.filter:IsMenuOpen(), "View menu did not open")
assert(panel.filter.menu:IsShown(), "View menu is not visible")

local keep = {}
for _, widget in ipairs({ panel, panel.filter.menu }) do
    while widget do
        keep[widget] = true
        widget = widget:GetParent()
    end
end
for _, child in ipairs({ UIParent:GetChildren() }) do
    if not keep[child] then
        child:Hide()
    end
end
assert(panel.filter:IsMenuOpen(), "Hiding unrelated UI closed the menu")
```

Adapt the retained frames to the scene: also keep any tooltip, dialog, or other surface you want to capture. Hiding a frame can trigger `OnHide` callbacks, so assert the chosen state again afterward. Do not assume `--filter UIParent` will include independent popup roots.

```sh
bash tools/capture_preview.sh --lua .cache/simulator-previews/scene.lua \
  --name view-open --width 1000 --height 750
```

This is an optional recipe, not a required output.

## Scaling and composition

Canvas dimensions are screenshot pixels; increasing them does not enlarge UI elements. `panel:SetScale(2)` enlarges the panel but may leave an independent menu at its original scale. For an intentionally enlarged menu illustration, a scene can scale and anchor the popup explicitly after opening it:

```lua
local menu = panel.filter.menu
menu:SetScale(2)
menu:ClearAllPoints()
menu:SetPoint("TOPRIGHT", panel.filter, "BOTTOMRIGHT", 0, 0)
```

Choose a canvas large enough for the panel and popup. Changing scale after menu layout can invalidate its original screen-clamping position; re-anchor it or reopen and inspect it. Scene-only positioning/scaling adjustments belong in the setup script, not production UI code. Disclose them when assessing actual in-game placement or size.

Other optional states can be composed before capture. For instance, to collapse a preview quest through its real control:

```lua
local found = false
for _, region in ipairs({ panel:GetRegions() }) do
    if region:GetObjectType() == "FontString"
        and region:GetText() == "The Lost Supplies"
        and region.toggleButton then
        region.toggleButton:Click()
        found = true
        break
    end
end
assert(found, "Quest heading was not found")
```

For sort or filter states, use their menu responders or saved preferences before starting preview. Do not mix real and sample snapshots; preview keeps sample collapse choices separate from saved quest preferences.

## Assets and validation

- When the addon lives inside a WoW installation, the runner discovers the nearest ancestor containing both `Data` and `.build.info`. Otherwise set `WOW_INSTALL_PATH` explicitly. The installation is mounted read-only. No machine-wide search or download is performed.
- `--no-game-assets` deliberately uses fallback assets. Missing textures can make borders, buttons and icons vanish; fallback fonts can differ substantially. Check the log's **Game assets** line before judging appearance.
- Use distinct `--name` values to retain variants. Names are basenames, not paths; use the positional output directory to select a location.
- The runner logs the scene, filter, canvas, asset source and renderer output. Docker failures, reported setup errors and missing/empty images fail without replacing the previous screenshot. Temporary capture directories and containers are cleaned up; the log remains.
- Add scene assertions for the UI state you expect. Capture success alone cannot prove the relevant UI is visible. Open the generated image and check for clipping, incorrect scale, missing assets and unexpected overlays.
- `--visibility-boost` is for debugging dark surfaces, not color judgments. Label images as **simulator previews**; they do not replace live-client validation.
