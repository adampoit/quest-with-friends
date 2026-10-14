"""Release bundles use an allowlist, not a recursive directory copy."""

import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile

from tools.bundle_addon import (
	ADDON_ROOT,
	DEV_FILES,
	RUNTIME_ASSETS,
	bundle,
	development_toc,
	write_development_toc,
)
from tools.generate_panel_lock import generate


class BundleTests(unittest.TestCase):
	temp: tempfile.TemporaryDirectory[str]
	root: Path

	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.temp = tempfile.TemporaryDirectory()
		self.addCleanup(self.temp.cleanup)
		self.root = Path(self.temp.name)
		_ = (self.root / "QuestWithFriends.toc").write_text(
			"## Version: 0.1.0\n\nCore.lua\n"
		)
		_ = (self.root / "Core.lua").write_text("-- runtime\n")
		_ = (self.root / "README.md").write_text("Install under Interface/AddOns.\n")
		_ = (self.root / "LICENSE").write_text("MIT License\n")
		(self.root / "Media").mkdir()
		for asset in RUNTIME_ASSETS:
			_ = (self.root / asset).write_bytes((ADDON_ROOT / asset).read_bytes())

	def test_only_runtime_files_and_readme_are_bundled(self):
		for name in (
			".cache/data.html",
			".git/config",
			".jj/repo/data",
			".ruff_cache/data",
			"tools/__pycache__/tool.pyc",
			"tests/test.lua",
			"QuestEquivalences.generated.lua",
			"Media/unlisted.tga",
		):
			path = self.root / name
			path.parent.mkdir(parents=True, exist_ok=True)
			_ = path.write_text("not for release")
		output = bundle(self.root)
		self.assertEqual(self.root / "dist/QuestWithFriends-0.1.0.zip", output)
		with ZipFile(output) as archive:
			self.assertIsNone(archive.testzip())
			self.assertEqual(
				{
					"QuestWithFriends/QuestWithFriends.toc",
					"QuestWithFriends/Core.lua",
					"QuestWithFriends/README.md",
					"QuestWithFriends/LICENSE",
					"QuestWithFriends/Media/QuestToggle.tga",
					"QuestWithFriends/Media/PanelLock.tga",
				},
				set(archive.namelist()),
			)
			self.assertEqual(b"-- runtime\n", archive.read("QuestWithFriends/Core.lua"))
			self.assertEqual(b"MIT License\n", archive.read("QuestWithFriends/LICENSE"))
		_ = bundle(self.root)

	def test_release_excludes_development_files_and_generated_toc(self):
		for name in (*DEV_FILES, "QuestWithFriendsDev.toc"):
			_ = (self.root / name).write_text("-- dev only\n")
		with ZipFile(bundle(self.root)) as archive:
			for name in (*DEV_FILES, "QuestWithFriendsDev.toc"):
				self.assertNotIn(f"QuestWithFriends/{name}", archive.namelist())

	def test_release_rejects_development_files_in_toc(self):
		for name in DEV_FILES:
			with self.subTest(name=name):
				_ = (self.root / "QuestWithFriends.toc").write_text(
					f"## Version: 0.1.0\nCore.lua\n{name}\n"
				)
				with self.assertRaisesRegex(ValueError, "Development-only"):
					_ = bundle(self.root)

	def test_development_manifest_tracks_release_metadata_and_load_order(self):
		toc = (ADDON_ROOT / "QuestWithFriends.toc").read_text()
		dev = development_toc(toc)
		self.assertEqual(toc.splitlines()[0], dev.splitlines()[0])
		self.assertIn("## Title: Quest With Friends (Dev)", dev)
		self.assertIn("## SavedVariables: QuestWithFriendsDevDB", dev)
		self.assertIn("## OptionalDeps: AddonKit, QuestWithFriends", dev)
		self.assertNotIn("X-Wago-ID", dev)
		files = [line for line in dev.splitlines() if line.endswith(".lua")]
		self.assertEqual("Bootstrap.lua", files[0])
		self.assertLess(
			files.index("Development.lua"), files.index("QuestWithFriends.lua")
		)
		self.assertEqual("InGameTests.lua", files[-1])

	def test_development_bundle_uses_a_separate_installation(self):
		with tempfile.TemporaryDirectory() as temp:
			output = bundle(ADDON_ROOT, Path(temp) / "dev.zip", development=True)
			with ZipFile(output) as archive:
				self.assertIsNone(archive.testzip())
				self.assertTrue(
					all(
						name.startswith("QuestWithFriendsDev/")
						for name in archive.namelist()
					)
				)
				for name in DEV_FILES:
					self.assertIn(f"QuestWithFriendsDev/{name}", archive.namelist())
				toc = archive.read(
					"QuestWithFriendsDev/QuestWithFriendsDev.toc"
				).decode()
				self.assertEqual(
					development_toc((ADDON_ROOT / "QuestWithFriends.toc").read_text()),
					toc,
				)
				self.assertNotIn(
					"QuestWithFriendsDev/QuestWithFriends.toc", archive.namelist()
				)

	def test_development_bundle_rejects_release_tags(self):
		with self.assertRaisesRegex(ValueError, "Release tags"):
			_ = bundle(self.root, development=True, tag="v0.1.0")

	def test_live_development_manifest_matches_packaged_manifest(self):
		output = write_development_toc(self.root)
		self.assertEqual("QuestWithFriendsDev.toc", output.name)
		self.assertEqual(
			development_toc((self.root / "QuestWithFriends.toc").read_text()),
			output.read_text(),
		)

	def test_cannot_overwrite_source_toc(self):
		for development in (False, True):
			for name in DEV_FILES:
				_ = (self.root / name).write_text("-- dev only\n")
			with self.assertRaisesRegex(ValueError, "overwrite"):
				_ = bundle(
					self.root,
					self.root / "QuestWithFriends.toc",
					development=development,
				)

	def test_missing_file_preserves_previous_bundle(self):
		output = bundle(self.root)
		previous = output.read_bytes()
		(self.root / "Core.lua").unlink()
		with self.assertRaisesRegex(ValueError, "missing"):
			_ = bundle(self.root)
		self.assertEqual(previous, output.read_bytes())

	def test_toggle_texture_is_bundled_with_transparent_edges(self):
		output = bundle(self.root)
		with ZipFile(output) as archive:
			texture = archive.read("QuestWithFriends/Media/QuestToggle.tga")
		self.assertEqual((self.root / "Media/QuestToggle.tga").read_bytes(), texture)
		self.assertEqual(2, texture[2])
		self.assertEqual(32, int.from_bytes(texture[12:14], "little"))
		self.assertEqual(32, int.from_bytes(texture[14:16], "little"))
		self.assertEqual(32, texture[16])
		self.assertEqual(8, texture[17])
		self.assertEqual(18 + 32 * 32 * 4, len(texture))
		alpha = texture[21::4]
		self.assertIn(255, alpha)
		self.assertTrue(any(0 < value < 255 for value in alpha))
		for y in range(32):
			for x in range(32):
				if x < 4 or x >= 28 or y < 4 or y >= 28:
					self.assertEqual(0, alpha[y * 32 + x])

	def test_lock_texture_contains_reproducible_distinct_states(self):
		output = bundle(self.root)
		with ZipFile(output) as archive:
			texture = archive.read("QuestWithFriends/Media/PanelLock.tga")
		self.assertEqual(generate(), texture)
		self.assertEqual(2, texture[2])
		self.assertEqual(64, int.from_bytes(texture[12:14], "little"))
		self.assertEqual(32, int.from_bytes(texture[14:16], "little"))
		self.assertEqual(32, texture[16])
		self.assertEqual(0x28, texture[17])
		self.assertEqual(18 + 64 * 32 * 4, len(texture))
		alpha = texture[21::4]
		states = [
			bytes(alpha[y * 64 + offset + x] for y in range(32) for x in range(32))
			for offset in (0, 32)
		]
		self.assertNotEqual(*states)
		for state in states:
			self.assertIn(255, state)
			self.assertTrue(any(0 < value < 255 for value in state))
			for y in range(32):
				for x in range(32):
					if x < 4 or x >= 28 or y < 4 or y >= 28:
						self.assertEqual(0, state[y * 32 + x])

	def test_missing_lock_texture_preserves_previous_bundle(self):
		output = bundle(self.root)
		previous = output.read_bytes()
		(self.root / "Media/PanelLock.tga").unlink()
		with self.assertRaisesRegex(ValueError, "missing"):
			_ = bundle(self.root)
		self.assertEqual(previous, output.read_bytes())

	def test_missing_texture_preserves_previous_bundle(self):
		output = bundle(self.root)
		previous = output.read_bytes()
		(self.root / "Media/QuestToggle.tga").unlink()
		with self.assertRaisesRegex(ValueError, "missing"):
			_ = bundle(self.root)
		self.assertEqual(previous, output.read_bytes())

	def test_matching_release_tag(self):
		output = bundle(self.root, tag="v0.1.0")
		with ZipFile(output) as archive:
			self.assertIsNone(archive.testzip())

	def test_wrong_release_tag_preserves_previous_bundle(self):
		output = bundle(self.root)
		previous = output.read_bytes()
		for tag in ("0.1.0", "v0.1.1", "v0.1.0-rc.1", ""):
			with self.subTest(tag=tag):
				with self.assertRaisesRegex(ValueError, "Release tag must be v0.1.0"):
					_ = bundle(self.root, tag=tag)
				self.assertEqual(previous, output.read_bytes())

	def test_matching_prerelease_tag(self):
		_ = (self.root / "QuestWithFriends.toc").write_text(
			"## Version: 0.1.0-rc.1\n\nCore.lua\n"
		)
		output = bundle(self.root, tag="v0.1.0-rc.1")
		self.assertEqual("QuestWithFriends-0.1.0-rc.1.zip", output.name)

	def test_nested_windows_paths_and_duplicate_entries(self):
		(self.root / "assets").mkdir()
		_ = (self.root / "assets/icon.blp").write_bytes(b"texture")
		with (self.root / "QuestWithFriends.toc").open("a") as toc:
			_ = toc.write("# comment\nassets\\icon.blp\nCore.lua\n")
		output = bundle(self.root, self.root / "custom.zip")
		with ZipFile(output) as archive:
			self.assertEqual(
				b"texture", archive.read("QuestWithFriends/assets/icon.blp")
			)

	def test_unsafe_paths_are_rejected(self):
		for name in ("../secret.lua", "/tmp/secret.lua", "C:\\secret.lua"):
			with self.subTest(name=name):
				_ = (self.root / "QuestWithFriends.toc").write_text(
					f"## Version: 0.1.0\n{name}\n"
				)
				with self.assertRaisesRegex(ValueError, "Unsafe"):
					_ = bundle(self.root)

	def test_cannot_overwrite_runtime_file(self):
		with self.assertRaisesRegex(ValueError, "overwrite"):
			_ = bundle(self.root, self.root / "Core.lua")


if __name__ == "__main__":
	_ = unittest.main()
