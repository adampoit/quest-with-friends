#!/usr/bin/env python3
"""Sync tracked compatibility branches and validate pinned preview candidates."""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import cast

if not __package__:
	sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.check_game_versions import (
	API,
	BASELINES,
	ROOT,
	TOC,
	Candidate,
	TrackingIssue,
	branch_target,
	json_object,
	paged_items,
	parse_baselines,
	proposed_toc,
	run,
	tracking_issues,
	version_tuple,
)


def api(root: Path, endpoint: str, *arguments: str) -> dict[str, object]:
	result = run(root, "gh", "api", f"{API}/{endpoint}", *arguments)
	return json_object(cast(object, json.loads(result))) if result else {}


def ref_sha(root: Path, branch: str) -> str:
	sha = json_object(api(root, f"git/ref/heads/{branch}").get("object")).get("sha")
	if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
		raise ValueError("GitHub returned an invalid commit SHA")
	return sha


def source_file(root: Path, sha: str, path: Path) -> str:
	data = api(
		root, f"contents/{path.as_posix()}", "--method", "GET", "-f", f"ref={sha}"
	)
	content = data.get("content")
	if not isinstance(content, str):
		raise TypeError("GitHub source file is missing base64 content")
	return base64.b64decode(content).decode("utf-8-sig")


def comment_once(root: Path, issue: TrackingIssue, key: str, message: str) -> None:
	marker = f"<!-- qwf-compatibility-report:{key} -->"
	for comment in paged_items(root, f"issues/{issue.number}/comments?per_page=100"):
		body = comment.get("body")
		if isinstance(body, str) and marker in body:
			return
	_ = run(
		root,
		"gh",
		"issue",
		"comment",
		str(issue.number),
		"--body",
		f"{marker}\n{message}",
	)


_TOCS = (TOC, Path("QuestWithFriendsDev.toc"))


def isolated_git(
	root: Path, *arguments: str, content: str | None = None, raw: bool = False
) -> str:
	# Candidate trees stay data; ignore external merge drivers and disable hooks.
	result = subprocess.run(
		[
			"git",
			"-c",
			"core.hooksPath=/dev/null",
			"-c",
			"credential.helper=",
			"-c",
			"credential.helper=!gh auth git-credential",
			*arguments,
		],
		cwd=root,
		env=os.environ
		| {
			"GIT_CONFIG_NOSYSTEM": "1",
			"GIT_CONFIG_GLOBAL": os.devnull,
			"GIT_TERMINAL_PROMPT": "0",
			"GIT_AUTHOR_NAME": "not-adam[bot]",
			"GIT_AUTHOR_EMAIL": "299629278+not-adam[bot]@users.noreply.github.com",
			"GIT_COMMITTER_NAME": "not-adam[bot]",
			"GIT_COMMITTER_EMAIL": "299629278+not-adam[bot]@users.noreply.github.com",
		},
		input=content,
		capture_output=True,
		text=True,
		check=True,
	)
	return result.stdout if raw else result.stdout.strip()


def _target_toc(toc: str, live: dict[str, str], issue: TrackingIssue) -> str:
	targets = live | {issue.client: issue.version}
	try:
		updated = proposed_toc(
			toc, targets, Candidate(issue.client, issue.version, 1, issue.version)
		)
	except ValueError:
		updated = proposed_toc(
			toc, live, Candidate(issue.client, issue.version, 1, live[issue.client])
		)
	match = re.search(r"(?m)^##[ \t]*Interface:[ \t]*([^\r\n]+)", updated)
	if match is None or len(match[1].split(",")) != len(targets):
		raise ValueError("TOC has ambiguous Interface metadata")
	return updated


def sync_branch(
	root: Path,
	main_sha: str,
	issue: TrackingIssue,
	live: dict[str, str],
	*,
	base: str = "main",
) -> bool:
	branch_sha = ref_sha(root, issue.branch)
	url = run(root, "gh", "repo", "view", "--json", "url", "--jq", ".url")
	if not url.endswith(".git"):
		url += ".git"
	with tempfile.TemporaryDirectory() as directory:
		repo = Path(directory).resolve()
		_ = isolated_git(repo, "init", "--quiet", "--template=")
		_ = isolated_git(
			repo,
			"fetch",
			"--no-tags",
			"--no-recurse-submodules",
			url,
			branch_sha,
			main_sha,
		)
		original = isolated_git(repo, "rev-parse", f"{branch_sha}^{{tree}}")
		contains_main = (
			isolated_git(repo, "merge-base", branch_sha, main_sha) == main_sha
		)
		tree = (
			original
			if contains_main
			else isolated_git(
				repo, "merge-tree", "--write-tree", branch_sha, main_sha
			).splitlines()[0]
		)
		targets = parse_baselines(
			cast(
				object,
				json.loads(
					isolated_git(repo, "show", f"{tree}:{BASELINES.as_posix()}")
				),
			)
		)
		if targets != live | {issue.client: issue.version}:
			raise ValueError("Merged baselines do not match the tracked PTR target")
		_ = isolated_git(repo, "read-tree", tree)
		for path in _TOCS:
			toc = isolated_git(repo, "show", f"{tree}:{path.as_posix()}", raw=True)
			updated = _target_toc(toc, live, issue)
			mode = isolated_git(
				repo, "ls-files", "--stage", "--", path.as_posix()
			).split()[0]
			if mode not in ("100644", "100755"):
				raise ValueError("TOCs must be regular files")
			if updated != toc:
				blob = isolated_git(
					repo, "hash-object", "-w", "--stdin", content=updated
				)
				_ = isolated_git(
					repo,
					"update-index",
					"--cacheinfo",
					f"{mode},{blob},{path.as_posix()}",
				)
		tree = isolated_git(repo, "write-tree")
		if contains_main and tree == original:
			return False
		parents = ["-p", branch_sha] + ([] if contains_main else ["-p", main_sha])
		commit = isolated_git(
			repo,
			"commit-tree",
			tree,
			*parents,
			"-m",
			f"Merge {base} into {issue.branch}",
		)
		# A single non-force push publishes the merge and both corrected manifests.
		_ = isolated_git(repo, "push", url, f"{commit}:refs/heads/{issue.branch}")
		return True


def sync_branches(root: Path, base: str) -> None:
	main_sha = ref_sha(root, base)
	baselines = parse_baselines(
		cast(object, json.loads(source_file(root, main_sha, BASELINES)))
	)
	failed: list[str] = []
	for issue in tracking_issues(root):
		if issue.state != "open":
			continue
		client, version = issue.client, issue.version
		if version_tuple(version) <= version_tuple(baselines[client]):
			print(
				f"Already promoted or superseded on {base}: {issue.branch}; close its issue and remove the branch"
			)
			continue
		try:
			result = sync_branch(root, main_sha, issue, baselines, base=base)
			print(f"{'Updated' if result else 'Already current'}: {issue.branch}")
		except (subprocess.CalledProcessError, ValueError, TypeError) as error:
			stderr = (
				(cast(str | None, error.stderr) or cast(str | None, error.stdout))
				if isinstance(error, subprocess.CalledProcessError)
				else str(error)
			)
			failed.append(issue.branch)
			comment_once(
				root,
				issue,
				f"sync:{main_sha}",
				f"Automatic merge of `{base}` (`{main_sha}`) into `{issue.branch}` failed. Resolve conflicts or restore the branch, merge the latest `{base}`, and rerun tests before publishing a preview. No history was rewritten.\n\n```text\n{stderr or str(error)}\n```",
			)
	if failed:
		raise ValueError(f"Could not sync: {', '.join(failed)}")


def report_test_failure(root: Path, branch: str, sha: str, url: str) -> None:
	_ = branch_target(branch)
	issues = [
		issue
		for issue in tracking_issues(root)
		if issue.branch == branch and issue.state == "open"
	]
	if not issues or ref_sha(root, branch) != sha:
		return
	comment_once(
		root,
		issues[0],
		f"tests:{sha}",
		f"Tests failed for the current `{branch}` tip (`{sha}`). Fix the failures before publishing a preview.\n\n[Test run]({url})",
	)


def validate_preview(
	root: Path, base: str, client: str, version: str, sha: str
) -> TrackingIssue:
	branch = f"ptr/{client}"
	_ = branch_target(branch)
	_ = version_tuple(version)
	if re.fullmatch(r"[0-9a-f]{40}", sha) is None:
		raise ValueError("Preview requires a full commit SHA")
	issues = [
		issue
		for issue in tracking_issues(root)
		if issue.branch == branch and issue.state == "open" and issue.version == version
	]
	if len(issues) != 1:
		raise ValueError("Preview requires an open tracking issue for this branch")
	branch_sha = ref_sha(root, branch)
	if branch_sha != sha and api(root, f"compare/{sha}...{branch_sha}").get(
		"status"
	) not in ("ahead", "identical"):
		raise ValueError("Tagged alpha commit must belong to its PTR branch")
	main_sha = ref_sha(root, base)
	status = api(root, f"compare/{main_sha}...{sha}")["status"]
	if status not in ("ahead", "identical"):
		raise ValueError(
			f"Merge the latest {base} into {branch} before publishing a preview"
		)
	live = parse_baselines(
		cast(object, json.loads(source_file(root, main_sha, BASELINES)))
	)
	if version_tuple(version) <= version_tuple(live[client]):
		raise ValueError(
			"Candidate is already live or superseded; use the stable release workflow"
		)
	targets = parse_baselines(
		cast(object, json.loads(source_file(root, sha, BASELINES)))
	)
	if targets[client] != version:
		raise ValueError("Branch target does not match its compatibility baseline")
	if targets != live | {client: version}:
		raise ValueError("PTR source must only change its selected client baseline")
	for path in _TOCS:
		toc = source_file(root, sha, path)
		_ = proposed_toc(toc, targets, Candidate(client, version, 1, version))
	return issues[0]


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	sub = parser.add_subparsers(dest="command", required=True)
	sync = sub.add_parser(
		"sync", help="merge the default branch into open tracked branches (CI only)"
	)
	_ = sync.add_argument("--base", required=True)
	report = sub.add_parser(
		"report-test-failure", help="notify an active branch's issue (CI only)"
	)
	_ = report.add_argument("--branch", required=True)
	_ = report.add_argument("--sha", required=True)
	_ = report.add_argument("--url", required=True)
	args = parser.parse_args()
	command = cast(str, args.command)
	try:
		if command == "sync":
			sync_branches(ROOT, cast(str, args.base))
		else:
			report_test_failure(
				ROOT, cast(str, args.branch), cast(str, args.sha), cast(str, args.url)
			)
	except (OSError, ValueError, TypeError) as error:
		parser.exit(1, f"Compatibility operation failed: {error}\n")
	except subprocess.CalledProcessError as error:
		stderr = cast(str | None, error.stderr)
		parser.exit(1, f"Compatibility operation failed: {stderr or error}\n")


if __name__ == "__main__":
	main()
