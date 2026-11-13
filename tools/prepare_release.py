#!/usr/bin/env python3
"""Prepare tag-driven draft releases and verify approved publication artifacts."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import cast

if not __package__:
	sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.bundle_addon import bundle
from tools.check_game_versions import (
	BASELINES,
	ROOT,
	TOC,
	interface_number,
	json_object,
	parse_baselines,
	run,
)
from tools.compatibility_branches import api, ref_sha, source_file, validate_preview
from tools.release_package import (
	ReleaseTag,
	interface_versions,
	parse_tag,
	toc_version,
	validate_release_archive,
)


def tag_sha(root: Path, tag: str) -> str:
	_ = parse_tag(tag)
	obj = json_object(api(root, f"git/ref/tags/{tag}").get("object"))
	for _ in range(8):
		sha = obj.get("sha")
		if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
			raise ValueError("Release tag has an invalid SHA")
		if obj.get("type") == "commit":
			return sha
		if obj.get("type") != "tag":
			break
		obj = json_object(api(root, f"git/tags/{sha}").get("object"))
	raise ValueError("Release tag must resolve to a commit")


def check_source(root: Path, version: ReleaseTag) -> dict[str, str]:
	toc = (root / TOC).read_text(encoding="utf-8-sig")
	if toc_version(toc) != version.base:
		raise ValueError("Source TOC Version must match the tag's stable base version")
	targets = parse_baselines(cast(object, json.loads((root / BASELINES).read_text())))
	interfaces = cast(
		list[str], re.findall(r"^##[ \t]*Interface:[ \t]*([^\r\n]+)", toc, re.MULTILINE)
	)
	expected = sorted(str(interface_number(value)) for value in targets.values())
	if (
		len(interfaces) != 1
		or sorted(value.strip() for value in interfaces[0].split(",")) != expected
	):
		raise ValueError(
			"TOC interfaces must match the reviewed compatibility baselines"
		)
	return targets


def release_plan(root: Path, sha: str, tag: str, base: str) -> dict[str, object]:
	version = parse_tag(tag)
	if re.fullmatch(r"[0-9a-f]{40}", sha) is None or tag_sha(ROOT, tag) != sha:
		raise ValueError("Pushed tag does not match the requested source SHA")
	targets = check_source(root, version)
	issue = 0
	if version.client:
		issue = validate_preview(
			ROOT, base, version.client, targets[version.client], sha
		).number
	else:
		main = ref_sha(ROOT, base)
		live = parse_baselines(
			cast(object, json.loads(source_file(ROOT, main, BASELINES)))
		)
		if targets != live:
			raise ValueError(
				"Live releases must match live baselines; use a PTR tag for previews"
			)
		if not version.prerelease:
			status = api(ROOT, f"compare/{sha}...{main}").get("status")
			if status not in ("ahead", "identical"):
				raise ValueError(
					"Stable releases must already be on the default branch"
				)
	return {
		"schema": 1,
		"source_sha": sha,
		"tag": tag,
		"version": version.version,
		"channel": version.channel,
		"client": version.client,
		"game_version": targets[version.client] if version.client else "",
		"targets": targets,
		"storefronts": version.storefronts,
		"issue": issue,
	}


def validate_plan(plan: dict[str, object]) -> ReleaseTag:
	tag = plan.get("tag")
	if not isinstance(tag, str):
		raise ValueError("Release plan requires a tag")
	version = parse_tag(tag)
	targets = parse_baselines(plan.get("targets"))
	expected: dict[str, object] = {
		"schema": 1,
		"version": version.version,
		"channel": version.channel,
		"client": version.client,
		"game_version": targets[version.client] if version.client else "",
		"storefronts": version.storefronts,
	}
	if type(plan.get("schema")) is not int or any(
		plan.get(key) != value for key, value in expected.items()
	):
		raise ValueError("Release plan does not match its tag policy")
	sha = plan.get("source_sha")
	if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
		raise ValueError("Release plan requires a full source SHA")
	issue = plan.get("issue")
	if type(issue) is not int or (issue <= 0 if version.client else issue != 0):
		raise ValueError("Release plan has an invalid tracking issue")
	return version


def build_release(
	root: Path, plan: dict[str, object], output: Path
) -> dict[str, object]:
	version = validate_plan(plan)
	if check_source(root, version) != plan["targets"]:
		raise ValueError("Source targets changed after planning")
	archive = bundle(
		root,
		output / f"QuestWithFriends-{version.version}.zip",
		tag=version.tag,
		preview_version=version.version if version.prerelease else None,
	)
	return plan | {"archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}


def verify_release(
	archive: Path, plan: dict[str, object], release: object, sha: str
) -> ReleaseTag:
	version = validate_plan(plan)
	if validate_release_archive(archive, release) != version:
		raise ValueError("Published release does not match the package plan")
	if plan["source_sha"] != sha:
		raise ValueError("Release tag moved after the package was built")
	if plan.get("archive_sha256") != hashlib.sha256(archive.read_bytes()).hexdigest():
		raise ValueError("Release ZIP checksum does not match the approved package")
	if set(interface_versions(archive)) != set(
		parse_baselines(plan["targets"]).values()
	):
		raise ValueError("Release ZIP interfaces do not match the package plan")
	return version


def draft_release(root: Path, archive: Path, manifest: Path) -> None:
	archive, manifest = archive.resolve(), manifest.resolve()
	plan = json_object(cast(object, json.loads(manifest.read_text())))
	version = validate_plan(plan)
	sha = tag_sha(root, version.tag)
	_ = verify_release(
		archive,
		plan,
		{"tag_name": version.tag, "draft": False, "prerelease": version.prerelease},
		sha,
	)
	try:
		existing = api(root, f"releases/tags/{version.tag}")
	except subprocess.CalledProcessError as error:
		if "(HTTP 404)" not in (cast(str | None, error.stderr) or ""):
			raise
		existing = {}
	if existing:
		if existing.get("prerelease") is not version.prerelease:
			raise ValueError("Existing release has a different channel")
		assets = existing.get("assets")
		if not isinstance(assets, list):
			raise ValueError("Existing release has invalid assets")
		names = [json_object(asset).get("name") for asset in cast(list[object], assets)]
		for file in (archive, manifest):
			if names.count(file.name) > 1:
				raise ValueError("Existing release has duplicate assets")
			if file.name in names:
				with tempfile.TemporaryDirectory() as directory:
					_ = run(
						root,
						"gh",
						"release",
						"download",
						version.tag,
						"--pattern",
						file.name,
						"--dir",
						directory,
					)
					if (Path(directory) / file.name).read_bytes() != file.read_bytes():
						raise ValueError(
							"Refusing to replace an existing release asset"
						)
			elif existing.get("draft") is True:
				_ = run(root, "gh", "release", "upload", version.tag, str(file))
			else:
				raise ValueError("Published release is missing a reviewed asset")
		return
	notes = f"Source revision: `{sha}`. Channel: **{version.channel}**.\n"
	if version.client:
		notes += (
			f"\n**PTR preview: {version.client} {plan['game_version']}.** "
			+ "Experimental GitHub-only download; install only in the matching "
			+ f"test client. Tracking issue: #{plan['issue']}.\n"
		)
	elif version.prerelease:
		notes += "\nExperimental live-client build. Not a stable release.\n"
	notes += (
		"\nInstall as QuestWithFriends, replacing—not alongside—another copy. "
		+ "Review these notes before publishing."
	)
	arguments = ["--prerelease", "--latest=false"] if version.prerelease else []
	title = (
		f"{version.tag} — {version.client.title()} PTR {plan['game_version']}"
		if version.client
		else version.tag
	)
	print(
		run(
			root,
			"gh",
			"release",
			"create",
			version.tag,
			str(archive),
			str(manifest),
			"--verify-tag",
			"--draft",
			"--generate-notes",
			"--title",
			title,
			"--notes",
			notes,
			*arguments,
		)
	)


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	sub = parser.add_subparsers(dest="command", required=True)
	plan = sub.add_parser("plan")
	_ = plan.add_argument("root", type=Path)
	_ = plan.add_argument("--tag", required=True)
	_ = plan.add_argument("--sha", required=True)
	_ = plan.add_argument("--base", required=True)
	build = sub.add_parser("build")
	_ = build.add_argument("root", type=Path)
	_ = build.add_argument("plan", type=Path)
	_ = build.add_argument("output", type=Path)
	for command in ("verify", "draft"):
		operation = sub.add_parser(command)
		_ = operation.add_argument("archive", type=Path)
		_ = operation.add_argument("plan", type=Path)
		if command == "verify":
			_ = operation.add_argument("release", type=Path)
	args = parser.parse_args()
	try:
		command = cast(str, args.command)
		if command == "plan":
			result = release_plan(
				cast(Path, args.root),
				cast(str, args.sha),
				cast(str, args.tag),
				cast(str, args.base),
			)
		elif command == "build":
			result = build_release(
				cast(Path, args.root),
				json_object(
					cast(object, json.loads(cast(Path, args.plan).read_text()))
				),
				cast(Path, args.output),
			)
		elif command == "draft":
			draft_release(ROOT, cast(Path, args.archive), cast(Path, args.plan))
			return
		else:
			metadata = json_object(
				cast(object, json.loads(cast(Path, args.plan).read_text()))
			)
			version = validate_plan(metadata)
			_ = verify_release(
				cast(Path, args.archive),
				metadata,
				cast(object, json.loads(cast(Path, args.release).read_text())),
				tag_sha(ROOT, version.tag),
			)
			result = {
				"channel": version.channel,
				"version": version.version,
				"curseforge": "curseforge" in version.storefronts,
				"wago": "wago" in version.storefronts,
			}
		print(json.dumps(result))
	except (OSError, ValueError, TypeError, subprocess.CalledProcessError) as error:
		parser.exit(1, f"Release preparation failed: {error}\n")


if __name__ == "__main__":
	main()
