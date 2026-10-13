#!/usr/bin/env python3
"""Package the runtime, README, license, and third-party notices."""

import argparse
import re
import tempfile
from pathlib import Path, PurePosixPath
from typing import cast
from zipfile import ZIP_DEFLATED, ZipFile


ADDON_NAME = "QuestWithFriends"
ADDON_ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ASSETS = ("Media/QuestToggle.tga", "Media/PanelLock.tga")


def bundle(root: Path, output: Path | None = None, *, tag: str | None = None) -> Path:
	root = root.resolve()
	toc_name = f"{ADDON_NAME}.toc"
	toc = (root / toc_name).read_text(encoding="utf-8-sig")
	version_match = re.search(r"^##\s*Version:\s*(\S+)\s*$", toc, re.MULTILINE)
	if not version_match or not re.fullmatch(r"[A-Za-z0-9._-]+", version_match[1]):
		raise ValueError("TOC must contain a filename-safe Version")

	if tag is not None and tag != f"v{version_match[1]}":
		raise ValueError(f"Release tag must be v{version_match[1]}, got {tag}")

	names = [toc_name, "README.md", "LICENSE", *RUNTIME_ASSETS]
	for line in toc.splitlines():
		line = line.strip()
		if line and not line.startswith("#"):
			names.append(line.replace("\\", "/"))

	files: dict[str, Path] = {}
	for name in names:
		relative = PurePosixPath(name)
		if relative.is_absolute() or ".." in relative.parts or ":" in name:
			raise ValueError(f"Unsafe TOC path: {name}")
		source = (root / relative).resolve()
		if not source.is_relative_to(root):
			raise ValueError(f"File points outside the addon: {name}")
		if not source.is_file():
			raise ValueError(f"Required addon file is missing: {name}")
		files[relative.as_posix()] = source

	output = (
		output or root / "dist" / f"{ADDON_NAME}-{version_match[1]}.zip"
	).resolve()
	if output in files.values():
		raise ValueError("Output would overwrite an addon file")
	output.parent.mkdir(parents=True, exist_ok=True)
	# Publish only a complete ZIP, leaving any previous bundle intact on failure.
	with tempfile.NamedTemporaryFile(
		dir=output.parent, suffix=".zip", delete=False
	) as temp:
		temporary = Path(temp.name)
	try:
		with ZipFile(temporary, "w", compression=ZIP_DEFLATED) as archive:
			for name, source in files.items():
				archive.write(source, f"{ADDON_NAME}/{name}")
		_ = temporary.replace(output)
	finally:
		temporary.unlink(missing_ok=True)
	return output


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	_ = parser.add_argument(
		"output", nargs="?", type=Path, help="optional ZIP output path"
	)
	_ = parser.add_argument(
		"--tag", help="require a release tag matching v<TOC version>"
	)
	args = parser.parse_args()
	try:
		output = bundle(
			ADDON_ROOT, cast(Path | None, args.output), tag=cast(str | None, args.tag)
		)
	except (OSError, ValueError) as error:
		parser.exit(1, f"Bundle failed: {error}\n")
	with ZipFile(output) as archive:
		print(
			f"Created {output} ({len(archive.namelist())} files, {output.stat().st_size:,} bytes)"
		)


if __name__ == "__main__":
	main()
