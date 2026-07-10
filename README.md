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
- `/sodlock clearflag <player>` — **(officer only)** clear a member's saved
  compliance flags (Guild Found tamper / "not detected") and forgive a
  played-without-addon gap; useful when they're offline / not in the roster
- Minimap button: left-click = roster, right-click = options

### Who controls what?
Settings live on a **Guild Settings** tab and sync to the whole guild:

- **Officers** set the active **phase** and **lock mode**. "Officer" = a guild
  rank index at or below the configurable **Officer rank threshold** (0 = Guild
  Master).
- The **guild leader** sets the **enforcement config** — which rules are
  enforced (level / instance / gear / profession / quest / rune), whether
  illegal gear is auto-unequipped, the instance grace period, and whether
  members who **play with the addon disabled** are flagged. Every member follows
  this config automatically.

Incoming ruleset broadcasts are validated against the *original setter's* guild
rank, so a non-officer cannot relay a forged ruleset. Only **personal**
preferences (local kill switch, warning sound, minimap button) stay per-player.
Players not in a guild control their own local config (no broadcast).

## Guild Found (closed economy)

An optional, guild-leader-controlled **closed-economy** policy — the guild
analogue of "self-found". Each restriction is an **independent toggle** (mix and
match), set on the **Guild Settings** tab and synced to all members:

- **Trade** — you may only trade fellow guild members. An optional per-item
  **allowlist**, plus blanket exemptions for **conjured items** and **items
  still in their group-loot trade window**, permit specific items to be traded
  outside the guild; gold never crosses the guild boundary.
- **Mail** — you may only mail guild members, and **player** mail received from
  outsiders is locked (can't be opened or looted) and marked with a **"Blocked"**
  overlay in the inbox, with a **Return** button to send it back. Ordinary
  NPC/system mail (quest rewards, vendor buyback, in-game support) is unaffected,
  but **Auction House mail is always blocked** so no gold or items sneak back in
  through it.
- **Auction House** — blocked entirely.

Enforcement is **best-effort client-side** (the addon's honor-system model): it
can't defend against someone editing the addon or SavedVariables, so the real
goal is **detection + accountability**, surfaced to officers in the compliance
roster.

### Compliance & the saved tamper flag

Every member's status report includes their local Guild Found state. If a member
reports a restriction **off** while the guild has it **on** (a SavedVariables
opt-out), the roster flags them **"Guild Found disabled locally."**

That flag is **saved** the moment they're caught — it **sticks** even after they
turn the restriction back on or relog, so a tamperer can't clear it just by
cooperating for one status cycle. **Only an officer can clear it**, either with
the **"Clear"** button on the flagged row in the compliance window or with
`/sodlock clearflag <player>`. The clear is **synced guild-wide** (so it lifts
for every officer at once, and a member can't clear their own flag); if they
start tampering again afterward, they're simply re-flagged.

The roster also shows an officer-only **"Addon Not Detected"** section — guild
members with no recent status report (addon off, not installed, or blocking guild
sync). A member seen **online for a sustained period with no report** is **saved**
here (marked "saved") so the record **survives their logout**, instead of only
showing while they happen to be online. Officers clear a saved record the same way
(Clear button / `/sodlock clearflag`), and it clears itself automatically if the
member later starts reporting.

Both signals are best-effort: a modified addon can still report in, so they
surface non-participation rather than prove it. "Not detected" also can't be told
apart from "still loading" for a short while, which is why it waits for sustained
silence before saving anything.

### Played-without-addon detection

The guild leader can enable a check (**Enforcement Behavior → "Flag playing
without the addon"**) that compares each character's server **`/played`** against
the time the addon was actually loaded. Any time played while the addon was off
accrues as a **durable, retroactive gap** — baked into `/played`, so it's caught
the next time they log in with the addon even if no officer was watching — and
flags the member out of compliance once it exceeds the configurable **tolerance**.
This closes the "turn the addon off for the raid, turn it back on after" loophole
that the live "Addon Not Detected" signal can't catch.

Honest **multi-PC play** is reconciled through the guild: each computer shares the
highest `/played` it has witnessed, and an alternate PC adopts that value so hours
played elsewhere aren't mistaken for playing without the addon. Only playtime
*after* install is ever counted, and an officer can **forgive** a gap with the
same **Clear** button / `/sodlock clearflag` (the member's counter resets, so it
only returns if they rack up new addon-off time).

## How sync works

- Communication is over the guild addon channel (prefix `SoDPL`), payloads
  serialized with **LibSerialize** and compressed with **LibDeflate**.
- An officer changing the phase/mode — or the guild leader changing the
  enforcement config — bumps a monotonic `epoch` and broadcasts the whole
  ruleset. Members apply the **highest epoch** they've seen and cache it.
- On login a client asks the guild for the current ruleset; any client answers
  with its cached copy (authority still comes from the original setter's rank).
- Every 60s each member broadcasts a status report (level, phase, mode,
  violation flags, local Guild Found state, and any played-without-addon gap);
  the Compliance module aggregates these into the roster. (Cadence stretches
  automatically in very large guilds to stay within the guild channel's rate
  limit.) On login a member also asks the guild for the highest `/played` it
  has witnessed for them, so multi-PC play reconciles instead of false-flagging.
- An officer clearing a saved Guild Found flag broadcasts that clear, validated
  against the clearing officer's rank the same way a ruleset broadcast is.

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
