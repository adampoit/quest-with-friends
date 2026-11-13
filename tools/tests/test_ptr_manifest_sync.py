"""Exercise PTR merges against local Git repositories, without GitHub access."""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest.mock import patch

from tools import compatibility_branches as branches
from tools.check_game_versions import (
	BASELINES,
	TOC,
	Candidate,
	TrackingIssue,
	proposed_toc,
)
from tools.compatibility_branches import isolated_git as git

LIVE = {"retail": "12.1.5", "forever": "1.60.1"}
DEV_TOC = Path("QuestWithFriendsDev.toc")
RELEASE_TOC = "## Interface: 120105, 16001\n## Title: Quest With Friends\n## Notes: Party quests\n## Version: 0.1.9\nRuntime.lua\n"
DEVELOPMENT_TOC = RELEASE_TOC.replace("0.1.9", "dev")


@unittest.skipUnless(shutil.which("git"), "Git is required for PTR merge tests")
class ManifestSyncTests(unittest.TestCase):
	root: Path
	origin: Path
	main: str
	issue: TrackingIssue

	def __init__(self, methodName: str = "runTest") -> None:
		super().__init__(methodName)
		temp = tempfile.TemporaryDirectory()
		self.addCleanup(temp.cleanup)
		self.root = Path(temp.name).resolve() / "work"
		self.origin = self.root.parent / "remote.git"
		self.main = ""
		self.issue = TrackingIssue(2, "ptr/retail", "open", "12.1.7")

	def prepare(self, client: str = "retail", version: str = "12.1.7") -> None:
		self.root.mkdir()
		self.origin.mkdir()
		_ = git(self.root, "init", "--quiet", "--template=", "-b", "main")
		_ = git(self.origin, "init", "--quiet", "--bare", "--template=")
		_ = (self.root / TOC).write_text(RELEASE_TOC)
		(self.root / BASELINES).parent.mkdir()
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE))
		_ = (self.root / "Runtime.lua").write_text("base\n")
		_ = self.commit("Initial")
		self.issue = TrackingIssue(2, f"ptr/{client}", "open", version)
		_ = git(self.root, "checkout", "-b", self.issue.branch)
		_ = (self.root / TOC).write_text(
			proposed_toc(RELEASE_TOC, LIVE, Candidate(client, version, 1, LIVE[client]))
		)
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE | {client: version}))
		_ = self.commit("PTR target")
		_ = git(self.root, "checkout", "main")
		_ = (self.root / TOC).write_text(RELEASE_TOC.replace("0.1.9", "0.1.11"))
		_ = (self.root / DEV_TOC).write_text(DEVELOPMENT_TOC)
		_ = (self.root / "Runtime.lua").write_text("main\n")
		self.main = self.commit("Introduce checked-in dev manifest")
		_ = git(self.root, "push", str(self.origin), "main", self.issue.branch)

	def commit(self, message: str) -> str:
		_ = git(self.root, "add", ".")
		_ = git(self.root, "commit", "-m", message)
		return git(self.root, "rev-parse", "HEAD")

	def tip(self) -> str:
		return git(self.origin, "rev-parse", self.issue.branch)

	def sync(self) -> bool:
		with (
			patch.object(branches, "run", return_value=str(self.origin)),
			patch.object(branches, "ref_sha", return_value=self.tip()),
		):
			return branches.sync_branch(self.root, self.main, self.issue, LIVE)

	def test_new_dev_manifest_is_aligned_in_the_same_published_merge(self):
		self.prepare()
		before = self.tip()
		with patch.object(branches, "isolated_git", wraps=git) as commands:
			self.assertTrue(self.sync())
			pushes = [
				cast(tuple[str, ...], call.args[1:])
				for call in commands.call_args_list
				if call.args[1] == "push"
			]
			self.assertEqual(1, len(pushes))
			self.assertFalse(
				any(
					argument.startswith("--force") or argument == "-f"
					for argument in pushes[0]
				)
			)
		self.assertEqual(
			f"{before} {self.main}",
			git(self.origin, "show", "-s", "--format=%P", self.tip()),
		)
		self.assertEqual(
			RELEASE_TOC.replace("0.1.9", "0.1.11").replace("120105", "120107"),
			git(self.origin, "show", f"{self.tip()}:{TOC}", raw=True),
		)
		self.assertEqual(
			DEVELOPMENT_TOC.replace("120105", "120107"),
			git(self.origin, "show", f"{self.tip()}:{DEV_TOC}", raw=True),
		)
		self.assertEqual("main", git(self.root, "branch", "--show-current"))
		self.assertEqual("", git(self.root, "status", "--porcelain"))

	def test_forever_sync_keeps_retail_on_its_live_interface(self):
		self.prepare("forever", "1.60.2")
		self.assertTrue(self.sync())
		for path in (TOC, DEV_TOC):
			self.assertIn(
				"## Interface: 120105, 16002\n",
				git(self.origin, "show", f"{self.tip()}:{path}", raw=True),
			)

	def test_repeated_sync_is_a_noop(self):
		self.prepare()
		self.assertTrue(self.sync())
		before = self.tip()
		self.assertFalse(self.sync())
		self.assertEqual(before, self.tip())

	def test_repairs_both_live_manifests_when_main_was_already_merged(self):
		self.prepare()
		_ = git(self.root, "checkout", self.issue.branch)
		_ = git(self.root, "merge", "--no-edit", "main")
		_ = (self.root / TOC).write_text(RELEASE_TOC.replace("0.1.9", "0.1.11"))
		before = self.commit("Simulate stale interface metadata")
		_ = git(self.root, "push", str(self.origin), self.issue.branch)
		self.assertTrue(self.sync())
		self.assertEqual(
			before, git(self.origin, "show", "-s", "--format=%P", self.tip())
		)
		for path in (TOC, DEV_TOC):
			self.assertIn(
				"## Interface: 120107, 16001\n",
				git(self.origin, "show", f"{self.tip()}:{path}", raw=True),
			)

	def test_source_conflicts_do_not_modify_the_remote_branch(self):
		self.prepare()
		_ = git(self.root, "checkout", self.issue.branch)
		_ = (self.root / "Runtime.lua").write_text("PTR change\n")
		before = self.commit("Conflicting source edit")
		_ = git(self.root, "push", str(self.origin), self.issue.branch)
		with self.assertRaises(subprocess.CalledProcessError):
			_ = self.sync()
		self.assertEqual(before, self.tip())

	def test_unreviewed_interfaces_are_not_silently_replaced(self):
		self.prepare()
		_ = git(self.root, "checkout", self.issue.branch)
		_ = (self.root / TOC).write_text(RELEASE_TOC.replace("120105", "120199"))
		before = self.commit("Unexpected interface")
		_ = git(self.root, "push", str(self.origin), self.issue.branch)
		with self.assertRaises(ValueError):
			_ = self.sync()
		self.assertEqual(before, self.tip())

	def test_extra_interfaces_are_rejected_without_publishing(self):
		self.prepare()
		_ = git(self.root, "checkout", self.issue.branch)
		_ = (self.root / TOC).write_text(
			RELEASE_TOC.replace("120105", "120107, 120105")
		)
		before = self.commit("Ambiguous interfaces")
		_ = git(self.root, "push", str(self.origin), self.issue.branch)
		with self.assertRaisesRegex(ValueError, "ambiguous"):
			_ = self.sync()
		self.assertEqual(before, self.tip())

	def test_unreviewed_baselines_are_not_silently_retargeted(self):
		self.prepare()
		_ = git(self.root, "checkout", self.issue.branch)
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE | {"retail": "12.1.9"}))
		before = self.commit("Unexpected target")
		_ = git(self.root, "push", str(self.origin), self.issue.branch)
		with self.assertRaisesRegex(ValueError, "tracked PTR target"):
			_ = self.sync()
		self.assertEqual(before, self.tip())

	def test_a_concurrent_branch_update_is_never_overwritten(self):
		self.prepare()
		before = self.tip()
		tree = git(self.origin, "rev-parse", f"{before}^{{tree}}")
		concurrent = git(
			self.origin, "commit-tree", tree, "-p", before, "-m", "Concurrent change"
		)

		def race(
			root: Path, *arguments: str, content: str | None = None, raw: bool = False
		) -> str:
			if arguments[0] == "push":
				_ = git(
					self.origin,
					"update-ref",
					f"refs/heads/{self.issue.branch}",
					concurrent,
					before,
				)
			return git(root, *arguments, content=content, raw=raw)

		with (
			patch.object(branches, "isolated_git", side_effect=race),
			self.assertRaises(subprocess.CalledProcessError),
		):
			_ = self.sync()
		self.assertEqual(concurrent, self.tip())
