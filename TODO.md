# Feature Ideas

Keep additions focused on the core question: **“Are we good to move on?”**

## Further improvements

- [x] **Group related differences by quest.** List affected members beneath a single quest rather than repeating the quest for each member.
- [ ] **Catch-up explanations.** For missing quests, show whether they can be shared, where to pick them up when known, and any known prerequisites. Explain why sharing is unavailable rather than only omitting the button.
- [ ] **Quest-chain mismatch detection.** Show when someone is ahead or behind in the same chain instead of reporting unrelated missing quests. Use reliable chain data and handle branches conservatively; this is already envisioned in `PRODUCT.md`.
- [x] **Ignore unrelated quests.** Personal, party-session quest ignores with context-menu and bulk actions, a join-time offer, optional automatic ignoring, undo, and a separate ignored-quests view with individual/bulk restore. Survive reloads/disconnects; reset when you leave the party.
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
- [x] **Ignore delve companions.** Exclude NPC party members from comparisons and stop PARTY message attempts when no other players are grouped, preventing repeated "You aren't in a party" messages in solo delves.
- [x] **Objective progress views.** Choose When anyone finishes (default), When I finish, or Always. Preserve actionable party status independently of informational counts; persist the choice and support preview.
