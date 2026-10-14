"""Compatibility detection and PR orchestration stay network-free in tests."""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import cast
from unittest.mock import patch

from tools import check_game_versions as monitor
from tools.curseforge_game_versions import (
	FOREVER_VERSION_TYPE_ID,
	RETAIL_VERSION_TYPE_ID,
)

BASELINES = {"retail": "12.1.0", "forever": "1.60.1"}
TOC = "## Interface: 120100, 16001\n## Version: 0.1.7\nCore.lua\n"
SCRIPT = Path(monitor.__file__)


def entry(
	name: str, version_id: object, type_id: int = RETAIL_VERSION_TYPE_ID
) -> dict[str, object]:
	return {"name": name, "id": version_id, "gameVersionTypeID": type_id}


def catalog() -> list[dict[str, object]]:
	return [entry("12.1.0", 100), entry("1.60.1", 200, FOREVER_VERSION_TYPE_ID)]


class CandidateTests(unittest.TestCase):
	def test_current_and_older_versions_do_not_trigger_updates(self):
		self.assertEqual(
			[], monitor.find_candidates(catalog() + [entry("12.0.7", 999)], BASELINES)
		)

	def test_only_latest_version_per_client_is_selected_numerically_not_by_id(self):
		versions = catalog() + [
			entry("12.1.10", 5),
			entry("12.1.5", 999),
			entry("13.0.0", 1),
			entry("1.60.2", 50, FOREVER_VERSION_TYPE_ID),
		]
		candidates = monitor.find_candidates(versions, BASELINES)
		self.assertEqual(
			[
				("forever", "1.60.2"),
				("retail", "13.0.0"),
			],
			[(c.client, c.version) for c in candidates],
		)
		self.assertEqual("12.1.0", candidates[-1].previous)

	def test_catalog_with_both_reported_retail_updates_selects_only_12_1_7(self):
		versions = catalog() + [entry("12.1.5", 999), entry("12.1.7", 5)]
		for ordered in (versions, list(reversed(versions))):
			self.assertEqual(
				[monitor.Candidate("retail", "12.1.7", 5, "12.1.0")],
				monitor.find_candidates(ordered, BASELINES),
			)

	def test_double_digit_patch_is_newer_than_single_digit_patch(self):
		versions = catalog() + [entry("12.1.10", 5), entry("12.1.7", 999)]
		self.assertEqual(
			"12.1.10", monitor.find_candidates(versions, BASELINES)[0].version
		)

	def test_unrelated_client_types_and_nonnumeric_labels_are_ignored(self):
		versions = catalog() + [
			entry("99.0.0", 300, 999),
			entry("12.2.0 PTR", 301),
			entry("12.2", 302),
			entry("12.02.0", 303),
			entry("12.100.0", 304),
		]
		self.assertEqual([], monitor.find_candidates(versions, BASELINES))

	def test_ambiguous_versions_are_rejected(self):
		for duplicate in (
			entry("12.1.0", 101),
			entry("1.60.1", 201, FOREVER_VERSION_TYPE_ID),
		):
			with (
				self.subTest(duplicate=duplicate),
				self.assertRaisesRegex(ValueError, "Ambiguous"),
			):
				_ = monitor.find_candidates(catalog() + [duplicate], BASELINES)

	def test_invalid_ids_are_rejected(self):
		for version_id in (None, True, "101", 0, -1, 1.5):
			with (
				self.subTest(version_id=version_id),
				self.assertRaisesRegex(ValueError, "version ID"),
			):
				_ = monitor.find_candidates(
					catalog() + [entry("12.1.5", version_id)], BASELINES
				)

	def test_malformed_or_incomplete_catalogs_fail_closed(self):
		invalid: list[object] = [
			None,
			{},
			"error",
			[None],
			[1],
			[],
			[entry("12.1.0", 100)],
		]
		for versions in invalid:
			with (
				self.subTest(versions=versions),
				self.assertRaises((ValueError, TypeError)),
			):
				_ = monitor.find_candidates(versions, BASELINES)

	def test_interface_conversion(self):
		self.assertEqual(120105, monitor.interface_number("12.1.5"))
		self.assertEqual(16002, monitor.interface_number("1.60.2"))
		for version in ("12.1", "12.01.0", "12.0.100", "0.1.0", "12.1.0\n"):
			with self.subTest(version=version), self.assertRaises(ValueError):
				_ = monitor.interface_number(version)

	def test_toc_change_preserves_other_client_version_and_runtime_files(self):
		candidate = monitor.Candidate("retail", "12.1.5", 101, "12.1.0")
		self.assertEqual(
			TOC.replace("120100", "120105"),
			monitor.proposed_toc(TOC, BASELINES, candidate),
		)
		candidate = monitor.Candidate("forever", "1.60.2", 201, "1.60.1")
		reversed_toc = TOC.replace("120100, 16001", "16001, 120100").replace(
			"\n", "\r\n"
		)
		self.assertEqual(
			reversed_toc.replace("16001", "16002"),
			monitor.proposed_toc(reversed_toc, BASELINES, candidate),
		)

	def test_toc_drift_and_malformed_metadata_are_rejected(self):
		candidate = monitor.Candidate("retail", "12.1.5", 101, "12.1.0")
		for toc in (
			"",
			TOC + TOC,
			TOC.replace("16001", "16002"),
			TOC.replace("16001", "bad"),
			TOC.replace("16001", "16001, 16001"),
		):
			with self.subTest(toc=toc), self.assertRaises(ValueError):
				_ = monitor.proposed_toc(toc, BASELINES, candidate)

	def test_body_requests_review_without_claiming_verified_support(self):
		candidate = monitor.Candidate("retail", "12.1.5", 101, "12.1.0")
		body = candidate.body("adampoit")
		for text in (
			"@adampoit",
			"not verified support",
			"PTR",
			"120105",
			"`101`",
			"GetBuildInfo()",
			"gh pr checkout compatibility/retail-12.1.5",
		):
			self.assertIn(text, body)

	def test_committed_baselines_match_current_toc(self):
		baselines = monitor.read_baselines(monitor.ROOT)
		toc = (monitor.ROOT / monitor.TOC).read_text(encoding="utf-8")
		for client, version in baselines.items():
			candidate = monitor.Candidate(client, version, 1, version)
			self.assertEqual(toc, monitor.proposed_toc(toc, baselines, candidate))

	def test_baseline_schema_is_validated(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			(root / monitor.BASELINES).parent.mkdir(parents=True)
			invalid: list[object] = [
				{},
				[],
				BASELINES | {"classic": "1.15.0"},
				BASELINES | {"retail": 12},
				BASELINES | {"retail": "12.1"},
			]
			for data in invalid:
				_ = (root / monitor.BASELINES).write_text(
					json.dumps(data), encoding="utf-8"
				)
				with (
					self.subTest(data=data),
					self.assertRaises((ValueError, TypeError)),
				):
					_ = monitor.read_baselines(root)

	def test_cli_is_read_only_by_default_and_works_outside_repository(self):
		baselines = monitor.read_baselines(monitor.ROOT)
		major, _, _ = monitor.version_tuple(baselines["retail"])
		future = f"{major + 1}.0.0"
		versions_catalog = [
			entry(baselines["retail"], 100),
			entry(baselines["forever"], 200, FOREVER_VERSION_TYPE_ID),
			entry(future, 101),
		]
		with tempfile.TemporaryDirectory() as directory:
			versions = Path(directory) / "catalog.json"
			_ = versions.write_text(json.dumps(versions_catalog), encoding="utf-8")
			result = subprocess.run(
				[sys.executable, str(SCRIPT), str(versions)],
				cwd=directory,
				capture_output=True,
				text=True,
				check=False,
			)
			self.assertEqual(0, result.returncode, result.stderr)
			self.assertEqual(
				[
					{
						"client": "retail",
						"version": future,
						"version_id": 101,
						"branch": f"compatibility/retail-{future}",
					}
				],
				json.loads(result.stdout),
			)

	@unittest.skipUnless(
		shutil.which("busted"), "Busted is required for generated-TOC regression tests"
	)
	def test_generated_candidate_tocs_pass_lua_suite(self):
		baselines = monitor.read_baselines(monitor.ROOT)
		original_toc = (monitor.ROOT / monitor.TOC).read_text(encoding="utf-8")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			for name in ("src", "dev", "tests"):
				_ = shutil.copytree(monitor.ROOT / name, root / name)
			for updates in (
				{"retail": "12.1.5"},
				{"retail": "12.1.7"},
				{"forever": "1.60.2"},
				{"retail": "13.0.0", "forever": "1.61.0"},
			):
				with self.subTest(updates=updates):
					toc = original_toc
					reviewed = baselines.copy()
					for client, version in updates.items():
						candidate = monitor.Candidate(
							client, version, 1, reviewed[client]
						)
						toc = monitor.proposed_toc(toc, reviewed, candidate)
						reviewed[client] = version
					_ = (root / monitor.TOC).write_text(toc, encoding="utf-8")
					result = subprocess.run(
						["busted", "tests", "-v"],
						cwd=root,
						capture_output=True,
						text=True,
						check=False,
					)
					self.assertEqual(
						0, result.returncode, result.stdout + result.stderr
					)

	def test_cli_requires_explicit_mutation_options(self):
		result = subprocess.run(
			[sys.executable, str(SCRIPT), "missing.json", "--create-prs"],
			capture_output=True,
			text=True,
			check=False,
		)
		self.assertNotEqual(0, result.returncode)
		self.assertIn("requires --base and --reviewer", result.stderr)


@unittest.skipUnless(
	shutil.which("git"), "Git is required for local PR orchestration tests"
)
class PullRequestTests(unittest.TestCase):
	root: Path
	origin: Path

	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		if shutil.which("git") is None:
			return
		self.temp: tempfile.TemporaryDirectory[str] = tempfile.TemporaryDirectory()
		self.addCleanup(self.temp.cleanup)
		self.root = Path(self.temp.name) / "checkout"
		self.origin = Path(self.temp.name) / "origin.git"
		self.root.mkdir()
		_ = monitor.run(self.root, "git", "init", "--bare", str(self.origin))
		_ = monitor.run(self.root, "git", "init", "-b", "main")
		_ = monitor.run(self.root, "git", "config", "user.name", "Test Bot")
		_ = monitor.run(
			self.root, "git", "config", "user.email", "test@example.invalid"
		)
		_ = monitor.run(self.root, "git", "config", "commit.gpgsign", "false")
		_ = monitor.run(self.root, "git", "config", "core.hooksPath", "/dev/null")
		(self.root / monitor.BASELINES).parent.mkdir()
		_ = (self.root / monitor.BASELINES).write_text(
			json.dumps(BASELINES, indent=2) + "\n", encoding="utf-8"
		)
		_ = (self.root / monitor.TOC).write_text(TOC, encoding="utf-8")
		_ = monitor.run(self.root, "git", "add", ".")
		_ = monitor.run(self.root, "git", "commit", "-m", "Initial")
		_ = monitor.run(self.root, "git", "remote", "add", "origin", str(self.origin))
		self.real_run: Callable[..., str] = monitor.run
		self.gh_calls: list[tuple[str, ...]] = []
		self.existing: list[dict[str, int]] = []
		self.fail_creation: bool = False
		self.candidate: monitor.Candidate = monitor.Candidate(
			"retail", "12.1.5", 101, "12.1.0"
		)

	def fake_gh(self, root: Path, *command: str) -> str:
		if command[0] != "gh":
			return self.real_run(root, *command)
		self.gh_calls.append(command)
		if command[1:3] == ("pr", "list"):
			self.assertIn("all", command)
			return json.dumps(self.existing)
		if command[1:3] == ("pr", "create"):
			if self.fail_creation:
				raise subprocess.CalledProcessError(
					1, command, stderr="simulated API failure"
				)
			return "https://github.invalid/pull/1"
		self.fail(f"Unexpected GitHub call: {command}")

	def open_prs(self, candidates: list[monitor.Candidate] | None = None):
		with patch.object(monitor, "run", side_effect=self.fake_gh):
			monitor.open_prs(
				self.root,
				[self.candidate] if candidates is None else candidates,
				"main",
				"adampoit",
			)

	def test_creates_isolated_branch_commit_and_review_request(self):
		self.open_prs()
		self.assertEqual(
			"main", self.real_run(self.root, "git", "branch", "--show-current")
		)
		self.assertEqual("", self.real_run(self.root, "git", "status", "--porcelain"))
		self.assertEqual(BASELINES, monitor.read_baselines(self.root))
		branch = self.candidate.branch
		self.assertEqual(
			[str(monitor.TOC), str(monitor.BASELINES)],
			self.real_run(
				self.root, "git", "diff", "--name-only", f"main..{branch}"
			).splitlines(),
		)
		updated = cast(
			object,
			json.loads(
				self.real_run(self.root, "git", "show", f"{branch}:{monitor.BASELINES}")
			),
		)
		self.assertEqual(BASELINES | {"retail": "12.1.5"}, updated)
		self.assertIn(
			"120105, 16001",
			self.real_run(self.root, "git", "show", f"{branch}:{monitor.TOC}"),
		)
		create = self.gh_calls[-1]
		self.assertEqual("adampoit", create[create.index("--reviewer") + 1])
		self.assertIn("@adampoit", create[create.index("--body") + 1])

	def test_existing_pr_in_any_state_prevents_push_and_new_notification(self):
		self.existing = [{"number": 42}]
		self.open_prs()
		self.assertEqual(1, len(self.gh_calls))
		self.assertEqual(
			"", self.real_run(self.root, "git", "ls-remote", "--heads", "origin")
		)

	def test_existing_latest_pr_does_not_fall_back_to_an_older_candidate(self):
		self.existing = [{"number": 2}]
		candidates = monitor.find_candidates(
			catalog() + [entry("12.1.5", 101), entry("12.1.7", 102)], BASELINES
		)
		self.open_prs(candidates)
		self.assertEqual(1, len(self.gh_calls))
		self.assertIn("compatibility/retail-12.1.7", self.gh_calls[0])
		self.assertEqual(
			"", self.real_run(self.root, "git", "ls-remote", "--heads", "origin")
		)

	def test_recovers_push_after_failed_pr_creation_without_rewriting_branch(self):
		self.fail_creation = True
		with self.assertRaises(subprocess.CalledProcessError):
			self.open_prs()
		branch_sha = self.real_run(self.root, "git", "rev-parse", self.candidate.branch)
		self.fail_creation = False
		self.open_prs()
		self.assertEqual(
			branch_sha,
			self.real_run(self.root, "git", "rev-parse", self.candidate.branch),
		)
		self.assertEqual(
			"main", self.real_run(self.root, "git", "branch", "--show-current")
		)

	def test_multiple_candidates_branch_from_baseline_not_each_other(self):
		self.open_prs(
			[self.candidate, monitor.Candidate("forever", "1.60.2", 201, "1.60.1")]
		)
		updated = cast(
			object,
			json.loads(
				self.real_run(
					self.root,
					"git",
					"show",
					f"compatibility/forever-1.60.2:{monitor.BASELINES}",
				)
			),
		)
		self.assertEqual(BASELINES | {"forever": "1.60.2"}, updated)

	def test_dirty_checkout_is_rejected_before_github_access(self):
		_ = (self.root / "untracked.txt").write_text(
			"do not commit me", encoding="utf-8"
		)
		with self.assertRaisesRegex(ValueError, "clean CI checkout"):
			self.open_prs()
		self.assertEqual([], self.gh_calls)

	def test_invalid_reviewer_is_rejected_before_github_access(self):
		with self.assertRaisesRegex(ValueError, "GitHub user login"):
			monitor.open_prs(self.root, [self.candidate], "main", "@not-a-login")
		self.assertEqual([], self.gh_calls)


if __name__ == "__main__":
	_ = unittest.main()
