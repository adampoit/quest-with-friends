#!/usr/bin/env python3
"""Resolve CurseForge Retail and Forever version IDs from a published addon ZIP."""

import argparse
import json
import sys
from pathlib import Path
from typing import cast
from zipfile import BadZipFile

if not __package__:
	sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.release_package import interface_versions


RETAIL_VERSION_TYPE_ID = 517
FOREVER_VERSION_TYPE_ID = 88568
SUPPORTED_VERSION_TYPE_IDS = (RETAIL_VERSION_TYPE_ID, FOREVER_VERSION_TYPE_ID)


def resolve_game_versions(archive: Path, versions: object) -> list[int]:
	if not isinstance(versions, list):
		raise ValueError("CurseForge game versions must be an array of objects")
	catalog: list[dict[str, object]] = []
	for version in cast(list[object], versions):
		if not isinstance(version, dict):
			raise ValueError("CurseForge game versions must be an array of objects")
		catalog.append(cast(dict[str, object], version))

	ids: list[int] = []
	for name in interface_versions(archive):
		matches = [
			version.get("id")
			for version in catalog
			if version.get("name") == name
			and version.get("gameVersionTypeID") in SUPPORTED_VERSION_TYPE_IDS
		]
		if not matches:
			raise ValueError(
				f"CurseForge has no supported game version matching {name}"
			)
		if len(matches) != 1:
			raise ValueError(
				f"CurseForge has ambiguous supported game versions matching {name}"
			)
		version_id = matches[0]
		if type(version_id) is not int or version_id <= 0:
			raise ValueError(f"CurseForge returned an invalid version ID for {name}")
		ids.append(version_id)
	return ids


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	_ = parser.add_argument("archive", type=Path, help="published addon ZIP")
	_ = parser.add_argument("versions", type=Path, help="CurseForge game versions JSON")
	args = parser.parse_args()
	archive = cast(Path, args.archive)
	versions_path = cast(Path, args.versions)
	try:
		versions = cast(object, json.loads(versions_path.read_text(encoding="utf-8")))
		ids = resolve_game_versions(archive, versions)
	except (OSError, ValueError, BadZipFile) as error:
		parser.error(str(error))
	print(json.dumps(ids))


if __name__ == "__main__":
	main()
