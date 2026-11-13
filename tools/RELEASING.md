# Publishing releases

Pushed version tags prepare releases. Publishing the resulting GitHub draft is the approval gate for storefront uploads. There is no manual publishing workflow dispatch.

## Maintainer flow

1. Commit the candidate and push its branch. Merge these workflow changes into the default branch and update candidate branches before using the new publishing flow: the tagged revision must contain the tag-triggered workflow.
2. Set the source `QuestWithFriends.toc` version to the next **stable base**, such as `0.1.11`, before its first alpha/beta. Keep that base throughout testing; the packager overrides only the version inside prerelease ZIPs. The checked-in development TOC keeps its fixed `dev` version; do not regenerate it when changing the release base. Keep Interface metadata aligned in both TOCs when changing supported game patches.
3. Get branch CI green, then create and push a tag at the candidate commit:

   ```sh
   jj tag set v0.1.11-beta.1 -r <candidate-change-or-commit>
   jj git push --remote origin --tag v0.1.11-beta.1
   ```

4. Watch **Actions → Prepare release**. It validates the tag and client targets, tests the pinned commit, builds one normal-installation ZIP, and creates a **draft** GitHub release. The ZIP and `release-plan.json` checksum/provenance manifest are attached together.
5. Open the draft under **Releases**. Review/edit the notes and optionally download and test the ZIP. Keep the prerelease checkbox consistent with the tag; do not replace the reviewed ZIP or manifest.
6. Click **Publish release**. The `release: published` event starts the eligible storefront workflows. Nothing is uploaded to storefronts while the release is a draft. Storefront moderation may delay availability after upload.

Publishing a draft in the GitHub UI generates the storefront event as the maintainer. Draft creation by `GITHUB_TOKEN` does not need to trigger another workflow.

## Versions and distribution

| Tag                       | Meaning           | GitHub                 | CurseForge | Wago    |
| ------------------------- | ----------------- | ---------------------- | ---------- | ------- |
| `v0.1.11-alpha.retail.1`  | Retail PTR alpha  | Prerelease, not Latest | Skipped    | Skipped |
| `v0.1.11-alpha.forever.1` | Forever PTR alpha | Prerelease, not Latest | Skipped    | Skipped |
| `v0.1.11-beta.1`          | Live-client beta  | Prerelease, not Latest | Beta       | Beta    |
| `v0.1.11`                 | Stable            | Stable                 | Release    | Stable  |

Alpha tags **must** contain exactly one supported client. Beta and stable tags **must not** contain a client. Unqualified alphas, unknown clients, old patch-qualified PTR spellings and other suffixes are rejected. Use lowercase channels and positive sequence numbers without leading zeroes.

Retail and Forever have independent alpha sequences. The actual game patch is read from the tagged compatibility metadata and recorded in the release title and manifest; it is not part of the tag. The addon version and protocol version are independent.

Stable tags must point to commits already on the default branch. Live betas may point to feature branches, but their interface metadata and compatibility baselines must match the current live baselines. Merely calling a future-client build a "beta" does not make it eligible for storefronts.

To promote a final beta, tag its tested commit with the stable base version. The source already has that base version, so no runtime changes are needed. If a promotion merge changes runtime code, test another beta first. The pipeline tests the stable tag again; it does not automatically certify live-client testing or runtime equivalence to an earlier beta.

## PTR branches and tracking

There are only two PTR branch names: **`ptr/retail`** and **`ptr/forever`**. Each client can have only one open tracked game patch at a time. Compatibility detection still opens tracking issues, prepares branches and merges the default branch into active candidates; it does not publish automatically.

Sync uses Git 2.39+ in a temporary object-only repository to merge the pinned default-branch commit and align both TOCs with the reviewed PTR target. It preserves the release and `dev` versions and the other client's live interface. One non-force push publishes the merge and corrected manifests together, so CI does not see an intermediate mismatched pair. Candidate files are never checked out or executed; external merge drivers and hooks are disabled. Already-merged branches also have their manifests checked and repaired when they still contain live interfaces. Repeated syncs are no-ops once aligned. Genuine merge conflicts, unexpected interfaces/baselines, or concurrent divergent pushes fail instead of rewriting history or guessing at a target.

An issue records the client and patch with a marker such as:

```text
<!-- qwf-ptr:retail:12.1.7 -->
```

Use a short alpha tag at the reviewed PTR candidate:

```sh
jj tag set v0.1.11-alpha.retail.1 -r <candidate>
jj git push --remote origin --tag v0.1.11-alpha.retail.1
```

The selected client's tagged baseline must match its open tracking issue and be newer than live. The other client must retain its live baseline. The tagged commit must belong to the corresponding PTR branch and contain the current default branch; a tag has no intrinsic originating branch, so membership and metadata are verified explicitly.

The title identifies the patch, for example **v0.1.11-alpha.retail.1 — Retail PTR 12.1.7**. Once built, the manifest pins this target even if the branch later advances or is deleted. PTR alphas remain GitHub-only: storefront alpha stability support is not a guarantee of distinct PTR-client targeting.

When retiring a target, close its issue and delete the branch before detecting a new patch for that client. Closed issues remain version-specific tombstones, not permanent suppression of the reusable branch name. An existing active target blocks creating a second one; automation never force-pushes or silently retargets it. Delete obsolete drafts separately.

### Migrating existing compatibility branches

The old **Publish compatibility preview** workflow is removed. Before resuming automation, rename an active `compatibility/retail-<patch>` branch to `ptr/retail` (or the Forever equivalent) on GitHub and replace its issue marker with the corresponding `qwf-ptr` marker above. If several old candidates are open for one client, explicitly retire the others first. Automation fails with migration instructions instead of guessing which branch to replace.

Closed legacy issues remain patch-specific tombstones. Old published tags are not renamed; their verbose spelling is not accepted for new preparations. No remote branches or issues are renamed by these tooling changes themselves.

## Integrity, retries and failures

- Tag validation and build/test jobs have no storefront credentials. Trusted automation from the default branch plans/packages the candidate as data; publishing does not run scripts from the candidate checkout.
- Source and automation revisions are pinned during preparation. Annotated and lightweight tags are supported. Deleting a tag does not prepare a release.
- Storefront workflows re-fetch the published release, check its channel against the tag, resolve the tag's commit, and verify the manifest, packaged version, interface targets and ZIP SHA-256 before accessing storefront credentials.
- Storefront jobs use the reviewed ZIP, not a rebuilt package or the current source TOC. Unknown/ambiguous catalog versions fail rather than selecting a "nearest" version.
- Preparation can resume an incomplete draft by attaching missing assets. Existing assets and edited release notes are never overwritten. A moved tag, changed asset, or mismatched channel fails closed.
- Prefer **Re-run failed jobs** so preparation reuses its original package artifact. Rebuilding an entire run can produce a different ZIP checksum and intentionally will not replace an existing draft asset.
- Storefront publication is not atomic. Each storefront has a separate run and concurrency lock. There are no automatic retries of upload POSTs: if an upload fails or times out, inspect the storefront before rerunning because it may already have accepted the file. Reconcile uncertain uploads manually rather than blindly retrying or moving a tag.
- Older releases without a `release-plan.json` asset cannot use the new verified storefront path automatically.

Protect release tags and restrict publication to trusted maintainers. A tag push is a preparation request; clicking **Publish release** is the final public-distribution decision.
