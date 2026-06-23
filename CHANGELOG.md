# Changelog

All notable changes to SoD Phase Lock will be documented here.

---

## [0.2.0] - 2026-06-23

### Added
- Quest phase database (`Data/Quests.lua`): a 384-quest phase map (P2–P7) plus the Nightmare Incursions, sourced from Questie.

### Changed
- **Quest enforcement is now a hard block** (previously warn-only): declines the accept dialog (`QUEST_DETAIL`), abandons quests that slip in via sharing or auto-accept (`QUEST_ACCEPTED`), and closes the turn-in window (`QUEST_PROGRESS` / `QUEST_COMPLETE`). A full scan also sweeps and abandons any banned quests already in the log. Quest violations are now reported to the compliance roster.

---

## [0.1.0] - 2026-06-23

### Added

#### Phase system
- Eight SoD phases (P1–P8) covering the full Season of Discovery progression:
  Blackfathom Deeps → Gnomeregan → Sunken Temple → Molten Core → Blackwing Lair → Ahn'Qiraj → Naxxramas → Scarlet Enclave.
- Per-phase level caps (25 / 40 / 50 / 60) and profession skill caps.
- Cumulative instance unlock sets — each phase inherits all prior-phase dungeons and raids.
- Item ban database seeded for Phases 1–4 (2,279 / 2,039 / 1,538 / 0 items respectively).

#### Two enforcement modes
- **Relaxed** — enforces the phase level cap only. Entering a higher-phase instance is allowed; over-cap gear is flagged informally (red X in bags) but not removed.
- **Authentic** — full restrictions on top of the level cap: instance gating, gear/items, profession caps, quests, runes, and the Rune Broker NPC.

#### Enforcement rules (configurable per guild)
- **Level cap** — warns when the player's level exceeds the phase cap; reminds them to turn off XP gain.
- **Instance gating** (authentic) — warns on entering a not-yet-unlocked dungeon or raid; 90-second grace period before the violation is reported to the compliance log, so brief pop-ins don't penalize players.
- **Gear / items** (authentic) — scans equipped items against the phase's ban list and required-level cap; unequips violations out of combat. Declines `EQUIP_BIND_CONFIRM` / `AUTOEQUIP_BIND_CONFIRM` popups for over-phase BoE items to prevent them binding. In relaxed mode the same logic runs locally (no guild report) if "Block over-phase gear" is enabled.
- **Profession cap** (authentic) — flags any tradeskill above the phase's skill ceiling (ignores Languages).
- **Quests** (authentic) — warns on accepting or turning in quests not yet available in the active phase (database populated incrementally).
- **Runes** (authentic) — scans every learned rune via `C_Engraving.GetRunes()`; flags runes from a later phase using the explicit phase allowlist when seeded, or a required-level fallback otherwise.
- **Rune Broker** (authentic) — closes the Rune Broker merchant/gossip window on interaction and alerts the player.

#### Guild sync
- Officers broadcast the active phase and mode to all online guild members over the guild addon channel using AceComm + LibSerialize + LibDeflate.
- Epoch-based conflict resolution: the highest epoch always wins, preventing stale broadcasts from overwriting a newer ruleset.
- New members automatically receive the current ruleset via a `REQ` message sent on login; online members respond with the latest ruleset.
- 60-second status pings from each member carry their current violations; the compliance log updates immediately on a new violation without waiting for the next ping.
- Officer rank threshold is configurable (0 = Guild Master only, up to rank 9).
- Players not in a guild act as their own officer (local-only, no broadcast).
- Cross-character / cross-guild contamination of `SavedVariables` is detected on login and cleared before the sync request fires.

#### Compliance roster
- Aggregates status pings from all guild members into a sorted roster.
- Violators are listed first under a red "Out of Compliance (N)" section; compliant members follow under a green "Compliant (N)" section.
- Five-column table layout: Player, Level, Phase, Mode, Status (lists each active violation reason).
- Stale entries (no ping for 300 s) are automatically dropped.
- Status bar shows the live out-of-compliance / compliant count and ping cadence.

#### Options UI
- Two-tab panel ("General" and "Guild Settings") accessible from `/sodlock`, the minimap button, or the standard AddOns interface.
- **General tab:** local enable/disable kill switch, sound toggle, minimap button toggle, personal challenge toggles (layer extra restrictions on yourself beyond the guild ruleset).
- **Guild Settings tab:** officer controls for phase and mode; guild-leader controls for individual enforcement rules, block-over-phase-gear toggle, and instance grace period (slider, 0–600 s). Non-leaders see guild settings read-only.
- Enforcement option toggles print a targeted confirmation ("Block Rune Broker: enabled") rather than the generic ruleset summary.
- Guild enforcement config is synced to all members alongside phase/mode; every member follows the same rule set automatically.

#### Bag overlay
- Semi-transparent red wash and red X icon on bag-slot items that violate the current phase.
- In authentic mode: flags items in the phase ban list or with a required level above the cap.
- In relaxed mode: flags items whose required level exceeds the level cap (informational only — no enforcement action).
- Tooltip decoration appended to any item tooltip (bag, character sheet, chat link) showing "SoD Phase Lock: Unlocks in \<phase name\>" when the item is illegal.
- Native Blizzard bag UI and **Baganator** are both supported; the Baganator corner-widget is auto-activated on first load.
- Overlays refresh on bag open/close, item move, phase change, and via a lightweight `OnUpdate` driver while bags are visible.

#### First-login welcome popup
- One-time dialog on first login per character offering a plain-English choice between Relaxed and Authentic mode.
- Officers: selection broadcasts the chosen mode to the guild immediately.
- Non-officers: selection sets a local preference (incoming guild broadcasts can still override it).

#### Minimap button
- LibDataBroker / LibDBIcon launcher; position saved per character; togglable from the options panel.

#### Slash commands
- `/sodlock` — opens the options panel.
- `/sodlock status` — prints the current phase, mode, and local violation state to chat.
- `/sodlock roster` — opens/closes the compliance roster window.
- `/sodlock scan` — runs a full enforcement scan immediately.
