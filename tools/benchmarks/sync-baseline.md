# Baseline: four-player synchronization benchmark

**Historical results before the scheduling changes.** See the [updated comparison](../SYNC_BENCHMARK.md).

Measured 2026-11-12 on Apple M3 Pro, macOS 26.6.2, LuaJIT 2.1.1785763465 **with JIT disabled** and native bit operations. CPU numbers are medians of five runs. Timing and byte counts were identical across those runs, apart from the documented 50 ms convergence polling granularity.

**Summary:** ordinary one-objective updates became **7.2× faster** and used **94.5% fewer application bytes**. Aggregate Lua CPU stayed roughly the same: fewer comparisons are offset by state hashing. Startup, idle traffic, burst behavior and checkpoints have different tradeoffs.

## Workload and measurement boundaries

- Four players, each with **20 logged quests plus 30 recently turned-in quests**. The 30 is this addon's retained-completion cache limit, not the game's quest-log limit. History is populated through actual `QUEST_TURNED_IN` handlers; it is not injected as live log entries.
- Real quest IDs, titles and objective targets from [QuestieDB revision e0a6eaa86f181ac99262e34126bcd2ed1a1712d6](https://github.com/Questie/QuestieDB/tree/e0a6eaa86f181ac99262e34126bcd2ed1a1712d6). Examples: The Killing Fields, The People's Militia, Westfall Stew, The Coast Isn't Clear, Redridge Goulash and Dry Times. The 30 retained entries come from Northshire/Elwynn progression.
- There are **33 objectives in the logged quests and 17 in retained history**. All four players share these IDs, with different progress. Initial full payloads are **3,634–3,662 bytes**, before transport envelopes and 1.2 identity metadata.
- Questie target rows do not provide client slot order or quantities. Active quantities are reviewed against source summaries; historical quantities use summary numbers or a one-unit fallback. Labels use source target names, with a synthesized NPC `slain` suffix. Progress, 80-slot inventories and binding information are modeled; six common materials can receive `item_stock` annotations. Source zone IDs stand in for numeric map IDs. These are representative synthetic logs, **not live-client captures or a validated character leveling route**. Source descriptions are not transmitted.
- The production runtime at `6763772acd7c3e9092377d51f2c8db613fde0b85` is executed in four isolated environments. It is run in 1.1/full-only mode and 1.2 mode with the **same** scan/comparison code. This compares protocol behavior, not historical release binaries.
- Actual coalescing, queue selection, 220-byte fragmentation, 0.5-second pacing, capability discovery, checkpoint scheduling and receiver assembly/application are exercised. No loss or API throttling is injected. Mixed-version fallback is tested separately.
- **Latency is virtual elapsed time** from event to all other peers holding the updated data. Default link delay is zero; 50 ms one-way is measured separately. Timers are ideal, not WoW frame-quantized. Startup/drain completion is polled every 50 ms; isolated update receipt is observed at exact callback times.
- **CPU is host-measured, exclusive addon callback time, summed across all four clients.** Nested categories are not double-counted. Test setup, verification, simulated transport dispatch and idle waiting are excluded. Instrumentation has overhead; comparisons and render preparation run, but actual panel widgets, rendering/GPU, real game API costs and Blizzard transport/server behavior do not. CPU is not added to or advanced through the virtual clock. Do not treat these as measured live-WoW milliseconds.
- Byte counts include message bodies and application envelopes, but exclude the `QWF` registration prefix and Blizzard framing. A `PARTY` broadcast is counted once, not three times for its recipients. Four independent send queues operate concurrently.

## Ordinary update: exact latency budget

One player changes one objective after initial synchronization:

| Stage                            |          1.1 full |         1.2 partial |
| -------------------------------- | ----------------: | ------------------: |
| Refresh coalescing               |            0.80 s |              0.80 s |
| Wait for first send              |            0.50 s |              0.50 s |
| Remaining paced fragments        | 8.00 s: 16 × 0.50 | 0: fits one message |
| Modeled one-way link delay       |                 0 |                   0 |
| **All three recipients updated** |        **9.30 s** |          **1.30 s** |
| Messages                         |            17 `D` |               1 `P` |
| Application bytes                |             3,880 |                 214 |

With **50 ms one-way link delay**, measured totals are **9.35 s versus 1.35 s**. Real frame scheduling, API throttling and network variability are additional unknowns.

Changing the same objective on **all four players at once** still takes 9.30 s versus 1.30 s, not four times longer. It sends **68 full fragments / 15,514 bytes** versus **4 partial messages / 856 bytes**.

## CPU budget for that one-player update

Milliseconds below include the sender and all three recipients; category medians need not sum exactly to the independently calculated total median.

| Exclusive CPU stage                      |          1.1 |          1.2 |
| ---------------------------------------- | -----------: | -----------: |
| Quest scan, bag annotation, activity     |        0.179 |        0.267 |
| Encoding                                 |        0.163 |        0.190 |
| SHA-256/128                              |            0 |       15.069 |
| Decode, validation, patch/state assembly |        0.347 |        1.118 |
| Comparison and render preparation        |       18.064 |        1.966 |
| Queue, fragmentation, send glue          |        0.187 |        0.037 |
| Other event/timer work                   |        0.359 |        0.100 |
| **Total across four clients**            | **19.27 ms** | **18.85 ms** |

Per machine, the sender spends about **1.36 → 5.35 ms**, while each recipient spends about **5.96 → 4.42 ms** in total. Full snapshots spread receiver work over 17 arrivals; the partial path concentrates it into one arrival. Its seven digest calls comprise one sender digest and two per recipient: the small replacement payload and reconstructed full candidate.

For simultaneous four-player changes, total CPU is **78.68 ms versus 78.40 ms**. In this idealized synchronized-arrival model, each 1.2 client can spend approximately **13–14 ms at one simulated instant** processing its three incoming updates, versus roughly 1.6–1.8 ms for a full-snapshot fragment wave. This is not a measured game frame, but makes live-client frame-cost profiling important.

A separate three-run arithmetic-only digest test raises the 1.2 one-player total from about **19 ms to 131 ms**. WoW-style native bit support is therefore important. The benchmark explicitly installs native bits in its isolated client globals; merely inheriting the host global would accidentally benchmark the portable fallback because `Sync.lua` uses `rawget`.

## Other scenarios

| Scenario                                        | 1.1 convergence | 1.2 convergence | 1.1 bytes | 1.2 bytes | Four-client CPU, 1.1 / 1.2 |
| ----------------------------------------------- | --------------: | --------------: | --------: | --------: | -------------------------: |
| Cold party join                                 |         ~9.35 s |        ~11.00 s |    15,534 |    16,228 |          33.00 / 105.13 ms |
| Four players, four changed quests each          |          9.30 s |          2.80 s |    15,525 |     2,895 |           81.59 / 95.67 ms |
| One update during an already-running checkpoint |         15.30 s |          1.50 s |    17,297 |     2,431 |           91.65 / 31.61 ms |
| Five minutes idle after joining                 |               — |               — |         0 |    24,980 |             ~0 / 156.17 ms |
| Five minutes questing after joining             |       see below |       see below |   467,010 |    53,231 |     2,758.58 / 2,462.53 ms |

Checkpoint-row bytes/CPU cover only the time from the new objective event until its receipt, not completion of every other outstanding transfer. Startup is intentionally full in both modes; 1.2 has discovery traffic and slightly larger snapshots. Idle 1.2 traffic includes capability/heartbeat broadcasts and a full checkpoint; it is not free.

The **five-minute questing** workload advances one unfinished objective per player every ten seconds: 30 batches / 120 player updates, without wrapping counters. It includes maintenance traffic and checkpoints:

- **1.1:** 2,040 full fragments; every batch converges in 9.30 s.
- **1.2:** 173 partial fragments, 69 full fragments, 76 capability announcements and 76 heartbeats: **394 messages total**. Median batch latency is **1.80 s**, range **1.30–10.00 s**.
- This is **88.6% fewer bytes**, **80.7% fewer messages**, but only **10.7% less aggregate CPU**. Average CPU per client is approximately **690 ms versus 616 ms over the entire five minutes**; that is about 2.30 versus 2.05 ms per second, not per frame.
- The **10-second outlier is real**: an update coalescing with a not-yet-started forced checkpoint inherits its full-send obligation. Later updates can overtake an already-running older checkpoint, but this particular update starts inside the checkpoint itself. Small-update prioritization does not eliminate that case.
- These five-minute totals exclude the initial party join, which is reported separately.

With **three 1.2 peers and one 1.1 peer**, the ordinary four-player wave falls back to **68 full fragments**, **15,763 bytes**, and **9.30 s**. Capability gating behaves as designed; partial latency savings require all four peers to support them.

## Continuous-update finding

A separate stress workload changes the same objective every second for **61 seconds**, cycling its bounded counter. **Neither version sends any data snapshots during those 61 seconds.** The first data send occurs at 61.30 s, after the final event at 60 s:

1. Refresh coalescing creates a queued snapshot after 0.8 s.
2. Its first send is scheduled another 0.5 s later.
3. The next event at 1.0 s makes the queued snapshot obsolete before it starts.
4. The pump discards it; this repeats while events continue.

Once changes stop, the final state takes **9.30 s in 1.1 versus 1.30 s in 1.2** from its event to all peers. This benchmark intentionally records the current behavior rather than fixing production code. A bounded-wait/latest-state send policy is needed to guarantee progress under continuous objective events. Some intermediate cache values coincidentally match when the counter cycles; that must not be mistaken for delivered updates.

## Reproduction and evidence

See [README.md](../README.md#synchronization-benchmark) for extraction and benchmark commands. The extractor executes a trusted local QuestieDB checkout and writes outside it. No upstream dataset is vendored.

- [Machine-readable median/count summary](sync-questiedb-before.json).
- Upstream archive SHA-256: `16c11546ad8486cf202c4b04987bd7aa9815a60eefb8167a065b6b4f87eb777e`.
- Extracted fixture SHA-256: `b2cf0a978fa47237a48b40dd0311e5033ef2c3cea56b919e6caa3aeb087f77df`.
- Full local run data: `.cache/benchmark-source/results.json`, `portable.json`, `latency50.json`.
- Production code is unchanged. The recovery-test network harness is shared with the benchmark; stages are wrapped inside isolated environments using debug upvalue inspection, without adding production logging or profiling hooks.
