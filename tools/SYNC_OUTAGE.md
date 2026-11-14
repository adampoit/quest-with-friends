# Four-player Forever outage reproduction

Run from the repository root; no game client, saved account data or upstream quest database is required:

```sh
luajit tools/reproduce_sync_outage.lua
luajit tools/reproduce_sync_outage.lua combined
busted tests/unit/sync_outage_spec.lua tests/unit/heartbeat_repair_spec.lua -v
```

The four isolated protocol-1.3 clients execute the production runtime through `tests/support/sync_network.lua`. The fixture has 16 synthetic quests per player, producing 12-chunk full baselines. Sessions and heartbeat phases are deterministic. Native bit operations are used when available, with the runtime's arithmetic fallback otherwise.

## Fault sequence

After 60 simulated seconds of startup/settling, each variant follows the same windows:

| Phase       | Duration    | Disconnect fault                                                                      | Throttle fault                                                                |
| ----------- | ----------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `silent`    | 110 s       | Drop every message to/from client 4, but keep it reported connected                   | Starting 40 s into the phase, reject alternating send attempts on clients 1–3 |
| `offline`   | 50 s        | Report client 4 offline to clients 1–3 using `UNIT_CONNECTION`; keep dropping traffic | Continue alternating rejections                                               |
| `reconnect` | 30 s        | Restore delivery/connectivity and restart client 4 with a fresh runtime/session       | Continue alternating rejections                                               |
| `drain`     | Up to 120 s | No fault                                                                              | Remove rejections; stop advancing once current                                |
| `update`    | 10 s        | Change one quest on client 1                                                          | No fault                                                                      |
| `idle`      | 120 s       | No quest changes                                                                      | No fault                                                                      |

`disconnect` applies only the disconnect column, `throttle` only the throttle column, and `combined` both. Phase labels in the throttle-only control describe time windows, not actual connection changes. All variants change one quest title on every player at the start of `reconnect`, so convergence requires newly delivered data rather than merely matching old caches.

The isolated client's timers continue behind the partition until its restart. Reloading preserves its quest log and saved settings, creates a new addon environment, and invalidates callbacks from the previous environment. Messages already submitted to the mock transport can still arrive.

## Measurements and current result

The command reports each client's completed full/partial snapshots, unchanged full snapshots, successfully submitted broadcast refresh requests (`requests`) and targeted requests (`repairs`), rejected API calls, refresh-status transitions for peers **other than client 4**, and snapshot timeouts. These are application-level counts, not Blizzard network-byte measurements.

Before/after measurements use the same fault windows and synthetic quest workload:

| Variant         | Unchanged full snapshots from clients 1–3 during `silent`, before → after | Fresh-data convergence after restore/update, before → after |
| --------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Disconnect only | 24 → 0                                                                    | 8.00 → 7.00 s                                               |
| Throttle only   | 0 → 0                                                                     | 4.20 → 2.70 s                                               |
| Combined        | 4 → 0                                                                     | 36.00 → 23.50 s                                             |

The before measurements used protocol 1.2, before the recovery redesign. The after measurements use protocol 1.3: silence only marks cached data stale, and state advertisements replace redundant periodic capability announcements. No client sends a snapshot, broadcast/targeted repair request, or refreshing transition during `silent`. Once WoW reports the offline/reconnect roster change, normal bounded baseline synchronization still runs.

The combined before case completed fewer retransmissions during silence because many chunk attempts were rejected, not because it was more efficient. Its throttle fault persists for the first 30 seconds after reconnect in both runs.

**Silence alone reproduced party-wide refresh amplification; the new freshness policy eliminates that cascade.** Separate lost-update tests verify that a newer returning heartbeat still repairs genuinely missed data: only the explicitly capable source responds to a targeted request. Mixed-version tests retain broadcast fallback without inferring capability from version numbers.

All three variants eventually converge, accept a subsequent partial update without a full snapshot, and remain current during the final idle phase with no further snapshots or repair/refresh requests. Normal state announcements continue. Cached comparisons remain visible during silence and the disconnected peer receives distinct stale/offline notices.

Automated assertions now require zero repair/snapshot traffic during silence and bounded reconnect traffic, while retaining convergence, cached-data, partial-resumption and idle checks. Additional coverage tests targeted-response coalescing, 15/30/60-second repair backoff, cancellation, incomplete transfers, explicit refresh obligations, metadata size limits and legacy fallback on both clients.

## Limits

This is a controlled fault experiment inspired by the play-session logs, **not an exact replay or proof of the original disconnect's cause**. It does not model WoW frame stalls, combat lockdown, packet buffering or competing addons. Alternating API rejections are externally injected; the harness does not model Blizzard's throttle/token budget and therefore cannot establish whether recovery traffic itself caused tonight's throttling. Synthetic timings are not live-client latency guarantees.
