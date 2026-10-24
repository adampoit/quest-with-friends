"""Integration-branch maintenance never needs network access in tests."""

import base64
import json
import subprocess
import unittest
from pathlib import Path
from typing import TYPE_CHECKING, TypeVar, cast, final
from unittest.mock import Mock, patch

from tools import check_game_versions as monitor
from tools import compatibility_branches as branches
from tools.compatibility_branches import comment_once

if TYPE_CHECKING:
	from typing import override
else:
	# Python 3.10 has no typing.override; tests need no runtime typing dependency.
	_Method = TypeVar("_Method")

	def override(method: _Method) -> _Method:
		return method


MAIN_SHA = "a" * 40
BRANCH_SHA = "b" * 40
BRANCH = "compatibility/retail-12.1.7"
ISSUE = monitor.TrackingIssue(2, BRANCH, "open")
LIVE = {"retail": "12.1.5", "forever": "1.60.1"}
TARGET = LIVE | {"retail": "12.1.7"}
LIVE_TOC = "## Interface: 120105, 16001\n## Version: 0.1.9\nCore.lua\n"
TARGET_TOC = LIVE_TOC.replace("120105", "120107")


class TrackingIssueTests(unittest.TestCase):
	def lookup(
		self, pages: list[list[dict[str, object]]]
	) -> list[monitor.TrackingIssue]:
		trusted = [
			[issue | {"author_association": "OWNER"} for issue in page]
			for page in pages
		]
		with patch.object(monitor, "run", return_value=json.dumps(trusted)) as command:
			issues = monitor.tracking_issues(Path("."))
			assert command.call_args is not None
			self.assertIn("--paginate", command.call_args.args)
			self.assertIn("--slurp", command.call_args.args)
			return issues

	def test_paginated_lookup_ignores_unrelated_issues_and_legacy_prs(self):
		issue: dict[str, object] = {
			"number": 2,
			"state": "open",
			"body": monitor.issue_marker(BRANCH),
		}
		self.assertEqual(
			[ISSUE],
			self.lookup(
				[
					[
						{"body": None},
						issue | {"pull_request": dict[str, object]()},
						{"body": "unrelated"},
					],
					[issue],
				]
			),
		)

	def test_closed_issue_is_retained_as_a_detection_tombstone(self):
		self.assertEqual(
			[monitor.TrackingIssue(2, BRANCH, "closed")],
			self.lookup(
				[
					[
						{
							"number": 2,
							"state": "closed",
							"body": monitor.issue_marker(BRANCH),
						}
					],
				]
			),
		)

	def test_duplicate_markers_are_rejected(self):
		marker = monitor.issue_marker(BRANCH)
		issue: dict[str, object] = {"number": 2, "state": "open", "body": marker}
		for pages in ([[issue, issue]], [[issue | {"body": marker + "\n" + marker}]]):
			with self.subTest(pages=pages), self.assertRaises(ValueError):
				_ = self.lookup(pages)

	def test_untrusted_issue_authors_cannot_register_or_disrupt_branch_automation(self):
		issue: dict[str, object] = {
			"number": 2,
			"state": "open",
			"body": monitor.issue_marker(BRANCH),
			"author_association": "NONE",
			"user": {"login": "external-user"},
		}
		with patch.object(monitor, "run", return_value=json.dumps([[issue]])):
			self.assertEqual([], monitor.tracking_issues(Path(".")))
		issue["user"] = {"login": "not-adam[bot]"}
		with patch.object(monitor, "run", return_value=json.dumps([[issue]])):
			self.assertEqual([ISSUE], monitor.tracking_issues(Path(".")))

	def test_branch_names_cannot_escape_the_compatibility_namespace(self):
		for branch in (
			"main",
			"compatibility/retail-12.1.7; echo bad",
			"compatibility/retail-12.01.7",
			"compatibility/classic-1.1.1",
			BRANCH + "\n",
		):
			with self.subTest(branch=branch), self.assertRaises(ValueError):
				_ = monitor.branch_target(branch)


@final
class SyncTests(unittest.TestCase):
	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.root = Path(".")
		self.track = Mock(return_value=[ISSUE])
		self.ref = Mock(return_value=MAIN_SHA)
		self.source = Mock(return_value=json.dumps(LIVE))
		self.api = Mock(return_value={"sha": BRANCH_SHA})
		self.comment = Mock()

	@override
	def setUp(self) -> None:
		for name, value in (
			("tracking_issues", self.track),
			("ref_sha", self.ref),
			("source_file", self.source),
			("api", self.api),
			("comment_once", self.comment),
		):
			patcher = patch.object(branches, name, new=value)
			_ = patcher.start()
			self.addCleanup(patcher.stop)

	def test_sync_uses_atomic_server_merge_with_pinned_main_commit(self):
		branches.sync_branches(self.root, "main")
		self.api.assert_called_once_with(
			self.root,
			"merges",
			"--method",
			"POST",
			"-f",
			f"base={BRANCH}",
			"-f",
			f"head={MAIN_SHA}",
			"-f",
			f"commit_message=Merge main into {BRANCH}",
		)
		self.comment.assert_not_called()

	def test_up_to_date_branch_is_a_noop(self):
		self.api.return_value = {}
		branches.sync_branches(self.root, "main")
		self.comment.assert_not_called()

	def test_closed_and_promoted_candidates_are_not_synced(self):
		self.track.return_value = [
			monitor.TrackingIssue(2, BRANCH, "closed"),
			monitor.TrackingIssue(3, "compatibility/retail-12.1.5", "open"),
		]
		branches.sync_branches(self.root, "main")
		self.api.assert_not_called()

	def test_conflict_is_reported_and_other_branches_still_sync(self):
		self.track.return_value = [
			ISSUE,
			monitor.TrackingIssue(3, "compatibility/forever-1.60.2", "open"),
		]
		self.api.side_effect = [
			subprocess.CalledProcessError(1, "gh", stderr="Merge conflict (HTTP 409)"),
			{"sha": BRANCH_SHA},
		]
		with self.assertRaisesRegex(ValueError, "Could not sync"):
			branches.sync_branches(self.root, "main")
		self.assertEqual(2, self.api.call_count)
		assert self.comment.call_args is not None
		self.assertEqual(f"sync:{MAIN_SHA}", self.comment.call_args.args[2])
		self.assertIn(
			"No history was rewritten", cast(str, self.comment.call_args.args[3])
		)

	def test_current_tip_test_failure_is_reported(self):
		self.ref.return_value = BRANCH_SHA
		branches.report_test_failure(
			self.root, BRANCH, BRANCH_SHA, "https://github.invalid/run/1"
		)
		self.comment.assert_called_once()

	def test_obsolete_and_closed_branch_test_failures_are_not_reported(self):
		branches.report_test_failure(
			self.root, BRANCH, BRANCH_SHA, "https://github.invalid/run/1"
		)
		self.track.return_value = [monitor.TrackingIssue(2, BRANCH, "closed")]
		branches.report_test_failure(
			self.root, BRANCH, MAIN_SHA, "https://github.invalid/run/1"
		)
		self.comment.assert_not_called()

	def test_notification_is_deduplicated_across_comment_pages(self):
		marker = f"<!-- qwf-compatibility-report:tests:{BRANCH_SHA} -->"
		with patch.object(
			monitor,
			"run",
			return_value=json.dumps([[{"body": None}], [{"body": marker}]]),
		) as command:
			comment_once(self.root, ISSUE, f"tests:{BRANCH_SHA}", "failure")
			self.assertEqual(1, command.call_count)

	def test_new_notification_is_posted_to_the_tracking_issue(self):
		with (
			patch.object(monitor, "run", return_value="[[]]"),
			patch.object(branches, "run", return_value="ok") as command,
		):
			comment_once(self.root, ISSUE, "key", "failure")
			assert command.call_args is not None
			self.assertEqual(
				(
					self.root,
					"gh",
					"issue",
					"comment",
					"2",
					"--body",
					"<!-- qwf-compatibility-report:key -->\nfailure",
				),
				command.call_args.args,
			)


@final
class PreviewTests(unittest.TestCase):
	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.root = Path(".")
		self.track = Mock(return_value=[ISSUE])
		self.api = Mock(return_value={"status": "ahead"})
		self.files = {
			(MAIN_SHA, monitor.BASELINES): json.dumps(LIVE),
			(BRANCH_SHA, monitor.BASELINES): json.dumps(TARGET),
			(MAIN_SHA, monitor.TOC): LIVE_TOC,
			(BRANCH_SHA, monitor.TOC): TARGET_TOC,
		}

		def get_ref(_root: Path, branch: str) -> str:
			return MAIN_SHA if branch == "main" else BRANCH_SHA

		def get_source(_root: Path, sha: str, path: Path) -> str:
			return self.files[(sha, path)]

		self.ref = Mock(side_effect=get_ref)
		self.source = Mock(side_effect=get_source)

	@override
	def setUp(self) -> None:
		for name, value in (
			("tracking_issues", self.track),
			("ref_sha", self.ref),
			("source_file", self.source),
			("api", self.api),
		):
			patcher = patch.object(branches, name, new=value)
			_ = patcher.start()
			self.addCleanup(patcher.stop)

	def plan(self):
		return branches.preview_plan(self.root, "main", BRANCH, "123.1")

	def test_preview_metadata_pins_source_and_has_a_unique_prerelease_version(self):
		self.assertEqual(
			{
				"sha": BRANCH_SHA,
				"tag": "v0.1.9-ptr.retail.12.1.7.123.1",
				"version": "0.1.9-ptr.retail.12.1.7.123.1",
				"issue": "2",
				"client": "retail",
				"game_version": "12.1.7",
			},
			self.plan(),
		)
		self.api.assert_called_once_with(
			self.root, f"compare/{MAIN_SHA}...{BRANCH_SHA}"
		)
		second = branches.preview_plan(self.root, "main", BRANCH, "123.2")
		self.assertNotEqual(self.plan()["tag"], second["tag"])

	def test_missing_or_closed_tracking_issue_blocks_preview(self):
		for issues in ([], [monitor.TrackingIssue(2, BRANCH, "closed")]):
			self.track.return_value = issues
			with self.assertRaisesRegex(ValueError, "open tracking issue"):
				_ = self.plan()

	def test_unsynced_branch_blocks_preview(self):
		for status in ("behind", "diverged"):
			self.api.return_value = {"status": status}
			with (
				self.subTest(status=status),
				self.assertRaisesRegex(ValueError, "Merge the latest main"),
			):
				_ = self.plan()

	def test_already_promoted_or_superseded_candidate_blocks_preview(self):
		for live in ("12.1.7", "12.2.0"):
			self.files[(MAIN_SHA, monitor.BASELINES)] = json.dumps(
				LIVE | {"retail": live}
			)
			with (
				self.subTest(live=live),
				self.assertRaisesRegex(ValueError, "already live or superseded"),
			):
				_ = self.plan()

	def test_baseline_and_toc_drift_block_preview(self):
		self.files[(BRANCH_SHA, monitor.BASELINES)] = json.dumps(LIVE)
		with self.assertRaisesRegex(ValueError, "Branch target"):
			_ = self.plan()
		self.files[(BRANCH_SHA, monitor.BASELINES)] = json.dumps(TARGET)
		self.files[(BRANCH_SHA, monitor.TOC)] = LIVE_TOC
		with self.assertRaisesRegex(ValueError, "TOC does not match"):
			_ = self.plan()

	def test_main_prerelease_version_is_not_used_as_preview_base(self):
		self.files[(MAIN_SHA, monitor.TOC)] = LIVE_TOC.replace("0.1.9", "0.1.9-beta.1")
		with self.assertRaisesRegex(ValueError, "stable addon version"):
			_ = self.plan()

	def test_untrusted_branch_and_sequence_inputs_are_rejected(self):
		for branch, sequence in (
			("main", "123.1"),
			(BRANCH, "../1"),
			(BRANCH, "1.0"),
			(BRANCH, "1.1\n"),
		):
			with (
				self.subTest(branch=branch, sequence=sequence),
				self.assertRaises(ValueError),
			):
				_ = branches.preview_plan(self.root, "main", branch, sequence)


class GitHubApiTests(unittest.TestCase):
	def test_source_file_is_read_at_the_immutable_sha(self):
		with patch.object(
			branches,
			"api",
			return_value={"content": base64.b64encode(TARGET_TOC.encode()).decode()},
		) as request:
			self.assertEqual(
				TARGET_TOC, branches.source_file(Path("."), BRANCH_SHA, monitor.TOC)
			)
			assert request.call_args is not None
			self.assertEqual(
				("--method", "GET", "-f", f"ref={BRANCH_SHA}"),
				request.call_args.args[2:],
			)

	def test_invalid_ref_sha_is_rejected(self):
		with (
			patch.object(branches, "api", return_value={"object": {"sha": "unsafe"}}),
			self.assertRaisesRegex(ValueError, "invalid commit SHA"),
		):
			_ = branches.ref_sha(Path("."), BRANCH)


class WorkflowTests(unittest.TestCase):
	def workflow(self, name: str) -> str:
		return (monitor.ROOT / ".github/workflows" / name).read_text()

	def test_distribution_uploads_exclude_prereleases_before_using_secrets(self):
		for name in ("curseforge.yml", "wago.yml"):
			with self.subTest(name=name):
				workflow = self.workflow(name)
				self.assertIn(
					"if: github.event.release.prerelease == false && !contains(github.event.release.tag_name, '-')",
					workflow,
				)
				self.assertIn(".prerelease == false", workflow)

	def test_preview_tests_and_packages_the_same_pinned_sha(self):
		workflow = self.workflow("compatibility-preview.yml")
		self.assertEqual(2, workflow.count("ref: ${{ needs.validate.outputs.sha }}"))
		self.assertIn("needs: [validate, tests]", workflow)
		self.assertIn('--target "$SOURCE_SHA" --prerelease --latest=false', workflow)
		self.assertIn("plan-preview \\\n", workflow)
		self.assertNotIn("secrets: inherit", workflow)
		self.assertNotIn("--dev", workflow)

	def test_reusable_tests_checkout_the_requested_sha_in_both_jobs(self):
		self.assertEqual(
			2, self.workflow("test.yml").count("ref: ${{ inputs.ref || github.sha }}")
		)

	def test_api_created_compatibility_branches_have_an_explicit_test_trigger(self):
		workflow = self.workflow("test.yml")
		self.assertIn("  create:\n", workflow)
		self.assertEqual(
			2,
			workflow.count(
				"if: github.event_name != 'create' || (github.event.ref_type == 'branch' && startsWith(github.event.ref, 'compatibility/'))"
			),
		)
		self.assertIn(
			"github.event.workflow_run.event == 'create'",
			self.workflow("compatibility-sync.yml"),
		)

	def test_detection_syncs_branches_immediately_after_tracking(self):
		workflow = self.workflow("compatibility.yml")
		self.assertIn(
			'python3 tools/compatibility_branches.py sync --base "$BASE_BRANCH"',
			workflow,
		)
		self.assertLess(
			workflow.index("--create-tracking"),
			workflow.index("compatibility_branches.py sync"),
		)

	def test_stable_preparation_is_default_branch_only(self):
		self.assertIn(
			"if: github.ref == format('refs/heads/{0}', github.event.repository.default_branch)",
			self.workflow("release.yml"),
		)
		self.assertNotIn("--prerelease", self.workflow("release.yml"))

	def test_failure_reporter_only_trusts_push_runs_from_this_repository(self):
		workflow = self.workflow("compatibility-sync.yml")
		self.assertIn("github.event.workflow_run.event == 'push'", workflow)
		self.assertIn(
			"github.event.workflow_run.head_repository.full_name == github.repository",
			workflow,
		)
		self.assertIn("ref: ${{ github.event.repository.default_branch }}", workflow)


if __name__ == "__main__":
	_ = unittest.main()
