"""Wago publication uses the same reviewed ZIP and notes as GitHub."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast
from zipfile import ZipFile

from tools.release_package import TOC_PATH
from tools.wago_metadata import prepare_upload, project_id, resolve_patches


SCRIPT = Path(__file__).resolve().parents[1] / "wago_metadata.py"
PROJECT_ID = "aB3dE5fG"


class WagoMetadataTests(unittest.TestCase):
	temp: tempfile.TemporaryDirectory[str]
	root: Path
	archive: Path
	release: dict[str, object]
	catalog: dict[str, object]

	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.temp = tempfile.TemporaryDirectory()
		self.addCleanup(self.temp.cleanup)
		self.root = Path(self.temp.name)
		self.archive = self.root / "release.zip"
		self.release = {
			"tag_name": "v1.2.3",
			"name": "v1.2.3",
			"body": '# Reviewed notes\nQuotes " and $(touch unexpected)',
			"draft": False,
			"prerelease": False,
		}
		self.catalog = {
			"patches": {
				"retail": ["12.1.0", "12.1.5"],
				"forever": ["1.60.1"],
				"classic": ["1.15.7"],
			}
		}
		self.write_toc()

	def write_toc(
		self, interfaces: str = "120100, 16001", project: str | None = PROJECT_ID
	) -> None:
		toc = f"## Interface: {interfaces}\n"
		if project is not None:
			toc += f"## X-Wago-ID: {project}\n"
		with ZipFile(self.archive, "w") as archive:
			archive.writestr(TOC_PATH, toc)

	def metadata(self, release: object = None) -> dict[str, object]:
		return cast(
			dict[str, object],
			prepare_upload(
				self.archive, self.release if release is None else release, self.catalog
			)["metadata"],
		)

	def run_cli(self) -> subprocess.CompletedProcess[str]:
		release_path = self.root / "release.json"
		catalog_path = self.root / "catalog.json"
		_ = release_path.write_text(json.dumps(self.release))
		_ = catalog_path.write_text(json.dumps(self.catalog))
		return subprocess.run(
			[
				sys.executable,
				str(SCRIPT),
				str(self.archive),
				str(release_path),
				str(catalog_path),
			],
			cwd=self.root,
			capture_output=True,
			text=True,
		)

	def test_published_release_targets_both_clients(self):
		self.assertEqual(
			{
				"project_id": PROJECT_ID,
				"metadata": {
					"label": "v1.2.3",
					"stability": "stable",
					"changelog": self.release["body"],
					"supported_retail_patches": ["12.1.0"],
					"supported_forever_patches": ["1.60.1"],
				},
			},
			prepare_upload(self.archive, self.release, self.catalog),
		)

	def test_release_types_match_github_approval(self):
		for tag, prerelease, expected in (
			("v1.2.3", False, "stable"),
			("v1.2.3-beta.1", True, "beta"),
			("v1.2.3-rc.1", True, "beta"),
			("v1.2.3-ALPHA.1", True, "alpha"),
		):
			with self.subTest(tag=tag):
				metadata = self.metadata(
					self.release | {"tag_name": tag, "prerelease": prerelease}
				)
				self.assertEqual(expected, metadata["stability"])

	def test_missing_title_and_notes_use_safe_defaults(self):
		metadata = self.metadata(self.release | {"name": None, "body": None})
		self.assertEqual("v1.2.3", metadata["label"])
		self.assertEqual("", metadata["changelog"])

	def test_multiple_patch_versions_are_deduplicated(self):
		self.write_toc("120100, 16001, 120105, 120100, 16001")
		self.assertEqual(
			{
				"supported_retail_patches": ["12.1.0", "12.1.5"],
				"supported_forever_patches": ["1.60.1"],
			},
			resolve_patches(self.archive, self.catalog),
		)

	def test_single_client_releases_are_supported(self):
		for interfaces, expected in (
			("120100", {"supported_retail_patches": ["12.1.0"]}),
			("16001", {"supported_forever_patches": ["1.60.1"]}),
		):
			with self.subTest(interfaces=interfaces):
				self.write_toc(interfaces)
				self.assertEqual(expected, resolve_patches(self.archive, self.catalog))

	def test_unmatched_versions_fail_instead_of_selecting_latest(self):
		for interfaces, missing in (
			("120200, 16001", "12.2.0"),
			("120100, 16002", "1.60.2"),
		):
			with self.subTest(interfaces=interfaces):
				self.write_toc(interfaces)
				with self.assertRaisesRegex(
					ValueError, f"no supported game version matching {missing}"
				):
					_ = resolve_patches(self.archive, self.catalog)

	def test_missing_client_catalog_does_not_silently_omit_forever(self):
		catalog = {"patches": {"retail": ["12.1.0"]}}
		with self.assertRaisesRegex(
			ValueError, "no supported game version matching 1.60.1"
		):
			_ = resolve_patches(self.archive, catalog)

	def test_ambiguous_clients_are_rejected(self):
		catalog = {"patches": {"retail": ["12.1.0", "1.60.1"], "forever": ["1.60.1"]}}
		with self.assertRaisesRegex(ValueError, "ambiguous game clients"):
			_ = resolve_patches(self.archive, catalog)

	def test_classic_is_not_mistaken_for_forever(self):
		self.write_toc("11507")
		with self.assertRaisesRegex(
			ValueError, "no supported game version matching 1.15.7"
		):
			_ = resolve_patches(self.archive, self.catalog)

	def test_missing_or_invalid_project_ids_are_rejected(self):
		for project in (
			None,
			"",
			"short",
			"abc/defg",
			PROJECT_ID + "\n## X-Wago-ID: another1",
		):
			with self.subTest(project=project):
				self.write_toc(project=project)
				with self.assertRaisesRegex(ValueError, "exactly one valid X-Wago-ID"):
					_ = project_id(self.archive)

	def test_invalid_catalogs_are_rejected(self):
		for catalog in (
			None,
			list[object](),
			{"patches": None},
			{"patches": {"retail": "12.1.0"}},
			{"patches": {"forever": [None]}},
		):
			with self.subTest(catalog=catalog):
				with self.assertRaises(ValueError):
					_ = resolve_patches(self.archive, catalog)

	def test_drafts_are_rejected(self):
		with self.assertRaisesRegex(ValueError, "must be published"):
			_ = self.metadata(self.release | {"draft": True})

	def test_invalid_release_fields_are_rejected(self):
		for field, value in (
			("tag_name", "bad/tag"),
			("prerelease", "false"),
			("name", 123),
			("body", 123),
		):
			with self.subTest(field=field):
				with self.assertRaises(ValueError):
					_ = self.metadata(self.release | {field: value})
		with self.assertRaisesRegex(ValueError, "release must be an object"):
			_ = prepare_upload(self.archive, "invalid", self.catalog)

	def test_cli_reads_reviewed_archive_and_safely_serializes_notes(self):
		_ = (self.root / "QuestWithFriends.toc").write_text(
			"## Interface: 120105\n## X-Wago-ID: another1\n"
		)
		result = self.run_cli()
		self.assertEqual(0, result.returncode, result.stderr)
		upload = cast(dict[str, object], json.loads(result.stdout))
		self.assertEqual(PROJECT_ID, upload["project_id"])
		metadata = cast(dict[str, object], upload["metadata"])
		self.assertEqual(["12.1.0"], metadata["supported_retail_patches"])
		self.assertEqual(["1.60.1"], metadata["supported_forever_patches"])
		self.assertEqual(self.release["body"], metadata["changelog"])
		self.assertFalse((self.root / "unexpected").exists())

	def test_cli_failure_outputs_no_upload_metadata(self):
		self.write_toc("120200")
		result = self.run_cli()
		self.assertNotEqual(0, result.returncode)
		self.assertEqual("", result.stdout)
		self.assertIn("no supported game version matching 12.2.0", result.stderr)


if __name__ == "__main__":
	_ = unittest.main()
