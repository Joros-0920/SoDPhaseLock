# Changelog

All notable changes to SoD Phase Lock will be documented here.

---

## [0.7.5] - 2026-07-12

### Added
- **Officers can now see when a member is *carrying* over-phase gear in their bags**, not just wearing it. The compliance roster appends a soft note like "(+2 over-phase in bags)" to that member's row. It's **informational only** — carrying isn't wearing, so it does **not** mark them out of compliance and nothing is auto-removed. Only shown when the guild enforces the gear rule, and rune relics (idols/librams/totems) are excluded.

### Changed
- **Guild Found now reports the actual *quantity* of items gained while the addon was off, not just how many distinct item types.** Looting a stack of 20 herbs off-radar now reads "20 item(s)" instead of "1".
- **Internal refactor (no behavior change):** the low-level bag/bank scanning code — duplicated across the wealth-integrity check, the auto-unequip free-slot search, and the bag-overlay diagnostics — now lives in one shared place. Keeps the three in lock-step so future fixes can't drift between them.

### Fixed
- **Fixed a false Guild Found wealth flag when you move your own gear between an equipped slot and your bags.** The item check only ever looked at bag contents, so unequipping a weapon, trinket, etc. into your bags while the addon was off made it look like a brand-new item had appeared from nowhere (e.g. "+0g, 1 item(s) while addon off"). Equipped gear is now counted alongside your bags, so moving a piece you already own between a worn slot and a bag nets out and no longer flags. Nothing genuinely entering your inventory is affected.
- **Fixed false Guild Found wealth flags when you move your own items between your bags and your bank.** Because the bank can't be read while you're logged out, withdrawing an item from the bank (or depositing one) while the addon was off used to look like an item appearing from nowhere. The check now reconciles bag↔bank moves across the two windows it *can* see: a bag item that matches your last-known bank contents is treated as a withdrawal (not a gain), and an item that left your bags is remembered so a matching deposit is recognised the next time you open the bank. Genuinely new items are still flagged (deferred to your next bank visit in the rare ambiguous case). Requires having opened your bank with the addon on at least once so it knows your bank contents.
- **No more false Guild Found flags for taking your own items out of your mailbox.** Pulling an item you'd mailed yourself (or that was already in your inbox) into your bags while the addon was off used to look like a brand-new item. The mailbox is now sampled as a known-holdings source and nets those relocations out, the same way bag↔bank moves are reconciled. (Requires having opened your mailbox with the addon on at least once.)
- **No more false Guild Found flags for taking your own *gold* out of your mailbox.** The mailbox reconciliation initially only covered items; pulling gold you'd mailed yourself into your bags while the addon was off (or right after login) could still read as money appearing from nowhere. Mail gold is now tracked the same way as mail items and nets those relocations out. (Requires having opened your mailbox with the addon on at least once.)
- **Fixed a false flag when you open mail and grab an attachment *very* quickly after logging in.** The mailbox was sampled on a short delay, so a fast grab could happen before the addon recorded what was in your mailbox — making your own item or gold look brand-new. The mailbox is now captured the instant it opens and remembers the most it held during the visit, so a quick take can't erase its own credit.
- **More robust against items still loading at login.** The wealth check now waits for your bags to fully settle (two matching scans) before comparing, closing a window where a half-loaded bag or an in-flight stack count could produce a phantom "gained" item right after logging in.

---

## [0.7.4] - 2026-07-11

### Fixed
- **Fixed a false Guild Found wealth flag that reported your entire gold balance as "off-radar," and grew every time you relogged.** The money check could compare your current gold against a baseline of **0** (money data, like bags, can read as 0 for a moment right after login), so it counted your whole balance as gained-while-addon-off — and stacked another full balance on each addon-off/on cycle (e.g. 5g → +5g → +10g …). This was the gold-side version of the whole-inventory false flag fixed for items in 0.7.2; the money path never got the same guard. It now refuses to fold against a 0/unread baseline and won't overwrite a real balance with a spurious 0. Members already carrying an inflated counter should be **Cleared** once (roster Clear button or `/sodlock clearflag <name>`); it won't re-inflate after the clear.

---

## [0.7.3] - 2026-07-11

### Added
- **New `/sodlock wealth` diagnostic command.** Prints whether Guild Found is active, whether the leader's "Flag off-radar gold/items" toggle is on, whether this session's baseline has been established yet, and the current money/item baseline sizes plus what's been reported so far — for troubleshooting why a gold/item change was or wasn't flagged.

### Changed
- **The Guild Found wealth-integrity baseline now settles roughly twice as fast after login** (previously ~15-20 seconds, now ~8-11 seconds in the common case), by tightening the cross-PC reconciliation window and its message jitter. No change to correctness — an honest alternate-PC player is still safely reconciled first.

### Fixed
- **A slow bag-load no longer silently drops a genuine off-radar item gain.** Previously, if your bags hadn't finished loading by the moment the addon compared them, that comparison was skipped once and the next bag update quietly adopted the new (post-trade) contents as the baseline — with no record the gain ever happened. It now retries for a few seconds until bags are actually populated before giving up.
- **Reduced the chance of members getting stuck in a stale state (e.g. "Guild Found disabled locally") due to a lost sync message.** Ruleset broadcasts and officer actions (Clear, played-gap forgive, wealth-gap forgive) were each sent exactly once with no retry — if that single message got lost in guild-channel congestion (e.g. a mass-login moment), the affected member could stay stuck until an unrelated event happened to re-sync them. These messages are now resent a couple of times over the following few seconds so a single lost copy doesn't strand anyone; receiving the same message twice is harmless (it just re-confirms the same state).
- **A returning member whose very first sync request went unanswered could get stuck out-of-date indefinitely**, since the old retry logic only re-asked if they had *never* synced at all in this addon's lifetime — not if they already had an old phase/settings from a previous session. Now any member who hasn't heard back from the guild yet this session retries automatically, closing that gap.

---

## [0.7.2] - 2026-07-11

### Added
- **"Audit" button on the Compliance roster.** Any member flagged for off-radar gold/items (Guild Found) now has an **Audit** button next to Clear/Kick. Clicking it opens a window listing the exact gold amount and the items reported as having moved while their addon was off — hover an item for its tooltip. Shown to officers for any member, and to a member for their own row.

### Changed
- **Guild Found now catches gold/items moved during much shorter addon-off windows.** The off-radar wealth check used to piggyback on the "played without the addon" gap, so it only kicked in if you had the addon off for more than ~3 minutes. It now uses its own, far shorter window (~45 seconds), so briefly disabling the addon to receive an item or gold from an outsider and turning it right back on is caught the next time you log in. (The "played without addon" flag itself is unchanged.)

### Fixed
- **A member could get permanently, falsely flagged "Guild Found disabled locally".** If a member's client ended up sitting at the guild's current ruleset with the wrong Guild Found settings (which could happen during a version rollout or a bad sync at login), the addon had no way to correct them — later broadcasts of the *same* ruleset were ignored — so they kept mis-enforcing Guild Found locally and stayed flagged forever, even though they'd done nothing wrong. Now such a member is corrected the next time they receive the ruleset (e.g. on their next login), and officers no longer see the flag flash while a member is still syncing. A stale flag is also no longer shown at all once Guild Found is fully turned off for the guild.

### Notes
- If a member is *already* stuck with the flag, it clears once they relog (their client re-syncs and corrects itself), or immediately if an officer re-toggles a Guild Found setting or uses the **Clear** button (`/sodlock clearflag <player>`).

---

## [0.7.1] - 2026-07-11

### Added
- **Catch gold and items that move while the addon is off (Guild Found).** Guild Found keeps a closed economy — no gold or items in or out from outside the guild — but those trade/mail/Auction House blocks only work while the addon is running. Someone could turn the addon off, receive 500g or a bag of items from an outsider (or mail gold *out* to one), and turn it back on with nothing to show for it. Now the addon keeps a private snapshot of your gold, bag contents, and bank contents, and the next time you log in after having played with the addon **disabled** (and, for the bank, the next time you open it), it compares against that snapshot and reports **any** gold or items that changed while it wasn't watching — flagging the member for officer review (e.g. "Guild Found: +340g, 12 item(s) while addon off"). There is no tolerance: in a closed economy no play without the addon is acceptable, so any change at all is surfaced. This piggybacks on the existing played-without-addon detection, so it only ever triggers for a member who actually played with the addon off.
- **A guild-leader toggle** (Guild Settings → **Guild Found** → **"Flag off-radar gold/items"**, on by default whenever any Guild Found restriction is active) turns the check on or off for the whole guild.
- **Officers clear it with the same "Clear" button** (or `/sodlock clearflag <player>`) that already clears the other integrity flags — it resets the member's counter guild-wide, and the flag only returns if *new* gold or items move while the addon is off again.

### Fixed
- **Resizing the Compliance window no longer freezes or crashes the game.** Dragging the window's edge could send it into a runaway relayout loop and hard-lock the client. The Compliance window is now a fixed size (its content scrolls as before).

### Notes
- Officers judge the source: the addon can only report that value moved while it wasn't watching, not whether it came from a legitimate source (mob loot, quest gold) or a Guild Found breach. It's a review signal, not proof.
- **Bank is tracked too.** Since bank contents can only be read while the bank window is open, an item hidden in the bank while the addon was off is caught the next time the member opens their bank with the addon running — moving items between bags and the bank normally never flags.
- Best-effort, like every integrity signal: a modified addon can still forge it. It closes the "turn the addon off, move value, turn it back on" loophole for the lazy case, not a determined one.

---

## [0.7.0] - 2026-07-09

### Added
- **Catch members who play with the addon turned off.** A new guild-leader check (Guild Settings → Enforcement Behavior → **"Flag playing without the addon"**) compares your character's server *total time played* against the time the addon was actually loaded. Any time you play with the addon disabled or uninstalled shows up as a gap, and once it passes the tolerance you set (0–10 minutes, in 1-minute steps; default **5 minutes**), you're flagged **out of compliance** ("played 2.4h without addon"). Unlike "Addon Not Detected", this is **retroactive and durable** — the gap is baked into your `/played`, so it's caught the next time you log in with the addon even if no officer was watching at the time. This closes the common "turn the addon off for the raid, turn it back on after" loophole.
- **Playing the same character on multiple PCs is handled.** Each computer keeps its own record, so on its own an alternate PC would mistake the hours you played on your *other* PC for time without the addon. To prevent that, your addon shares the highest playtime it has witnessed with the guild, and when you log in on another PC it asks the guild for that value and adopts it — so honest multi-PC play isn't flagged, while genuinely playing with the addon off (on *any* PC) still is. If no guildmate who has seen your other PC is online to answer, the alternate PC may flag you until it catches up; an officer can forgive it.
- **Officers can forgive a played-without-addon gap.** The roster's **"Clear"** button (and `/sodlock clearflag`) now also forgives this gap: it tells the member's client to reset its counter, so the flag genuinely clears guild-wide and only returns if they rack up *new* time with the addon off.
- **Guild Found: blocked mail is now marked right in your inbox.** When the mail restriction is on, any mail you can't open is covered with a **"Blocked"** overlay in the inbox list, so you can see at a glance which letters are locked. Blocked **player** mail also gets a **"Return"** button to send it straight back to the sender.

### Changed
- **Guild config changes now announce exactly what changed.** When an officer toggles a rule (Guild Found trade/mail/AH, enforcement options, trade exceptions, etc.), the whole guild now sees the specific change — e.g. "Guild Found: Trade: enabled (set by <officer>)" — instead of the generic "Ruleset is now … mode, Phase N" line. Actual phase/mode changes still show the phase line as before.
- **Guild Found: you can now allow trading items still in their trade window.** A new checkbox under the **Trade Between Guild Members** toggle ("Allow items still in their trade window") lets recently group-looted bind-on-pickup drops — the ones you can still hand to players who were eligible to loot them — be traded outside the guild, without having to list each item. Off by default. (The "Allow conjured items" exemption now sits alongside it there too, moved out of the Exceptions window.)
- **Guild Found: only actual player mail is restricted now.** Ordinary NPC and system mail — quest rewards, vendor buyback, in-game support — is no longer blocked. **Auction House mail is still always blocked** while the mail restriction is on (sale proceeds, won auctions, outbid/expired refunds), so there's no way to pull gold or items back in through the AH.
- **Guild Found: removed the pop-up nag when opening the mailbox.** It used to warn every time you opened your mail if any outsider letter was sitting there; now you're only warned when you actually try to open or take from blocked mail (and the inbox "Blocked" overlay shows which).
- **Options: the Enforcement Behavior settings stay in a tidy two-column layout** regardless of how wide you make the options window.

### Notes
- Only playtime *after* you install the addon is ever counted — your prior `/played` is never held against you.
- Best-effort, like every integrity signal: a modified addon can still forge it, and a client that disables addons after a patch can accrue an innocent gap (the tolerance and the officer forgive are the mitigations).

---

## [0.6.9] - 2026-07-09

### Fixed
- **Turning the addon off no longer hides a Guild Found opt-out.** A member who simply unchecked **Enable** stopped enforcing every Guild Found restriction while still reporting as compliant, because the tamper check compared the *guild's* settings against themselves rather than against whether the member was actually enforcing anything. Members now report their master on/off switch, so anyone who disables the addon while the guild has any Guild Found restriction active is flagged **"Guild Found disabled locally"** — saved and officer-cleared like the other integrity flags.
- **The Auction House block now also covers buying.** The extra safety net (beyond closing the window) previously only stopped *posting* auctions; it now also blocks placing bids and buying commodities, so gold can't leave via a buyout either.
- **Trading conjured items with the "Allow Conjured Items" exception no longer gets wrongly blocked.** When a trade partner's item hadn't finished loading on your client, it could be treated as non-conjured and block the trade; the addon now loads the missing data and re-checks automatically, freeing the Trade button once it resolves.

### Changed
- **Enchanting and lockpicking services now respect the Trade restriction.** With "Trade Between Guild Members" on, casting an enchant or picking a lockbox for someone outside your guild (an item placed in the trade window's "will not be traded" slot) is now blocked just like a normal cross-guild trade.

---

## [0.6.8] - 2026-07-07

### Changed
- **"Addon Not Detected" is now saved, so members without the addon leave a record.** Previously the officer-only "Addon Not Detected" list was computed live and only ever showed members who were **online right then** — so someone who never installs the addon (or fully disables it) simply vanished from the roster the moment they logged off, and an officer who wasn't watching never saw them. Now, once a member has been **online for a sustained period with no status report at all**, that fact is **saved** and keeps showing (marked "saved") even after they log off — until an **officer clears it**, exactly like the Guild Found flag. If they later install the addon and start reporting, the record clears itself automatically. Officers clear a saved record with the same **"Clear"** button or **`/sodlock clearflag <player>`** (which now clears any saved flag on a member).

### Notes
- This is best-effort, like all of the addon's integrity signals: it flags "not provably running the addon," which can't be told apart from "still loading" for a short while (hence the sustained-silence delay) and can be defeated by a modified addon that fakes reports.

---

## [0.6.7] - 2026-07-07

### Changed
- **A "Guild Found disabled locally" flag now sticks until an officer clears it.** Previously this warning was recalculated from each member's status update, so anyone caught disabling a Guild Found restriction could make it disappear simply by turning the restriction back on (or relogging) before an officer looked. Now the first time a member is caught, the flag is **saved** and they keep showing as out of compliance — even once their addon reports clean again — until an **officer** clears it. The clear is **synced to the whole guild**, so it lifts for every officer at once, and a member cannot clear their own flag. If they start tampering again after being cleared, they are simply re-flagged.
- Officers clear a saved flag either from the **Compliance window** (a new "Clear" button on the flagged member's row) or with **`/sodlock clearflag <player>`**.

---

## [0.6.6] - 2026-07-06

### Fixed
- **Members no longer stay stuck showing "out-of-sync ruleset."** A member who missed a ruleset broadcast because they were loading in, briefly out of range, or the guild-channel message got dropped could sit flagged as out-of-sync in the Compliance roster indefinitely, since the only resync retry ran once shortly after login. Every member now notices when a guildmate's regular status update reports a newer ruleset than their own and quietly asks the guild to resend it, so stragglers catch up on their own within a minute or two without needing to relog. The extra request is throttled and answered just once guild-wide, so it adds no meaningful channel traffic even in large guilds.

---

## [0.6.5] - 2026-07-05

### Fixed
- **More Phase-1 enchants no longer flagged as "later phase."** A full audit of every Phase-1 enchant against the internal enchant-ID table found two more that were being flagged (and, with "block over-phase gear" on, removed) under an earlier-phase lock — because they share an internal enchant ID with a genuinely later enchant on a *different* slot: **Lesser Spirit** (2H Weapon / Bracer / Shield — shares the "Spirit +3" ID with *Boots - Lesser Spirit*) and **Shield - Lesser Protection** (shares the "Armor +30" ID with *Cloak - Defense*, despite the different name). Both are now correctly available from Phase 1. As with the 0.6.4 cases, the genuinely-later siblings (*Boots - Lesser Spirit*, *Cloak - Defense*) are no longer enforced in earlier phases, since the game can't tell them apart from the item link.

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
