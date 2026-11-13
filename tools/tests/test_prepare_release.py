"""Tag preparation and publication gates never contact GitHub in tests."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

import tools.prepare_release as releases
from tools.bundle_addon import ADDON_ROOT, RUNTIME_ASSETS
from tools.check_game_versions import BASELINES, TOC, TrackingIssue
from tools.release_package import parse_tag, read_toc, validate_published_release

SHA = "a" * 40
MAIN = "b" * 40
LIVE = {"retail": "12.1.5", "forever": "1.60.1"}
BETA = "v0.1.11-beta.1"
PTR = "v0.1.11-alpha.retail.1"


class TagTests(unittest.TestCase):
	def test_channels_and_destinations_are_explicit(self):
		for tag, channel, destinations in (
			("v0.1.11", "stable", ["curseforge", "wago"]),
			(BETA, "beta", ["curseforge", "wago"]),
			(PTR, "alpha", []),
			("v0.1.11-alpha.forever.2", "alpha", []),
		):
			with self.subTest(tag=tag):
				version = parse_tag(tag)
				self.assertEqual(channel, version.channel)
				self.assertEqual(destinations, version.storefronts)
				self.assertEqual(channel != "stable", version.prerelease)

	def test_invalid_or_ambiguous_tags_fail_closed(self):
		for tag in (
			"0.1.11",
			"v01.1.11",
			"v0.1.11-beta",
			"v0.1.11-beta.01",
			"v0.1.11-ALPHA.1",
			"v0.1.11-feature.alpha.1",
			"v0.1.11+beta",
			"v0.1.11-alpha.1\n",
			"v0.1.11-alpha.1",
			"v0.1.11-alpha.classic.1",
			"v0.1.11-alpha.ptr.retail.12.1.7.1",
			"v0.1.11-beta.retail.1",
			"v0.1.11-retail",
			"v0.1.11-rc.1",
			"v0.1.11;echo bad",
			"v0.1.11-alpha.ptr.classic.1.1.1.1",
		):
			with self.subTest(tag=tag), self.assertRaises(ValueError):
				_ = parse_tag(tag)

	def test_drafts_and_mismatched_github_channel_flags_are_rejected(self):
		for tag, draft, prerelease in (
			(BETA, True, True),
			(BETA, False, False),
			("v0.1.11", False, True),
		):
			with self.subTest(tag=tag, draft=draft), self.assertRaises(ValueError):
				_ = validate_published_release(
					{"tag_name": tag, "draft": draft, "prerelease": prerelease}
				)

	def test_lightweight_and_annotated_tags_resolve_to_commits(self):
		for responses in (
			[{"object": {"type": "commit", "sha": SHA}}],
			[
				{"object": {"type": "tag", "sha": MAIN}},
				{"object": {"type": "commit", "sha": SHA}},
			],
		):
			with patch.object(releases, "api", side_effect=responses):
				self.assertEqual(SHA, releases.tag_sha(Path("."), BETA))

	def test_tag_cycles_and_invalid_objects_are_rejected(self):
		for obj in (
			{"type": "tree", "sha": SHA},
			{"type": "commit", "sha": "bad"},
			{"type": "tag", "sha": SHA},
		):
			with (
				patch.object(releases, "api", return_value={"object": obj}),
				self.assertRaises(ValueError),
			):
				_ = releases.tag_sha(Path("."), BETA)


class PreparationTests(unittest.TestCase):
	temp: tempfile.TemporaryDirectory[str]
	root: Path

	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.temp = tempfile.TemporaryDirectory()
		self.addCleanup(self.temp.cleanup)
		self.root = Path(self.temp.name).resolve()
		(self.root / "tools").mkdir()
		(self.root / "Media").mkdir()
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE))
		_ = (self.root / TOC).write_text(
			"## Version: 0.1.11\n## Interface: 120105, 16001\nCore.lua\n"
		)
		_ = (self.root / "Core.lua").write_text("-- actual runtime\n")
		_ = (self.root / "README.md").write_text("Installation instructions\n")
		_ = (self.root / "LICENSE").write_text("MIT\n")
		for asset in RUNTIME_ASSETS:
			_ = (self.root / asset).write_bytes((ADDON_ROOT / asset).read_bytes())

	def plan(
		self, tag: str = BETA, status: str = "ahead", tagged_sha: str = SHA
	) -> dict[str, object]:
		with (
			patch.object(releases, "tag_sha", return_value=tagged_sha),
			patch.object(releases, "ref_sha", return_value=MAIN),
			patch.object(releases, "source_file", return_value=json.dumps(LIVE)),
			patch.object(releases, "api", return_value={"status": status}),
		):
			return releases.release_plan(self.root, SHA, tag, "main")

	def package(self, tag: str = BETA) -> tuple[Path, Path, dict[str, object]]:
		plan = self.plan(tag)
		manifest = releases.build_release(self.root, plan, self.root / "dist")
		path = self.root / "release-plan.json"
		_ = path.write_text(json.dumps(manifest))
		return self.root / f"dist/QuestWithFriends-{tag[1:]}.zip", path, manifest

	def test_plan_pins_source_and_policy(self):
		plan = self.plan()
		self.assertEqual(SHA, plan["source_sha"])
		self.assertEqual("beta", plan["channel"])
		self.assertEqual(LIVE, plan["targets"])
		self.assertEqual(["curseforge", "wago"], plan["storefronts"])

	def test_stable_source_must_already_be_on_default_branch(self):
		for status in ("behind", "diverged", "unknown"):
			with (
				self.subTest(status=status),
				self.assertRaisesRegex(ValueError, "default branch"),
			):
				_ = self.plan("v0.1.11", status=status)
		self.assertEqual("stable", self.plan("v0.1.11", status="identical")["channel"])

	def test_moved_tag_wrong_base_version_and_interface_drift_are_rejected(self):
		with self.assertRaisesRegex(ValueError, "source SHA"):
			_ = self.plan(tagged_sha=MAIN)
		with self.assertRaisesRegex(ValueError, "base version"):
			_ = self.plan("v0.1.12-beta.1")
		_ = (self.root / TOC).write_text(
			"## Version: 0.1.11\n## Interface: 120107, 16001\nCore.lua\n"
		)
		with self.assertRaisesRegex(ValueError, "TOC interfaces"):
			_ = self.plan()

	def test_future_baselines_cannot_be_smuggled_into_a_live_beta(self):
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE | {"retail": "12.1.7"}))
		_ = (self.root / TOC).write_text(
			"## Version: 0.1.11\n## Interface: 120107, 16001\nCore.lua\n"
		)
		with self.assertRaisesRegex(ValueError, "PTR tag"):
			_ = self.plan()

	def test_ptr_plans_use_tracking_readiness_and_the_pinned_sha(self):
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE | {"retail": "12.1.7"}))
		_ = (self.root / TOC).write_text(
			"## Version: 0.1.11\n## Interface: 120107, 16001\nCore.lua\n"
		)
		with patch.object(
			releases,
			"validate_preview",
			return_value=TrackingIssue(42, "ptr/retail", "open", "12.1.7"),
		) as readiness:
			plan = self.plan(PTR)
			readiness.assert_called_once_with(
				ADDON_ROOT, "main", "retail", "12.1.7", SHA
			)
		self.assertEqual([], plan["storefronts"])
		self.assertEqual(42, plan["issue"])

	def test_short_forever_alpha_pins_its_patch_from_source_metadata(self):
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE | {"forever": "1.60.2"}))
		_ = (self.root / TOC).write_text(
			"## Version: 0.1.11\n## Interface: 120105, 16002\nCore.lua\n"
		)
		with patch.object(
			releases,
			"validate_preview",
			return_value=TrackingIssue(43, "ptr/forever", "open", "1.60.2"),
		) as readiness:
			plan = self.plan("v0.1.11-alpha.forever.1")
			readiness.assert_called_once_with(
				ADDON_ROOT, "main", "forever", "1.60.2", SHA
			)
		self.assertEqual("1.60.2", plan["game_version"])
		self.assertEqual("forever", plan["client"])
		self.assertEqual([], plan["storefronts"])
		with self.assertRaisesRegex(ValueError, "tag policy"):
			_ = releases.validate_plan(plan | {"game_version": "1.60.3"})

	def test_alpha_draft_title_includes_the_patch_without_encoding_it_in_the_tag(self):
		_ = (self.root / BASELINES).write_text(json.dumps(LIVE | {"retail": "12.1.7"}))
		_ = (self.root / TOC).write_text(
			"## Version: 0.1.11\n## Interface: 120107, 16001\nCore.lua\n"
		)
		with patch.object(
			releases,
			"validate_preview",
			return_value=TrackingIssue(42, "ptr/retail", "open", "12.1.7"),
		):
			archive, manifest, _ = self.package(PTR)
		with (
			patch.object(releases, "tag_sha", return_value=SHA),
			patch.object(releases, "api", return_value={}),
			patch.object(releases, "run", return_value="draft URL") as command,
		):
			releases.draft_release(self.root, archive, manifest)
			assert command.call_args is not None
			self.assertIn(f"{PTR} — Retail PTR 12.1.7", command.call_args.args)

	def test_build_overrides_only_packaged_version_and_records_checksum(self):
		before = (self.root / TOC).read_bytes()
		archive, _, manifest = self.package()
		self.assertEqual(before, (self.root / TOC).read_bytes())
		self.assertIn("## Version: 0.1.11-beta.1", read_toc(archive))
		self.assertEqual(
			hashlib.sha256(archive.read_bytes()).hexdigest(), manifest["archive_sha256"]
		)
		with ZipFile(archive) as package:
			self.assertEqual(
				b"-- actual runtime\n", package.read("QuestWithFriends/Core.lua")
			)
			self.assertNotIn("release-plan.json", package.namelist())

	def test_stable_package_uses_the_same_runtime(self):
		beta, _, _ = self.package()
		stable, _, _ = self.package("v0.1.11")
		with ZipFile(beta) as a, ZipFile(stable) as b:
			self.assertEqual(a.namelist(), b.namelist())
			for name in a.namelist():
				if not name.endswith(".toc"):
					self.assertEqual(a.read(name), b.read(name))

	def test_plan_fields_cannot_override_tag_policy(self):
		for changes in (
			{"channel": "stable"},
			{"storefronts": ["wago"]},
			{"source_sha": "short"},
			{"version": "0.1.11"},
		):
			with self.subTest(changes=changes), self.assertRaises(ValueError):
				_ = releases.validate_plan(self.plan() | changes)

	def test_approved_package_verifies_and_cannot_be_relabelled_or_replaced(self):
		archive, _, manifest = self.package()
		release = {"tag_name": BETA, "draft": False, "prerelease": True}
		self.assertEqual(
			"beta", releases.verify_release(archive, manifest, release, SHA).channel
		)
		for changes in (
			{"draft": True},
			{"prerelease": False},
			{"tag_name": "v0.1.11"},
		):
			with self.subTest(changes=changes), self.assertRaises(ValueError):
				_ = releases.verify_release(archive, manifest, release | changes, SHA)
		with self.assertRaisesRegex(ValueError, "tag moved"):
			_ = releases.verify_release(archive, manifest, release, MAIN)
		with self.assertRaisesRegex(ValueError, "checksum"):
			_ = releases.verify_release(
				archive, manifest | {"archive_sha256": "0" * 64}, release, SHA
			)
		with self.assertRaisesRegex(ValueError, "interfaces"):
			_ = releases.verify_release(
				archive,
				manifest | {"targets": LIVE | {"retail": "12.1.7"}},
				release,
				SHA,
			)

	def test_cli_build_is_offline_and_emits_machine_readable_manifest(self):
		plan = self.root / "plan.json"
		_ = plan.write_text(json.dumps(self.plan()))
		result = subprocess.run(
			[
				sys.executable,
				str(Path(releases.__file__)),
				"build",
				str(self.root),
				str(plan),
				str(self.root / "out"),
			],
			capture_output=True,
			text=True,
			check=False,
		)
		self.assertEqual(0, result.returncode, result.stderr)
		self.assertEqual(SHA, json.loads(result.stdout)["source_sha"])

	def test_draft_creation_never_creates_tags_or_publishes(self):
		archive, manifest, _ = self.package()
		with (
			patch.object(releases, "tag_sha", return_value=SHA),
			patch.object(releases, "api", return_value={}),
			patch.object(releases, "run", return_value="draft URL") as command,
		):
			releases.draft_release(self.root, archive, manifest)
			assert command.call_args is not None
			arguments = command.call_args.args
			for flag in ("--draft", "--verify-tag", "--prerelease", "--latest=false"):
				self.assertIn(flag, arguments)
			self.assertNotIn("--target", arguments)

	def test_draft_assets_resolve_before_changing_to_the_automation_checkout(self):
		archive, manifest, _ = self.package()
		previous = Path.cwd()
		try:
			os.chdir(self.root)
			with (
				patch.object(releases, "tag_sha", return_value=SHA),
				patch.object(releases, "api", return_value={}),
				patch.object(releases, "run", return_value="draft URL") as command,
			):
				releases.draft_release(
					ADDON_ROOT,
					archive.relative_to(self.root),
					manifest.relative_to(self.root),
				)
				assert command.call_args is not None
				self.assertIn(str(archive), command.call_args.args)
				self.assertIn(str(manifest), command.call_args.args)
		finally:
			os.chdir(previous)

	def test_api_errors_do_not_turn_into_duplicate_release_creation(self):
		archive, manifest, _ = self.package()
		for status in (404, 403, 500):
			with (
				self.subTest(status=status),
				patch.object(releases, "tag_sha", return_value=SHA),
				patch.object(
					releases,
					"api",
					side_effect=subprocess.CalledProcessError(
						1, "gh", stderr=f"error (HTTP {status})"
					),
				),
				patch.object(releases, "run", return_value="draft URL") as command,
			):
				if status == 404:
					releases.draft_release(self.root, archive, manifest)
					command.assert_called_once()
				else:
					with self.assertRaises(subprocess.CalledProcessError):
						releases.draft_release(self.root, archive, manifest)
					command.assert_not_called()

	def existing_draft(
		self, altered: bool = False, published: bool = False, missing: bool = False
	) -> list[tuple[object, ...]]:
		archive, manifest, _ = self.package()
		assets = (
			[{"name": manifest.name}]
			if missing
			else [{"name": archive.name}, {"name": manifest.name}]
		)
		existing = {"draft": not published, "prerelease": True, "assets": assets}
		calls: list[tuple[object, ...]] = []

		def remote(root: Path, *args: str) -> str:
			calls.append((root, *args))
			if args[:3] == ("gh", "release", "download"):
				name = args[args.index("--pattern") + 1]
				directory = Path(args[args.index("--dir") + 1])
				source = archive if name == archive.name else manifest
				_ = (directory / name).write_bytes(
					b"altered" if altered else source.read_bytes()
				)
			return ""

		with (
			patch.object(releases, "tag_sha", return_value=SHA),
			patch.object(releases, "api", return_value=existing),
			patch.object(releases, "run", side_effect=remote),
		):
			releases.draft_release(self.root, archive, manifest)
		return calls

	def test_matching_draft_reruns_preserve_assets_and_edited_notes(self):
		calls = self.existing_draft()
		self.assertEqual(2, len(calls))
		self.assertTrue(all(call[3] == "download" for call in calls))

	def test_partial_draft_can_attach_missing_assets_without_clobbering(self):
		calls = self.existing_draft(missing=True)
		self.assertEqual(1, sum(call[3] == "upload" for call in calls))
		self.assertTrue(all("--clobber" not in call for call in calls))

	def test_reruns_cannot_replace_assets_or_modify_a_published_release(self):
		with self.assertRaisesRegex(ValueError, "replace"):
			_ = self.existing_draft(altered=True)
		with self.assertRaisesRegex(ValueError, "Published release"):
			_ = self.existing_draft(published=True, missing=True)
