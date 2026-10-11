"""Publication compatibility comes from the reviewed ZIP, not the checkout."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile

from tools.curseforge_game_versions import (
	FOREVER_VERSION_TYPE_ID,
	RETAIL_VERSION_TYPE_ID,
	TOC_PATH,
	interface_versions,
	resolve_game_versions,
)


SCRIPT = Path(__file__).resolve().parents[1] / "curseforge_game_versions.py"


class CurseForgeGameVersionTests(unittest.TestCase):
	temp: tempfile.TemporaryDirectory[str]
	root: Path
	archive: Path
	versions: list[dict[str, object]]

	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.temp = tempfile.TemporaryDirectory()
		self.addCleanup(self.temp.cleanup)
		self.root = Path(self.temp.name)
		self.archive = self.root / "release.zip"
		self.versions = [
			{
				"id": 16519,
				"name": "12.1.0",
				"gameVersionTypeID": RETAIL_VERSION_TYPE_ID,
			},
			{
				"id": 16984,
				"name": "12.1.5",
				"gameVersionTypeID": RETAIL_VERSION_TYPE_ID,
			},
			{
				"id": 14422,
				"name": "12.0.1",
				"gameVersionTypeID": RETAIL_VERSION_TYPE_ID,
			},
			{
				"id": 17053,
				"name": "1.60.1",
				"gameVersionTypeID": FOREVER_VERSION_TYPE_ID,
			},
			{"id": 42, "name": "12.1.0", "gameVersionTypeID": 999},
			{"id": 43, "name": "1.60.1", "gameVersionTypeID": 999},
		]
		self.write_toc("## Interface: 120100, 16001\n")

	def write_toc(self, toc: str) -> None:
		with ZipFile(self.archive, "w") as archive:
			archive.writestr(TOC_PATH, toc)

	def run_cli(self) -> subprocess.CompletedProcess[str]:
		versions = self.root / "versions.json"
		_ = versions.write_text(json.dumps(self.versions), encoding="utf-8")
		return subprocess.run(
			[sys.executable, str(SCRIPT), str(self.archive), str(versions)],
			cwd=self.root,
			capture_output=True,
			text=True,
		)

	def test_matches_retail_and_forever_and_ignores_other_version_types(self):
		self.assertEqual(
			[16519, 17053], resolve_game_versions(self.archive, self.versions)
		)

	def test_forever_entry_can_precede_retail(self):
		self.write_toc("## Interface: 16001, 120100\n")
		self.assertEqual(
			[17053, 16519], resolve_game_versions(self.archive, self.versions)
		)

	def test_multiple_versions_are_deduplicated(self):
		self.write_toc("## Interface: 120100, 16001, 120105, 120100, 16001\n")
		self.assertEqual(
			[16519, 17053, 16984], resolve_game_versions(self.archive, self.versions)
		)

	def test_patch_number_and_bom_are_supported(self):
		self.write_toc("\ufeff## Interface: 120001, 16001\r\n")
		self.assertEqual(["12.0.1", "1.60.1"], interface_versions(self.archive))
		self.assertEqual(
			[14422, 17053], resolve_game_versions(self.archive, self.versions)
		)

	def test_unknown_retail_version_does_not_select_latest(self):
		self.write_toc("## Interface: 120200, 16001\n")
		with self.assertRaisesRegex(
			ValueError, "no supported game version matching 12.2.0"
		):
			_ = resolve_game_versions(self.archive, self.versions)

	def test_every_declared_version_must_match(self):
		for interfaces, missing in (
			("120100, 120200, 16001", "12.2.0"),
			("120100, 16002", "1.60.2"),
		):
			with self.subTest(interfaces=interfaces):
				self.write_toc(f"## Interface: {interfaces}\n")
				with self.assertRaisesRegex(
					ValueError, f"no supported game version matching {missing}"
				):
					_ = resolve_game_versions(self.archive, self.versions)

	def test_missing_forever_version_is_not_silently_skipped(self):
		versions = [
			version
			for version in self.versions
			if version.get("gameVersionTypeID") != FOREVER_VERSION_TYPE_ID
		]
		with self.assertRaisesRegex(
			ValueError, "no supported game version matching 1.60.1"
		):
			_ = resolve_game_versions(self.archive, versions)

	def test_classic_version_is_not_mistaken_for_forever(self):
		self.write_toc("## Interface: 11507\n")
		self.versions.append({"id": 99999, "name": "1.15.7", "gameVersionTypeID": 999})
		with self.assertRaisesRegex(
			ValueError, "no supported game version matching 1.15.7"
		):
			_ = resolve_game_versions(self.archive, self.versions)

	def test_duplicate_supported_matches_are_rejected(self):
		for version in (self.versions[0], self.versions[3]):
			with self.subTest(name=version["name"]):
				versions = self.versions + [version | {"id": 99999}]
				with self.assertRaisesRegex(
					ValueError, "ambiguous supported game versions"
				):
					_ = resolve_game_versions(self.archive, versions)

	def test_invalid_version_ids_are_rejected(self):
		for version_id in (True, "16519", 0, -1, 16519.5, None):
			with self.subTest(version_id=version_id):
				versions = [self.versions[0] | {"id": version_id}]
				with self.assertRaisesRegex(ValueError, "invalid version ID"):
					_ = resolve_game_versions(self.archive, versions)

	def test_invalid_api_shapes_are_rejected(self):
		for versions in (dict[str, object](), None, "error", [None], [16519]):
			with self.subTest(versions=versions):
				with self.assertRaisesRegex(ValueError, "array of objects"):
					_ = resolve_game_versions(self.archive, versions)

	def test_missing_packaged_toc_is_rejected(self):
		with ZipFile(self.archive, "w") as archive:
			archive.writestr("QuestWithFriends.toc", "## Interface: 120100\n")
		with self.assertRaisesRegex(ValueError, "Release ZIP is missing"):
			_ = interface_versions(self.archive)

	def test_missing_or_invalid_interface_metadata_is_rejected(self):
		for toc in (
			"## Title: Quest With Friends\n",
			"## Interface: 120100, invalid\n",
			"## Interface: 120100,\n",
			"## Interface: 0\n",
			"## Interface: 123\n",
		):
			with self.subTest(toc=toc):
				self.write_toc(toc)
				with self.assertRaisesRegex(ValueError, "Interface metadata"):
					_ = interface_versions(self.archive)

	def test_forever_only_toc_is_supported(self):
		self.write_toc("## Interface: 16001\n")
		self.assertEqual(["1.60.1"], interface_versions(self.archive))
		self.assertEqual([17053], resolve_game_versions(self.archive, self.versions))

	def test_cli_reads_archive_instead_of_checkout(self):
		_ = (self.root / "QuestWithFriends.toc").write_text("## Interface: 120105\n")
		result = self.run_cli()
		self.assertEqual(0, result.returncode, result.stderr)
		self.assertEqual([16519, 17053], json.loads(result.stdout))

	def test_cli_failure_outputs_no_ids(self):
		self.write_toc("## Interface: 120200\n")
		result = self.run_cli()
		self.assertNotEqual(0, result.returncode)
		self.assertEqual("", result.stdout)
		self.assertIn("no supported game version matching 12.2.0", result.stderr)


if __name__ == "__main__":
	_ = unittest.main()
