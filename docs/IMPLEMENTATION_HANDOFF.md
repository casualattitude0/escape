# Implementation Handoff: Hunter Report + Lockdown

Roadmap: `docs/PROJECT_PHASE.md` § Next Slice
Branch: develop
Date: 2026-07-16
Type: Game (Godot 4)

## 1. Build Target

> A Hunter can spot the Runner, trigger a zone lockdown that blocks sabotage, and alert all teammates on the minimap so they converge. The Runner must react to being locked.

## 2. Scope

### In Scope (build these)
- [ ] Report action: Hunter presses a key while the Runner is inside their fog-clear radius. Server validates visibility before accepting. — MUST
- [ ] Zone definition: divide the current level into named zones (rectangular regions, derived from level geometry). — MUST
- [ ] Zone lockdown: when a report fires, the zone the Runner occupies blocks all sabotage input for `LOCKDOWN_TIME` seconds. Server-authoritative (reject sabotage RPCs, not just hide the UI). — MUST
- [ ] Lockdown cooldown: after lockdown expires on a zone, that zone can't be locked again for `LOCKDOWN_COOLDOWN` seconds. — MUST
- [ ] Minimap report ping: all Hunters see a highlighted zone on the minimap when a report fires. Ping fades over `PING_FADE` seconds. — MUST
- [ ] Minimap rework (Runner): replace current display with directional arrows pointing toward each Hunter. Show bearing only, not position or distance. — MUST
- [ ] Minimap rework (Hunter): remove teammate position dots. Only show: own position, facility outline, report pings, sound pings. — MUST
- [ ] Visual lockdown indicator on the game world: the locked zone shows a tint/flash so players in that area know lockdown is active. — SHOULD
- [ ] HUD element showing lockdown status and cooldown timer for the zone the local player is in. — SHOULD
- [ ] Runner notification: when your zone gets locked, a brief on-screen indicator shows "zone locked" so you know sabotage is blocked. — SHOULD

### Out of Scope (don't touch)
- Elevators, vertical movement, or new maps. Phase 2.
- Pressure ratchet (increasing Runner exposure). Phase 3.
- Sound design beyond placeholder. Phase 3.
- Power-up items for Hunters. Deferred per GDD §8.
- Random map assembly. Deferred per GDD §8.
- Combat rebalancing. Tune after this slice is playtested, not during.

### Placeholder OK (fake these)
- Zone boundaries: hardcoded rectangles matching existing level rooms. No editor, no procedural subdivision.
- Lockdown visual: solid color tint or flashing overlay. Programmer art.
- Report sound: any short beep or click. Real audio is Phase 3.
- Directional arrows on Runner minimap: simple triangle or chevron.

## 3. Experience Requirements

| Player Action | Expected Response | Timing | Quality Target |
|---------------|-------------------|--------|----------------|
| Hunter presses Report key while Runner is in their fog-clear circle | Report fires. Their screen shows confirmation. Zone lockdown begins. All Hunters' minimaps flash the zone. | Report triggers within 1 frame of input. Minimap ping appears within same network tick for all Hunters. | Instant, no ambiguity about whether it worked |
| Hunter presses Report key but Runner is NOT visible | Nothing happens. No cooldown consumed. Optional: brief "no target" feedback. | Immediate rejection | Silent or near-silent. No punishment for checking. |
| Runner presses sabotage key on a device in a locked zone | Sabotage does not progress. Runner gets an on-screen indicator that the zone is locked. | Immediate rejection, within 1 frame | Clear that it's blocked, not broken. The Runner should know *why* their input isn't working. |
| Runner is mid-sabotage when lockdown activates | Sabotage stops. Progress does NOT roll back (rollback only happens on stun). Runner sees lockdown indicator. | Sabotage halts on the tick lockdown begins | No lost progress, just frozen progress. Distinct from stun. |
| Lockdown expires | Sabotage becomes available again in that zone. Cooldown period begins. | On the tick `LOCKDOWN_TIME` elapses | No player action needed. Runner can resume sabotage. |
| Hunter tries to report a zone that's on cooldown | Report fails. Optional: "zone on cooldown" feedback. | Immediate | Hunter knows to go find the Runner elsewhere or wait. |
| Runner looks at minimap | Sees arrows pointing toward each Hunter's bearing. Does not see Hunter positions or distances. | Updated every frame | Arrows rotate smoothly. Runner always knows which directions are dangerous. |
| Hunter looks at minimap | Sees own position, facility outline, report zone pings (fading), sound pings (existing). No teammate dots. | Report pings appear instantly on report, fade over `PING_FADE` seconds | Clear visual difference between report pings (player-triggered, zone-wide) and sound pings (passive, point-based). |

## 4. System Requirements

| System | What It Does | Exists? | Notes |
|--------|-------------|---------|-------|
| Zone map | Rectangular regions covering the level, each with an ID | No | Simplest approach: array of Rect2 + zone ID. Derived from room geometry in the current fixed layout. |
| Report system | Hunter input → visibility check → lockdown trigger + minimap broadcast | No | New system. Needs server-authoritative visibility check (reuse fog radius logic from `fog.gd`). |
| Lockdown state | Per-zone timer tracking active lockdown and cooldown | No | Server-authoritative. Replicated to all clients for UI display. |
| Minimap (existing) | Facility outline, positions, pings | Yes | Needs rework: remove Hunter teammate dots, add zone highlight layer, add Runner directional arrows. |
| Fog/spotting (existing) | Visibility radius per player | Yes | Report reuses the "Runner inside clear radius" check. May need to expose a `can_see_runner()` query to the report system. |
| Device system (existing) | Sabotage input handling | Yes | Needs one gate: check lockdown state before accepting sabotage. |

## 5. Asset Requirements

| Asset | Real or Placeholder | Spec |
|-------|-------------------|------|
| Zone boundary overlay (lockdown visual) | Placeholder OK | Translucent color rect or shader tint over the locked zone |
| Report ping on minimap | Placeholder OK | Colored rectangle or highlight matching the zone shape on the minimap |
| Directional arrow for Runner minimap | Placeholder OK | Simple triangle/chevron, one per Hunter, rotates to point at their bearing |
| Report key icon/prompt | Placeholder OK | Text label or simple icon near the Report key binding |
| Lockdown HUD timer | Placeholder OK | Text countdown or simple bar |

## 6. Acceptance Criteria

### Engineering Done
- [ ] Report input is server-validated (visibility check based on fog radius, not proximity)
- [ ] Lockdown blocks sabotage server-side (RPC rejection, not client-only)
- [ ] Lockdown timer and cooldown replicate to all clients
- [ ] Minimap shows zone pings to all Hunters on report
- [ ] Runner minimap shows directional arrows, no Hunter positions
- [ ] Hunter minimap shows no teammate positions
- [ ] Zone definitions cover the entire playable area with no gaps

### Experience Done
- [ ] A Hunter who spots the Runner mid-sabotage can report and lock the zone before the device breaks (on a device that's at 0 progress, the lockdown window is long enough to matter)
- [ ] A second Hunter, seeing only the minimap ping, can navigate toward the locked zone and arrive before lockdown expires
- [ ] The Runner knows they're locked (not confused by "broken" controls) and makes a visible choice: fight, flee, or wait
- [ ] Soul: the moment a report fires and two Hunters converge from different directions while the Runner decides whether to fight or run. That three-way decision point is the game.

### NOT Done Until
- [ ] Played a 2v1 match where at least one report-to-convergence sequence happened without anyone narrating what to do
- [ ] Tried a match where the Runner breaks all devices and escapes despite lockdowns (confirms it's not too oppressive)

## 7. Known Risks

| Risk | Impact | Tempting Shortcut | Why It Kills the Slice |
|------|--------|-------------------|------------------------|
| Client-side-only lockdown check | Critical | Easier than server validation | Runner can bypass by modifying client. More importantly, latency desync means the lockdown timing is unreliable. Server authority is the point. |
| Proximity-based report (skip fog check) | Critical | Simpler distance check | Removes the "find the Runner" game entirely. Hunters would report through walls, making fog meaningless. |
| Lockdown blocks movement instead of sabotage | High | Feels more dramatic | GDD recommends sabotage-block for prototype. Movement-block makes single-Hunter reports too powerful (traps the Runner), violating "single Hunter can't stop the Runner" principle. |
| Skipping minimap rework | High | "We'll fix it later" | If both sides see the same info, you can't test whether the information asymmetry creates interesting play. The asymmetry IS the test. |
| Tuning lockdown duration before playtesting | Medium | "I know roughly what it should be" | Pick a starting value (e.g., 8s lockdown, 15s cooldown), playtest, then tune. Pre-optimization wastes time. |

## 8. Test Hooks

| What to Test | How to Test | Pass Criteria |
|-------------|-------------|---------------|
| Report visibility gate | Hunter attempts report at various distances from Runner, including through walls | Report only succeeds when Runner is inside the fog-clear radius with line of sight |
| Lockdown sabotage block | Runner begins sabotaging, lockdown fires mid-mash | Sabotage stops immediately. Progress preserved. Resumes after lockdown expires. |
| Lockdown cooldown | Report same zone twice quickly | Second report rejected during cooldown. Succeeds after cooldown expires. |
| Minimap ping replication | Fire a report in a 3-player match | All Hunters see the zone ping simultaneously. Runner sees nothing from the report (only their directional arrows). |
| Runner directional arrows | Runner stands still, Hunters move around the map | Arrows smoothly track Hunter bearings. Arrow count matches Hunter count. |
| Edge case: Runner leaves locked zone | Runner walks out of the locked zone during lockdown | Runner can sabotage devices in unlocked zones. Lockdown only applies to the specific zone. |
| Edge case: all zones on cooldown | Report every zone in quick succession | System correctly tracks per-zone cooldown independently. |
| Edge case: Runner in zone boundary | Runner stands on the border between two zones | Runner is assigned to exactly one zone (whichever their center/position falls in). No double-lockdown or no-lockdown gap. |
