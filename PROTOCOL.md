# Quest With Friends protocol 1.3

Protocol versions are independent of addon release versions. The addon sends protocol **1.3** using the `QWF` addon prefix and `PARTY` channel. Readers accept any supported **major** version regardless of its minor version, validating and skipping unknown optional extensions. Optional capabilities are discovered independently; peers do not negotiate a lowest shared minor version. There is no fallback to unversioned or integer-version development formats.

## Compatibility rules

- **Major:** selects the required schema and baseline semantics. Changing existing fields, meanings, states, categories, encoding, or limits requires a major bump.
- **Minor:** introduces optional extension tags or optional message kinds. Missing or unknown additions must not prevent baseline synchronization or change its meaning. Added features fall back to baseline behavior when their data is absent.
- Major and minor components are canonical decimal integers: major 1–999, minor 0–999. Leading zeroes, signs, fractions, and exponent forms are invalid.
- Protocol 1.0 has no defined extension tags; its reader validates and discards every extension value. Protocol 1.1 adds the optional quest-level `item_stock` tag. Protocol 1.2 adds optional `q1` partial synchronization and the snapshot-level `sync` tag. Protocol 1.3 adds optional `r1` targeted repair through the snapshot-level `repair` tag and `R` message. Older peers retain baseline comparisons, skipping extensions and message kinds they do not understand.
- Unknown message kinds within a supported major are ignored. Extensions do not replace required fields or relax their validation. Extension names retain their meaning within a major and must not be repurposed.

## Message envelopes

```text
1.3:H
1.3:X
1.3:D:<revision>:<part>:<total>:<payload fragment>
1.3:C:<session>:q1
1.3:V:<state identity>
1.3:P:<revision>:<part>:<total>:<partial payload fragment>
1.3:R:<target session>
```

The `major.minor` marker prefixes every message. For example, a 1.0 reader accepts `1.7:H` and baseline snapshots from `1.7:D:...`, but rejects major 2.

- `H`: request a fresh snapshot and announce synchronization, including after reload. Senders also queue their own snapshot. Refreshing preserves cached data and in-progress assembly. A refresh permits revision counters to restart after a peer reloads.
- `X`: the sender's snapshot exceeds the size limit. Recipients show an oversized warning instead of claiming synchronization.
- `D`: one fragment of a complete snapshot. Revision counters start at 1 and increase during the sender's login. Parts are 1-based; reverse-order delivery and identical duplicates are supported.
- `C`, `V`, `P`: optional 1.2 messages, defined under **Partial synchronization** below. They do not change the meaning of `H`, `X`, or `D`.
- `R`: optional 1.3 request for a full snapshot from one explicitly capable session, defined under **Targeted repair** below. Other party members ignore it.

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
2. Protocol minor: `3` for this release; older and higher minors are accepted.
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
5. Snapshot extension block: one length-prefixed field, empty in 1.0 and 1.1; optionally contains `sync` in 1.2 and `repair` in 1.3.

Numeric values contain decimal digits only; signed, fractional, and exponent forms are invalid. Version components additionally require canonical spelling. The complete payload is limited to **22,000 bytes**. An empty 1.3 snapshot without extensions encodes as `1:11:31:00:`; the 1.0 encoding `1:11:01:00:`, 1.1 encoding `1:11:11:00:` and 1.2 encoding `1:11:21:00:` remain accepted.

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

## Partial synchronization (optional `q1`, 1.2)

### Capabilities and fallback

`C:<session>:q1` explicitly advertises support for this entire feature: guarded quest replacements, raw extension retention, state digests and recovery. A valid `V` or `sync` extension also explicitly establishes this capability. The session is 32 lowercase hexadecimal characters, generated afresh on addon startup. It distinguishes sequence counters across reloads; it is not authentication.

Routine partial updates are allowed only after the sender has fully submitted a tagged baseline and every connected roster member has recently advertised `q1` (within 45 seconds). Unknown and legacy recipients require ordinary full snapshots at the normal event-driven cadence. Offline members do not participate in capability selection; reconnects invalidate their capability and baseline knowledge. Roster changes require a fresh outgoing baseline. `PARTY` broadcasts reach every member; there is no recipient-specific transport or minor-version downgrade. Newer optional fields remain in full snapshots even in mixed-version parties.

Capability announcements are sent at startup/refresh and periodically when there is no published tagged state. Once published, periodic `V` advertisements establish capability without redundant periodic `C` messages. A new session invalidates that peer's partial-update base and retains its cached comparison; the progress watchdog allows its startup baseline to arrive before requesting repair. The last eight retired sessions are ignored. Baseline 1.0/1.1 reload announcements clear partial capability knowledge. A capability announcement alone never proves that a cached partial state is current.

### State identity and snapshot extension `sync`

An identity is three length-prefixed fields:

```text
<session><sequence><digest>
```

The sequence uses canonical decimal spelling, 1–100,000,000. It is the same number as the enclosing `D` or `P` revision. Unsent revisions may be coalesced, so gaps are legal. The digest is the first 128 bits of SHA-256, encoded as 32 lowercase hexadecimal characters. SHA-256 is implemented identically with native bit operations or portable Lua 5.1 arithmetic.

The optional snapshot extension `sync` contains this identity. An invalid identity, mismatched revision, or incorrect digest rejects the snapshot for a `q1` reader. Legacy readers skip the tag normally.

Digest input is the complete length-prefixed snapshot payload with `sync` removed: protocol fields, quest count, quest records sorted by actual ID, and the snapshot extension block with remaining tags sorted by name. Quest records retain their exact wire bytes, including objective order and unknown quest extensions. Unknown snapshot extension values are retained too. Receivers must not digest a baseline decode/re-encode: baseline decoding deliberately discards unknown extensions. Sender encodings are deterministic; transport headers, session, sequence and the digest itself are excluded.

If adding metadata would exceed the existing snapshot or extension limits, the sender retains ordinary untagged full-snapshot delivery rather than reducing baseline coverage or increasing limits. It cannot publish partial updates until a tagged baseline fits again. Such full-only states retain baseline recovery semantics; capability announcements establish presence but cannot verify their contents.

### Partial payload

`P` uses the same revision/fragment limits as `D`, with independent assembly. Its complete payload, at most 22,000 bytes, is this sequence of length-prefixed fields:

```text
<session>
<base sequence><base digest>
<result sequence><result digest>
<removal count><removed quest ID>...
<changed-quests snapshot payload>
```

- The result sequence must exceed the explicit base sequence and equal the envelope revision. It need not be `base + 1`.
- The session must match the established baseline session. The base sequence and digest must match the receiver's exact committed state.
- Removals contain 0–500 unique, strictly increasing canonical IDs, each present in the base. A removed ID cannot also be replaced.
- The changed-quests field is a normal snapshot payload whose version exactly matches the `P` envelope, without `sync`. Each included quest replaces its entire previous record or adds a new quest. Omitted quests remain unchanged. Replacement objectives and optional metadata replace, not merge with, previous values.
- Snapshot-level optional extensions in the changed-quests payload replace the previous snapshot extension set, including clearing absent tags.
- The reconstructed complete snapshot must satisfy all ordinary bounds and validation rules and match the result digest. No trailing fields or bytes are allowed.

Receivers validate against a candidate state and commit quests, metadata and identity atomically. Missing bases, corruption and conflicting duplicate fragments never mutate cached state. Already-committed revisions and retired-session traffic are ignored; invalid or inapplicable newer updates request full recovery. There are no arithmetic increments, replay buffers, acknowledgements or per-quest revision counters.

The sender selects the base when a transfer is about to start, from its newest fully submitted state—not from the last scan or queued target. It uses `P` only when smaller than a full snapshot. Failed submissions retry through the normal paced sender. Started transfers remain immutable.

### Heartbeats, recovery and ordering

`V:<state identity>` advertises the newest fully submitted state, even while idle. One periodic state advertisement (or capability-only announcement when no state is published) runs every 15–18 seconds, using session-derived jitter. A newer advertised state without matching assembly in progress, an equal-sequence digest mismatch, or missing baseline triggers peer repair. Older advertisements do not roll state backward.

For a tagged state, more than 45 seconds without a valid state advertisement, committed update or new transfer fragment marks cached data stale. **Silence alone sends no repair request or snapshot.** It cancels that peer's outstanding repair/watchdog work until communication resumes. Capability-only announcements do not verify a tagged state or reset this freshness deadline. They do prove contact: a live peer without state verification can undergo bounded repair, including when a full-only sender resumes capability announcements instead of state heartbeats. Detection runs on the periodic timer, so timeout notices can occur up to one timer interval later. Oversized and incompatible peers retain their distinct warnings.

A returning advertisement that exactly matches the cached session, sequence and digest restores current status without a snapshot, provided no assembly or explicit refresh obligation is outstanding. A different state is repaired; an incomplete assembly resumes progress monitoring. An explicit refresh still requires a snapshot, including after a silent interval.

Recovery retains cached comparisons and uses the peer-specific repair path below, falling back to `H` for peers without explicit support. Per-peer retries back off through 15, 30 and 60 seconds; successful state verification resets the backoff. Broadcast fallback requests additionally share a 15-second client-wide minimum interval. Queued requests coalesce and are canceled when the peer recovers, becomes silent/offline/incompatible/oversized, changes session or leaves. Transport submission failures retain the separate 1–8-second paced retry policy.

A subsequently valid exact-base partial can also establish a current state; it cancels local repair work but does not cancel a response already being transmitted by another client. Full snapshots remain mandatory for initial synchronization, explicit refresh and roster/reconnect recovery, and are used for repairs and ordinary full-only fallback. There are no scheduled full-snapshot checkpoints or periodic local rescans, including in mixed-version parties. Full snapshots have no delivery guarantee; retries, heartbeat checks and stale notices remain necessary.

Small partial transfers may interrupt a running full snapshot once a published base exists. The full transfer resumes unchanged, receiving at least one send opportunity between partial transfers so continuous updates cannot starve it. Receivers never let an older full snapshot overwrite a newer committed partial state. Sender publication likewise never rolls backward when a suspended full transfer finishes. Initial baselines still have to arrive before partial updates can apply.

These rules prevent silently applying a patch to the wrong base and eventually detect completely lost final updates while communication works. They cannot guarantee current data during a network outage, and digests have a theoretical collision risk.

## Targeted repair (optional `r1`, 1.3)

The snapshot extension `repair` with exact value `r1`, in a validated tagged snapshot with minor >= 3, explicitly advertises support for `R`. The capability belongs to that committed session/state and is preserved through partial updates like other snapshot extensions. Removing the tag or using another value disables selection of targeted repair. A version number alone, `C`, or `V` does not establish `r1`. Unknown values retain baseline behavior. The tag participates in the state digest; older `q1` readers retain it as an unknown extension. Senders omit it rather than make an otherwise valid baseline exceed the size limit.

`R:<target session>` contains exactly one 32-character lowercase hexadecimal session, with no trailing fields. It is sent on `PARTY` only after explicit support is known. Only the client whose current session matches the target handles it; wrong/retired sessions, malformed requests and envelopes below minor 3 are ignored. The sender must be a current roster peer, as with all messages.

The target queues its own full snapshot, coalescing an equivalent queued or active full transfer. Responses share a 15-second minimum interval across requesters, since the snapshot is broadcast to everyone. A requester that missed earlier fragments may need a later retry. Handling `R` does not clear the requester's capability, invalidate other peers' bases, mark other comparisons refreshing, or require the requester to transmit its own snapshot. Normal partial/full ordering and pacing still apply.

If support is absent, use the original `H` path, including the requester's own baseline and the recipients' normal full responses. This retains interoperability with 1.0–1.2 and future peers without `r1`; unchanged baseline message meanings require no major bump. Legacy binaries may still initiate broader recovery themselves.

## Delivery and recovery

Ordinary changes coalesce in a fixed 0.2-second window; subsequent events do not restart it. Local scans and rendering remain immediate. All message kinds share a send budget: the first message is eligible immediately when idle, and subsequent successful submissions are spaced at least 0.5 seconds apart. Failed API submissions retry with 1–8-second exponential backoff; newly queued data or control messages cannot shorten that retry deadline. At most one newer target state is queued behind an active transfer; intermediate changes coalesce. With `q1`, an interrupted full snapshot may additionally remain suspended behind a prioritized partial transfer.

Before the first successful chunk submission, routine snapshots are checked against the latest local event scan. Obsolete unsent revisions are replaced with the latest scanned state at the existing eligible send opportunity, without restarting batching or adding a fresh pacing delay. This guarantees send progress under continuous events, subject to transport eligibility, rather than waiting for activity to stop. An unsent routine copy of the last fully submitted payload is also suppressed. This check includes retries of a rejected first chunk. Once any chunk succeeds, that revision finishes unchanged, including retries of the same message. Explicit refresh/recovery obligations are preserved, including requests absorbed by an already-queued routine snapshot. No wire format or version changes are involved.

A peer awaiting a snapshot is initially checked for assembly progress after 15 seconds. Lack of progress requests peer repair, with recovery intervals backing off to 60 seconds; a silent tagged peer instead remains stale without requests until communication resumes. Routine snapshots received while cached data is healthy use a quiet updating indicator, retaining the last-known comparison without inserting connection notices. Pending snapshots still do not count as fully current internally. Initial loading, explicit refreshes, roster/reconnect recovery, invalid snapshots, and stalled transfers retain prominent waiting, refreshing or stale notices. Cached data remains comparable until a complete valid snapshot replaces it. Leaving the party cancels sends and recovery work.

Successful API submission is not an acknowledgement of delivery. Missing fragments are recovered through the watchdog; there are no per-fragment acknowledgements. Legacy peers retain baseline recovery without idle heartbeats; `q1` peers additionally use the state advertisements described above.
