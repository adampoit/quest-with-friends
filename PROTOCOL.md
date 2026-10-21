# Quest With Friends protocol 1.1

Protocol versions are independent of addon release versions. The addon sends protocol **1.1** using the `QWF` addon prefix and `PARTY` channel. Readers accept any supported **major** version regardless of its minor version, validating and skipping unknown optional extensions. There is no negotiation or fallback to unversioned or integer-version development formats.

## Compatibility rules

- **Major:** selects the required schema and baseline semantics. Changing existing fields, meanings, states, categories, encoding, or limits requires a major bump.
- **Minor:** introduces optional extension tags or optional message kinds. Missing or unknown additions must not prevent baseline synchronization or change its meaning. Added features fall back to baseline behavior when their data is absent.
- Major and minor components are canonical decimal integers: major 1–999, minor 0–999. Leading zeroes, signs, fractions, and exponent forms are invalid.
- Protocol 1.0 has no defined extension tags; its reader validates and discards every extension value. Protocol 1.1 adds the optional quest-level `item_stock` tag. Older peers retain baseline comparisons without spare-item rows.
- Unknown message kinds within a supported major are ignored. Extensions do not replace required fields or relax their validation. Extension names retain their meaning within a major and must not be repurposed.

## Message envelopes

```text
1.1:H
1.1:X
1.1:D:<revision>:<part>:<total>:<payload fragment>
```

The `major.minor` marker prefixes every message. For example, a 1.0 reader accepts `1.7:H` and baseline snapshots from `1.7:D:...`, but rejects major 2.

- `H`: request a fresh snapshot and announce synchronization, including after reload. Senders also queue their own snapshot. Refreshing preserves cached data and in-progress assembly. A refresh permits revision counters to restart after a peer reloads.
- `X`: the sender's snapshot exceeds the size limit. Recipients show an oversized warning instead of claiming synchronization.
- `D`: one fragment of a complete snapshot. Revision counters start at 1 and increase during the sender's login. Parts are 1-based; reverse-order delivery and identical duplicates are supported.

Revisions are decimal integers from 1 to 100,000,000, with at most 9 digits. Part and total fields contain at most 3 digits; `1 <= part <= total <= 100`. Each fragment contains 1–220 bytes. Complete messages must not exceed WoW's 255-byte limit, including the version marker.

Fragments from different revisions or version markers are never combined. A newer revision replaces incomplete older assembly. Quest data, classifications, and optional data belong to one revision and are applied only after all fragments arrive and the entire payload validates. Invalid payloads do not replace cached snapshots. The payload's major and minor must exactly match the assembled envelope version.

A missing or malformed version envelope, or an unsupported major, produces an incompatible-protocol notice and stops that peer's recovery watchdog. Messages with a valid supported-major envelope but unknown kinds or malformed bodies are ignored. Receiving valid supported-major data permits synchronization to resume.

## Snapshot payload

Every field is encoded as:

```text
<byte length>:<value>
```

Lengths count bytes, not Unicode characters. Empty values are `0:`. Colons, pipes, and UTF-8 text require no escaping because fields are length-prefixed. Payloads have no undeclared trailing fields or data.

Fields, in order:

1. Protocol major: `1`.
2. Protocol minor: `1` for this release; older and higher minors are accepted.
3. Quest count: 0–500.
4. For each quest, sorted by actual quest ID:
   - Quest ID: 1–100,000,000; duplicates are invalid.
   - Title: up to 300 bytes.
   - State: `active`, `ready`, or `completed`.
   - UI map ID: 0–100,000,000; 0 means unknown.
   - Category: empty (unclassified), `profession`, or `class`.
   - Objective count: 0–30.
   - For each objective, in quest-log order:
     - Text: up to 500 bytes.
     - Fulfilled count: 0–100,000,000.
     - Required count: 0–100,000,000.
   - Quest extension block: one length-prefixed field; optionally contains `item_stock` in 1.1.
5. Snapshot extension block: one length-prefixed field, empty in 1.0 and 1.1.

Numeric values contain decimal digits only; signed, fractional, and exponent forms are invalid. Version components additionally require canonical spelling. The complete payload is limited to **22,000 bytes**. An empty 1.1 snapshot encodes as `1:11:11:00:`; the 1.0 encoding `1:11:01:00:` remains accepted.

Categories belong to this snapshot revision. A later empty category removes the previous classification, and removing a quest also removes its remote classification. There are no separate category messages.

## Optional extension blocks

Both extension scopes use the same format. The outer field's byte length delimits a sequence of length-prefixed **tag, value** pairs; there is no separate entry count:

```text
<block byte length>:<tag byte length>:<tag><value byte length>:<value>...
```

For example, the hypothetical tag `chain_id` with value `123` produces `15:8:chain_id3:123`. This is illustrative, not a defined feature.

- Each block is limited to 1,024 bytes and 32 entries.
- Tags contain 1–32 ASCII bytes and match `[a-z][a-z0-9_]*`.
- Values are opaque strings containing 0–512 bytes. Future tag definitions specify their value schemas; no type is inferred by older readers.
- Tags are unique within each block; the same tag may appear in different scopes.
- Encoders sort tags for deterministic output. Readers validate structure, bounds, and uniqueness even for unknown tags, then skip unknown values.
- Empty blocks are `0:` and are required even when there are no extensions.

An invalid extension invalidates the whole snapshot. A valid unknown extension does not alter baseline quest state, classifications, comparisons, or completeness. Dropping unknown extensions is intentional: older readers do not preserve or retransmit them.

### Quest extension: `item_stock` (1.1)

The value is a sequence of length-prefixed triples, without a header or count:

```text
<objective index><item ID><spare count>...
```

Indices are 1-based positions in the baseline objective array, strictly increasing and unique. Each index must exist and have a positive required count. Item IDs are 1–100,000,000; spare counts are 0–100,000,000. Positive spare counts require baseline fulfilled >= required. Malformed triples reject the entire snapshot. The tag is interpreted only when the snapshot and reader support minor 1 or later. Baseline objective counts and states remain unchanged.

An entry identifies a conservatively matched, never-binding carried item. The spare count excludes bound/locked stacks and reserves the full quantities needed by all matching logged item objectives, including filtered quests. Inventory is scanned only in equipped bags, not banks. Senders match an item objective's normalized text exactly to a unique carried item name and require its capped objective progress to agree with carried stock. Uncached, ambiguous or mismatched data has no entry; this name-based association is not a quest-API-provided item identity. Missing inventory APIs also omit this feature.

The 512-byte value limit applies. Senders include entries in objective order and omit later entries that do not fit, preserving the complete baseline objective array. No entry means unknown, not zero spare; an explicit zero identifies a matched item without any confirmed spare stock. On receipt, a complete snapshot replaces all prior stock metadata atomically.

Show a finished holder's objective only while a comparable member still needs it. Targets must agree; cross-ID variants additionally require both item IDs to match, and state-only variants never gain item rows. Known conflicting item IDs are not compared for stock. Finished item progress is capped for presentation, with ` · N spare` appended only for positive spare counts. Ready/completed state labels remain distinct. For quests turned in during this session, senders may retain baseline objective positions and fulfilled targets, reusing only locally verified item identities from before turn-in. They rescan carried inventory on every refresh and reserve only currently logged requirements, not consumed completed requirements. Completed holders show item rows only for positive spare counts. Historical completion flags alone never supply item identities or stock; retained objectives are session-only and bounded by the recent-completion cache. Stock alone does not create an out-of-sync quest group when everyone is caught up.

## Delivery and recovery

Messages are paced at 0.5-second intervals. Failed API submissions retry with 1–8-second exponential backoff. At most one newer snapshot is queued behind an active snapshot; intermediate changes coalesce.

Before the first successful chunk submission, routine snapshots are checked against the latest local event scan. Obsolete unsent revisions are discarded; the pending coalesced refresh queues the latest state. An unsent routine copy of the last fully submitted payload is also suppressed. This check includes retries of a rejected first chunk. Once any chunk succeeds, that revision finishes unchanged, including retries of the same message. Explicit refresh/recovery obligations are preserved, including requests absorbed by an already-queued routine snapshot. No wire format or version changes are involved.

A peer awaiting a snapshot is checked for assembly progress every 15 seconds. Lack of progress requests a new snapshot, with recovery intervals backing off to 60 seconds. Routine snapshots received while cached data is healthy use a quiet updating indicator, retaining the last-known comparison without inserting connection notices. Pending snapshots still do not count as fully current internally. Initial loading, explicit refreshes, roster/reconnect recovery, invalid snapshots, and stalled transfers retain prominent waiting, refreshing or stale notices. Cached data remains comparable until a complete valid snapshot replaces it. Leaving the party cancels sends and recovery work.

Successful API submission is not an acknowledgement of delivery. Missing fragments are recovered through the watchdog; this protocol has no per-fragment acknowledgements or heartbeat for otherwise idle peers.
