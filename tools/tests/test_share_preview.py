import json
import os
import subprocess
import sys
import tempfile
import unittest
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
    sys.exit(1 if mode == "missing-image" else 0)
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
		self, mode: str = "success", install_path: str | Path = ""
	) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
		result = subprocess.run(
			["bash", str(CAPTURE_SCRIPT), str(self.output)],
			cwd=self.workdir,
			env={
				**os.environ,
				"PATH": f"{self.workdir}{os.pathsep}{os.environ['PATH']}",
				"DOCKER_CALLS": str(self.calls),
				"DOCKER_MODE": mode,
				"WOW_INSTALL_PATH": str(install_path),
				"XDG_CACHE_HOME": str(self.workdir / "cache"),
				"QWF_SIMULATOR_CACHE_DIR": "",
			},
			capture_output=True,
			text=True,
			check=False,
		)
		calls = [
			cast(list[str], json.loads(line))
			for line in self.calls.read_text().splitlines()
		]
		self.assertEqual(list(self.output.glob(".capture.*")), [])
		return result, calls

	def test_capture_without_install_disables_casc_and_keeps_mounts_read_only(self):
		result, calls = self.capture()
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(self.screenshot.read_bytes(), b"preview")
		run = calls[-1]
		self.assertIn("WOW_SIM_CASC=0", run)
		self.assertIn("--init", run)
		self.assertIn(f"{ROOT}:/app/Interface/AddOns/QuestWithFriends:ro", run)
		self.assertIn(f"{os.getuid()}:{os.getgid()}", run)
		self.assertIn("screenshot", run)
		self.assertIn("QuestWithFriendsPanel", run)

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
