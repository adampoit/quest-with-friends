"""Replay explicit ATT branch reviews without inventing turn-in or live-client facts."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

from tools.quest_sources import (
	LEX,
	Catalog,
	SourceError,
	array,
	constructor_end,
	integer,
	mapping,
	mask_lua,
)


@dataclass(frozen=True)
class Facts:
	title: str
	starter: int
	restrictions: str
	prerequisites: frozenset[int]
	objectives: tuple[dict[str, object], ...] | None
	path: str


def field(block: str, name: str) -> str | None:
	code = mask_lua(block)
	root = code.find("{")
	if root < 0:
		raise SourceError("ATT review requires a literal quest table")
	pattern = re.compile(r'\[\s*["\']' + re.escape(name) + r'["\']\s*\]\s*=')
	found: list[str] = []
	for match in pattern.finditer(block):
		prefix = code[root : match.start()]
		if code[match.end() - 1] != "=" or prefix.count("{") - prefix.count("}") != 1:
			continue
		depth = 0
		for end in range(match.end(), len(code)):
			char = code[end]
			if char == "," and depth == 0:
				value = LEX.sub(
					lambda token: " " if token[0].startswith("--") else token[0],
					block[match.end() : end],
				)
				found.append(" ".join(value.split()))
				break
			if char in "{([":
				depth += 1
			elif char in "})]":
				depth -= 1
				if depth < 0:
					raise SourceError(f"Unterminated ATT field {name}")
	if len(found) > 1:
		raise SourceError(
			f"Conditional/duplicate ATT field {name} needs a different review"
		)
	return found[0] if found else None


def prerequisites(block: str) -> frozenset[int]:
	single, multiple = field(block, "sourceQuest"), field(block, "sourceQuests")
	if single and multiple:
		raise SourceError("Ambiguous ATT prerequisite encoding")
	if single:
		if not single.isdigit():
			raise SourceError("ATT branch review requires literal prerequisite IDs")
		return frozenset({int(single)})
	if multiple:
		if not re.fullmatch(r"\{\s*(?:\d+\s*(?:,\s*\d+\s*)*,?\s*)?\}", multiple):
			raise SourceError("ATT branch review requires a literal prerequisite list")
		return frozenset(int(match[0]) for match in re.finditer(r"\d+", multiple))
	return frozenset()


def objectives(block: str) -> tuple[dict[str, object], ...] | None:
	code = mask_lua(block)
	result: list[dict[str, object]] = []
	indices: list[int] = []
	calls = list(re.finditer(r"\b(?:objective|questobjective|qo)\s*\(", code))
	literal_calls = list(re.finditer(r"\bobjective\s*\(\s*(\d+)\s*,", code))
	if len(calls) != len(literal_calls):
		return None
	for match in literal_calls:
		end = constructor_end(code, match.end())
		row = block[match.start() : end]
		# Conditional targets or helper providers cannot establish a counted client slot.
		if re.search(r"--\s*#", row):
			return None
		header = row.split("\n", 1)[0]
		count = re.search(r"--\s*0/(\d+)\s+(.+)", header)
		provider, providers = field(row, "provider"), field(row, "providers")
		if not count or int(count[1]) <= 0 or (provider and providers):
			return None
		literal = r'\{\s*(["\'])([nio])\1\s*,\s*(\d+)\s*,?\s*\}'
		target = (
			re.fullmatch(literal, provider)
			if provider
			else re.fullmatch(r"\{\s*" + literal + r"\s*,?\s*\}", providers or "")
		)
		if not target:
			return None
		kind, id = target[2], target[3]
		indices.append(int(match[1]))
		result.append(
			{
				"index": int(match[1]),
				"count": int(count[1]),
				"target": [{"n": "npc", "i": "item", "o": "object"}[kind], int(id)],
				"text": count[2].strip(),
			}
		)
	if indices != list(range(1, len(indices) + 1)):
		return None
	return tuple(result)


def record_ref(record: dict[str, object]) -> dict[str, object]:
	block = record.get("block")
	if not isinstance(block, str):
		raise SourceError(
			"ATT review requires a contributor record, not a reward catalog ID"
		)
	return {
		"path": record["path"],
		"line": record["line"],
		"sha256": hashlib.sha256(block.encode("utf-8")).hexdigest(),
	}


def facts(catalog: Catalog, id: int, reference: object) -> Facts:
	ref = mapping(reference)
	quest = catalog.quests.get(id)
	if not quest:
		raise SourceError(f"ATT review quest {id} is absent")
	matches = [
		row for row in quest["records"] if row.get("block") and record_ref(row) == ref
	]
	if len(matches) != 1:
		raise SourceError(f"ATT record pin changed or is ambiguous for quest {id}")
	record = matches[0]
	block, title, path = record["block"], record.get("title_comment"), record["path"]
	if (
		not isinstance(block, str)
		or not isinstance(title, str)
		or not isinstance(path, str)
	):
		raise SourceError("ATT review needs a named contributor quest")
	if record.get("constructor") not in {"q", "quest"} or quest["repeatable"] is True:
		raise SourceError(
			"Hidden, unavailable or recurring ATT constructors cannot be approved"
		)
	timeline = field(block, "timeline")
	if (
		not timeline
		or "ADDED_" not in timeline
		or re.search(r"\b(?:REMOVED|CREATED)_", timeline)
	):
		raise SourceError(
			"ATT branch review needs an added, not removed/creation-only quest"
		)
	for key in (
		"u",
		"isHidden",
		"isBreadcrumb",
		"repeatable",
		"isRepeatable",
		"isDaily",
		"isWeekly",
		"isMonthly",
		"isYearly",
	):
		if (value := field(block, key)) and value not in {"false", "0"}:
			raise SourceError(
				f"ATT quest {id} has unsupported applicability field {key}"
			)
	starter = field(block, "qg")
	races, classes = field(block, "races"), field(block, "classes")
	if not starter or not starter.isdigit() or not races:
		raise SourceError(
			"ATT branch review needs an explicit starter and race restriction"
		)
	return Facts(
		title,
		int(starter),
		f"classes={classes or 'unspecified'};races={races}",
		prerequisites(block),
		objectives(block),
		path,
	)


def validate_branch_review(catalog: Catalog, group: object) -> None:
	group = mapping(group)
	if catalog.source != "att" or catalog.game != "retail":
		raise SourceError("ATT branch reviews apply only to Retail ATT source")
	policy = mapping(group.get("att_review"))
	if policy.get("turn_in") != "unknown" or policy.get("live_client") is not False:
		raise SourceError(
			"ATT reviews must disclose unknown turn-ins and no live-client verification"
		)
	for key in ("applicability", "recurrence", "relationship"):
		if not isinstance(value := policy.get(key), str) or not value.strip():
			raise SourceError(f"ATT branch review needs an explicit {key} rationale")
	if group.get("history") is True:
		completion = mapping(policy.get("completion"))
		if completion.get("scope") != "party-comparison" or (
			not isinstance(reason := completion.get("rationale"), str)
			or not reason.strip()
		):
			raise SourceError(
				"Completion sharing needs an explicit party-comparison story-step rationale"
			)
	if group.get("progress") == "state" and (
		not isinstance(reason := policy.get("state_only_reason"), str)
		or not reason.strip()
	):
		raise SourceError(
			"State-only ATT families need a positive branch-equivalence rationale"
		)
	ids = [integer(id) for id in array(group["ids"])]
	rows = mapping(group["quests"])
	if set(rows) != {str(id) for id in ids}:
		raise SourceError("ATT review must cover every member")
	members: list[Facts] = []
	for id in ids:
		row = mapping(rows[str(id)])
		member = facts(catalog, id, row.get("record"))
		if (
			row.get("start") != [["npc", member.starter]]
			or row.get("restrictions") != member.restrictions
		):
			raise SourceError(
				"ATT reviewed starter/restrictions do not match the pinned record"
			)
		if row.get("end") is not None or row.get("repeatable") is not False:
			raise SourceError(
				"ATT review cannot invent a turn-in or waive recurrence review"
			)
		if group["progress"] == "objectives":
			if row.get("objectives_complete") is not True or not member.objectives:
				raise SourceError(
					"ATT progress review needs all contiguous, explicitly counted source slots"
				)
			parsed = member.objectives
			reviewed = [mapping(value) for value in array(row.get("objectives"))]
			if len(parsed) != len(reviewed):
				raise SourceError("ATT reviewed objective count differs from source")
			for source, objective in zip(parsed, reviewed):
				if (
					objective.get("targets") != [source["target"]]
					or objective.get("count") != source["count"]
				):
					raise SourceError(
						"ATT reviewed targets/quantities do not match source"
					)
				if objective.get("kind") not in {"monster", "item", "object", "event"}:
					raise SourceError("Invalid ATT reviewed objective kind")
		members.append(member)
	if (
		len({member.title for member in members}) != 1
		or group.get("title") != members[0].title
	):
		raise SourceError("ATT branch review needs an identical source title")
	if (
		len({member.starter for member in members}) != 1
		or len({member.restrictions for member in members}) < 2
	):
		raise SourceError(
			"ATT branch family needs a shared starter and differing restrictions"
		)
	if group["progress"] == "objectives":
		if any(member.objectives != members[0].objectives for member in members[1:]):
			raise SourceError("ATT ordered objective evidence differs across members")
		if any(
			mapping(rows[str(id)])["objectives"]
			!= mapping(rows[str(ids[0])])["objectives"]
			for id in ids
		):
			raise SourceError("ATT reviewed objective policies differ across members")
	witnesses: dict[int, Facts] = {}
	for value in array(policy.get("witnesses")):
		witness = mapping(value)
		id = integer(witness["id"])
		if id in ids or id in witnesses:
			raise SourceError(
				"ATT branch witnesses must be distinct and outside the family"
			)
		witnesses[id] = facts(catalog, id, witness.get("record"))
	if not witnesses or len({w.title for w in witnesses.values()}) != 1:
		raise SourceError(
			"ATT review needs named witnesses from one adjacent quest step"
		)
	if len({m.path for m in [*members, *witnesses.values()]}) != 1:
		raise SourceError(
			"ATT branch review must stay within one reviewed contributor context"
		)
	if policy.get("direction") == "successors":
		links = [w.prerequisites.intersection(ids) for w in witnesses.values()]
		if any(m.prerequisites.intersection(witnesses) for m in members):
			raise SourceError("ATT successor witnesses form a prerequisite cycle")
		if any(
			not link or (len(link) != 1 and link != frozenset(ids)) for link in links
		) or {id for link in links for id in link} != set(ids):
			raise SourceError(
				"ATT successors do not positively witness every family member"
			)
	elif policy.get("direction") == "predecessors":
		if any(
			not m.prerequisites or not m.prerequisites <= witnesses.keys()
			for m in members
		):
			raise SourceError(
				"ATT members do not reference the reviewed predecessor step"
			)
		if any(w.prerequisites.intersection(ids) for w in witnesses.values()):
			raise SourceError("ATT predecessor witnesses form a prerequisite cycle")
		if {id for m in members for id in m.prerequisites} != witnesses.keys():
			raise SourceError("ATT predecessor witnesses contain unrelated records")
	else:
		raise SourceError(
			"ATT review needs an explicit predecessor/successor direction"
		)
