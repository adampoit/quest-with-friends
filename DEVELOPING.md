# Developing Quest With Friends

[`src/Load.xml`](src/Load.xml) defines the load order for both addon manifests. The runtime uses the WoW addon namespace rather than `require`.

## Runtime boundaries

- [`QuestWithFriends.lua`](src/QuestWithFriends.lua) connects WoW events and APIs to the modules. It scans local quests and builds the inputs to the comparison and panel.
- [`sync/Sync.lua`](src/sync/Sync.lua) is the sync engine's public entry point. It owns batching and coordinates sender and peer state; the addon doesn't drive either one directly.
- [`Core.lua`](src/Core.lua) compares and sorts quest data without depending on the game's event or transport APIs.
- [`sync/Sender.lua`](src/sync/Sender.lua) owns the outbound queue, fragment pacing, retries, and the last fully submitted state. It reads current snapshot content and submits messages through injected functions.
- [`sync/Peers.lua`](src/sync/Peers.lua) owns incoming fragment assembly, committed peer snapshots, freshness, and repair decisions. The sender asks for eligible repairs at send time so recovery or a roster change can cancel a pending request.
- [`sync/SnapshotCodec.lua`](src/sync/SnapshotCodec.lua) validates and decodes full snapshots. [`sync/State.lua`](src/sync/State.lua) uses the exact validated quest record bytes for digests and partial updates; re-encoding the decoded quests would lose unknown extensions.

## Using the sync engine

Create a `QWF.Sync.new` instance with `now`, `after`, `send`, and `getLocalQuests`. `after` must defer callbacks, and `send` returns whether the transport accepted the message for submission. Supply a fresh 32-character lowercase hex `session` for protocol 1.2 and up. Protocol minor and snapshot limits are fixed per instance.

`getLocalQuests()` returns the required quest map. The optional `offerOptionalQuests(selected, offer)` hook can propose extra records in priority order, for example relevant completion history. Call `offer(id, quest)` to add a record if it fits the wire limits and does not replace an existing quest. Accepted records appear immediately in `selected`, which the hook can consult but must not edit directly. The required quests are never trimmed.

- `setRoster(members, connections, grouped, trigger)` takes ordered `{ key = ... }` entries and a key-to-connected map. Membership and connectivity changes automatically trigger synchronization. `refresh(trigger)` explicitly requests full snapshots.
- `localChanged(trigger)` queues an update. The optional `prepareLocal(trigger, batched)` hook lets the host rescan locally before batching or submitting, without putting WoW APIs in the engine.
- `receive(key, message)` accepts a message after the host verifies the channel and normalizes the sender key. `peer(key)` returns status, connectivity, and the last committed quests, with no transfer state. Treat the quest tables as read-only; the engine replaces them rather than mutating a prior snapshot. `diagnostics()` and `peerDiagnostics(key)` return detached summaries for tooling.

Keep quest scans and panel rendering out of the sync modules. See [PROTOCOL.md](PROTOCOL.md) for wire compatibility and ordering rules.

## Checks

Run `busted tests/unit/sync -v` for the [engine, state, and snapshot codec tests](tests/unit/sync), which do not load the addon runtime. Run `busted tests -v` for the full Lua suite, including the [multi-client harness](tests/support/sync_network.lua), which exercises the runtime with simulated time, transport, and reloads. Both commands use Lua 5.1-compatible tooling.

Run `python3 -m unittest discover -s tools/tests` for the tooling tests. The [CI workflow](.github/workflows/test.yml) also tests both manifests in the UI simulator.

For release packaging and publishing, see [tools/RELEASING.md](tools/RELEASING.md).
