import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import cast

ROOT = Path(__file__).resolve().parents[2]
FAKE_DOCKER = """
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
with open(os.environ["DOCKER_CALLS"], "a", encoding="utf-8") as file:
    file.write(json.dumps(args) + "\\n")
mode = os.environ["DOCKER_MODE"]
if args[:2] == ["image", "inspect"]:
    if mode == "missing-image":
        sys.exit(1)
    if "preview-text" in args[args.index("--format") + 1]:
        print("" if mode in {"old-image", "stock-text-image"} else "top-fontstring-inset-2")
    else:
        print({"old-image": "srgb-no-brightness-boost", "unpatched-image": ""}.get(mode, "srgb-runtime-visibility-boost"))
    sys.exit(0)
if args[:2] == ["rm", "--force"]:
    sys.exit(0)
if mode == "cid-run-error":
    Path(args[args.index("--cidfile") + 1]).write_text("fake-container")
if mode in {"run-error", "cid-run-error"}:
    sys.exit(17)
output = next(
    value.removesuffix(":/output")
    for index, value in enumerate(args)
    if index > 0 and args[index - 1] == "-v" and value.endswith(":/output")
)
filename = Path(args[args.index("-o") + 1]).relative_to("/output")
if mode != "missing-output":
    Path(output, filename).write_bytes(b"" if mode == "empty-output" else b"preview")
if mode == "lua-error":
    print("[exec-lua] error: demo failed")
"""


class PreviewTests(unittest.TestCase):
	def __init__(self, methodName: str = "runTest") -> None:
		super().__init__(methodName)
		self.directory: tempfile.TemporaryDirectory[str] = tempfile.TemporaryDirectory(
			prefix="qwf preview "
		)
		self.addCleanup(self.directory.cleanup)
		self.workdir: Path = Path(self.directory.name)
		self.repo: Path = self.workdir / "addon"
		self.copy_capture_tools(self.repo)
		self.script: Path = self.repo / "tools" / "capture_preview.sh"
		self.calls: Path = self.workdir / "calls.jsonl"
		self.output: Path = self.workdir / "preview output"
		self.output.mkdir()
		self.screenshot: Path = self.output / "preview.webp"
		_ = self.screenshot.write_bytes(b"previous screenshot")
		docker = self.workdir / "docker"
		_ = docker.write_text(f"#!{sys.executable}\n{FAKE_DOCKER}", encoding="utf-8")
		docker.chmod(0o755)

	@staticmethod
	def copy_capture_tools(repo: Path) -> None:
		tools = repo / "tools"
		(tools / "simulator").mkdir(parents=True)
		_ = shutil.copyfile(
			ROOT / "tools" / "capture_preview.sh", tools / "capture_preview.sh"
		)
		_ = shutil.copyfile(
			ROOT / "tools" / "simulator" / "preview_demo.lua",
			tools / "simulator" / "preview_demo.lua",
		)

	def make_install(self, name: str = "World of Warcraft") -> Path:
		install = self.workdir / name
		(install / "Data").mkdir(parents=True)
		_ = (install / ".build.info").write_text("fixture")
		return install

	def capture(
		self,
		mode: str = "success",
		install_path: str | Path = "",
		arguments: Sequence[str] | None = None,
	) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
		result = subprocess.run(
			[
				"bash",
				str(self.script),
				*(arguments if arguments is not None else [str(self.output)]),
			],
			cwd=self.workdir,
			env={
				**os.environ,
				"PATH": f"{self.workdir}{os.pathsep}{os.environ['PATH']}",
				"DOCKER_CALLS": str(self.calls),
				"DOCKER_MODE": mode,
				"WOW_INSTALL_PATH": str(install_path),
				"XDG_CACHE_HOME": str(self.workdir / "cache"),
				"QWF_SIMULATOR_CACHE_DIR": "",
				"WOW_SIM_VISIBILITY_BOOST": "1",
				"WOW_SIM_STOCK_TEXT_POSITION": "1",
			},
			capture_output=True,
			text=True,
			check=False,
		)
		calls = [
			cast(list[str], json.loads(line))
			for line in (
				self.calls.read_text().splitlines() if self.calls.exists() else []
			)
		]
		self.assertEqual(list(self.workdir.rglob(".capture.*")), [])
		return result, calls

	def test_capture_without_install_disables_casc_and_keeps_mounts_read_only(self):
		result, calls = self.capture()
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(self.screenshot.read_bytes(), b"preview")
		run = calls[-1]
		self.assertIn("WOW_SIM_CASC=0", run)
		self.assertIn("WOW_SIM_VISIBILITY_BOOST=0", run)
		self.assertIn("WOW_SIM_STOCK_TEXT_POSITION=0", run)
		self.assertIn("calibrated top-aligned FontStrings", result.stdout)
		self.assertIn("Preview mode: faithful colors", result.stdout)
		self.assertIn("faithful colors", (self.output / "preview.log").read_text())
		self.assertIn("--init", run)
		self.assertIn(f"{self.repo}:/app/Interface/AddOns/QuestWithFriends:ro", run)
		self.assertIn(f"{os.getuid()}:{os.getgid()}", run)
		self.assertIn("screenshot", run)
		self.assertIn("QuestWithFriendsPanel", run)
		self.assertIn(f"{self.repo}/tools/simulator/preview_demo.lua:/demo.lua:ro", run)

	def test_stock_text_position_is_opt_in_and_preserves_calibrated_preview(self):
		result, calls = self.capture(
			arguments=["--stock-text-position", str(self.output)]
		)
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_STOCK_TEXT_POSITION=1", calls[-1])
		self.assertIn("Text position: stock (calibration disabled)", result.stdout)
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")
		self.assertEqual(
			(self.output / "preview-stock-text-position.webp").read_bytes(), b"preview"
		)

	def test_stock_text_failure_preserves_both_captures(self):
		stock = self.output / "preview-stock-text-position.webp"
		_ = stock.write_bytes(b"previous stock screenshot")
		result, _ = self.capture(
			mode="lua-error", arguments=["--stock-text-position", str(self.output)]
		)
		self.assertEqual(result.returncode, 1)
		self.assertEqual(stock.read_bytes(), b"previous stock screenshot")
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_stock_renderer_is_identified_in_the_log(self):
		result, _ = self.capture(mode="stock-text-image")
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn(
			"renderer has no text calibration; rebuild to enable it", result.stdout
		)

	def test_stock_text_and_visibility_boost_can_be_combined(self):
		result, calls = self.capture(
			arguments=["--stock-text-position", "--visibility-boost", str(self.output)]
		)
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_STOCK_TEXT_POSITION=1", calls[-1])
		self.assertIn("WOW_SIM_VISIBILITY_BOOST=1", calls[-1])
		self.assertEqual(
			(
				self.output / "preview-stock-text-position-visibility-boost.webp"
			).read_bytes(),
			b"preview",
		)

	def test_visibility_boost_is_opt_in_and_does_not_replace_faithful_preview(self):
		result, calls = self.capture(arguments=["--visibility-boost", str(self.output)])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_VISIBILITY_BOOST=1", calls[-1])
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")
		self.assertEqual(
			(self.output / "preview-visibility-boost.webp").read_bytes(), b"preview"
		)
		self.assertIn("debug only; colors are not faithful", result.stdout)
		self.assertIn(
			"debug only", (self.output / "preview-visibility-boost.log").read_text()
		)

	def test_visibility_boost_flag_can_follow_output_directory(self):
		result, calls = self.capture(arguments=[str(self.output), "--visibility-boost"])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_VISIBILITY_BOOST=1", calls[-1])

	def test_visibility_boost_failures_preserve_both_previews(self):
		boosted = self.output / "preview-visibility-boost.webp"
		_ = boosted.write_bytes(b"previous debug screenshot")
		for mode, code in [("lua-error", 1), ("run-error", 17)]:
			with self.subTest(mode=mode):
				result, _ = self.capture(
					mode=mode, arguments=["--visibility-boost", str(self.output)]
				)
				self.assertEqual(result.returncode, code)
				self.assertEqual(boosted.read_bytes(), b"previous debug screenshot")
				self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_old_renderer_requires_rebuild_to_enable_visibility_boost(self):
		result, calls = self.capture(
			mode="old-image", arguments=["--visibility-boost", str(self.output)]
		)
		self.assertEqual(result.returncode, 1)
		self.assertIn("Rebuild the renderer for --visibility-boost", result.stderr)
		self.assertEqual(len(calls), 1)
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_unpatched_renderer_requires_rebuild_for_faithful_colors(self):
		result, calls = self.capture(mode="unpatched-image")
		self.assertEqual(result.returncode, 1)
		self.assertIn("Rebuild the renderer for faithful colors", result.stderr)
		self.assertEqual(len(calls), 1)
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_help_does_not_require_docker(self):
		result, calls = self.capture(arguments=["--help"])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("--visibility-boost", result.stdout)
		self.assertIn("--stock-text-position", result.stdout)
		self.assertEqual(calls, [])

	def test_invalid_arguments_fail_before_accessing_docker(self):
		for arguments in [("--unknown",), (str(self.output), "extra")]:
			with self.subTest(arguments=arguments):
				result, calls = self.capture(arguments=arguments)
				self.assertEqual(result.returncode, 2)
				self.assertIn("Usage:", result.stderr)
				self.assertEqual(calls, [])

	def test_double_dash_allows_directory_names_starting_with_a_dash(self):
		result, calls = self.capture(arguments=["--", "-preview"])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn(f"{self.workdir / '-preview'}:/output", calls[-1])
		self.assertEqual(
			(self.workdir / "-preview" / "preview.webp").read_bytes(), b"preview"
		)

	def test_game_install_is_mounted_read_only(self):
		install = self.make_install()
		result, calls = self.capture(install_path=install)
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn(f"{install}:/wow:ro", calls[-1])
		self.assertIn("WOW_INSTALL_PATH=/wow", calls[-1])
		self.assertNotIn("WOW_SIM_CASC=0", calls[-1])

	def test_discovers_install_above_addon_without_using_the_callers_directory(self):
		install = self.make_install()
		self.repo = install / "_retail_" / "Interface" / "AddOns" / "QuestWithFriends"
		self.copy_capture_tools(self.repo)
		self.script = self.repo / "tools" / "capture_preview.sh"
		result, calls = self.capture()
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn(f"{install}:/wow:ro", calls[-1])
		self.assertIn("auto-discovered above addon", result.stdout)

	def test_explicit_install_overrides_discovery(self):
		_ = (self.workdir / "Data").mkdir()
		_ = (self.workdir / ".build.info").write_text("fixture")
		explicit = self.make_install("Another install")
		result, calls = self.capture(install_path=explicit)
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn(f"{explicit}:/wow:ro", calls[-1])
		self.assertNotIn(f"{self.workdir}:/wow:ro", calls[-1])
		self.assertIn("Game assets: WOW_INSTALL_PATH", result.stdout)

	def test_discovery_requires_both_data_and_build_info(self):
		_ = (self.workdir / "Data").mkdir()
		result, calls = self.capture()
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_CASC=0", calls[-1])
		self.assertIn("fallback assets may be missing", result.stdout)

	def test_no_game_assets_disables_discovery_and_explicit_install(self):
		_ = (self.workdir / "Data").mkdir()
		_ = (self.workdir / ".build.info").write_text("fixture")
		result, calls = self.capture(
			install_path="/invalid/path",
			arguments=["--no-game-assets", str(self.output)],
		)
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_CASC=0", calls[-1])
		self.assertNotIn("WOW_INSTALL_PATH=/wow", calls[-1])
		self.assertIn("disabled by --no-game-assets", result.stdout)

	def test_invalid_explicit_install_fails_before_docker(self):
		result, calls = self.capture(install_path=self.workdir)
		self.assertEqual(result.returncode, 2)
		self.assertIn("Data and .build.info", result.stderr)
		self.assertEqual(calls, [])

	def test_custom_scene_controls_capture_without_an_implicit_frame_filter(self):
		scene = self.workdir / "my scene.lua"
		_ = scene.write_text("assert(QuestWithFriends.Panel)")
		result, calls = self.capture(
			arguments=[
				"--lua",
				scene.name,
				"--name",
				"view-open",
				"--width",
				"1000",
				"--height",
				"750",
				str(self.output),
			]
		)
		self.assertEqual(result.returncode, 0, result.stderr)
		run = calls[-1]
		self.assertIn(f"{scene}:/demo.lua:ro", run)
		self.assertNotIn("--filter", run)
		self.assertEqual(run[run.index("--width") + 1], "1000")
		self.assertEqual(run[run.index("--height") + 1], "750")
		self.assertEqual((self.output / "view-open.webp").read_bytes(), b"preview")
		log = (self.output / "view-open.log").read_text()
		self.assertIn(f"Scene: {scene}", log)
		self.assertIn("Filter: none", log)
		self.assertIn("Canvas: 1000x750", log)
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_explicit_filter_is_respected_with_custom_scenes_in_either_option_order(
		self,
	):
		scene = self.workdir / "scene.lua"
		_ = scene.write_text("assert(QuestWithFriends.Panel)")
		for options in (
			["--lua", str(scene), "--filter", "UIParent"],
			["--filter", "UIParent", "--lua", str(scene)],
		):
			with self.subTest(options=options):
				result, calls = self.capture(arguments=[*options, str(self.output)])
				self.assertEqual(result.returncode, 0, result.stderr)
				run = calls[-1]
				self.assertEqual(run[run.index("--filter") + 1], "UIParent")

	def test_explicit_none_filter_omits_renderer_filter_for_default_scene(self):
		result, calls = self.capture(arguments=["--filter", "none", str(self.output)])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertNotIn("--filter", calls[-1])

	def test_invalid_scene_name_and_dimensions_fail_before_docker(self):
		for options in (
			["--lua"],
			["--lua", "missing.lua"],
			["--filter"],
			["--name"],
			["--name", "../escape"],
			["--name", "name/escape"],
			["--width", "0"],
			["--width", "1.5"],
			["--height", "-1"],
			["--height", "10000"],
		):
			with self.subTest(options=options):
				result, calls = self.capture(arguments=options)
				self.assertEqual(result.returncode, 2, result.stderr)
				self.assertEqual(calls, [])

	def test_missing_and_empty_screenshots_preserve_previous_capture(self):
		for mode in ("missing-output", "empty-output"):
			with self.subTest(mode=mode):
				result, _ = self.capture(mode=mode)
				self.assertEqual(result.returncode, 1)
				self.assertIn("Screenshot failed; see", result.stderr)
				self.assertTrue((self.output / "preview.log").is_file())
				self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_failed_container_is_cleaned_up_and_logs_remain_available(self):
		result, calls = self.capture(mode="cid-run-error")
		self.assertEqual(result.returncode, 17)
		self.assertEqual(calls[-1], ["rm", "--force", "fake-container"])
		self.assertIn(str(self.output / "preview.log"), result.stderr)
		self.assertTrue((self.output / "preview.log").is_file())
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_lua_failure_does_not_replace_previous_screenshot(self):
		result, _ = self.capture(mode="lua-error")
		self.assertEqual(result.returncode, 1)
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_container_failure_is_propagated_and_preserves_previous_screenshot(self):
		result, _ = self.capture(mode="run-error")
		self.assertEqual(result.returncode, 17)
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")

	def test_missing_image_reports_build_command(self):
		result, calls = self.capture(mode="missing-image")
		self.assertEqual(result.returncode, 1)
		self.assertIn("build_simulator_image.sh", result.stderr)
		self.assertIn("--preview", result.stderr)
		self.assertEqual(len(calls), 1)
