"""Synthetic, network-free coverage for the local-source generation pipeline."""

from __future__ import annotations

import contextlib
import copy
import io
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import TypedDict, cast
from unittest.mock import patch

from tools import generate_quest_equivalences as g
from tools import quest_sources as s

REVISION = "a" * 40


def forever_catalog() -> s.Catalog:
	return s.questiedb_catalog(
		{
			"flavor": "Forever",
			"quests": {
				"1": {
					"name": "Delivery",
					"zoneOrSort": -666,
					"presentFields": {"zoneOrSort": True},
					"requiredRaces": 1 << 33,
					"exclusiveTo": {"1": 2},
				},
				"2": {
					"name": "Delivery",
					"zoneOrSort": -666,
					"presentFields": {"zoneOrSort": True},
				},
				"3": {
					"name": "Unreviewed Camping",
					"zoneOrSort": -666,
					"presentFields": {"zoneOrSort": True},
				},
			},
		},
		REVISION,
		{"data.lua": "b" * 64},
	)


class GroupFixture(TypedDict):
	ids: list[int]
	source_sha256: str
	rationale: str
	evidence: list[str]
	progress: str
	history: bool
	quests: dict[str, dict[str, object]]


class ReviewFixture(TypedDict):
	schema: int
	game: str
	source: str
	groups: list[GroupFixture]


def review(catalog: s.Catalog) -> ReviewFixture:
	return {
		"schema": 1,
		"game": catalog.game,
		"source": catalog.source,
		"groups": [
			{
				"ids": [1, 2],
				"source_sha256": catalog.sha256,
				"rationale": "Synthetic mutually exclusive class branches, independently reviewed",
				"evidence": ["synthetic client capture"],
				"progress": "objectives",
				"history": False,
				"quests": {
					str(id): {
						"start": [["npc", 10]],
						"end": [["npc", 20]],
						"restrictions": [["class", id]],
						"repeatable": False,
						"objectives_complete": True,
						"objectives": [
							{"kind": "monster", "targets": [["npc", 30]], "count": 6}
						],
					}
					for id in [1, 2]
				},
			}
		],
	}


class SourceTests(unittest.TestCase):
	def test_att_static_inventory_masks_comments_and_strings_and_keeps_duplicates(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			path = root / ".contrib/.db/standard/zone.lua"
			path.parent.mkdir(parents=True)
			_ = path.write_text("""
-- q(999, {})
--[=[ q(998, {}) ]=]
local ignored = "q(997, {})"
local ignoredLong = [[ q(996, {}) ]]
q(1, { -- Quest (Mage)
    ["g"] = { objective(1, { -- 0/6 Target
        ["provider"] = {"n", 30},
    }) },
})
q(2, { -- Quest (Warrior)
})
q(1, { -- Quest (Mage)
    ["timeline"] = { ADDED_OLD },
})
""")
			catalog = s.read_att(root, "retail", REVISION)
			self.assertEqual({1, 2}, set(catalog.quests))
			self.assertEqual(2, len(catalog.quests[1]["records"]))
			self.assertIn(
				"objective(1, { -- 0/6 Target",
				str(catalog.quests[1]["records"][0]["block"]),
			)
			self.assertEqual([[1, 2]], s.candidates(catalog))
			self.assertEqual(
				catalog.sha256, s.read_att(root, "retail", REVISION).sha256
			)
			_ = path.write_text(path.read_text() + "\n-- changed source\n")
			self.assertNotEqual(
				catalog.sha256, s.read_att(root, "retail", REVISION).sha256
			)

	def test_att_reward_only_ids_do_not_become_validated_quests(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			data = root / ".contrib/.db/standard"
			data.mkdir(parents=True)
			_ = (data / "zone.lua").write_text("q(1, {})")
			(data / "00 - Item DB").mkdir()
			_ = (data / "00 - Item DB/questDB.json").write_text(
				json.dumps({"quests": [{"questID": 2}]})
			)
			catalog = s.read_att(root, "retail", REVISION)
			self.assertEqual({1, 2}, set(catalog.quests))
			self.assertEqual([], s.candidates(catalog))

	def test_missing_contributor_source_and_malformed_lua_fail(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			with self.assertRaises(s.SourceError):
				_ = s.read_att(root, "retail", REVISION)
			data = root / ".contrib/.db/standard"
			data.mkdir(parents=True)
			_ = (data / "broken.lua").write_text("q(1, {")
			with self.assertRaises(s.SourceError):
				_ = s.read_att(root, "retail", REVISION)

	def test_questiedb_presence_holes_and_large_masks_are_preserved(self):
		catalog = forever_catalog()
		self.assertEqual(1 << 33, catalog.quests[1]["fields"]["requiredRaces"])
		self.assertNotIn("questFlags", catalog.quests[1]["fields"])
		self.assertTrue(catalog.quests[1]["restrictions_inferred"])
		self.assertEqual([[1, 2]], s.candidates(catalog))
		with self.assertRaises(s.SourceError):
			_ = s.questiedb_catalog({"flavor": "Retail", "quests": {}}, REVISION, {})
		with self.assertRaises(s.SourceError):
			_ = s.read_questiedb(Path("does-not-exist"), "retail", REVISION)

	def test_revision_format_is_required(self):
		for revision in ["HEAD", "abc", "A" * 40, "a" * 39]:
			with self.subTest(revision=revision), self.assertRaises(s.SourceError):
				s.validate_revision(revision)

	@unittest.skipUnless(shutil.which("lua"), "Lua required")
	def test_exporter_uses_materialization_not_normalized_getters(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			(root / "emulator").mkdir()
			_ = (root / "QuestieDB.toc").write_text("synthetic")
			_ = (root / "emulator/client.lua").write_text(
				"return { install = function() end, reset = function() end }"
			)
			_ = (root / "emulator/metadata.lua").write_text("""
return {
  install = function() end, parse = function() end,
  loadAddon = function()
    return {
      flavor = {name = "Forever"},
      Enum = {questKeys = {name = 1, objectives = 2, questFlags = 3, zoneOrSort = 4}},
      Quest = {GetAllIds = function() return {1} end},
      read = {source = {Materialize = function()
        return {[1] = {[1] = 'Name "quoted"', [2] = {[3] = {[1] = {30, "Target", 999}}}, [4] = -666}}
      end}},
    }
  end,
}
""")
			catalog = s.read_questiedb(root, "forever", REVISION)
			fields = catalog.quests[1]["fields"]
			self.assertEqual('Name "quoted"', fields["name"])
			self.assertEqual(
				999,
				s.mapping(s.mapping(s.mapping(fields["objectives"])["3"])["1"])["3"],
			)
			self.assertNotIn("questFlags", s.mapping(fields["presentFields"]))
			self.assertNotIn("questFlags", fields)
			self.assertEqual(-666, fields["zoneOrSort"])


class ReviewTests(unittest.TestCase):
	def __init__(self, methodName: str = "runTest"):
		super().__init__(methodName)
		self.catalog: s.Catalog = forever_catalog()
		self.review: ReviewFixture = review(self.catalog)

	def test_explicit_review_passes_and_lua_retains_policy(self):
		groups = g.validate_reviews(self.catalog, self.review)
		lua = g.render_lua(self.catalog, groups)
		self.assertIn('QuestEquivalencesGame = "forever"', lua)
		self.assertIn('progress = "objectives", history = false', lua)
		if shutil.which("lua"):
			with tempfile.TemporaryDirectory() as directory:
				path = Path(directory) / "table.lua"
				_ = path.write_text(
					lua
					+ "\nassert(QuestWithFriends.QuestEquivalences[1] == QuestWithFriends.QuestEquivalences[2])"
				)
				_ = subprocess.run(["lua", str(path)], check=True)

	def test_missing_or_conflicting_evidence_never_falls_back_to_state(self):
		for field, value in [
			("repeatable", None),
			("repeatable", True),
			("objectives_complete", False),
			("objectives", []),
			("end", [["npc", 99]]),
			("start", [["npc", 99]]),
			("restrictions", [["class", 1]]),
		]:
			with self.subTest(field=field, value=value):
				registry = copy.deepcopy(self.review)
				registry["groups"][0]["quests"]["2"][field] = value
				with self.assertRaises(s.SourceError):
					_ = g.validate_reviews(self.catalog, registry)

	def test_source_recurring_flags_cannot_be_overridden_by_a_review(self):
		self.catalog.quests[1]["repeatable"] = True
		self.review["groups"][0]["source_sha256"] = self.catalog.sha256
		with self.assertRaises(s.SourceError):
			_ = g.validate_reviews(self.catalog, self.review)

	def test_quantity_order_and_target_mismatches_fail(self):
		for change in ["count", "targets", "order"]:
			with self.subTest(change=change):
				registry = copy.deepcopy(self.review)
				rows = registry["groups"][0]["quests"]
				if change == "count":
					s.mapping(s.array(rows["2"]["objectives"])[0])["count"] = None
				elif change == "targets":
					s.mapping(s.array(rows["2"]["objectives"])[0])["targets"] = [
						["npc", 99]
					]
				else:
					second = {"kind": "item", "count": 2, "targets": [["item", 40]]}
					s.array(rows["1"]["objectives"]).append(second)
					s.array(rows["2"]["objectives"]).insert(0, second)
				with self.assertRaises(s.SourceError):
					_ = g.validate_reviews(self.catalog, registry)

	def test_changed_pin_cross_game_history_and_overlap_fail(self):
		for change in ["pin", "game", "source", "history", "overlap", "rationale"]:
			with self.subTest(change=change):
				registry = copy.deepcopy(self.review)
				group = registry["groups"][0]
				if change == "pin":
					group["source_sha256"] = "0" * 64
				elif change == "game":
					registry["game"] = "other"
				elif change == "source":
					registry["source"] = "other"
				elif change == "history":
					group["history"] = True
				elif change == "rationale":
					group["rationale"] = ""
				else:
					registry["groups"].append(copy.deepcopy(group))
				with self.assertRaises(s.SourceError):
					_ = g.validate_reviews(self.catalog, registry)

	def test_state_policy_must_be_explicit_and_still_requires_equivalence_review(self):
		self.review["groups"][0]["progress"] = "state"
		for row in self.review["groups"][0]["quests"].values():
			del row["objectives"]
			del row["objectives_complete"]
		self.assertEqual(
			"state", g.validate_reviews(self.catalog, self.review)[0]["progress"]
		)

	def test_category_review_never_adds_unreviewed_camping(self):
		registry = {
			"schema": 1,
			"game": "forever",
			"source": "questiedb",
			"category": -666,
			"ids": [1, 2],
		}
		self.assertEqual([1, 2], g.reviewed_categories(self.catalog, registry))
		_ = s.mapping(self.catalog.quests[2]["fields"]["presentFields"]).pop(
			"zoneOrSort"
		)
		with self.assertRaises(s.SourceError):
			_ = g.reviewed_categories(self.catalog, registry)


class CommandTests(unittest.TestCase):
	def test_reviewed_outputs_are_deterministic_and_bad_pins_preserve_them(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			catalog = forever_catalog()
			registry = review(catalog)
			reviews_path = root / "reviews.json"
			category_path = root / "categories.json"
			_ = reviews_path.write_text(json.dumps(registry))
			_ = category_path.write_text(
				json.dumps(
					{
						"schema": 1,
						"game": "forever",
						"source": "questiedb",
						"category": -666,
						"ids": [1, 2],
					}
				)
			)
			artifacts = [
				root / "report.json",
				root / "equivalences.lua",
				root / "categories.lua",
				root / "categories-evidence.json",
			]
			args = [
				"--game",
				"forever",
				"--questiedb-source",
				str(root / "source"),
				"--revision",
				REVISION,
				"--reviews",
				str(reviews_path),
				"--category-review",
				str(category_path),
				"--report",
				str(artifacts[0]),
				"--output",
				str(artifacts[1]),
				"--categories-output",
				str(artifacts[2]),
				"--categories-manifest",
				str(artifacts[3]),
			]
			with (
				patch.object(g, "read_questiedb", return_value=catalog),
				contextlib.redirect_stdout(io.StringIO()),
				contextlib.redirect_stderr(io.StringIO()),
			):
				self.assertEqual(0, g.main(args))
				first = [path.read_text() for path in artifacts]
				self.assertEqual(
					{"reviewed": [1, 2], "unreviewed": [3]},
					s.mapping(cast(object, json.loads(first[0])))["categories"],
				)
				self.assertIn('progress = "objectives", history = false', first[1])
				self.assertIn(
					'QWF.QuestCategories.forever[id] = "profession"', first[2]
				)
				manifest = s.mapping(cast(object, json.loads(first[3])))
				self.assertEqual(catalog.sha256, manifest["source_sha256"])
				self.assertEqual("questiedb", manifest["source"])
				self.assertEqual(
					[1, 2],
					[s.mapping(row)["id"] for row in s.array(manifest["quests"])],
				)
				self.assertEqual(0, g.main(args))
				self.assertEqual(first, [path.read_text() for path in artifacts])
				registry["groups"][0]["source_sha256"] = "0" * 64
				_ = reviews_path.write_text(json.dumps(registry))
				self.assertEqual(1, g.main(args))
				self.assertEqual(first, [path.read_text() for path in artifacts])

	def test_discovery_only_does_not_promote_and_empty_output_is_explicit(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			report = root / "report.json"
			output = root / "table.lua"
			_ = output.write_text("previous table")
			args = [
				"--att-source",
				str(root / "source"),
				"--revision",
				REVISION,
				"--report",
				str(report),
			]
			catalog = forever_catalog()
			with (
				patch.object(g, "read_att", return_value=catalog),
				contextlib.redirect_stdout(io.StringIO()),
				contextlib.redirect_stderr(io.StringIO()),
			):
				self.assertEqual(0, g.main(args))
				self.assertEqual("previous table", output.read_text())
				self.assertEqual([], json.loads(report.read_text())["groups"])
				self.assertEqual(1, g.main(args + ["--output", str(output)]))
				self.assertEqual("previous table", output.read_text())
				self.assertEqual(
					0, g.main(args + ["--output", str(output), "--allow-empty"])
				)
				self.assertIn("local groups = {\n}", output.read_text())

	def test_invalid_source_leaves_all_outputs_untouched(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			output = root / "table.lua"
			report = root / "report.json"
			_ = output.write_text("previous")
			_ = report.write_text("previous")
			with contextlib.redirect_stderr(io.StringIO()):
				self.assertEqual(
					1,
					g.main(
						[
							"--questiedb-source",
							str(root / "missing"),
							"--revision",
							REVISION,
							"--report",
							str(report),
							"--output",
							str(output),
							"--allow-empty",
						]
					),
				)
			self.assertEqual("previous", output.read_text())
			self.assertEqual("previous", report.read_text())

	def test_outputs_cannot_overwrite_each_other_inputs_or_source_checkout(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			base = ["--att-source", str(root / "source"), "--revision", REVISION]
			for args in [
				["--report", str(root / "same"), "--output", str(root / "same")],
				["--report", str(root / "same"), "--reviews", str(root / "same")],
				["--report", str(root / "source/report.json")],
			]:
				with (
					self.subTest(args=args),
					contextlib.redirect_stderr(io.StringIO()),
					self.assertRaises(SystemExit),
				):
					_ = g.main(base + args)

	def test_legacy_network_flags_are_not_supported(self):
		with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
			_ = g.main(["--all", "--refresh", "--delay", "2"])


if __name__ == "__main__":
	_ = unittest.main()
