#!/usr/bin/env python3
"""Sync tracked compatibility branches and validate pinned preview candidates."""

import argparse
import base64
import json
import re
import subprocess
import sys
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
			# GitHub merges against the current branch tip atomically; no reset or force push.
			result = api(
				root,
				"merges",
				"--method",
				"POST",
				"-f",
				f"base={issue.branch}",
				"-f",
				f"head={main_sha}",
				"-f",
				f"commit_message=Merge {base} into {issue.branch}",
			)
			print(f"{'Updated' if result else 'Already current'}: {issue.branch}")
		except subprocess.CalledProcessError as error:
			stderr = cast(str | None, error.stderr)
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
	toc = source_file(root, sha, TOC)
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
