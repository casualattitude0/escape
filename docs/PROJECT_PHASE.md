# Project Phase & Roadmap — Escape

_Analysis date: 2026-07-16 · Type: Game (Godot 4, asymmetric multiplayer)_

## Evidence scorecard

| Field | Value |
|-------|-------|
| Stated phase | Prototype (GDD §8 explicitly scopes a prototype-first plan) |
| Evidence phase | Early Prototype |
| Confidence | High |
| Momentum | Accelerating (64 commits in 3 days, all gameplay) |
| Stated vs revealed intent | GDD describes a full game with random maps, elevators, reporting, power-ups. Code reveals a focused prototype push that follows the GDD's own "defer these" list. Aligned. |

**Evidence for placement:**
- Core sabotage loop works: Runner mashes 4 devices (10 hits each), escape point opens, timer counts down (`scripts/world/device_system.gd`, `scripts/world/game_manager.gd`)
- Knock-to-stun works: 3 hits, 1.2s iframes, 4s decay, 2.5s stun, knockback (`scripts/world/knock_system.gd`)
- Runner kill + 2.5s cooldown, Hunter infinite respawn (`scripts/player/player_combat.gd`)
- Fog of war with role-asymmetric radii and spotting (`scripts/ui/fog.gd`)
- Tunnel slide for Runner with exit stun and sound emission (`scripts/player/player_movement.gd`)
- Multiplayer networking with relay server, snapshot/resume (`scripts/net/`)
- Two fixed level layouts, menu, HUD, minimap all present
- Old grapple system fully removed, combat rewritten to match current GDD

**What's missing (blocks vertical slice):**
- Reporting + zone lockdown: the GDD's "strongest Hunter tool" does not exist in code. Without it, Hunters have no way to convert "I see the Runner" into team-wide information or frozen progress. Hunter gameplay is just "chase and swing."
- Elevators (Hunter vertical fast-travel): no vertical movement network. Hunters can't reposition between floors.
- Minimap doesn't match GDD spec: currently shows Hunter teammates (GDD says no), doesn't show Runner directional arrows to Runner player.
- No multi-floor map designed for the vertical/horizontal movement split.
- No pressure ratchet (Runner exposure increasing as devices break).

## Where it's going

Vertical slice, demo quality. One designed map with all GDD systems working. A build you can hand to 3-5 players and learn whether the asymmetric chase is worth making into a full game.

## Roadmap

### Phase 1 — Hunter Coordination  ← current focus
- **Goal:** Hunters can spot, report, lockdown, and converge on the Runner. The GDD's core tension ("can Hunters coordinate before the device breaks?") is observable.
- **Exit criterion:** In a 3-player match (1 Runner, 2 Hunters), a Hunter spots the Runner sabotaging, triggers a report, the zone locks, teammates see the alert on minimap and converge, and the group attempts a 3-knock stun before the device breaks. This sequence happens without debug shortcuts.
- **Key work:**
  - Build reporting system: Hunter triggers report when Runner is in their fog-clear radius. Triggers zone lockdown (Runner can't sabotage in locked zone for n seconds) and minimap alert for all Hunters.
  - Add lockdown cooldown per zone (m seconds after lockdown expires).
  - Fix minimap asymmetry: Runner sees Hunter direction indicators (not positions). Hunters lose teammate dots, only see report-triggered zone pings.
  - Decide lockdown effect: "can't sabotage" (GDD's prototype recommendation) vs "can't leave zone."
- **Dependencies:** Current knock system, fog spotting mechanic, minimap, device system all exist.
- **Rough effort:** ~3-5 days at current pace.
- **Risks:** Lockdown tuning. Too long and the Runner is stuck losing every encounter. Too short and Hunters can't converge in time. The n/m values are the entire balance question for this phase.

### Phase 2 — Movement Networks + Map
- **Goal:** Both teams have distinct fast-travel (Runner: tunnels, Hunter: elevators). The map has vertical play. "Who gets to the device first" is a real routing decision.
- **Exit criterion:** A multi-floor map where the Runner uses tunnels to cross horizontally and Hunters use elevators to move vertically. Both paths have trade-offs (tunnels have exit stun + sound, elevators have wait time). Devices are spread across floors so both networks matter.
- **Key work:**
  - Build elevator system for Hunters (ride between floors, possible wait/call time).
  - Design one multi-floor level that places tunnels, elevators, devices, and spawn points to create the routing game.
  - Tunnel system already works; may need new tunnel placements in the new map.
  - Review and tune movement speeds so the "race to the device" feels tight.
- **Dependencies:** Phase 1 (reporting makes the race meaningful; without it, converging is pointless).
- **Rough effort:** ~5-7 days.
- **Risks:** Level design is the hard part, not the elevator code. A bad map makes every system feel broken. Playtesting the map layout is the real work here.

### Phase 3 — Vertical Slice Polish
- **Goal:** A stranger can play a full match and understand what's happening.
- **Exit criterion:** 3-5 external players complete a match. No one asks "what am I supposed to do?" after the first 30 seconds.
- **Key work:**
  - Pressure ratchet: Runner gets more exposed (brighter outline, shorter report cooldown) as devices break.
  - Sound design: sabotage noise, tunnel enter/exit, elevator, report alert, lockdown indicator.
  - Visual feedback: lockdown zone overlay, report cooldown HUD, device damage states, stun/iframe clarity.
  - Art pass on devices, escape point, tunnel mouths, elevator.
  - Onboarding: minimal role explanation at match start.
- **Dependencies:** Phases 1-2 (all systems exist).
- **Rough effort:** ~5-7 days.
- **Risks:** "Polish" is unbounded. Lock a checklist before starting. The goal is comprehensible, not beautiful.

## Cross-cutting risks
- **Balance is unknowable until Phase 1 ships.** The GDD's 7 key knobs (iframe duration, attack CD, stun duration, decay, lockdown n/m, device hits) all interact. Resist tuning individual knobs in isolation. Playtest with reporting + lockdown in the loop before adjusting combat numbers.
- **Map design gates Phase 2.** Building an elevator system is a day of work. Designing a map where elevators and tunnels create interesting routing is the actual constraint.
- **Match duration:** Currently 300s (bumped from 90s). The GDD says 90s "to be tuned." This number will change repeatedly. Keep it as a single constant.

## Open questions
- Lockdown effect: "can't sabotage" vs "can't leave zone" (GDD recommends "can't sabotage" for prototype)
- Minimap report ping: exact Runner position vs zone/area indicator (GDD recommends zone)
- Knock accumulation: does getting stunned reset the current knock count? (Current code: yes, resets on stun)
- Elevator wait/call time, or instant ride
- Runner ability to interfere with elevators (GDD recommends: no, keep networks independent)

## Next Slice

**Recommended:** Hunter Report + Lockdown
**Score:** 9/10
**Hypothesis:** If Hunters can report and lock zones, the "spot → converge → stun" chain creates real team coordination pressure. If it doesn't, the asymmetric design needs a different Hunter verb, or the map/movement matters more than the information game.

### What to build
- Report action: Hunter presses a key when Runner is visible (inside fog-clear radius). Triggers lockdown on the zone the Runner occupies.
- Zone lockdown: Runner cannot sabotage devices in the locked zone for n seconds. Runner can still move and fight.
- Lockdown cooldown: after lockdown expires, that zone can't be locked again for m seconds.
- Minimap alert: all Hunters see a zone ping when a report fires. Ping fades over time.
- Minimap rework: Runner sees directional arrows toward Hunters (bearing, not position). Hunters lose teammate position dots.

### What to fake (placeholder OK)
- Zone boundaries: use existing level geometry or simple rectangular regions. No need for a zone editor.
- Visual lockdown indicator: tint or flash on the zone. Programmer art is fine.
- Sound: placeholder beep for report and lockdown. Real audio is Phase 3.

### What must be real (do NOT fake)
- Server-authoritative lockdown: the Runner's sabotage input must be rejected server-side during lockdown, not just hidden client-side. Cheating this breaks the playtest signal.
- Fog-based visibility check: the report must require actual line-of-sight (Runner in the Hunter's clear fog radius), not proximity. Proximity-based reporting removes the "find the Runner" game.
- Minimap asymmetry: if both sides see the same info, you can't test whether information asymmetry creates interesting decisions.

### Success criteria
- In a 2v1 match, a Hunter spots the Runner mid-sabotage, reports, and a second Hunter sees the minimap ping and moves toward the locked zone. The Runner has to choose: fight, flee, or wait out the lockdown. This decision point happens naturally, not because someone read instructions.

### Failure looks like
- Lockdown is too short to matter (Hunters can't arrive in time on the current map). Means the map is too big or Hunter speed is too low. Learn: map size and movement speed are the real constraint, not reporting.
- Lockdown is too long and the Runner loses every device attempt. Means n needs to come down or Runner needs an escape valve (lockdown break mechanic?). Learn: reporting alone is enough to shut down the Runner, which means the game needs Runner counter-play.
- Hunters don't bother reporting because chasing is easier. Means reporting costs too much (time, positioning) relative to just swinging. Learn: report needs to be nearly free or give a bigger reward.

### Build time estimate
~3-5 days

### Dependencies
- Fog spotting mechanic (exists)
- Device system (exists)
- Minimap (exists, needs rework)
- Zone concept (needs definition, can be simple rectangular regions on the current map)

### Rejected alternatives
- **Elevators first:** Tests the movement game but without reporting, Hunters have no reason to converge. Elevators without a "go here now" signal are just faster walking. Lower validation value.
- **Full map redesign:** Addresses the "boring layout" problem but is weeks of work and doesn't test the information asymmetry at all. Wrong risk to test first. If reporting doesn't work, a new map won't save it.
