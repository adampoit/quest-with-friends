import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import cast

ROOT = Path(__file__).resolve().parents[2]
CAPTURE_SCRIPT = ROOT / "tools" / "capture_share_preview.sh"
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
    print({"old-image": "srgb-no-brightness-boost", "unpatched-image": ""}.get(mode, "srgb-runtime-visibility-boost"))
    sys.exit(0)
if mode == "run-error":
    sys.exit(17)
output = next(
    value.removesuffix(":/output")
    for index, value in enumerate(args)
    if index > 0 and args[index - 1] == "-v" and value.endswith(":/output")
)
filename = Path(args[args.index("-o") + 1]).relative_to("/output")
Path(output, filename).write_bytes(b"preview")
if mode == "lua-error":
    print("[exec-lua] error: demo failed")
"""


class SharePreviewTests(unittest.TestCase):
	def __init__(self, methodName: str = "runTest") -> None:
		super().__init__(methodName)
		self.directory: tempfile.TemporaryDirectory[str] = tempfile.TemporaryDirectory(
			prefix="qwf preview "
		)
		self.addCleanup(self.directory.cleanup)
		self.workdir: Path = Path(self.directory.name)
		self.calls: Path = self.workdir / "calls.jsonl"
		self.output: Path = self.workdir / "preview output"
		self.output.mkdir()
		self.screenshot: Path = self.output / "share.webp"
		_ = self.screenshot.write_bytes(b"previous screenshot")
		docker = self.workdir / "docker"
		_ = docker.write_text(f"#!{sys.executable}\n{FAKE_DOCKER}", encoding="utf-8")
		docker.chmod(0o755)

	def capture(
		self,
		mode: str = "success",
		install_path: str | Path = "",
		arguments: Sequence[str] | None = None,
	) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
		result = subprocess.run(
			[
				"bash",
				str(CAPTURE_SCRIPT),
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
		self.assertIn("Preview mode: faithful colors", result.stdout)
		self.assertIn("faithful colors", (self.output / "share.log").read_text())
		self.assertIn("--init", run)
		self.assertIn(f"{ROOT}:/app/Interface/AddOns/QuestWithFriends:ro", run)
		self.assertIn(f"{os.getuid()}:{os.getgid()}", run)
		self.assertIn("screenshot", run)
		self.assertIn("QuestWithFriendsPanel", run)

	def test_visibility_boost_is_opt_in_and_does_not_replace_faithful_preview(self):
		result, calls = self.capture(arguments=["--visibility-boost", str(self.output)])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_VISIBILITY_BOOST=1", calls[-1])
		self.assertEqual(self.screenshot.read_bytes(), b"previous screenshot")
		self.assertEqual(
			(self.output / "share-visibility-boost.webp").read_bytes(), b"preview"
		)
		self.assertIn("debug only; colors are not faithful", result.stdout)
		self.assertIn(
			"debug only", (self.output / "share-visibility-boost.log").read_text()
		)

	def test_visibility_boost_flag_can_follow_output_directory(self):
		result, calls = self.capture(arguments=[str(self.output), "--visibility-boost"])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("WOW_SIM_VISIBILITY_BOOST=1", calls[-1])

	def test_visibility_boost_failures_preserve_both_previews(self):
		boosted = self.output / "share-visibility-boost.webp"
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
			(self.workdir / "-preview" / "share.webp").read_bytes(), b"preview"
		)

	def test_game_install_is_mounted_read_only(self):
		install = self.workdir / "World of Warcraft"
		install.mkdir()
		result, calls = self.capture(install_path=install)
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn(f"{install}:/wow:ro", calls[-1])
		self.assertIn("WOW_INSTALL_PATH=/wow", calls[-1])
		self.assertNotIn("WOW_SIM_CASC=0", calls[-1])

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
