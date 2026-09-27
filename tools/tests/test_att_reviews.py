"""Source-specific approval is explicit, pinned and separate from endpoint verification."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from typing import cast

from tools import att_reviews as a
from tools import generate_quest_equivalences as g
from tools import quest_sources as s

ROOT = Path(__file__).resolve().parents[2]


def catalog_fixture(predecessors: bool = False, counted: bool = True) -> s.Catalog:
	blocks: list[str] = []
	for id, class_name in [(1, "MAGE"), (2, "WARRIOR")]:
		prior = '["sourceQuest"] = 3,' if predecessors else ""
		objective = (
			"""["groups"] = { objective(1, { -- 0/6 Target slain
    ["provider"] = {"n", 30},
  }) },"""
			if counted
			else ""
		)
		blocks.append(f"""q({id}, {{ -- Branch quest
  ["qg"] = 10,
  ["races"] = {{ HUMAN }},
  ["classes"] = {{ {class_name} }},
  ["timeline"] = {{ ADDED_4_0_3 }},
  ["qi"] = 99,
  {prior}
  {objective}
}})
""")
	prior = "" if predecessors else '["sourceQuests"] = { 1, 2 },'
	blocks.append(f"""q(3, {{ -- Adjacent step
  ["qg"] = 10,
  ["races"] = {{ HUMAN }},
  ["timeline"] = {{ ADDED_4_0_3 }},
  {prior}
}})
""")
	with tempfile.TemporaryDirectory() as directory:
		root = Path(directory)
		path = root / ".contrib/.db/standard/zone.lua"
		path.parent.mkdir(parents=True)
		_ = path.write_text("\n".join(blocks))
		return s.read_att(root, "retail", "a" * 40)


def registry_fixture(
	catalog: s.Catalog, progress: str = "objectives", direction: str = "successors"
) -> dict[str, object]:
	rows: dict[str, object] = {}
	for id in [1, 2]:
		ref = a.record_ref(catalog.quests[id]["records"][0])
		facts = a.facts(catalog, id, ref)
		rows[str(id)] = {
			"record": ref,
			"start": [["npc", facts.starter]],
			"end": None,
			"restrictions": facts.restrictions,
			"repeatable": False,
			"objectives_complete": progress == "objectives",
			"objectives": [{"kind": "monster", "targets": [["npc", 30]], "count": 6}]
			if progress == "objectives"
			else [],
		}
	return {
		"schema": 1,
		"source": "att",
		"game": "retail",
		"groups": [
			{
				"ids": [1, 2],
				"title": "Branch quest",
				"source_sha256": catalog.sha256,
				"basis": "att-reviewed-branches",
				"rationale": "Reviewed class branches of a finite storyline",
				"evidence": ["synthetic contributor source"],
				"history": False,
				"progress": progress,
				"quests": rows,
				"att_review": {
					"turn_in": "unknown",
					"live_client": False,
					"applicability": "Reviewed standard quest context",
					"recurrence": "Reviewed one-time story progression, not an explicit flag",
					"relationship": "Same task and adjacent step",
					"state_only_reason": "Same transition step; no objective schema is asserted",
					"direction": direction,
					"witnesses": [
						{
							"id": 3,
							"record": a.record_ref(catalog.quests[3]["records"][0]),
						}
					],
				},
			}
		],
	}


def group(registry: dict[str, object]) -> dict[str, object]:
	return s.mapping(s.array(registry["groups"])[0])


def row(registry: dict[str, object], id: int) -> dict[str, object]:
	return s.mapping(s.mapping(group(registry)["quests"])[str(id)])


class AttReviewTests(unittest.TestCase):
	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.catalog: s.Catalog = catalog_fixture()
		self.registry: dict[str, object] = registry_fixture(self.catalog)

	def repin(self, id: int, old: str, new: str) -> None:
		record = self.catalog.quests[id]["records"][0]
		block = str(record["block"])
		assert old in block
		record["block"] = block.replace(old, new)
		group(self.registry)["source_sha256"] = self.catalog.sha256
		if id in {1, 2}:
			row(self.registry, id)["record"] = a.record_ref(record)
		else:
			policy = s.mapping(group(self.registry)["att_review"])
			s.mapping(s.array(policy["witnesses"])[0])["record"] = a.record_ref(record)

	def test_counted_source_branch_approval_does_not_invent_turn_ins(self):
		accepted = g.validate_reviews(self.catalog, self.registry)
		self.assertEqual(1, len(accepted))
		self.assertIsNone(accepted[0]["quests"]["1"]["end"])
		self.assertEqual("objectives", accepted[0]["progress"])
		self.assertFalse(accepted[0]["history"])
		self.assertIn(
			"turn-ins unknown; not live-client verified",
			g.render_lua(self.catalog, accepted),
		)

	def test_explicit_completion_review_shares_history_without_turn_in_evidence(self):
		group(self.registry)["history"] = True
		s.mapping(group(self.registry)["att_review"])["completion"] = {
			"scope": "party-comparison",
			"rationale": "The counted task and sibling progression identify the same completed step",
		}
		accepted = g.validate_reviews(self.catalog, self.registry)
		self.assertTrue(accepted[0]["history"])
		self.assertIsNone(accepted[0]["quests"]["1"]["end"])
		self.assertIn(
			'progress = "objectives", history = true',
			g.render_lua(self.catalog, accepted),
		)
		self.catalog.quests[1]["repeatable"] = True
		group(self.registry)["source_sha256"] = self.catalog.sha256
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)

	def test_transition_completion_review_does_not_require_a_counted_schema(self):
		catalog = catalog_fixture(counted=False)
		registry = registry_fixture(catalog, progress="state")
		group(registry)["history"] = True
		s.mapping(group(registry)["att_review"])["completion"] = {
			"scope": "party-comparison",
			"rationale": "All one-time transitions converge at the same next step",
		}
		accepted = g.validate_reviews(catalog, registry)
		self.assertIn(
			'progress = "state", history = true', g.render_lua(catalog, accepted)
		)
		s.mapping(group(registry)["att_review"])["witnesses"] = []
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(catalog, registry)

	def test_completion_sharing_requires_its_own_scoped_rationale(self):
		for completion in [
			None,
			{},
			{"scope": "party-comparison"},
			{"scope": "game-credit", "rationale": "Same task"},
			{"scope": "party-comparison", "rationale": " "},
		]:
			with self.subTest(completion=completion):
				registry = copy.deepcopy(self.registry)
				group(registry)["history"] = True
				if completion is not None:
					s.mapping(group(registry)["att_review"])["completion"] = completion
				with self.assertRaises(s.SourceError):
					_ = g.validate_reviews(self.catalog, registry)

	def test_history_policy_must_be_an_explicit_boolean(self):
		for history in [None, 0, 1, "false", "true"]:
			with self.subTest(history=history):
				registry = copy.deepcopy(self.registry)
				group(registry)["history"] = history
				with self.assertRaises(s.SourceError):
					_ = g.validate_reviews(self.catalog, registry)
		_ = group(self.registry).pop("history")
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)

	def test_state_transition_uses_positive_branch_evidence_not_empty_objectives(self):
		catalog = catalog_fixture(counted=False)
		registry = registry_fixture(catalog, progress="state")
		self.assertEqual("state", g.validate_reviews(catalog, registry)[0]["progress"])
		s.mapping(group(registry)["att_review"])["witnesses"] = []
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(catalog, registry)

	def test_predecessor_branch_review_is_explicit(self):
		catalog = catalog_fixture(predecessors=True)
		registry = registry_fixture(catalog, direction="predecessors")
		self.assertEqual(1, len(g.validate_reviews(catalog, registry)))

	def test_quantity_target_slot_or_provider_ambiguity_cannot_be_reapproved(self):
		for old, new in [
			("0/6", "0/7"),
			('"n", 30', '"n", 31'),
			("objective(1,", "objective(2,"),
			("objective(1,", "objective(SLOT,"),
			("objective(1,", "qo(1,"),
			("objective(1,", "objective(SLOT, {}), objective(1,"),
			("0/6 Target slain", "Target slain"),
			('["provider"] = {"n", 30}', '["providers"] = {{"n", 30}, {"i", 99}}'),
			('["provider"] = {"n", 30}', '["provider"] = unknown({"n", 30})'),
			(
				'["provider"] = {"n", 30}',
				'["provider"] = {"n", 30}, ["providers"] = {{"n", 31}}',
			),
		]:
			with self.subTest(new=new):
				catalog = copy.deepcopy(self.catalog)
				registry = copy.deepcopy(self.registry)
				record = catalog.quests[2]["records"][0]
				record["block"] = str(record["block"]).replace(old, new)
				row(registry, 2)["record"] = a.record_ref(record)
				group(registry)["source_sha256"] = catalog.sha256
				with self.assertRaises(s.SourceError):
					_ = g.validate_reviews(catalog, registry)

	def test_unchanged_pins_cannot_hide_changed_member_evidence(self):
		record = self.catalog.quests[2]["records"][0]
		record["block"] = str(record["block"]).replace("0/6", "0/7")
		group(self.registry)["source_sha256"] = self.catalog.sha256
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)

	def test_missing_branch_member_and_cycles_are_rejected(self):
		self.repin(3, "{ 1, 2 }", "{ 1 }")
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)
		self.repin(3, "{ 1 }", "{ 1, 2 }")
		self.repin(1, '["qi"] = 99,', '["sourceQuest"] = 3,')
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)

	def test_recurring_removed_and_conditional_starters_are_rejected(self):
		for old, new in [
			('["qi"] = 99,', '["repeatable"] = true,'),
			('["qi"] = 99,', '["isDaily"] = true,'),
			("ADDED_4_0_3", "REMOVED_4_0_3"),
			('["qg"] = 10,', '["qg"] = 10, ["qg"] = 11,'),
		]:
			with self.subTest(new=new):
				catalog = copy.deepcopy(self.catalog)
				registry = copy.deepcopy(self.registry)
				record = catalog.quests[1]["records"][0]
				record["block"] = str(record["block"]).replace(old, new)
				row(registry, 1)["record"] = a.record_ref(record)
				group(registry)["source_sha256"] = catalog.sha256
				with self.assertRaises(s.SourceError):
					_ = g.validate_reviews(catalog, registry)

	def test_review_cannot_claim_live_verification_or_turn_in_knowledge(self):
		for key, value in [
			("live_client", True),
			("turn_in", "verified"),
			("recurrence", ""),
		]:
			registry = copy.deepcopy(self.registry)
			s.mapping(group(registry)["att_review"])[key] = value
			with self.subTest(key=key), self.assertRaises(s.SourceError):
				_ = g.validate_reviews(self.catalog, registry)
		row(self.registry, 1)["end"] = [["npc", 10]]
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)

	def test_branch_mode_is_not_an_implicit_endpoint_waiver(self):
		_ = group(self.registry).pop("basis")
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)
		group(self.registry)["basis"] = "att-reviewed-branches"
		self.catalog.game = "forever"
		self.registry["game"] = "forever"
		group(self.registry)["source_sha256"] = self.catalog.sha256
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.registry)

	def test_literal_field_reader_ignores_nested_keys_comments_and_strings(self):
		block = """q(1, {
  -- ["qg"] = 999,
  ["description"] = "['qg'] = 998,",
  ["qg"] = 10,
  ["groups"] = { i(99, { ["qg"] = 997, }) },
})"""
		self.assertEqual("10", a.field(block, "qg"))
		self.assertEqual([], list(a.objectives(block) or []))


class ShippedReviewTests(unittest.TestCase):
	def test_six_retail_families_have_replayable_source_pins_and_explicit_policies(
		self,
	):
		registry = s.mapping(
			cast(
				object,
				json.loads((ROOT / "tools/reviewed_quest_groups.json").read_text()),
			)
		)
		groups = [s.mapping(value) for value in s.array(registry["groups"])]
		self.assertEqual("retail", registry["game"])
		self.assertEqual("att", registry["source"])
		self.assertEqual(6, len(groups))
		self.assertEqual(54, sum(len(s.array(value["ids"])) for value in groups))
		self.assertEqual(4, sum(value["progress"] == "objectives" for value in groups))
		self.assertEqual(2, sum(value["progress"] == "state" for value in groups))
		lua = (ROOT / "QuestEquivalences.lua").read_text()
		for value in groups:
			self.assertEqual("att-reviewed-branches", value["basis"])
			self.assertTrue(value["history"])
			self.assertIn(str(value["title"]), lua)
			self.assertIn(str(value["source_sha256"]), lua)
			policy = s.mapping(value["att_review"])
			self.assertEqual("unknown", policy["turn_in"])
			self.assertFalse(policy["live_client"])
			completion = s.mapping(policy["completion"])
			self.assertEqual("party-comparison", completion["scope"])
			self.assertTrue(str(completion["rationale"]).strip())
			self.assertEqual(6, lua.count("history = true"))
			for source in s.mapping(value["quests"]).values():
				self.assertIsNone(s.mapping(source)["end"])
				self.assertRegex(
					str(s.mapping(s.mapping(source)["record"])["sha256"]),
					r"^[0-9a-f]{64}$",
				)


if __name__ == "__main__":
	_ = unittest.main()
