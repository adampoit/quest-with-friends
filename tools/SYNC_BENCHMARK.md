# Four-player synchronization benchmark: scheduling adjustments

**Historical measurements:** these runs predate removal of scheduled full checkpoints. The idle and five-minute results below include those checkpoints; they do not describe the current runtime's maintenance traffic. The recorded runtime checksum identifies the measured version.

Measured 2026-11-12 on Apple M3 Pro / macOS 26.6.2 / LuaJIT 2.1.1785763465, **JIT disabled**, native bit operations. CPU figures are medians of five runs. Both protocol modes use the new scheduler; the historical baseline uses the scheduler from `6763772acd7c3e9092377d51f2c8db613fde0b85`.

**Ordinary 1.2 update latency fell from 1.30 seconds to 0.20 seconds. Continuous updates now send throughout activity rather than waiting for it to stop.**

## What changed

- A fixed **200 ms batching window**, down from 800 ms. Additional events do not restart it; local scans and rendering remain immediate.
- **No extra idle-send delay.** The sender uses its next eligible slot rather than always waiting another 500 ms after queueing.
- A shared **500 ms pacing budget for all message kinds**, including handshakes and heartbeats. New work cannot bypass an existing retry deadline.
- When an unsent routine snapshot becomes outdated, replace it with the latest scanned state **at the already-scheduled send opportunity**. Do not start another batching/pacing cycle. Once any fragment succeeds, that transfer remains immutable.
- Explicit full refresh obligations, compatibility fallback and 1–8-second exponential retry backoff are retained.

These are scheduling changes, not wire-format changes. See [PROTOCOL.md](../PROTOCOL.md#delivery-and-recovery).

## Same four-player workload

Each player has **20 logged quests plus the maximum 30 retained turn-ins**, populated through actual quest-turn-in handlers. Thirty is the addon's history limit, not the game's quest-log limit. The logs contain 33 active-log objectives and 17 retained objectives. Initial full payloads are 3,634–3,662 bytes before transport envelopes and 1.2 state metadata.

Quest IDs, titles and target names come from [QuestieDB e0a6eaa86f181ac99262e34126bcd2ed1a1712d6](https://github.com/Questie/QuestieDB/tree/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6), including Westfall and Redridge quests. Progress, inventories, binding information and map IDs are modeled, not live-client captures. The fixture is unchanged between measurements. The [baseline report](benchmarks/sync-baseline.md) documents the source extraction and model assumptions in detail.

The actual runtime executes in four isolated environments. 1.1 is the current shared runtime in full-only mode, not a historical release binary. Virtual latency includes real scheduler/fragmentation decisions, but does not advance with host CPU processing. Default link delay is zero; a separate 50 ms one-way run is shown below. API throttling/loss is not injected in benchmarks; recovery tests cover those separately.

**CPU is host-measured addon callback time summed over all four clients**, not one machine or a live WoW frame. Categories are exclusive. Comparison and render preparation execute, but actual panel widgets/GPU, real game API costs and Blizzard transport behavior are excluded. Setup, simulated transport dispatch and verification are excluded; instrumentation and normal garbage-collection effects remain. Treat small CPU differences as noise, not a claimed optimization.

Application bytes include message bodies and application headers, excluding the `QWF` registration prefix and Blizzard framing. Each `PARTY` broadcast is counted once; four independent sender queues operate concurrently. Startup and final-drain times are polled at 50 ms granularity; ordinary update receipts are observed at exact callback times.

## Ordinary one-objective update

One player updates one objective after the party has synchronized:

| Timing stage                     | Previous 1.1 | Adjusted 1.1 | Previous 1.2 | Adjusted 1.2 |
| -------------------------------- | -----------: | -----------: | -----------: | -----------: |
| Fixed batching                   |       0.80 s |       0.20 s |       0.80 s |       0.20 s |
| Initial idle-send wait           |       0.50 s |            0 |       0.50 s |            0 |
| Remaining paced fragments        |       8.00 s |       8.00 s |            0 |            0 |
| **All three recipients updated** |   **9.30 s** |   **8.20 s** |   **1.30 s** |   **0.20 s** |
| Messages                         |       17 `D` |       17 `D` |        1 `P` |        1 `P` |
| Application bytes                |        3,880 |        3,880 |          214 |          214 |

With **50 ms one-way link delay**, adjusted totals are **8.25 seconds versus 0.25 seconds**. Real timer/frame quantization, API costs, competing addon traffic and network variability are additional unknowns.

If all four players update simultaneously, elapsed time is still **8.20 seconds versus 0.20 seconds**, not four times longer. Party-wide traffic is **68 full fragments / 15,514 bytes** versus **4 partial messages / 856 bytes**.

## CPU: one player updates, three peers receive

| Exclusive CPU stage, all four clients    | Adjusted 1.1 | Adjusted 1.2 |
| ---------------------------------------- | -----------: | -----------: |
| Scan, inventory annotation, activity     |     0.191 ms |     0.240 ms |
| Encoding                                 |     0.178 ms |     0.244 ms |
| SHA-256/128                              |     0.000 ms |    14.757 ms |
| Decode, validation, patch/state assembly |     0.405 ms |     1.057 ms |
| Comparison and render preparation        |    18.077 ms |     2.653 ms |
| Queueing, fragmentation, send glue       |     0.161 ms |     0.038 ms |
| Other event/timer work                   |     0.367 ms |     0.079 ms |
| **Total median**                         | **19.60 ms** | **19.16 ms** |

Component medians need not sum to the independently calculated total median. The earlier totals were 19.27 ms and 18.85 ms: CPU is approximately unchanged. This change removes scheduled waiting, not hashing or receiver work. With all four players updating, adjusted aggregate CPU is **78.19 ms / 74.05 ms** for 1.1 / 1.2.

The adjusted 1.2 one-player total is distributed approximately as **6.29 ms on the sender** and **4.2–4.3 ms on each recipient**. The seven digest calls comprise one sender digest, then two per recipient: the small changes payload and reconstructed full candidate. Partial updates concentrate work into fewer callbacks; full updates distribute comparison work across fragment arrivals. Live frame-cost profiling remains important.

For simultaneous four-player changes, about **17.8–18.4 ms per client** falls at the same virtual timestamp, versus **1.9–2.1 ms** for a full-snapshot fragment wave. Removing the idle delay can bunch sender hashing and incoming work more closely even when aggregate CPU is unchanged. This is not a measured game frame—real timer scheduling and network delivery may distribute the work differently—but it is an important live-client profiling follow-up.

A separate three-run arithmetic-only digest test raises the adjusted 1.2 total to **129.41 ms**, versus **19.16 ms** with native bits. The benchmark explicitly installs native bit functions in isolated client globals because `Sync.lua` uses `rawget`; inheriting the host globals alone would silently benchmark the portable fallback.

## Other latency scenarios

| Scenario                                        | Previous 1.1 | Adjusted 1.1 | Previous 1.2 | Adjusted 1.2 |
| ----------------------------------------------- | -----------: | -----------: | -----------: | -----------: |
| Cold party join                                 |      ~9.35 s |      ~8.55 s |     ~11.00 s |     ~10.50 s |
| Four players, four changed quests each          |       9.30 s |       8.20 s |       2.80 s |       1.70 s |
| One update during an already-running checkpoint |      15.30 s |      14.50 s |       1.50 s |       0.50 s |
| Five-minute questing: median batch latency      |       9.30 s |       8.20 s |       1.80 s |       0.70 s |

The checkpoint row measures receipt of the new update, not completion of every outstanding transfer. Cold joins still require full snapshots and capability discovery. With three adjusted 1.2 clients and one 1.1 client, ordinary updates correctly fall back to **68 full fragments / 15,763 bytes / 8.20 seconds**.

## Five minutes of questing, after initial synchronization

One unfinished objective advances per player every ten seconds: **30 batches / 120 player updates**, without wrapping counters. Maintenance/checkpoints are included, initial party join is excluded.

| Total over 300 seconds | Previous 1.1 | Adjusted 1.1 | Previous 1.2 | Adjusted 1.2 |
| ---------------------- | -----------: | -----------: | -----------: | -----------: |
| Messages               |        2,040 |        2,040 |          394 |          398 |
| Application bytes      |      467,010 |      467,010 |       53,231 |       53,758 |
| Aggregate callback CPU |      2.759 s |      2.599 s |      2.463 s |      2.410 s |

Adjusted 1.2 sends **177 partial fragments, 69 full fragments, 76 capability messages and 76 heartbeats**. It uses **88.5% fewer bytes** than adjusted 1.1; scheduling changes do not materially increase ordinary workload traffic or CPU.

All 30 batches converge during their intervals. Adjusted 1.2 batch latency ranges from **0.20 to 1.70 seconds**, median **0.70 seconds**, versus a previous range of 1.30–10.00 seconds. This is a measured workload result, **not a universal latency guarantee**: an update coalescing into a forced, not-yet-started full checkpoint can still inherit its full-send obligation. Checkpoint obligation handling was not redesigned by these adjustments.

Idle maintenance is unchanged: over five minutes adjusted 1.2 sends **24,980 bytes** and uses **152.13 ms aggregate callback CPU**, while 1.1 sends nothing. The 1.2 idle traffic includes capability/heartbeat announcements and a full checkpoint.

## Continuous-update regression: resolved send starvation

The stress workload changes one bounded objective counter per player every second for **61 seconds**. The last event occurs at second 60. Counter wrapping is deliberate synthetic churn, not a validated leveling route.

| Observation                            | Previous 1.1 | Adjusted 1.1 | Previous 1.2 |             Adjusted 1.2 |
| -------------------------------------- | -----------: | -----------: | -----------: | -----------------------: |
| First data send                        |      61.30 s |       0.20 s |      61.30 s |                   0.20 s |
| Data messages sent during the workload |            0 |          488 |            0 |                      244 |
| Final convergence, including drain     |     ~69.35 s |     ~76.25 s |     ~61.35 s | 61.00 s; already current |

**Adjusted 1.2 delivers all 61 four-player batches within 0.20–0.70 seconds of their events**, median 0.20 seconds. It sends **244 partial messages**, plus 16 capability messages and 16 heartbeats: **54,900 bytes total**. Aggregate CPU is **4.606 seconds** over the full 61-second workload, versus 1.372 seconds previously. The increase is expected: recipients now process 244 real updates instead of receiving almost nothing until the end.

Adjusted 1.1 also makes continuous send progress, but its immutable large transfers cannot keep up with one change per second. It skips intermediate states and may need to finish an older active snapshot before sending the final queued state. This makes the final drain longer than the old starved behavior, despite providing intermediate data throughout the run. The 1.2 path removes that bandwidth bottleneck for this workload.

Some old cached values happen to match a cycling counter. The benchmark's `cached_state_matched_before_next_batch` is therefore not by itself proof of delivered stress updates; actual send counts and first-send times establish the regression fix.

## Reproduction and evidence

See [README.md](README.md#synchronization-benchmark) for extraction and run commands. No upstream dataset is vendored.

- [Before measurements](benchmarks/sync-questiedb-before.json), [after measurements](benchmarks/sync-questiedb-summary.json), and the [full baseline report](benchmarks/sync-baseline.md).
- Fixture SHA-256: `b2cf0a978fa47237a48b40dd0311e5033ef2c3cea56b919e6caa3aeb087f77df`.
- The after summary records the exact production runtime SHA-256, avoiding a self-referential commit ID in generated results.
- Full local evidence: `.cache/benchmark-source/before-results.json`, `after-results.json`, `after-portable.json`, `after-latency50.json`.
- Regression coverage includes fixed batching deadlines, immediate eligible sends, stale queue replacement without postponement, continuous events faster than batching/pacing, shared control/data pacing, retry backoff, and immutable started full/partial transfers on both Retail and Forever.
