# SoD Phase Lock

A World of Warcraft Classic (Season of Discovery) addon that lets a guild
**coordinate and lock its members to a chosen SoD phase**, so everyone
progresses through the seasonal content together instead of out-running it.

## Modes

- **Relaxed** — locks players to the phase's **level cap** only. All other
  content stays reachable.
- **Authentic** — additionally restricts **phase-gated instances, gear/items,
  profession skill caps, quests, and SoD runes** to what was available at that
  phase.

## Usage

- `/sodlock` — open options
- `/sodlock status` — print the active ruleset and whether you're an officer
- `/sodlock roster` — open the guild compliance window
- `/sodlock scan` — re-check your current state now
- `/sodlock bag` — diagnose the bag "X" overlay (mode, gear rule, phase data, count)
- Minimap button: left-click = roster, right-click = options

### Who controls what?
Settings live on a **Guild Settings** tab and sync to the whole guild:

- **Officers** set the active **phase** and **lock mode**. "Officer" = a guild
  rank index at or below the configurable **Officer rank threshold** (0 = Guild
  Master).
- The **guild leader** sets the **enforcement config** — which rules are
  enforced (level / instance / gear / profession / quest / rune), whether
  illegal gear is auto-unequipped, and the instance grace period. Every member
  follows this config automatically.

Incoming ruleset broadcasts are validated against the *original setter's* guild
rank, so a non-officer cannot relay a forged ruleset. Only **personal**
preferences (local kill switch, warning sound, minimap button) stay per-player.
Players not in a guild control their own local config (no broadcast).

## How sync works

- Communication is over the guild addon channel (prefix `SoDPL`), payloads
  serialized with **LibSerialize** and compressed with **LibDeflate**.
- An officer changing the phase/mode — or the guild leader changing the
  enforcement config — bumps a monotonic `epoch` and broadcasts the whole
  ruleset. Members apply the **highest epoch** they've seen and cache it.
- On login a client asks the guild for the current ruleset; any client answers
  with its cached copy (authority still comes from the original setter's rank).
- Every 60s each member broadcasts a status report (level, phase, mode,
  violation flags); the Compliance module aggregates these into the roster.

## Extending the authentic data

The per-phase ruleset lives in `Data/Phases.lua`. The high-confidence fields
(level caps, the headline raid, profession caps, the instance progression) are
filled in. The large community-maintained tables ship with a working schema and
are meant to be expanded:

- `bannedItems[itemID] = true` — items whose *source* unlocks in a later phase
  (e.g. raid/dungeon loot from content that isn't out yet). Authentic gear
  gating already auto-flags any item whose **required level** exceeds the phase
  cap; `bannedItems` is for the harder cases (a low-level item from a
  future-phase source). Populate from Wowhead / AtlasLoot exports.
- `bannedQuests[questID] = true` — quests that belong to later-phase content.
- `runes[spellID] = true` — runes engravable at that phase. Rune enforcement is
  **off** for any phase whose `runes` table is empty.

### Bag addons (Baganator)

Baganator and other bag replacements hide the default Blizzard bags, so the
built-in "X" overlay can't draw on them. When **Baganator** is installed, the
addon registers a corner-widget plugin (**"SoD Phase Lock: blocked"**) that marks
flagged items inside Baganator's views; it auto-enables in the top-left corner and can be moved/removed in *Baganator → Icon Settings → Icon Corners*. 

`instanceUnlocks` is additive per phase; the cumulative enterable set is built
automatically at load.

## Installation

Copy the `SoDPhaseLock` folder into
`World of Warcraft/_classic_era_/Interface/AddOns/` and restart / `/reload`.

## Bundled libraries

Ace3 (AceAddon, AceEvent, AceConsole, AceComm, AceTimer, AceDB, AceConfig,
AceGUI, AceDBOptions, CallbackHandler, LibStub), LibSerialize, LibDeflate,
LibDBIcon-1.0 + LibDataBroker-1.1.
