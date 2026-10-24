#!/usr/bin/env python3
"""Plan compatibility candidates; optionally create integration branches and issues."""

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
API = "repos/{owner}/{repo}"
CLIENTS = {
	"retail": ("Retail", RETAIL_VERSION_TYPE_ID),
	"forever": ("Forever", FOREVER_VERSION_TYPE_ID),
}
VERSION_PATTERN = r"([1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)"
BRANCH_PATTERN = rf"compatibility/(retail|forever)-({VERSION_PATTERN})"


def version_tuple(version: str) -> tuple[int, int, int]:
	match = re.fullmatch(VERSION_PATTERN, version)
	if match is None:
		raise ValueError(f"Invalid numeric game version: {version}")
	return int(match[1]), int(match[2]), int(match[3])


def interface_number(version: str) -> int:
	major, minor, patch = version_tuple(version)
	return major * 10000 + minor * 100 + patch


def parse_baselines(data: object) -> dict[str, str]:
	mapping = json_object(data)
	if set(mapping) != set(CLIENTS):
		raise ValueError("Compatibility baselines must contain retail and forever")
	baselines: dict[str, str] = {}
	for client in CLIENTS:
		version = mapping[client]
		if not isinstance(version, str):
			raise TypeError(f"Invalid {client} compatibility baseline")
		_ = version_tuple(version)
		baselines[client] = version
	return baselines


def read_baselines(root: Path) -> dict[str, str]:
	return parse_baselines(
		cast(object, json.loads((root / BASELINES).read_text(encoding="utf-8")))
	)


def branch_target(branch: str) -> tuple[str, str]:
	match = re.fullmatch(BRANCH_PATTERN, branch)
	if match is None:
		raise ValueError(f"Invalid compatibility branch: {branch}")
	return match[1], match[2]


def issue_marker(branch: str) -> str:
	_ = branch_target(branch)
	return f"<!-- qwf-compatibility:{branch} -->"


@dataclass(frozen=True)
class TrackingIssue:
	number: int
	branch: str
	state: str


def run(root: Path, *command: str) -> str:
	return subprocess.run(
		command, cwd=root, check=True, capture_output=True, text=True
	).stdout.strip()


def json_object(value: object) -> dict[str, object]:
	if not isinstance(value, dict):
		raise TypeError("Expected a JSON object")
	return cast(dict[str, object], value)


def paged_items(root: Path, endpoint: str) -> list[dict[str, object]]:
	data = cast(
		object,
		json.loads(
			run(root, "gh", "api", f"{API}/{endpoint}", "--paginate", "--slurp")
		),
	)
	if not isinstance(data, list):
		raise TypeError("Expected paginated JSON arrays")
	items: list[dict[str, object]] = []
	for page in cast(list[object], data):
		if not isinstance(page, list):
			raise TypeError("Expected a JSON array per page")
		items.extend(json_object(item) for item in cast(list[object], page))
	return items


def tracking_issues(root: Path) -> list[TrackingIssue]:
	issues: list[TrackingIssue] = []
	seen: set[str] = set()
	for issue in paged_items(root, "issues?state=all&per_page=100"):
		author = issue.get("user")
		login = (
			cast(dict[str, object], author).get("login")
			if isinstance(author, dict)
			else None
		)
		# Public issue bodies must not be able to control privileged branch automation.
		if login != "not-adam[bot]" and issue.get("author_association") not in (
			"OWNER",
			"MEMBER",
			"COLLABORATOR",
		):
			continue
		body = issue.get("body")
		if "pull_request" in issue or not isinstance(body, str):
			continue
		markers = cast(
			list[str],
			re.findall(r"^<!-- qwf-compatibility:(.+) -->$", body, re.MULTILINE),
		)
		if not markers:
			continue
		if len(markers) != 1:
			raise ValueError("Tracking issue must contain exactly one branch marker")
		branch = markers[0]
		_ = branch_target(branch)
		if branch in seen:
			raise ValueError(f"Duplicate tracking issues for {branch}")
		number, state = issue.get("number"), issue.get("state")
		if type(number) is not int or number <= 0 or state not in ("open", "closed"):
			raise ValueError("Invalid tracking issue number/state")
		assert isinstance(state, str)
		seen.add(branch)
		issues.append(TrackingIssue(number, branch, state))
	return issues


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
		return f"""{issue_marker(self.branch)}
@{reviewer}: CurseForge lists **{label} {self.version}**.

- Live baseline at detection: `{self.previous}` → candidate: `{self.version}`
- Integration branch: `{self.branch}`
- Proposed TOC interface: `{interface_number(self.version)}`
- CurseForge version ID: `{self.version_id}`; game version type: `{type_id}`
- Source: https://wow.curseforge.com/api/game/versions

This is a compatibility candidate, **not verified support**. CurseForge listing does
not guarantee PTR availability or advance notice before launch. Confirm the actual
interface with `/dump GetBuildInfo()` before claiming support.

### Development and downloads

Target focused PRs at `{self.branch}`, not the default branch. Open tracking issues
keep their integration branches receiving automatic merges from the default branch.
Conflicts and failing branch tests are reported here; resolve them before publishing.
An existing branch is reused without rewriting its history; update an older branch
from the default branch and inspect its TOC before testing.

Checkout: `jj git fetch && jj new '{self.branch}@origin'`
Git alternative: `git fetch origin && git switch --track origin/{self.branch}`
Local dev ZIP: `python3 tools/bundle_addon.py --dev`

To share a normal-installation ZIP, run **Publish compatibility preview** from the
default branch with `{self.branch}` as its branch input. It runs tests and publishes
a GitHub-only prerelease. Nothing is uploaded to CurseForge or Wago.

### Readiness

- [ ] Matching PTR/beta or live client is available.
- [ ] Record client version, build, interface (`/dump GetBuildInfo()`), and tested addon revision.
- [ ] Check login, reload, saved settings, settings UI, preview, resizing, collapsing, and scrolling.
- [ ] With two clients: join/leave, reconnect, `/qwf` refresh, and verify both peers converge.
- [ ] Accept, progress, complete, turn in, abandon, and share quests; check zone and category filters.
- [ ] Check combat behavior and Lua errors.
- [ ] Automated tests pass; regression tests cover fixes.
- [ ] Recheck the other supported client after shared-code changes.
- [ ] PTR compatibility verified (record evidence in a comment).
- [ ] Patch is live; revalidate against the actual live client.
- [ ] Open a short-lived promotion PR to the default branch; review the complete diff, finalize stable addon version/changelog, and include `Closes #<issue-number>`.
- [ ] Merge promotion PR, publish stable normally, and delete the integration branch.

Closing this issue stops automatic syncing and preview publication, and suppresses
repeat detection for this version. Close and delete superseded branches explicitly;
newer candidates do not silently retire older work. Reopen to resume. No automatic
promotion or stable release occurs.
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


def post_json(
	root: Path, endpoint: str, payload: dict[str, object]
) -> dict[str, object]:
	result = subprocess.run(
		["gh", "api", endpoint, "--method", "POST", "--input", "-"],
		cwd=root,
		input=json.dumps(payload),
		check=True,
		capture_output=True,
		text=True,
	)
	data = json_object(cast(object, json.loads(result.stdout)))
	if data.get("errors"):
		raise ValueError(f"GitHub API errors: {data['errors']}")
	return data


def create_linked_branch(root: Path, branch: str, base: str, issue_number: int) -> None:
	client, version = branch_target(branch)
	baselines = read_baselines(root)
	candidate = Candidate(client, version, 0, baselines[client])
	base_sha = run(root, "git", "rev-parse", "--verify", f"{base}^{{commit}}")
	commit = json_object(
		cast(
			object, json.loads(run(root, "gh", "api", f"{API}/git/commits/{base_sha}"))
		)
	)
	base_tree = json_object(commit.get("tree")).get("sha")
	if not isinstance(base_tree, str):
		raise TypeError("GitHub base commit is missing its tree SHA")
	files = {
		TOC: proposed_toc(
			(root / TOC).read_text(encoding="utf-8"), baselines, candidate
		),
		BASELINES: json.dumps(baselines | {client: version}, indent=2) + "\n",
	}
	# Upload complete objects before creating the ref: a failed request cannot leave
	# a visible branch that lacks its compatibility metadata.
	tree = post_json(
		root,
		f"{API}/git/trees",
		{
			"base_tree": base_tree,
			"tree": [
				{
					"path": path.as_posix(),
					"mode": "100644",
					"type": "blob",
					"content": content,
				}
				for path, content in files.items()
			],
		},
	)
	if not isinstance(tree.get("sha"), str):
		raise TypeError("GitHub did not return the candidate tree SHA")
	created = post_json(
		root,
		f"{API}/git/commits",
		{
			"message": candidate.title,
			"tree": tree["sha"],
			"parents": [base_sha],
			"author": {
				"name": "not-adam[bot]",
				"email": "not-adam[bot]@users.noreply.github.com",
			},
		},
	)
	sha = created.get("sha")
	if not isinstance(sha, str):
		raise TypeError("GitHub did not return the candidate commit SHA")
	issue_id = run(
		root, "gh", "issue", "view", str(issue_number), "--json", "id", "--jq", ".id"
	)
	result = post_json(
		root,
		"graphql",
		{
			"query": "mutation($issue: ID!, $oid: GitObjectID!, $name: String!) { createLinkedBranch(input: {issueId: $issue, oid: $oid, name: $name}) { linkedBranch { ref { name target { oid } } } } }",
			"variables": {"issue": issue_id, "oid": sha, "name": branch},
		},
	)
	linked = json_object(
		json_object(json_object(result.get("data")).get("createLinkedBranch")).get(
			"linkedBranch"
		)
	)
	ref = json_object(linked.get("ref"))
	if ref.get("name") != branch or json_object(ref.get("target")).get("oid") != sha:
		raise ValueError("GitHub did not create the expected linked branch")
	print(f"Created {branch} linked to issue #{issue_number} at {sha}")


def track_candidates(
	root: Path, candidates: list[Candidate], base: str, reviewer: str
) -> None:
	if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", reviewer) is None:
		raise ValueError("Reviewer must be a GitHub user login")
	if run(root, "git", "status", "--porcelain"):
		raise ValueError("Branch creation requires a clean CI checkout")
	tracked = {issue.branch: issue for issue in tracking_issues(root)}
	for candidate in candidates:
		if candidate.branch in tracked:
			continue
		url = run(
			root,
			"gh",
			"issue",
			"create",
			"--title",
			candidate.title,
			"--body",
			candidate.body(reviewer),
			"--assignee",
			reviewer,
		)
		match = re.search(r"/issues/([1-9][0-9]*)$", url)
		if match is None:
			raise ValueError(f"GitHub did not return a tracking issue URL: {url}")
		tracked[candidate.branch] = TrackingIssue(
			int(match[1]), candidate.branch, "open"
		)
		print(url)
	baselines = read_baselines(root)
	for issue in tracked.values():
		client, version = branch_target(issue.branch)
		# Closed issues remain tombstones; only active, upcoming targets can recover.
		if issue.state != "open" or version_tuple(version) <= version_tuple(
			baselines[client]
		):
			continue
		remote = run(
			root, "git", "ls-remote", "--heads", "origin", f"refs/heads/{issue.branch}"
		)
		if remote:
			print(f"Keeping existing branch unchanged: {issue.branch}")
			continue
		create_linked_branch(root, issue.branch, base, issue.number)


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	_ = parser.add_argument("versions", type=Path, help="CurseForge game versions JSON")
	_ = parser.add_argument(
		"--create-tracking",
		action="store_true",
		help="create branches and assigned issues (CI only)",
	)
	_ = parser.add_argument(
		"--base", help="default branch; required with --create-tracking"
	)
	_ = parser.add_argument(
		"--reviewer", help="GitHub assignee; required with --create-tracking"
	)
	args = parser.parse_args()
	create_tracking = cast(bool, args.create_tracking)
	base = cast(str | None, args.base)
	reviewer = cast(str | None, args.reviewer)
	versions_path = cast(Path, args.versions)
	if create_tracking and (not base or not reviewer):
		parser.error("--create-tracking requires --base and --reviewer")
	try:
		versions = cast(object, json.loads(versions_path.read_text(encoding="utf-8")))
		baselines = read_baselines(ROOT)
		candidates = find_candidates(versions, baselines)
		for candidate in candidates:
			_ = proposed_toc(
				(ROOT / TOC).read_text(encoding="utf-8"), baselines, candidate
			)
		if create_tracking and base and reviewer:
			track_candidates(ROOT, candidates, base, reviewer)
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
		parser.error(f"Command failed: {stderr or error}")


if __name__ == "__main__":
	main()
