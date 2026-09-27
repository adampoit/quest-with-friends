"""Local quest inventories. Source presence is discovery evidence, not equivalence."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict, cast


class SourceError(ValueError):
	pass


def mapping(value: object) -> dict[str, object]:
	if not isinstance(value, dict) or any(
		not isinstance(key, str) for key in cast(dict[object, object], value)
	):
		raise SourceError("Expected a JSON object with string keys")
	return cast(dict[str, object], value)


def array(value: object) -> list[object]:
	if not isinstance(value, list):
		raise SourceError("Expected a JSON array")
	return cast(list[object], value)


def integer(value: object) -> int:
	if type(value) is not int:
		raise SourceError("Expected an integer")
	return value


class QuestRecord(TypedDict):
	titles: list[str]
	records: list[dict[str, object]]
	fields: dict[str, object]
	repeatable: bool | None
	restrictions_inferred: bool


def digest(value: object) -> str:
	return hashlib.sha256(
		json.dumps(
			value, sort_keys=True, ensure_ascii=False, separators=(",", ":")
		).encode()
	).hexdigest()


@dataclass
class Catalog:
	source: str
	game: str
	revision: str
	files: dict[str, str]
	quests: dict[int, QuestRecord]

	@property
	def sha256(self) -> str:
		return digest(self.manifest() | {"quests": self.quests})

	def manifest(self) -> dict[str, object]:
		return {
			"source": self.source,
			"game": self.game,
			"revision": self.revision,
			"files": self.files,
		}


def validate_revision(revision: str) -> None:
	if not re.fullmatch(r"[0-9a-f]{40}", revision):
		raise SourceError("--revision must be a full, lowercase upstream commit SHA")


def file_hashes(root: Path, paths: list[Path]) -> dict[str, str]:
	return {
		path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
		for path in sorted(paths)
	}


# Mask strings/comments before recognizing constructors; never execute ATT Lua.
LEX = re.compile(
	r'--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
	re.DOTALL,
)
CALL = re.compile(
	r"\b(q|quest|qNYI|hqt|aq|hq|dailyReward|weeklyReward|hqt_bonusRep|hqt_bonusRenown|hqt_bonusRenown_weekly)\s*\(\s*(\d+)\b"
)


def mask_lua(text: str) -> str:
	return LEX.sub(lambda match: re.sub(r"[^\n]", " ", match[0]), text)


def constructor_end(code: str, start: int) -> int:
	depth = 1
	for match in re.finditer(r"[()]", code[start:]):
		depth += 1 if match[0] == "(" else -1
		if depth == 0:
			return start + match.end()
	raise SourceError("Unclosed ATT quest constructor")


def read_att(root: Path, game: str, revision: str) -> Catalog:
	validate_revision(revision)
	if game not in {"retail", "forever"}:
		raise SourceError("Unsupported ATT game")
	flavor = "standard" if game == "retail" else "forever"
	data_root = root / ".contrib/.db" / flavor
	paths = sorted(data_root.rglob("*.lua"))
	if not paths:
		raise SourceError(
			"ATT contributor source is required (.contrib/.db); release ZIPs omit it"
		)
	records: dict[int, list[dict[str, object]]] = defaultdict(list)
	for path in paths:
		text = path.read_text(encoding="utf-8-sig")
		code = mask_lua(text)
		for match in CALL.finditer(code):
			end = constructor_end(code, match.end())
			block = text[match.start() : end]
			header = block.split("\n", 1)[0]
			title = header.split("--", 1)[1].strip() if "--" in header else None
			records[int(match[2])].append(
				{
					"path": path.relative_to(root).as_posix(),
					"line": text.count("\n", 0, match.start()) + 1,
					"constructor": match[1],
					"title_comment": title,
					"block": block,
				}
			)
	# The reward catalog adds discovery IDs, not objective/endpoint validation.
	quest_db = data_root / "00 - Item DB/questDB.json"
	if quest_db.exists():
		paths.append(quest_db)
		data = mapping(cast(object, json.loads(quest_db.read_text(encoding="utf-8"))))
		for value in array(data["quests"]):
			row = mapping(value)
			id = integer(row["questID"])
			if id <= 0:
				raise SourceError("Invalid ATT reward quest ID")
			records[id].append(
				{
					"path": quest_db.relative_to(root).as_posix(),
					"reward_record": row,
				}
			)
	quests: dict[int, QuestRecord] = {
		id: {
			"fields": {},
			"restrictions_inferred": True,
			"repeatable": any(
				row.get("constructor")
				in ("dailyReward", "weeklyReward", "hqt_bonusRenown_weekly")
				or re.search(
					r'(?:\[\s*["\'](?:isDaily|isWeekly|isMonthly|isYearly|isRepeatable|repeatable)["\']\s*\]|\b(?:isDaily|isWeekly|isMonthly|isYearly|isRepeatable|repeatable))\s*=\s*true\b',
					LEX.sub(
						lambda match: (
							match[0]
							if match[0].startswith(('"', "'"))
							else " " * len(match[0])
						),
						str(row.get("block", "")),
					),
				)
				for row in rows
			)
			or None,
			"titles": sorted(
				{
					title
					for row in rows
					if isinstance(title := row.get("title_comment"), str) and title
				}
			),
			"records": rows,
		}
		for id, rows in sorted(records.items())
	}
	if not quests:
		raise SourceError("No literal ATT quests found")
	return Catalog("att", game, revision, file_hashes(root, paths), quests)


def read_questiedb(root: Path, game: str, revision: str, lua: str = "lua") -> Catalog:
	validate_revision(revision)
	if game != "forever":
		raise SourceError(
			"QuestieDB has no Retail flavor; only Forever is supported here"
		)
	paths = sorted(root.rglob("*.lua")) + [root / "QuestieDB.toc"]
	before = file_hashes(root, paths)
	exporter = Path(__file__).with_name("export_questiedb.lua").resolve()
	with tempfile.TemporaryDirectory(prefix="qwf-questiedb-") as directory:
		output = Path(directory) / "quests.json"
		result = subprocess.run(
			[lua, str(exporter), str(output)],
			cwd=root,
			capture_output=True,
			text=True,
			timeout=180,
			check=False,
		)
		if result.returncode:
			raise SourceError(
				f"QuestieDB source materialization failed: {result.stderr.strip()}"
			)
		data = mapping(cast(object, json.loads(output.read_text(encoding="utf-8"))))
	if before != file_hashes(root, paths):
		raise SourceError("QuestieDB source changed during export")
	return questiedb_catalog(data, revision, before)


def questiedb_catalog(data: object, revision: str, files: dict[str, str]) -> Catalog:
	validate_revision(revision)
	data = mapping(data)
	if data.get("flavor") != "Forever":
		raise SourceError("QuestieDB export is not Forever")
	quests: dict[int, QuestRecord] = {}
	for key, value in mapping(data["quests"]).items():
		row = mapping(value)
		id = int(key)
		if id <= 0 or id in quests:
			raise SourceError("Invalid or duplicate QuestieDB ID")
		if not isinstance(row.get("presentFields"), dict):
			raise SourceError("QuestieDB export must preserve field presence")
		flag_mask = sum(
			integer(value)
			for key, value in mapping(data.get("questFlags") or {}).items()
			if key in {"DAILY", "WEEKLY", "MONTHLY", "YEARLY"}
		)
		repeatable_mask = integer(
			mapping(data.get("specialFlags") or {}).get("REPEATABLE", 0)
		)
		quests[id] = {
			"repeatable": bool(
				integer(row.get("questFlags", 0)) & flag_mask
				or integer(row.get("specialFlags", 0)) & repeatable_mask
			)
			or None,
			"titles": [name]
			if isinstance(name := row.get("name"), str) and name
			else [],
			"records": [],
			"fields": row,
			"restrictions_inferred": True,
		}
	if not quests:
		raise SourceError("QuestieDB export contains no quests")
	return Catalog("questiedb", "forever", revision, files, quests)


def values(value: object) -> list[object]:
	if isinstance(value, dict):
		return list(mapping(cast(object, value)).values())
	return array(cast(object, value)) if isinstance(value, list) else []


def candidates(catalog: Catalog) -> list[list[int]]:
	by_title: dict[str, set[int]] = defaultdict(set)
	groups: set[tuple[int, ...]] = set()
	for id, quest in catalog.quests.items():
		for title in quest["titles"]:
			# ATT annotations can identify class/race variants, but never prove equivalence.
			title = re.sub(r"\s*\([^()]*\)\s*$", "", title)
			by_title[" ".join(title.split()).casefold()].add(id)
		for other in values(quest["fields"].get("exclusiveTo")):
			if type(other) is int and other != id and other in catalog.quests:
				groups.add(tuple(sorted((id, other))))
	groups.update(tuple(sorted(ids)) for ids in by_title.values() if len(ids) > 1)
	return [list(ids) for ids in sorted(groups)]
