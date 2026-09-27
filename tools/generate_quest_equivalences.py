#!/usr/bin/env python3
"""Discover quests from local ATT/QuestieDB source and emit explicitly reviewed previews."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from subprocess import SubprocessError
from typing import TypedDict, cast

if not __package__:
	sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.att_reviews import validate_branch_review
from tools.quest_sources import (
	Catalog,
	SourceError,
	array,
	candidates,
	digest,
	mapping,
	read_att,
	read_questiedb,
)


class ObjectiveReview(TypedDict):
	kind: str
	targets: list[list[object]]
	count: int


class QuestReview(TypedDict):
	start: list[list[object]]
	end: list[list[object]] | None
	restrictions: list[list[object]] | str
	repeatable: bool
	objectives_complete: bool
	objectives: list[ObjectiveReview]


class GroupReview(TypedDict):
	ids: list[int]
	source_sha256: str
	rationale: str
	evidence: list[str]
	progress: str
	history: bool
	quests: dict[str, QuestReview]


@dataclass
class Options(argparse.Namespace):
	game: str
	att_source: Path | None
	questiedb_source: Path | None
	revision: str
	lua: str
	reviews: Path | None
	report: Path | None
	output: Path | None
	allow_empty: bool
	category_review: Path | None
	categories_output: Path | None
	categories_manifest: Path | None


def positive_ids(value: object) -> list[int]:
	ids = array(value)
	if not ids or any(type(id) is not int or id <= 0 for id in ids):
		raise SourceError("Expected positive quest IDs")
	return cast(list[int], ids)


def atomic_write(path: Path, text: str) -> None:
	path.parent.mkdir(parents=True, exist_ok=True)
	temporary = path.with_name(path.name + ".tmp")
	try:
		_ = temporary.write_text(text, encoding="utf-8")
		_ = temporary.replace(path)
	finally:
		temporary.unlink(missing_ok=True)


def json_text(value: object) -> str:
	return json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def entities(value: object, kinds: set[str]) -> frozenset[tuple[str, int]]:
	rows = array(value)
	if not rows:
		raise SourceError("Review needs nonempty endpoint/restriction evidence")
	result: set[tuple[str, int]] = set()
	for row in rows:
		entity = array(row)
		if len(entity) != 2:
			raise SourceError("Invalid reviewed entity")
		kind, id = entity
		if (
			not isinstance(kind, str)
			or kind not in kinds
			or type(id) is not int
			or id <= 0
		):
			raise SourceError("Invalid reviewed entity")
		result.add((kind, id))
	return frozenset(result)


def validate_reviews(catalog: Catalog, reviews: object) -> list[GroupReview]:
	reviews = mapping(reviews)
	if (
		reviews.get("schema") != 1
		or reviews.get("game") != catalog.game
		or reviews.get("source") != catalog.source
	):
		raise SourceError("Review registry does not match the source/game/schema")
	groups = cast(list[GroupReview], array(reviews["groups"]))
	snapshot_sha256 = catalog.sha256
	used: set[int] = set()
	accepted: list[GroupReview] = []
	for group in groups:
		raw = mapping(group)
		ids = positive_ids(group["ids"])
		if (
			len(ids) < 2
			or ids != sorted(set(ids))
			or not set(ids) <= catalog.quests.keys()
			or used.intersection(ids)
		):
			raise SourceError(
				"Reviewed groups must have present, sorted, unique, nonoverlapping IDs"
			)
		if group.get("source_sha256") != snapshot_sha256:
			raise SourceError(f"Source changed: re-review family {ids}")
		if (
			not isinstance(raw.get("rationale"), str)
			or not group["rationale"].strip()
			or not isinstance(raw.get("evidence"), list)
			or not group["evidence"]
			or any(
				not isinstance(link, str) or not link.strip()
				for link in array(raw["evidence"])
			)
		):
			raise SourceError(
				"Every family needs an independent equivalence rationale and evidence references"
			)
		if type(group.get("history")) is not bool:
			raise SourceError(
				"Review must explicitly enable or disable completion-history inference"
			)
		if group.get("progress") not in {"objectives", "state"}:
			raise SourceError("Review must explicitly choose objectives or state")
		basis = raw.get("basis", "endpoints")
		if basis == "att-reviewed-branches":
			validate_branch_review(catalog, raw)
			used.update(ids)
			accepted.append(group)
			continue
		if basis != "endpoints":
			raise SourceError("Unknown family review basis")
		if group["history"]:
			raise SourceError(
				"Completion-history inference needs an explicit ATT branch completion review"
			)
		rows = cast(dict[str, QuestReview], mapping(group["quests"]))
		if set(rows) != {str(id) for id in ids}:
			raise SourceError("Review must supply evidence for every member")
		starts: list[frozenset[tuple[str, int]]] = []
		ends: list[frozenset[tuple[str, int]]] = []
		restrictions: list[frozenset[tuple[str, int]]] = []
		for id in ids:
			row = rows[str(id)]
			_ = mapping(row)
			# These are supplemental reviewed facts, never defaults for missing source fields.
			if catalog.quests[id].get("repeatable") is True:
				raise SourceError(
					f"Source marks quest {id} as recurring; it cannot be approved"
				)
			if row.get("repeatable") is not False:
				raise SourceError(
					"Nonrepeatability must be explicitly reviewed for every member"
				)
			starts.append(entities(row.get("start"), {"npc", "object", "item"}))
			ends.append(entities(row.get("end"), {"npc", "object"}))
			restrictions.append(
				entities(row.get("restrictions"), {"class", "race", "faction"})
			)
			if group["progress"] == "objectives":
				if row.get("objectives_complete") is not True:
					raise SourceError(
						"Complete ordered objective schemas must be explicitly reviewed"
					)
				objectives = cast(list[ObjectiveReview], array(row.get("objectives")))
				if not objectives:
					raise SourceError(
						"Objective comparison needs a nonempty ordered schema"
					)
				for objective in objectives:
					_ = mapping(objective)
					if (
						type(objective.get("count")) is not int
						or objective["count"] <= 0
					):
						raise SourceError(
							"Every objective needs an explicit positive quantity"
						)
					_ = entities(
						objective.get("targets"), {"npc", "item", "object", "spell"}
					)
					if objective.get("kind") not in {
						"monster",
						"item",
						"object",
						"event",
					}:
						raise SourceError("Invalid objective kind")
		if not starts[0].intersection(*starts[1:]) or len(set(ends)) != 1:
			raise SourceError(
				"Reviewed family needs a global common starter and identical turn-in sets"
			)
		if len(set(restrictions)) < 2:
			raise SourceError(
				"Reviewed family needs differing class/race/faction restrictions"
			)
		if group["progress"] == "objectives":
			schemas = [json_text(rows[str(id)]["objectives"]) for id in ids]
			if len(set(schemas)) != 1:
				raise SourceError("Ordered counted objective schemas differ")
		used.update(ids)
		accepted.append(group)
	return sorted(accepted, key=lambda group: group["ids"])


def render_lua(catalog: Catalog, groups: list[GroupReview]) -> str:
	lines = [
		"local QWF = QuestWithFriends or {}",
		"QuestWithFriends = QWF",
		"",
		"-- Generated from local source and explicit reviews; do not edit groups by hand.",
		f"-- Source: {catalog.source} {catalog.revision}; game: {catalog.game}",
		f"-- Snapshot SHA256: {catalog.sha256}",
		"local groups = {",
	]
	for group in groups:
		raw = mapping(group)
		if isinstance(title := raw.get("title"), str):
			lines.append("\t-- " + " ".join(title.split()))
		if raw.get("basis") == "att-reviewed-branches":
			lines.append(
				"\t-- ATT branch review; turn-ins unknown; not live-client verified."
			)
		lines.append(
			"\t{ "
			+ ", ".join(map(str, group["ids"]))
			+ f', progress = "{group["progress"]}", history = {str(group["history"]).lower()}'
			+ " },"
		)
	lines += [
		"}",
		"",
		f'QWF.QuestEquivalencesGame = "{catalog.game}"',
		"QWF.QuestEquivalences = {}",
		"for _, ids in ipairs(groups) do",
		"\tfor _, id in ipairs(ids) do",
		'\t\tassert(not QWF.QuestEquivalences[id], "Duplicate quest equivalence: " .. id)',
		"\t\tQWF.QuestEquivalences[id] = ids",
		"\tend",
		"end",
		"",
	]
	return "\n".join(lines)


def reviewed_categories(catalog: Catalog, review: object) -> list[int]:
	review = mapping(review)
	if (
		catalog.source != "questiedb"
		or catalog.game != "forever"
		or review.get("schema") != 1
		or review.get("game") != "forever"
		or review.get("source") != "questiedb"
		or review.get("category") != -666
	):
		raise SourceError("Camping requires a Forever QuestieDB category review")
	ids = positive_ids(review["ids"])
	if ids != sorted(set(ids)):
		raise SourceError("Category review needs sorted, unique IDs")
	for id in ids:
		quest = catalog.quests.get(id)
		fields = quest["fields"] if quest else {}
		if (
			not mapping(fields.get("presentFields", {})).get("zoneOrSort")
			or fields.get("zoneOrSort") != -666
		):
			raise SourceError(
				f"Reviewed Camping quest {id} is missing or has changed category"
			)
	return ids


def render_categories(catalog: Catalog, ids: list[int]) -> str:
	return "\n".join(
		[
			"local QWF = QuestWithFriends",
			"",
			f"-- Reviewed Forever QuestieDB Camping category; revision {catalog.revision}",
			f"-- Snapshot SHA256: {catalog.sha256}",
			"local campingQuestIDs = {",
			*(f"\t{id}," for id in ids),
			"}",
			"",
			"QWF.QuestCategories = { forever = {} }",
			"for _, id in ipairs(campingQuestIDs) do",
			'\tQWF.QuestCategories.forever[id] = "profession"',
			"end",
			"",
		]
	)


def category_manifest(catalog: Catalog, ids: list[int]) -> dict[str, object]:
	records: list[dict[str, object]] = []
	for id in ids:
		titles = catalog.quests[id]["titles"]
		if len(titles) != 1:
			raise SourceError(f"Camping quest {id} needs a single source title")
		record: dict[str, object] = {"id": id, "title": titles[0], "category": -666}
		records.append(record | {"sha256": digest(record)})
	return {
		"schema": 1,
		"game": catalog.game,
		"source": catalog.source,
		"source_url": f"https://github.com/Questie/QuestieDB/tree/{catalog.revision}",
		"revision": catalog.revision,
		"source_sha256": catalog.sha256,
		"category": -666,
		"quests": records,
	}


def main(argv: list[str] | None = None) -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	_ = parser.add_argument("--game", choices=("retail", "forever"), default="retail")
	source = parser.add_mutually_exclusive_group(required=True)
	_ = source.add_argument(
		"--att-source", type=Path, help="Local ATT contributor checkout"
	)
	_ = source.add_argument(
		"--questiedb-source", type=Path, help="Trusted local QuestieDB checkout"
	)
	_ = parser.add_argument(
		"--revision",
		required=True,
		help="Full upstream commit SHA; local hashes also recorded",
	)
	_ = parser.add_argument(
		"--lua", default="lua", help="Lua 5.1/LuaJIT for the QuestieDB emulator"
	)
	_ = parser.add_argument(
		"--reviews",
		type=Path,
		help="Explicit source-specific family reviews",
	)
	_ = parser.add_argument(
		"--report", type=Path, help="Default: .cache/quest-sources/<game>/report.json"
	)
	_ = parser.add_argument(
		"--output",
		type=Path,
		help="Write reviewed equivalence Lua; otherwise discovery only",
	)
	_ = parser.add_argument(
		"--allow-empty",
		action="store_true",
		help="Explicitly permit an empty equivalence preview",
	)
	_ = parser.add_argument("--category-review", type=Path)
	_ = parser.add_argument(
		"--categories-output", type=Path, help="Write reviewed Camping category preview"
	)
	_ = parser.add_argument(
		"--categories-manifest",
		type=Path,
		help="Write source-pinned Camping evidence JSON",
	)
	args = cast(Options, parser.parse_args(argv))
	if bool(args.category_review) != bool(args.categories_output):
		parser.error(
			"--category-review and --categories-output must be supplied together"
		)
	if args.categories_manifest and not args.category_review:
		parser.error("--categories-manifest requires --category-review")
	if args.allow_empty and not args.output:
		parser.error("--allow-empty requires --output")
	report_path = (
		args.report or Path(".cache/quest-sources") / args.game / "report.json"
	)
	outputs = [
		path.resolve()
		for path in [
			report_path,
			args.output,
			args.categories_output,
			args.categories_manifest,
		]
		if path
	]
	inputs = [path.resolve() for path in [args.reviews, args.category_review] if path]
	if len(set(outputs)) != len(outputs) or set(outputs).intersection(inputs):
		parser.error("Output paths must be distinct and cannot overwrite review inputs")
	source_root = args.att_source or args.questiedb_source
	assert source_root is not None
	root = source_root.resolve()
	if any(path.is_relative_to(root) for path in outputs):
		parser.error(
			"Source checkouts are read-only; outputs must be outside the source directory"
		)
	try:
		catalog = (
			read_att(root, args.game, args.revision)
			if args.att_source
			else read_questiedb(root, args.game, args.revision, args.lua)
		)
		groups = (
			validate_reviews(
				catalog, cast(object, json.loads(args.reviews.read_text()))
			)
			if args.reviews
			else []
		)
		category_ids = (
			reviewed_categories(
				catalog, cast(object, json.loads(args.category_review.read_text()))
			)
			if args.category_review
			else []
		)
		proposals = candidates(catalog)
		accepted_ids = {tuple(group["ids"]) for group in groups}
		camping = sorted(
			id
			for id, quest in catalog.quests.items()
			if quest["fields"].get("zoneOrSort") == -666
		)
		report = {
			"schema": 3,
			**catalog.manifest(),
			"source_sha256": catalog.sha256,
			"coverage": "local source inventory; not a complete playable quest database",
			"quest_count": len(catalog.quests),
			"quests": catalog.quests,
			"groups": groups,
			"candidates": [
				{
					"ids": ids,
					"status": "reviewed"
					if tuple(ids) in accepted_ids
					else "needs-review",
					"reason": "Titles/exclusions are discovery only; counts, slot order, endpoints, recurrence and equivalence need review",
				}
				for ids in proposals
			],
			"categories": {
				"reviewed": category_ids,
				"unreviewed": sorted(set(camping) - set(category_ids)),
			},
		}
		# Validate all requested artifacts before replacing any Lua output.
		lua_text = render_lua(catalog, groups) if args.output else None
		category_text = (
			render_categories(catalog, category_ids) if args.categories_output else None
		)
		manifest_text = (
			json_text(category_manifest(catalog, category_ids))
			if args.categories_manifest
			else None
		)
		atomic_write(report_path, json_text(report))
		if args.output and not groups and not args.allow_empty:
			raise SourceError(
				f"No reviewed equivalences; Lua untouched. See {report_path}"
			)
		if lua_text is not None and args.output is not None:
			atomic_write(args.output, lua_text)
		if category_text is not None and args.categories_output is not None:
			atomic_write(args.categories_output, category_text)
		if manifest_text is not None and args.categories_manifest is not None:
			atomic_write(args.categories_manifest, manifest_text)
	except (
		OSError,
		ValueError,
		KeyError,
		TypeError,
		AttributeError,
		SubprocessError,
	) as error:
		print(f"error: {error}", file=sys.stderr)
		return 1
	print(
		f"Inventoried {len(catalog.quests)} {catalog.game} quests from {catalog.source}; {len(groups)} reviewed families. See {report_path}"
	)
	return 0


if __name__ == "__main__":
	sys.exit(main())
