#!/usr/bin/env python3
"""Plan compatibility updates from CurseForge; optionally open review PRs in CI."""

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import cast

if not __package__:
	sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.curseforge_game_versions import (
	FOREVER_VERSION_TYPE_ID,
	RETAIL_VERSION_TYPE_ID,
)

ROOT = Path(__file__).resolve().parents[1]
BASELINES = Path("tools/compatibility_versions.json")
TOC = Path("QuestWithFriends.toc")
CLIENTS = {
	"retail": ("Retail", RETAIL_VERSION_TYPE_ID),
	"forever": ("Forever", FOREVER_VERSION_TYPE_ID),
}
VERSION_PATTERN = r"([1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)"


def version_tuple(version: str) -> tuple[int, int, int]:
	match = re.fullmatch(VERSION_PATTERN, version)
	if match is None:
		raise ValueError(f"Invalid numeric game version: {version}")
	return int(match[1]), int(match[2]), int(match[3])


def interface_number(version: str) -> int:
	major, minor, patch = version_tuple(version)
	return major * 10000 + minor * 100 + patch


def read_baselines(root: Path) -> dict[str, str]:
	data = cast(object, json.loads((root / BASELINES).read_text(encoding="utf-8")))
	if not isinstance(data, dict):
		raise TypeError("Compatibility baselines must contain retail and forever")
	mapping = cast(dict[str, object], data)
	if set(mapping) != set(CLIENTS):
		raise ValueError("Compatibility baselines must contain retail and forever")
	baselines: dict[str, str] = {}
	for client in CLIENTS:
		version = mapping[client]
		if (
			not isinstance(version, str)
			or re.fullmatch(VERSION_PATTERN, version) is None
		):
			raise ValueError(f"Invalid {client} compatibility baseline")
		baselines[client] = version
	return baselines


@dataclass(frozen=True)
class Candidate:
	client: str
	version: str
	version_id: int
	previous: str

	@property
	def branch(self) -> str:
		return f"compatibility/{self.client}-{self.version}"

	@property
	def title(self) -> str:
		return f"Compatibility: test {CLIENTS[self.client][0]} {self.version}"

	def body(self, reviewer: str) -> str:
		label, type_id = CLIENTS[self.client]
		return f"""@{reviewer}: CurseForge lists **{label} {self.version}**. Please test before merging.

- Reviewed baseline: `{self.previous}` → candidate: `{self.version}`
- Proposed TOC interface: `{interface_number(self.version)}`
- CurseForge version ID: `{self.version_id}`; game version type: `{type_id}`
- Source: https://wow.curseforge.com/api/game/versions

This is a compatibility candidate, **not verified support**. CurseForge listing does
not guarantee PTR availability or advance notice before launch. The proposed
interface number is derived from the version; confirm it against the actual client.
Merging records this version as reviewed. This PR does not publish a release.

Checkout: `gh pr checkout {self.branch}`

### Manual validation

- [ ] Install on the matching PTR/beta, or live client if it has already launched.
- [ ] Record client version, build, interface (`/dump GetBuildInfo()`), and tested addon revision in a comment.
- [ ] Check login, reload, existing saved settings, settings UI, preview, resizing, collapsing, and scrolling.
- [ ] With two clients: join/leave, reconnect, `/qwf` refresh, and verify both peers converge.
- [ ] Accept, progress, complete, turn in, abandon, and share quests; check zone and category filters.
- [ ] Check relevant behavior in combat and inspect Lua errors.
- [ ] Confirm automated tests pass; add regression tests for any fixes.
- [ ] Recheck the other supported client after any shared-code changes.
- [ ] Update player-facing version references and changelog as appropriate.

Close without merging to dismiss this client/version; the monitor will not reopen it.
Reopen the PR to resume testing. Release preparation remains manual.
"""


def find_candidates(versions: object, baselines: dict[str, str]) -> list[Candidate]:
	if not isinstance(versions, list):
		raise TypeError("CurseForge game versions must be an array of objects")
	if any(not isinstance(v, dict) for v in cast(list[object], versions)):
		raise ValueError("CurseForge game versions must be an array of objects")
	catalog = cast(list[dict[str, object]], versions)
	candidates: list[Candidate] = []
	for client, (_, type_id) in CLIENTS.items():
		seen: set[str] = set()
		latest: Candidate | None = None
		for entry in catalog:
			if entry.get("gameVersionTypeID") != type_id:
				continue
			name = entry.get("name")
			# Labels such as beta/PTR are not safe inputs for deriving a TOC number.
			if not isinstance(name, str) or re.fullmatch(VERSION_PATTERN, name) is None:
				continue
			version_id = entry.get("id")
			if type(version_id) is not int or version_id <= 0:
				raise ValueError(f"Invalid CurseForge version ID for {client} {name}")
			if name in seen:
				raise ValueError(f"Ambiguous CurseForge version for {client} {name}")
			seen.add(name)
			if version_tuple(name) > version_tuple(baselines[client]) and (
				latest is None or version_tuple(name) > version_tuple(latest.version)
			):
				latest = Candidate(client, name, version_id, baselines[client])
		if not seen:
			raise ValueError(f"CurseForge returned no numeric versions for {client}")
		if latest is not None:
			candidates.append(latest)
	return sorted(candidates, key=lambda c: (c.client, version_tuple(c.version)))


def proposed_toc(toc: str, baselines: dict[str, str], candidate: Candidate) -> str:
	matches = list(
		re.finditer(r"^##[ \t]*Interface:[ \t]*([^\r\n]+)", toc, re.MULTILINE)
	)
	if len(matches) != 1:
		raise ValueError("Expected exactly one Interface metadata line")
	match = matches[0]
	values = [value.strip() for value in match[1].split(",")]
	if any(re.fullmatch(r"[0-9]+", value) is None for value in values):
		raise ValueError("Invalid TOC Interface metadata")
	for client, version in baselines.items():
		if values.count(str(interface_number(version))) != 1:
			raise ValueError(
				f"TOC does not match the reviewed {client} baseline {version}"
			)
	values[values.index(str(interface_number(candidate.previous)))] = str(
		interface_number(candidate.version)
	)
	return toc[: match.start(1)] + ", ".join(values) + toc[match.end(1) :]


def run(root: Path, *command: str) -> str:
	return subprocess.run(
		command, cwd=root, check=True, capture_output=True, text=True
	).stdout.strip()


def open_prs(root: Path, candidates: list[Candidate], base: str, reviewer: str) -> None:
	if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", reviewer) is None:
		raise ValueError("Reviewer must be a GitHub user login")
	if run(root, "git", "status", "--porcelain"):
		raise ValueError("PR creation requires a clean CI checkout")
	baselines = read_baselines(root)
	toc = (root / TOC).read_text(encoding="utf-8")
	for candidate in candidates:
		existing = cast(
			object,
			json.loads(
				run(
					root,
					"gh",
					"pr",
					"list",
					"--state",
					"all",
					"--head",
					candidate.branch,
					"--base",
					base,
					"--json",
					"number",
					"--limit",
					"100",
				)
			),
		)
		if not isinstance(existing, list):
			raise TypeError("GitHub PR lookup did not return an array")
		# Closed PRs are an intentional dismissal, not a reason to notify again.
		if existing:
			print(f"Already tracked: {candidate.branch}")
			continue
		try:
			remote = run(
				root,
				"git",
				"ls-remote",
				"--heads",
				"origin",
				f"refs/heads/{candidate.branch}",
			)
			if remote:
				# Recover a push that succeeded before PR creation failed; never overwrite it.
				_ = run(root, "git", "fetch", "origin", candidate.branch)
				_ = run(root, "git", "switch", "-C", candidate.branch, "FETCH_HEAD")
			else:
				_ = run(root, "git", "switch", "-c", candidate.branch, base)
				_ = (root / TOC).write_text(
					proposed_toc(toc, baselines, candidate), encoding="utf-8"
				)
				updated = baselines | {candidate.client: candidate.version}
				_ = (root / BASELINES).write_text(
					json.dumps(updated, indent=2) + "\n", encoding="utf-8"
				)
				_ = run(root, "git", "add", str(TOC), str(BASELINES))
				_ = run(root, "git", "commit", "-m", candidate.title)
				_ = run(
					root, "git", "push", "--set-upstream", "origin", candidate.branch
				)
			print(
				run(
					root,
					"gh",
					"pr",
					"create",
					"--base",
					base,
					"--head",
					candidate.branch,
					"--title",
					candidate.title,
					"--body",
					candidate.body(reviewer),
					"--reviewer",
					reviewer,
				)
			)
		finally:
			_ = run(root, "git", "switch", base)


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	_ = parser.add_argument("versions", type=Path, help="CurseForge game versions JSON")
	_ = parser.add_argument(
		"--create-prs",
		action="store_true",
		help="mutate branches and open PRs (CI only)",
	)
	_ = parser.add_argument("--base", help="default branch; required with --create-prs")
	_ = parser.add_argument(
		"--reviewer", help="GitHub login; required with --create-prs"
	)
	args = parser.parse_args()
	create_prs = cast(bool, args.create_prs)
	base = cast(str | None, args.base)
	reviewer = cast(str | None, args.reviewer)
	versions_path = cast(Path, args.versions)
	if create_prs and (not base or not reviewer):
		parser.error("--create-prs requires --base and --reviewer")
	try:
		versions = cast(object, json.loads(versions_path.read_text(encoding="utf-8")))
		baselines = read_baselines(ROOT)
		candidates = find_candidates(versions, baselines)
		for candidate in candidates:
			_ = proposed_toc(
				(ROOT / TOC).read_text(encoding="utf-8"), baselines, candidate
			)
		if create_prs and base and reviewer:
			open_prs(ROOT, candidates, base, reviewer)
		else:
			print(
				json.dumps(
					[
						{
							"client": c.client,
							"version": c.version,
							"version_id": c.version_id,
							"branch": c.branch,
						}
						for c in candidates
					],
					indent=2,
				)
			)
	except (OSError, ValueError, TypeError) as error:
		parser.error(str(error))
	except subprocess.CalledProcessError as error:
		stderr = cast(str | None, error.stderr)
		parser.error(f"Command failed: {stderr.strip() if stderr else str(error)}")


if __name__ == "__main__":
	main()
