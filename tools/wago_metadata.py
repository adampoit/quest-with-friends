#!/usr/bin/env python3
"""Prepare a Wago upload from a published addon ZIP and reviewed release notes."""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import cast
from zipfile import BadZipFile

if not __package__:
	sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.release_package import interface_versions, read_toc


SUPPORTED_CLIENTS = ("retail", "forever")


def project_id(archive: Path) -> str:
	values = cast(
		list[str],
		re.findall(
			r"^##[ \t]*X-Wago-ID:[ \t]*([^\r\n]*)", read_toc(archive), re.MULTILINE
		),
	)
	if len(values) != 1 or re.fullmatch(r"[A-Za-z0-9]{8}", values[0].strip()) is None:
		raise ValueError("Release TOC must contain exactly one valid X-Wago-ID")
	return values[0].strip()


def resolve_patches(archive: Path, catalog: object) -> dict[str, list[str]]:
	if not isinstance(catalog, dict):
		raise ValueError("Wago game catalog must contain a patches object")
	patches = cast(dict[str, object], catalog).get("patches")
	if not isinstance(patches, dict):
		raise ValueError("Wago game catalog must contain a patches object")

	available: dict[str, list[str]] = {}
	for client in SUPPORTED_CLIENTS:
		versions = cast(dict[str, object], patches).get(client, [])
		if not isinstance(versions, list) or not all(
			isinstance(version, str) for version in cast(list[object], versions)
		):
			raise ValueError(f"Wago {client} patches must be an array of strings")
		available[client] = cast(list[str], versions)

	result: dict[str, list[str]] = {}
	for version in interface_versions(archive):
		clients = [
			client for client in SUPPORTED_CLIENTS if version in available[client]
		]
		if not clients:
			raise ValueError(f"Wago has no supported game version matching {version}")
		if len(clients) != 1:
			raise ValueError(f"Wago has ambiguous game clients matching {version}")
		result.setdefault(f"supported_{clients[0]}_patches", []).append(version)
	return result


def prepare_upload(
	archive: Path, release: object, catalog: object
) -> dict[str, object]:
	if not isinstance(release, dict):
		raise ValueError("GitHub release must be an object")
	details = cast(dict[str, object], release)
	tag = details.get("tag_name")
	if not isinstance(tag, str) or re.fullmatch(r"v[A-Za-z0-9._-]+", tag) is None:
		raise ValueError("GitHub release must have a valid version tag")
	if details.get("draft") is not False:
		raise ValueError("GitHub release must be published, not a draft")
	prerelease = details.get("prerelease")
	if not isinstance(prerelease, bool):
		raise ValueError("GitHub release must specify prerelease status")
	label = details.get("name")
	notes = details.get("body")
	if label is not None and not isinstance(label, str):
		raise ValueError("GitHub release title must be a string")
	if notes is not None and not isinstance(notes, str):
		raise ValueError("GitHub release notes must be a string")

	stability = (
		"alpha" if "alpha" in tag.lower() else "beta" if prerelease else "stable"
	)
	return {
		"project_id": project_id(archive),
		"metadata": {
			"label": label or tag,
			"stability": stability,
			"changelog": notes or "",
			**resolve_patches(archive, catalog),
		},
	}


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	_ = parser.add_argument("archive", type=Path, help="published addon ZIP")
	_ = parser.add_argument("release", type=Path, help="published GitHub release JSON")
	_ = parser.add_argument("catalog", type=Path, help="Wago game catalog JSON")
	args = parser.parse_args()
	archive = cast(Path, args.archive)
	release_path = cast(Path, args.release)
	catalog_path = cast(Path, args.catalog)
	try:
		release = cast(object, json.loads(release_path.read_text(encoding="utf-8")))
		catalog = cast(object, json.loads(catalog_path.read_text(encoding="utf-8")))
		upload = prepare_upload(archive, release, catalog)
	except (OSError, ValueError, BadZipFile) as error:
		parser.error(str(error))
	print(json.dumps(upload))


if __name__ == "__main__":
	main()
