"""Exercise the benchmark against a synthetic corpus without downloading upstream data."""

import json
import shutil
import subprocess
import tempfile
import unittest
from functools import cache
from pathlib import Path
from typing import TypedDict, cast

ROOT = Path(__file__).resolve().parents[2]


class Measurement(TypedDict):
	duration_s: float
	bytes: int
	messages: dict[str, int]
	cpu_ms: dict[str, float]
	total_cpu_ms: float
	client_cpu_ms: dict[str, float]
	local_payload_bytes: dict[str, int]
	calls: dict[str, int]


class Report(TypedDict):
	results: dict[str, dict[str, dict[str, Measurement]]]
	mixed: Measurement


@cache
def benchmark_report() -> Report:
	interpreter = shutil.which("luajit") or shutil.which("lua")
	if not interpreter:
		raise unittest.SkipTest("Lua 5.1 or LuaJIT required")
	active = [
		9,
		13,
		22,
		38,
		64,
		103,
		104,
		117,
		151,
		152,
		153,
		20,
		34,
		89,
		91,
		92,
		115,
		116,
		125,
		150,
	]
	history = list(range(1000, 1030))
	rows = [
		f'[{id}]={{title="Synthetic quest {id}",zoneID=40,objectives={{{{text="Synthetic target {id}",numRequired=20,type="monster",targetID={id}}}}}}}'
		for id in active + history
	]
	fixture = (
		'return {source="synthetic",revision="test",active={'
		+ ",".join(map(str, active))
		+ "},history={"
		+ ",".join(map(str, history))
		+ "},quests={"
		+ ",".join(rows)
		+ "}}"
	)
	with tempfile.TemporaryDirectory(prefix="qwf-benchmark-test-") as directory:
		path = Path(directory) / "fixture.lua"
		_ = path.write_text(fixture)
		is_jit = "luajit" in Path(interpreter).name
		command = [interpreter] + (["-joff"] if is_jit else [])
		command += [
			"tools/benchmark_sync.lua",
			str(path),
			"1",
			"native" if is_jit else "portable",
			"single_player",
		]
		result = subprocess.run(
			command, cwd=ROOT, capture_output=True, text=True, timeout=90, check=False
		)
		if result.returncode:
			raise AssertionError(result.stderr)
		return cast(Report, json.loads(result.stdout))


class SyncBenchmarkTests(unittest.TestCase):
	def test_full_and_partial_use_real_pacing_and_converge(self):
		legacy = benchmark_report()["results"]["1.1"]["single_player"]["1"]
		partial = benchmark_report()["results"]["1.2"]["single_player"]["1"]
		self.assertEqual(partial["messages"], {"P": 1})
		self.assertAlmostEqual(partial["duration_s"], 0.2)
		self.assertAlmostEqual(
			legacy["duration_s"], 0.2 + 0.5 * (legacy["messages"]["D"] - 1)
		)
		self.assertLess(partial["bytes"], legacy["bytes"])
		self.assertEqual(len(partial["local_payload_bytes"]), 4)

	def test_cpu_categories_and_clients_are_exclusive(self):
		for version in ("1.1", "1.2"):
			result = benchmark_report()["results"][version]["single_player"]["1"]
			self.assertAlmostEqual(
				sum(result["cpu_ms"].values()), result["total_cpu_ms"]
			)
			self.assertAlmostEqual(
				sum(result["client_cpu_ms"].values()), result["total_cpu_ms"]
			)
			self.assertNotIn("transport_mock", result["cpu_ms"])
		self.assertEqual(
			benchmark_report()["results"]["1.2"]["single_player"]["1"]["calls"][
				"digest"
			],
			7,
		)

	def test_one_legacy_member_disables_partials(self):
		self.assertNotIn("P", benchmark_report()["mixed"]["messages"])
		self.assertGreater(benchmark_report()["mixed"]["messages"]["D"], 0)


if __name__ == "__main__":
	_ = unittest.main()
