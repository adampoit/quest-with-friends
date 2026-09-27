"""Shipped Camping overrides retain their pinned QuestieDB category evidence."""

import json
import re
import unittest
from pathlib import Path
from typing import TypedDict, cast

from tools.quest_sources import digest


class QuestRecord(TypedDict):
	id: int
	title: str
	category: int
	sha256: str


class SourceManifest(TypedDict):
	schema: int
	game: str
	source: str
	source_url: str
	revision: str
	source_sha256: str
	category: int
	quests: list[QuestRecord]


ROOT = Path(__file__).resolve().parents[2]


def source_manifest() -> SourceManifest:
	return cast(
		SourceManifest,
		json.loads((ROOT / "tests/fixtures/forever_camping_quests.json").read_text()),
	)


class QuestCategoryTests(unittest.TestCase):
	def test_offline_category_allowlist_retains_exactly_the_reviewed_ids(self):
		review = cast(
			dict[str, object],
			json.loads(
				(ROOT / "tools/reviewed_quest_categories.forever.json").read_text()
			),
		)
		manifest = source_manifest()
		self.assertEqual("forever", review["game"])
		self.assertEqual("questiedb", review["source"])
		self.assertEqual(-666, review["category"])
		self.assertEqual([row["id"] for row in manifest["quests"]], review["ids"])

	def test_camping_evidence_is_source_pinned_and_self_verifying(self):
		manifest = source_manifest()
		self.assertEqual(1, manifest["schema"])
		self.assertEqual("forever", manifest["game"])
		self.assertEqual("questiedb", manifest["source"])
		self.assertEqual(-666, manifest["category"])
		self.assertRegex(manifest["revision"], r"^[0-9a-f]{40}$")
		self.assertRegex(manifest["source_sha256"], r"^[0-9a-f]{64}$")
		self.assertEqual(
			f"https://github.com/Questie/QuestieDB/tree/{manifest['revision']}",
			manifest["source_url"],
		)
		for record in manifest["quests"]:
			with self.subTest(quest=record["id"]):
				self.assertEqual(-666, record["category"])
				self.assertTrue(record["title"])
				self.assertEqual(
					digest(
						{
							"id": record["id"],
							"title": record["title"],
							"category": record["category"],
						}
					),
					record["sha256"],
				)

	def test_shipped_table_matches_the_94_reviewed_source_records(self):
		manifest = source_manifest()
		ids = [record["id"] for record in manifest["quests"]]
		self.assertEqual(94, len(ids))
		self.assertEqual(sorted(set(ids)), ids)
		source = (ROOT / "QuestCategories.lua").read_text()
		self.assertIn(manifest["revision"], source)
		self.assertIn(manifest["source_sha256"], source)
		match = re.search(r"local campingQuestIDs = \{([^}]+)\}", source)
		self.assertIsNotNone(match)
		if match is None:
			return
		values = cast(list[str], re.findall(r"\d+", match.group(1)))
		self.assertEqual(ids, [int(value) for value in values])
		self.assertIn("QWF.QuestCategories = { forever = {} }", source)
		self.assertIn('QWF.QuestCategories.forever[id] = "profession"', source)
		self.assertFalse(
			set(ids).intersection({96627, 96628, 96630, 96638, 96652, 96656, 96659})
		)


if __name__ == "__main__":
	_ = unittest.main()
