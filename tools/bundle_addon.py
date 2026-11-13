#!/usr/bin/env python3
"""Package the runtime, README, license, and third-party notices."""

import argparse
import re
import tempfile
from pathlib import Path, PurePosixPath
from typing import cast
from xml.etree import ElementTree
from zipfile import ZIP_DEFLATED, ZipFile

ADDON_NAME = "QuestWithFriends"
ADDON_ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ASSETS = ("Media/QuestToggle.tga", "Media/PanelLock.tga")
DEV_ADDON_NAME = "QuestWithFriendsDev"
DEV_FILES = ("dev/Development.lua", "dev/InGameTests.lua")


def bundle(
	root: Path,
	output: Path | None = None,
	*,
	tag: str | None = None,
	development: bool = False,
	preview_version: str | None = None,
) -> Path:
	root = root.resolve()
	if development and tag is not None:
		raise ValueError("Release tags cannot be used with development packages")
	addon_name = DEV_ADDON_NAME if development else ADDON_NAME
	toc_name = f"{addon_name}.toc"
	toc = (root / toc_name).read_text(encoding="utf-8-sig")
	version_match = re.search(r"^##\s*Version:\s*(\S+)\s*$", toc, re.MULTILINE)
	if not version_match or not re.fullmatch(r"[A-Za-z0-9._-]+", version_match[1]):
		raise ValueError("TOC must contain a filename-safe Version")

	if preview_version is not None:
		if (
			development
			or re.fullmatch(
				r"[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9][A-Za-z0-9.-]*", preview_version
			)
			is None
		):
			raise ValueError(
				"Preview version must be a filename-safe prerelease for the release identity"
			)
		toc = (
			toc[: version_match.start(1)]
			+ preview_version
			+ toc[version_match.end(1) :]
		)
		version_match = re.search(r"^##\s*Version:\s*(\S+)\s*$", toc, re.MULTILINE)
		assert version_match is not None

	if tag is not None and tag != f"v{version_match[1]}":
		raise ValueError(f"Release tag must be v{version_match[1]}, got {tag}")

	names = ["README.md", "LICENSE", *RUNTIME_ASSETS]
	for line in toc.splitlines():
		line = line.strip()
		if line and not line.startswith("#"):
			name = line.replace("\\", "/")
			names.append(name)

	files: dict[str, Path] = {}
	loading: set[str] = set()

	def add_file(name: str, parent: PurePosixPath) -> None:
		relative = PurePosixPath(name.replace("\\", "/"))
		if (
			not relative.parts
			or relative.is_absolute()
			or ".." in relative.parts
			or ":" in name
		):
			raise ValueError(f"Unsafe manifest path: {name}")
		relative = parent / relative
		name = relative.as_posix()
		if not development and (
			relative.parts[0] == "dev"
			or relative.name in ("Development.lua", "InGameTests.lua")
		):
			raise ValueError(f"Development-only file in release manifest: {name}")
		source = (root / relative).resolve()
		if not source.is_relative_to(root):
			raise ValueError(f"File points outside the addon: {name}")
		if not source.is_file():
			raise ValueError(f"Required addon file is missing: {name}")
		if name in loading:
			raise ValueError(f"Circular XML include: {name}")
		if name in files:
			return
		files[name] = source
		if relative.suffix.lower() == ".xml":
			loading.add(name)
			try:
				document = ElementTree.parse(source)
			except ElementTree.ParseError as error:
				raise ValueError(f"Invalid XML manifest {name}: {error}") from error
			for element in document.iter():
				if element.tag.rsplit("}", 1)[-1] in ("Script", "Include"):
					dependency = element.get("file")
					if dependency:
						add_file(dependency, relative.parent)
			loading.remove(name)

	for name in names:
		add_file(name, PurePosixPath())

	output = (
		output or root / "dist" / f"{addon_name}-{version_match[1]}.zip"
	).resolve()
	if output in files.values() or output in (
		root / f"{ADDON_NAME}.toc",
		root / f"{DEV_ADDON_NAME}.toc",
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
	_ = parser.add_argument(
		"--preview-version",
		help="override only the packaged TOC with a prerelease version",
	)
	_ = parser.add_argument(
		"--dev", action="store_true", help="build a separate development addon ZIP"
	)
	args = parser.parse_args()
	requested_output = cast(Path | None, args.output)
	tag = cast(str | None, args.tag)
	development = cast(bool, args.dev)
	preview_version = cast(str | None, args.preview_version)
	try:
		output = bundle(
			ADDON_ROOT,
			requested_output,
			tag=tag,
			development=development,
			preview_version=preview_version,
		)
	except (OSError, ValueError) as error:
		parser.exit(1, f"Bundle failed: {error}\n")
	with ZipFile(output) as archive:
		print(
			f"Created {output} ({len(archive.namelist())} files, {output.stat().st_size:,} bytes)"
		)


if __name__ == "__main__":
	main()
