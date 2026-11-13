"""Read publication metadata from the reviewed addon ZIP."""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import cast
from zipfile import ZipFile

TOC_PATH = "QuestWithFriends/QuestWithFriends.toc"
NUMBER = r"(?:0|[1-9][0-9]*)"
BASE_VERSION = rf"{NUMBER}\.{NUMBER}\.{NUMBER}"


@dataclass(frozen=True)
class ReleaseTag:
	tag: str
	base: str
	channel: str
	client: str = ""

	@property
	def version(self) -> str:
		return self.tag[1:]

	@property
	def prerelease(self) -> bool:
		return self.channel != "stable"

	@property
	def storefronts(self) -> list[str]:
		if self.client:
			return []
		return ["curseforge", "wago"]


def parse_tag(tag: str) -> ReleaseTag:
	if re.fullmatch(rf"v{BASE_VERSION}", tag):
		return ReleaseTag(tag, tag[1:], "stable")
	match = re.fullmatch(rf"v({BASE_VERSION})-beta\.([1-9][0-9]*)", tag)
	if match:
		return ReleaseTag(tag, match[1], "beta")
	match = re.fullmatch(
		rf"v({BASE_VERSION})-alpha\.(retail|forever)\.([1-9][0-9]*)", tag
	)
	if match:
		return ReleaseTag(tag, match[1], "alpha", match[2])
	raise ValueError(f"Unsupported release tag: {tag}")


def validate_published_release(release: object) -> ReleaseTag:
	if not isinstance(release, dict):
		raise ValueError("GitHub release must be an object")
	details = cast(dict[str, object], release)
	tag = details.get("tag_name")
	if not isinstance(tag, str):
		raise ValueError("GitHub release must have a valid version tag")
	version = parse_tag(tag)
	if details.get("draft") is not False:
		raise ValueError("GitHub release must be published, not a draft")
	if details.get("prerelease") is not version.prerelease:
		raise ValueError("GitHub prerelease status does not match its tag")
	for field in ("name", "body"):
		if details.get(field) is not None and not isinstance(details[field], str):
			raise ValueError(f"GitHub release {field} must be a string")
	return version


def toc_version(toc: str) -> str:
	versions = cast(
		list[str], re.findall(r"^##[ \t]*Version:[ \t]*([^\r\n]+)", toc, re.MULTILINE)
	)
	if len(versions) != 1:
		raise ValueError("Expected exactly one TOC Version")
	return versions[0].strip()


def validate_release_archive(archive: Path, release: object) -> ReleaseTag:
	version = validate_published_release(release)
	if toc_version(read_toc(archive)) != version.version:
		raise ValueError("Packaged Version does not match the release tag")
	return version


def read_toc(archive: Path) -> str:
	with ZipFile(archive) as package:
		try:
			return package.read(TOC_PATH).decode("utf-8-sig")
		except KeyError:
			raise ValueError(f"Release ZIP is missing {TOC_PATH}") from None


def interface_versions(archive: Path) -> list[str]:
	toc = read_toc(archive)
	match = re.search(r"^##[ \t]*Interface:[ \t]*([^\r\n]+)", toc, re.MULTILINE)
	if match is None:
		raise ValueError("Release TOC is missing Interface metadata")

	values = [value.strip() for value in match[1].split(",")]
	if any(re.fullmatch(r"[0-9]+", value) is None for value in values):
		raise ValueError("Release TOC contains invalid Interface metadata")

	interfaces = [int(value) for value in values]
	if any(interface < 10000 for interface in interfaces):
		raise ValueError("Release TOC contains invalid Interface metadata")
	return list(
		dict.fromkeys(
			f"{interface // 10000}.{interface // 100 % 100}.{interface % 100}"
			for interface in interfaces
		)
	)
