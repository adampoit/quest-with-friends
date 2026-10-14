# Feature Ideas

Keep additions focused on the core question: **“Are we good to move on?”**

## Further improvements

- [x] **Group related differences by quest.** List affected members beneath a single quest rather than repeating the quest for each member.
- [ ] **Catch-up explanations.** For missing quests, show whether they can be shared, where to pick them up when known, and any known prerequisites. Explain why sharing is unavailable rather than only omitting the button.
- [ ] **Quest-chain mismatch detection.** Show when someone is ahead or behind in the same chain instead of reporting unrelated missing quests. Use reliable chain data and handle branches conservatively; this is already envisioned in `PRODUCT.md`.
- [ ] **Ignore unrelated quests.** Hide individual quests from comparisons temporarily or persistently, reducing noise from profession quests, old campaigns, and solo objectives.
- [ ] **Subtle transition notifications.** Offer optional alerts for meaningful changes, such as everyone finishing a quest or someone accepting a quest another member is missing. Avoid alerts for every objective update.
- [x] **Clear connection health.** Distinguish addon not detected, waiting, refreshing, and stale data. Keep cached comparisons visible with their connection status while fresh data arrives; `/qwf` requests a refresh.
- [x] **Exclude class and profession quests**
- [ ] **More compact mode**
- [x] **Collapsible quest headers**
- [x] **Resizable panel**
- [x] **Show remaining objective counts after turn-in.** Compare unfinished players with ready-to-turn-in or completed quests across the whole party.
- [x] **Offline member handling.** Show a distinct Offline notice, retain cached comparisons, and resume syncing automatically on reconnection.
- [x] **Redundant counts in the UI**
- [x] **Show finished tradeable item counts.** Show capped x/y with positive surplus such as `10/10 · 2 spare` while another member needs the items. Fall back to the current display when item identity or tradeability is uncertain.
