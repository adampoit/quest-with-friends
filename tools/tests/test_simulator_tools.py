import os
import subprocess
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = ROOT / "tools" / "build_simulator_image.sh"


class SimulatorBuildTests(unittest.TestCase):
	def run_build(
		self, arguments: Sequence[str] = (), docker_exit: int = 0
	) -> tuple[subprocess.CompletedProcess[str], list[str]]:
		with tempfile.TemporaryDirectory(prefix="qwf tools ") as directory:
			workdir = Path(directory)
			docker = workdir / "docker"
			_ = docker.write_text(
				'#!/bin/sh\nprintf "%s\\n" "$@" > "$DOCKER_CALLS"\nexit "$DOCKER_EXIT"\n',
				encoding="utf-8",
			)
			docker.chmod(0o755)
			calls = workdir / "calls.txt"
			environment = {
				**os.environ,
				"PATH": f"{workdir}{os.pathsep}{os.environ['PATH']}",
				"DOCKER_CALLS": str(calls),
				"DOCKER_EXIT": str(docker_exit),
			}
			result = subprocess.run(
				["bash", str(BUILD_SCRIPT), *arguments],
				cwd=workdir,
				env=environment,
				capture_output=True,
				text=True,
				check=False,
			)
			return result, calls.read_text(encoding="utf-8").splitlines()

	def test_default_build_stays_headless_and_forwards_options(self):
		result, calls = self.run_build(["--progress=plain"])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(
			calls,
			[
				"build",
				"--platform",
				"linux/amd64",
				"--target",
				"test",
				"--tag",
				"wow-ui-sim:0.1.32-portable",
				"--progress=plain",
				str(ROOT / "tools" / "simulator"),
			],
		)

	def test_preview_selects_renderer_target_without_forwarding_preview_flag(self):
		result, calls = self.run_build(["--preview", "--no-cache"])
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(
			calls[3:7], ["--target", "preview", "--tag", "wow-ui-sim:0.1.32-preview"]
		)
		self.assertEqual(calls[7], "--no-cache")
		self.assertNotIn("--preview", calls)

	def test_docker_failure_is_propagated(self):
		result, _ = self.run_build(docker_exit=23)
		self.assertEqual(result.returncode, 23)
