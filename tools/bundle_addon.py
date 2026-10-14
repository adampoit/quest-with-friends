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
DEV_ADDON_NAME = "QuestWithFriendsDev"
DEV_FILES = ("Development.lua", "InGameTests.lua")


def development_toc(toc: str) -> str:
	"""Derive the dev manifest from the release's interfaces and runtime list."""
	toc = re.sub(r"(?m)^## Title:.*$", "## Title: Quest With Friends (Dev)", toc)
	toc = re.sub(r"(?m)^(## Version:.*)$", r"\1-dev", toc)
	toc = re.sub(
		r"(?m)^## SavedVariables:.*$", "## SavedVariables: QuestWithFriendsDevDB", toc
	)
	# Load an enabled release first so it wins when both are checked.
	toc = re.sub(r"(?m)^(## OptionalDeps:.*)$", r"\1, QuestWithFriends", toc)
	toc = re.sub(r"(?m)^## X-(?:Wago-ID|Curse-Project-ID):.*\n?", "", toc)
	lines = toc.splitlines()
	index = (
		lines.index("QuestWithFriends.lua")
		if "QuestWithFriends.lua" in lines
		else len(lines)
	)
	lines.insert(index, "Development.lua")
	lines.append("InGameTests.lua")
	return "\n".join(lines) + "\n"


def write_development_toc(root: Path) -> Path:
	output = root / f"{DEV_ADDON_NAME}.toc"
	_ = output.write_text(
		development_toc((root / f"{ADDON_NAME}.toc").read_text(encoding="utf-8-sig")),
		encoding="utf-8",
	)
	return output


def bundle(
	root: Path,
	output: Path | None = None,
	*,
	tag: str | None = None,
	development: bool = False,
) -> Path:
	root = root.resolve()
	if development and tag is not None:
		raise ValueError("Release tags cannot be used with development packages")
	addon_name = DEV_ADDON_NAME if development else ADDON_NAME
	toc_name = f"{addon_name}.toc"
	toc = (root / f"{ADDON_NAME}.toc").read_text(encoding="utf-8-sig")
	if development:
		toc = development_toc(toc)
	version_match = re.search(r"^##\s*Version:\s*(\S+)\s*$", toc, re.MULTILINE)
	if not version_match or not re.fullmatch(r"[A-Za-z0-9._-]+", version_match[1]):
		raise ValueError("TOC must contain a filename-safe Version")

	if tag is not None and tag != f"v{version_match[1]}":
		raise ValueError(f"Release tag must be v{version_match[1]}, got {tag}")

	names = ["README.md", "LICENSE", *RUNTIME_ASSETS]
	for line in toc.splitlines():
		line = line.strip()
		if line and not line.startswith("#"):
			name = line.replace("\\", "/")
			names.append(name)

	files: dict[str, Path] = {}
	for name in names:
		relative = PurePosixPath(name)
		if relative.is_absolute() or ".." in relative.parts or ":" in name:
			raise ValueError(f"Unsafe TOC path: {name}")
		if not development and relative.as_posix() in DEV_FILES:
			raise ValueError(f"Development-only file in release TOC: {name}")
		source = (root / relative).resolve()
		if not source.is_relative_to(root):
			raise ValueError(f"File points outside the addon: {name}")
		if not source.is_file():
			raise ValueError(f"Required addon file is missing: {name}")
		files[relative.as_posix()] = source

	output = (
		output or root / "dist" / f"{addon_name}-{version_match[1]}.zip"
	).resolve()
	if output in files.values() or output in (
		root / f"{ADDON_NAME}.toc",
		root / toc_name,
	):
		raise ValueError("Output would overwrite an addon file")
	output.parent.mkdir(parents=True, exist_ok=True)
	# Publish only a complete ZIP, leaving any previous bundle intact on failure.
	with tempfile.NamedTemporaryFile(
		dir=output.parent, suffix=".zip", delete=False
	) as temp:
		temporary = Path(temp.name)
	try:
		with ZipFile(temporary, "w", compression=ZIP_DEFLATED) as archive:
			archive.writestr(f"{addon_name}/{toc_name}", toc)
			for name, source in files.items():
				archive.write(source, f"{addon_name}/{name}")
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
	mode = parser.add_mutually_exclusive_group()
	_ = mode.add_argument(
		"--dev", action="store_true", help="build a separate development addon ZIP"
	)
	_ = mode.add_argument(
		"--dev-toc",
		action="store_true",
		help="write the dev TOC for a live QuestWithFriendsDev checkout",
	)
	args = parser.parse_args()
	requested_output = cast(Path | None, args.output)
	tag = cast(str | None, args.tag)
	development = cast(bool, args.dev)
	dev_toc = cast(bool, args.dev_toc)
	if dev_toc and (requested_output or tag):
		parser.error("--dev-toc cannot be combined with an output path or release tag")
	try:
		if dev_toc:
			print(f"Created {write_development_toc(ADDON_ROOT)}")
			return
		output = bundle(
			ADDON_ROOT,
			requested_output,
			tag=tag,
			development=development,
		)
	except (OSError, ValueError) as error:
		parser.exit(1, f"Bundle failed: {error}\n")
	with ZipFile(output) as archive:
		print(
			f"Created {output} ({len(archive.namelist())} files, {output.stat().st_size:,} bytes)"
		)


if __name__ == "__main__":
	main()
