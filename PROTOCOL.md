# Quest With Friends protocol 1.0

Protocol versions are independent of addon release versions. The addon sends protocol **1.0** using the `QWF` addon prefix and `PARTY` channel. Readers accept any supported **major** version regardless of its minor version, validating and skipping unknown optional extensions. There is no negotiation or fallback to unversioned or integer-version development formats.

## Compatibility rules

- **Major:** selects the required schema and baseline semantics. Changing existing fields, meanings, states, categories, encoding, or limits requires a major bump.
- **Minor:** introduces optional extension tags or optional message kinds. Missing or unknown additions must not prevent baseline synchronization or change its meaning. Added features fall back to baseline behavior when their data is absent.
- Major and minor components are canonical decimal integers: major 1–999, minor 0–999. Leading zeroes, signs, fractions, and exponent forms are invalid.
- Protocol 1.0 has no defined extension tags. Normal addon snapshots emit empty extension sections. The generic codec can serialize extension maps, but the 1.0 reader validates and discards every extension value.
- Unknown message kinds within a supported major are ignored. Extensions do not replace required fields or relax their validation. Extension names retain their meaning within a major and must not be repurposed.

## Message envelopes

```text
1.0:H
1.0:X
1.0:D:<revision>:<part>:<total>:<payload fragment>
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
2. Protocol minor: `0` for this release; higher minors are accepted.
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
   - Quest extension block: one length-prefixed field, empty in 1.0.
5. Snapshot extension block: one length-prefixed field, empty in 1.0.

Numeric values contain decimal digits only; signed, fractional, and exponent forms are invalid. Version components additionally require canonical spelling. The complete payload is limited to **22,000 bytes**. An empty 1.0 snapshot encodes as `1:11:01:00:`.

Categories belong to this snapshot revision. A later empty category removes the previous classification, and removing a quest also removes its remote classification. There are no separate category messages.

## Optional extension blocks

Both extension scopes use the same format. The outer field's byte length delimits a sequence of length-prefixed **tag, value** pairs; there is no separate entry count:

```text
<block byte length>:<tag byte length>:<tag><value byte length>:<value>...
```

For example, the hypothetical tag `chain_id` with value `123` produces `15:8:chain_id3:123`. This is illustrative, not a defined 1.0 feature.

- Each block is limited to 1,024 bytes and 32 entries.
- Tags contain 1–32 ASCII bytes and match `[a-z][a-z0-9_]*`.
- Values are opaque strings containing 0–512 bytes. Future tag definitions specify their value schemas; no type is inferred by older readers.
- Tags are unique within each block; the same tag may appear in different scopes.
- Encoders sort tags for deterministic output. Readers validate structure, bounds, and uniqueness even for unknown tags, then skip unknown values.
- Empty blocks are `0:` and are required even when there are no extensions.

An invalid extension invalidates the whole snapshot. A valid unknown extension does not alter baseline quest state, classifications, comparisons, or completeness. Dropping unknown extensions is intentional: older readers do not preserve or retransmit them.

## Delivery and recovery

Messages are paced at 0.5-second intervals. Failed API submissions retry the same message with 1–8-second exponential backoff. At most one newer snapshot is queued behind an active snapshot; intermediate changes coalesce.

A peer awaiting a snapshot is checked for assembly progress every 15 seconds. Lack of progress requests a new snapshot, with recovery intervals backing off to 60 seconds. Cached data remains labeled refreshing or stale, and does not count as a complete party status. Leaving the party cancels sends and recovery work.

Successful API submission is not an acknowledgement of delivery. Missing fragments are recovered through the watchdog; this protocol has no per-fragment acknowledgements or heartbeat for otherwise idle peers.
