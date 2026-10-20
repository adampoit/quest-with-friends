"""The CurseForge export changes presentation, not the README's content."""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools.export_curseforge import README, export_description

SCRIPT = Path(__file__).resolve().parents[1] / "export_curseforge.py"
SCREENSHOT = '<p align="center">\n  <img src="https://example.com/image.png" alt="Panel" width="440" />\n</p>'


class CurseForgeExportTests(unittest.TestCase):
	def test_only_screenshot_block_changes(self):
		before = "# Title\n\n**Pitch** and [docs](https://example.com/docs).\n\n"
		after = "\n\nUse `QuestWithFriends-<version>.zip` and `/qwf preview`.\n"
		self.assertEqual(
			export_description(before + SCREENSHOT + after),
			before + "![Panel](https://example.com/image.png)" + after,
		)

	def test_image_entities_and_markdown_characters_are_escaped(self):
		readme = SCREENSHOT.replace(
			"https://example.com/image.png",
			"https://example.com/screen (1).png?a=1&amp;b=2",
		).replace('alt="Panel"', 'alt="Friends [ready] &amp; waiting"')
		self.assertEqual(
			export_description(readme),
			"![Friends \\[ready\\] & waiting](https://example.com/screen%20%281%29.png?a=1&b=2)",
		)

	def test_unexpected_screenshot_markup_fails(self):
		for readme in (
			"# No image",
			SCREENSHOT + "\n\n" + SCREENSHOT,
			SCREENSHOT.replace('width="440"', ""),
		):
			with (
				self.subTest(readme=readme),
				self.assertRaisesRegex(ValueError, "exactly one centered"),
			):
				_ = export_description(readme)

	def test_repository_export_has_absolute_links_and_no_html_block(self):
		markdown = export_description(README.read_text(encoding="utf-8"))
		self.assertIn("![Quest With Friends panel", markdown)
		self.assertNotIn('<p align="center">', markdown)
		self.assertNotIn("<img", markdown)
		links = [
			match[1] for match in re.finditer(r"!?\[[^\]]*\]\(([^)]+)\)", markdown)
		]
		self.assertGreater(len(links), 1)
		for link in links:
			self.assertTrue(link.startswith("https://"), link)

	def test_cli_works_outside_repository_and_writes_only_markdown(self):
		with tempfile.TemporaryDirectory() as directory:
			result = subprocess.run(
				[sys.executable, str(SCRIPT)],
				cwd=directory,
				capture_output=True,
				text=True,
				check=True,
			)
		self.assertEqual(result.stderr, "")
		self.assertEqual(
			result.stdout, export_description(README.read_text(encoding="utf-8"))
		)


if __name__ == "__main__":
	_ = unittest.main()
