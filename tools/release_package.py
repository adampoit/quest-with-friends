"""Read publication metadata from the reviewed addon ZIP."""

import re
from pathlib import Path
from zipfile import ZipFile


TOC_PATH = "QuestWithFriends/QuestWithFriends.toc"


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
