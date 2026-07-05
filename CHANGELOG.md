# Changelog

All notable changes to SoD Phase Lock will be documented here.

---

## [0.6.4] - 2026-07-05

### Fixed
- **The Compliance window no longer flickers on every update.** The Guild/Group Compliance list was fully torn down and rebuilt each time any guildmate's status ping arrived (~every heartbeat), even when nothing on screen had actually changed — so a large guild made the list flicker constantly. The list now rebuilds only when the visible data actually changes, and rapid bursts of reports are coalesced into a single rebuild, so a steady stream of unchanged pings produces no visible flicker.
- **Low-skill enchants are no longer flagged as "later phase."** Several enchants that require only ≤ 150 enchanting skill were bucketed to Phase 2, so under a Phase 1 lock they were flagged (and, with "block over-phase gear" on, the whole piece was removed): *Enchant Weapon - Lesser Striking*, *Chest - Minor Stats*, *Gloves - Mining / Herbalism / Fishing*, *2H Weapon - Lesser Impact*, and *Bracer - Lesser Strength / Lesser Stamina*. They're now correctly available from Phase 1. (Two of them share an internal enchant ID with a genuinely later enchant — *Weapon - Striking* and *Boots/Shield - Lesser Stamina* — so those siblings are no longer enforced in earlier phases, since the game can't tell the two apart from the item link and this avoids ever falsely removing the legal low-skill enchant.)

### Changed
- **The Available Enchants window now refreshes when you change gear.** Equipping, unequipping or swapping a piece now rebuilds the paper doll live, so each slot's item, enchant outline (green/red) and current-enchant label stay in sync with what you're wearing.
- **Minimap button clicks swapped:** **left-click** now opens the main window, **right-click** opens the compliance roster (previously reversed).

---

## [0.6.3] - 2026-07-03

### Fixed
- **Rune-granting relics (idols, librams, …) are no longer removed by the gear rule.** An equipped rune relic such as the *Idol of the Huntress* was being flagged "can't be worn this phase" and auto-unequipped when "block over-phase gear" was on, even with the **Rune** rule off — because self-enforcement still treated it as a later-phase *item*. Rune relics are now governed solely by the **Rune** rule everywhere (self gear scan, bind-equip block, and Group Compliance), matching how the bag red-X already worked: with the Rune rule off they're left alone; with it on, an equipped relic is flagged (and removed when blocking is on) only when its rune belongs to a later phase.

---

## [0.6.2] - 2026-07-03

### Added
- **Fel Portal ("Otherworldly Treasures") BoE drops are now correctly phased.** These items were added in a later phase but have low required-level ranges, and the addon's bulk item import had wrongly treated every one of them as strictly "later phase" — so a guild locked to the item's own phase would have its members' gear flagged/removed for using them. Each Fel Portal BoE is now bucketed to the phase it's actually intended for (Phase 1, 2 or 3), so it's allowed from that phase onward and blocked only before it.
- **New "Fel Portal Drops" section in the Overview panel** listing the BoEs that can be found from Otherworldly Treasures in the current phase (icons with hover tooltips and click-to-link, like the other Overview sections).

---

## [0.6.1] - 2026-07-03

### Fixed
- **The mage "Spell Power" rune no longer gets your gear removed.** When the gear rule was on, an item carrying the *Spell Power* engraving rune was mistaken for a later-phase **enchant** (it shares its name with *Enchant Weapon/Bracer - Spell Power*) and unequipped if "block over-phase gear" was on — even though the rune itself is legal for the phase. The rune's own tooltip line is now ignored when checking for later-phase enchants, so a coexisting real enchant is still caught but the rune no longer triggers a false removal. (This only ever affected the **gear** rule; the separate **Rune** rule handled the rune correctly all along.)

---

## [0.6.0] - 2026-07-02

### Added
- **New "Guild Population" tab** in the main SoD Phase Lock window (between **Overview** and **Available Enchants**): a filled pie chart of your guild's membership broken down by class, with a class-colored legend listing the count and percentage for each class.
- **Later-phase enchants are now enforced on your own gear.** Previously an equipped item was only removed if the *item* was from a later phase — an otherwise-legal item carrying an enchant from a later phase slipped through. Now, when the gear rule is on (self-enforced via Personal Challenges or guild-enforced), any equipped piece bearing a later-phase enchant is unequipped (out of combat; queued and removed when you leave combat), just like an over-phase item. The enchant itself can't be stripped, so the whole piece comes off. These are reported to the guild compliance roster separately as "N later-phase enchant(s)" so officers can tell an illegal item apart from a legal item with an illegal enchant.
- **Out-of-date notice.** The addon now tells you when a guildmate is running a newer version than you. Your version rides along on the guild-sync messages the addon already sends (no extra traffic), and the first time it sees a newer one it prints a one-time chat notice so you know to update. `/sodlock status` shows your current version and any newer version seen.

### Fixed
- **Idols, librams, totems and sigils are no longer wrongly unequipped.** Season of Discovery stores an engraved rune in the same item-link slot a permanent enchant uses, and a rune-granting relic (e.g. the Lunar Idol, which grants Fury of Stormrage) puts its rune there. The addon was reading that value as if it were a later-phase gear enchant, so with "block over-phase gear" on it auto-removed the relic. Runes are now recognized and never mistaken for a later-phase enchant: the relic slot is skipped (no gear enchant can live there), and for your own gear the addon checks whether a slot is actually engraved. The same false flag is also gone from the Group Compliance tab and item tooltips.
- **Rune items no longer get a red X in your bags when rune restrictions are off.** Engraving runes ("Rune of …") live in the same later-phase item list as gear, so with "block over-phase gear" on they were marked with the red X even for players who left the separate **Rune** rule unchecked. Now a rune item is only flagged when rune enforcement is actually on; with the Rune rule off, later-phase rune items in your bags (and their "unlocks in …" tooltip line) are left alone.
- **Rune-granting relics (idols, librams, …) are now gated by the Rune rule, not the gear rule.** Some SoD class runes are delivered as relic-slot items (e.g. *Idol of the Raging Shambler*); these were flagged with the red X by "block over-phase gear" even when the **Rune** rule was off. They're now governed solely by the Rune rule, using an explicit rune-relic list (`Data/RuneRelics.lua`) so ordinary stat relics are unaffected: with the Rune rule on, a rune relic is marked (and its tooltip reads "Rune unlocks in …") only when its rune belongs to a later phase; with the Rune rule off, it's left alone.
- **First-run welcome popup is now strictly per-character.** The "seen the welcome" flag lived in the profile scope, so assigning one shared profile to several characters could suppress the welcome on a brand-new alt. It now lives in the per-character scope, so every character reliably sees the welcome exactly once regardless of profile sharing.
- **Compliance window no longer jumps to the top.** The Guild/Group Compliance list rebuilds whenever a status ping arrives; it was snapping the scroll back to the top each time, making a long roster hard to read. Scroll position is now preserved across updates.

---

## [0.5.3] - 2026-07-02

### Fixed
- **Lua error on login.** The staggered-sync code introduced in 0.5.2 called `math.randomseed`, which doesn't exist in WoW's Lua sandbox, throwing an error as the addon enabled. Client jitter is now decorrelated without it, so login is clean again.

---

## [0.5.2] - 2026-07-02

### Changed
- **Guild sync now scales to very large guilds (~1000 members).** Status pings are staggered with per-client jitter instead of firing on a shared 60-second boundary, and the ping interval now adapts to the number of online members (60s for small guilds, stretching toward ~250s at 1000) so the guild-wide addon-message rate stays under WoW's drop threshold. The roster's staleness window scales with it. This should stop members going missing from the compliance roster in big guilds.
- **Ruleset-sync replies no longer storm.** Previously *every* member answered each "request current ruleset" message, so one login triggered up to N replies (and a mass login up to N²). Members now schedule a single jittered reply and cancel it the instant they see anyone else answer, so a request draws roughly one reply guild-wide.

### Notes
- The large-guild sync changes are protocol-compatible with 0.5.0/0.5.1 clients (message format is unchanged), so a mixed-version guild degrades gracefully during rollout. Not yet verified in a live client.

---

## [0.5.1] - 2026-07-02

### Fixed
- **Instances with a leading "The" no longer falsely locked.** `GetInstanceInfo()` and our data table sometimes disagreed on the leading article (Blizzard returns "Deadmines" while the map/journal name is "The Deadmines"), causing an allowed instance to be treated as out-of-phase. Instance names are now normalized — lowercased, leading "the " dropped, and collapsed to alphanumerics — so all spellings key identically.

---

## [0.5.0] - 2026-06-29

### Added
- **New "Group Compliance" tab** in the compliance window: a live check of your **current party/raid**. Unlike the guild roster (which relies on members running the addon), this inspects everyone in your group directly — **pugs and non-addon users included** — and flags anyone outside the active phase on **level, gear, enchants, or runes**. It runs automatically while the tab is open; members are inspected one at a time and must be online and within ~28 yards. There's a **Rescan** button for a manual refresh.
- **"Why did they fail?" tooltip.** Hover a flagged player's **Status** to see exactly what's wrong — their level vs the phase cap, the specific **later-phase item and enchant links**, and rune count.
- **Later-phase enchant detection.** The group check now flags gear wearing enchants from a later phase, and the item tooltip distinguishes between a later-phase **item** and a later-phase **enchant** applied to it. (Enchant→phase data sourced from Wowhead Classic, Phases 2–8.)
- **"Added this phase" in the Available Enchants tab.** When you click a gear slot, the enchants added in the **current phase** are grouped at the top under an "Added this phase" sub-header; the rest follow under "Available earlier", sorted with the most recent phases first.

### Changed
- **Available Enchants: the per-slot enchant list now scrolls.** It's capped at half the panel height so a long list no longer pushes the reagent shopping list off-screen.
- **SoD enchants placed in their correct phases.** The Season of Discovery enchants that were provisionally all in Phase 4 are now distributed to their real phases (Phases 2, 4, 6, and 8).
- **Wording:** "illegal item(s)" is now "invalid item(s)" in the compliance views.
- Minor layout polish: added left padding to the Available Enchants paper doll.

### Notes
- The group check is **best-effort and degrade-safe**: out-of-range/offline members show "Out of range" and aren't judged; other players' **runes** can't be inspected (no API), so only your own are checked. Where one enchant ID is shared across phases, the earlier phase wins to avoid false positives. Not yet verified in a live client.

---

## [0.4.3] - 2026-06-27

### Added
- **Reagent shopping list now reads your bags.** In the Available Enchants tab, each reagent in the shopping list shows how many you carry as `have/need` — **green** when you have enough, **yellow** when you're short. When you have enough of a reagent, the row is **crossed out** (strike-through + dimmed icon) so the materials you still need to buy stand out. Counts update live as your bags change.
- **New "Off-Hand" enchant slot** for Season of Discovery off-hand-frill enchants (e.g. *Superior Intellect*, *Excellent Spirit*, *Wisdom*); the paper doll surfaces them when a held off-hand item is equipped.

### Changed
- **Available Enchants data rebuilt from authoritative Wowhead Classic data.** Every enchant's name and reagents were re-sourced directly from Wowhead, expanding coverage to **153 enchants across Phases 1–4 with reagents for all of them** (previously ~90% and Phases 1–3 only). This also corrects several reagent errors in the previous data.

### Notes
- Phase buckets remain **best-effort** — vanilla enchants are placed by reagent tier and the new SoD-specific enchants provisionally in Phase 4; a few borderline ones may shift once verified in-client. Non-enchant entries from the source list (oils, wands, trinkets, relics, sigils, rods) are intentionally excluded.

---

## [0.4.2] - 2026-06-25

### Added
- **XP-lock indicator in the guild compliance roster.** The roster now shows, per member, whether they have **disabled XP gains** (via Grendag Brightbeard) — a green `Locked` in a new "XP" column, or a grey dash when XP is still on. It is detected locally with `IsXPUserDisabled()` and synced over the existing status reports. This is **informational only**: locking XP never marks a member out of compliance and never reddens their row.
- **Profession proficiency training is now blocked above the phase cap.** When the **"Profession skill cap"** rule is enabled, the trainer can no longer be used to learn a proficiency tier that would raise a profession past the phase's skill cap — at Phase 1 (cap 150) this blocks **Expert** and above, at Phase 2 (cap 225) it blocks **Artisan**. The attempt is refused with a warning instead of charging you and raising your cap.

### Changed
- **The "you're at the level cap — go disable XP" reminder no longer shows once you've actually disabled XP.** Players who have locked their XP at the cap are no longer nagged; the reminder still appears for anyone at the cap who is still gaining XP.

---

## [0.4.1] - 2026-06-25

### Changed
- **"Available Enchants" tab reworked into a character-screen paper doll.** Instead of a cumulative list grouped by slot, the tab now mirrors the in-game character pane: each gear slot is drawn in its real position showing your equipped item's icon. Enchantable slots get a colored outline — **green** when enchanted (with the enchant's name), **red** when enchantable but missing an enchant. Hovering a slot lists every enchant available up to the active phase, with your current one highlighted; clicking links the item into chat.
- Weapon slots resolve dynamically from the equipped item — Main Hand shows 1H vs 2H weapon enchants, Off Hand shows shield vs weapon enchants.
- Layout: the two slot columns are a centered block; the weapon row sits beneath with Main Hand under Wrist, Ranged under Trinket 2, and Off Hand centered between them.

---

## [0.4.0] - 2026-06-25

### Added
- **New "Available Enchants" tab.** Shows, grouped by gear slot, every enchanting recipe usable **up to and including the active phase** (cumulative across phases). Each enchant is an icon — hover for the in-game spell tooltip, click to link it into chat.
- **Per-slot "Current" line.** Each slot shows what you have equipped there and its enchant: green `Current: <enchant>` when enchanted, red `Current: not enchanted`, or grey `Current: nothing equipped`. Reads your equipped item and (when enchanted) the item's tooltip, so it works for any enchant.
- **Enchant data (`Data/Enchants.lua`)** for Phases 1–3 across Cloak, Chest, Bracer, Gloves, Boots, Shield, Weapon, and 2H Weapon, sourced from the Wowhead Classic enchanting recipe list and bucketed by required skill against the phase profession caps (≤150 → P1, 151–225 → P2, 226–300 → P3).

### Notes
- Phase buckets for borderline (~225-skill) "Greater" enchants are best-effort and may shift a phase once verified in-client; phases 4+ are not yet seeded.

---

## [0.3.2] - 2026-06-24

### Changed
- **Enforcement is now per-rule and opt-in.** "Relaxed" and "Authentic" are no longer a separate stored switch — the **mode is derived** from which rules are enabled. Turning a rule on (in the guild enforcement config or your personal challenges) is what enforces it; you're "Authentic" exactly when every authentic rule is on. Previously a rule needed *both* Authentic mode and its own toggle, so enabling personal challenges in Relaxed mode looked active but enforced nothing.
- **Fresh installs now enforce nothing until configured.** All enforcement rules (and auto-unequip) default to **off**; a guild leader enables and broadcasts them, and unsynced members impose no restrictions on their own.
- **Overview "This Phase" box** no longer shows the "quests unlocking this phase" line.

### Added
- **Blackrock Eruption (Phase 4 world event) quests are now blocked** when locked below Phase 4 — matching how the Nightmare Incursions are blocked below Phase 3.

### Fixed
- **Guild leaders could not save or broadcast the enforcement config.** A missing internal helper caused a silent error in the Guild Settings toggles, so the config looked set locally but was never synced ("Set by: —" stuck, no broadcast). The config now commits and broadcasts correctly.

---

## [0.3.1] - 2026-06-24

### Added
- **Phase 3 (Sunken Temple) loot** in the Overview panel: 9 Unique Drops and a full set of Crafted Epics across Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, and Tailoring.
- **Phase 3 highlights:** the Nightmare Incursions event and a new **Dual Spec** feature, surfaced via a new per-phase `feature` field that renders a "New feature:" line in both the This Phase and Coming Next summaries.
- **Crafted Epics grouped by profession:** the loot panel now renders a sub-header per profession above its own icon grid. A phase's Crafted Epics may be either a flat list or profession groups; the panel auto-detects the shape. Phases 1–3 are grouped.
- **Per-phase background art** behind the Overview phase panel (Blackfathom Deeps, Gnomeregan, Sunken Temple), darkened so the foreground text stays legible. Phases without art show none.
- **Block engraving later-phase runes (authentic mode):** applying a rune from a later phase in the character-sheet engraving panel is now cancelled, not just flagged after the fact — the rune analogue of the over-phase gear block. Gated on the "Block over-phase gear" setting; warn-only when that is off.

### Changed
- **Overview "This Phase" box** now lists the full set of currently enterable instances inline (the separate "All Available Instances" group was folded into the panel).
- Phase 1 Crafted Epics list trimmed to Blacksmithing, Leatherworking, and Tailoring (Alchemy, Enchanting, and Engineering removed).

### Fixed
- **Guild settings no longer bleed across characters on the same account.** The active ruleset (phase, mode, and enforcement config) is now stored per guild instead of in a single account-wide table, so a guildless alt — which acts as its own officer — can no longer change settings that a guilded character on the same account then sees. Each guild (and the no-guild context) keeps its own ruleset; switching guilds mid-session re-syncs from that guild. Existing settings are migrated automatically.

---

## [0.3.0] - 2026-06-23

### Added
- **Overview tab** in the options panel (between General and Guild Settings): summarizes the active phase — level/profession caps, headline raid, dungeons & raids newly unlocked this phase, count of quests unlocking this phase, the full list of currently enterable instances, and a "Coming Next" preview of the next phase (new raid, new instances, raised caps, and unlock date if set).
- **Phase loot panel** in the Overview's "This Phase" and "Coming Next" boxes: a two-column panel with the phase summary on the left and stacked loot sections pinned to the upper-right (in line with the headline raid). Each item is an icon that shows the genuine in-game item tooltip on hover and links the item into chat on click. "Coming Next" shows the upcoming phase's loot. Sections, top to bottom:
  - **Unique Drops** — epic raid loot.
  - **Crafted Epics** — profession-crafted epics.
  - **New Consumes** — new consumables.
  - Seeded for Blackfathom Deeps (P1) and Gnomeregan (P2); data lives in the new `Data/RaidDrops.lua` (`ns.PhaseRaidDrops` / `ns.PhaseCraftedEpics` / `ns.PhaseNewConsumes`).
- **Per-phase event** (`event` field on `ns.Phases`): shown as an "Event:" line in the This Phase box and a "New Event" line in Coming Next. Phase 2 → Blood Moon.

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
