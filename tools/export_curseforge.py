"""Export the README to stdout for pasting into CurseForge's Markdown editor."""

import html
import re
import sys
from pathlib import Path
from urllib.parse import quote

README = Path(__file__).resolve().parents[1] / "README.md"
SCREENSHOT = re.compile(
	r'^<p align="center">\s*'
	+ r'<img src="(?P<src>[^"]+)" alt="(?P<alt>[^"]*)" width="\d+"\s*/>\s*'
	+ r"</p>[ \t]*$",
	re.MULTILINE,
)


def export_description(readme: str) -> str:
	def markdown_image(match: re.Match[str]) -> str:
		alt = html.unescape(match["alt"])
		for character in ("\\", "[", "]"):
			alt = alt.replace(character, "\\" + character)
		src = quote(html.unescape(match["src"]), safe="/:?#@!$&'*+,;=%~.-_")
		return f"![{alt}]({src})"

	markdown, count = SCREENSHOT.subn(markdown_image, readme)
	if count != 1:
		raise ValueError("Expected exactly one centered README screenshot block")
	return markdown


def main() -> None:
	try:
		markdown = export_description(README.read_text(encoding="utf-8"))
	except (OSError, ValueError) as error:
		sys.exit(str(error))
	_ = sys.stdout.write(markdown)


if __name__ == "__main__":
	main()
