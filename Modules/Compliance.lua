local ADDON, ns = ...
local Addon = ns.Addon
local Compliance = Addon:NewModule("Compliance")
ns.Compliance = Compliance

-- roster[playerName] = {
--   level, phase, mode, epoch, overLevel, instance, gear, enchant, profession,
--   xpLocked (bool, informational — not a violation),
--   bagGear (count, informational — over-phase items carried in bags; not a violation),
--   compliant (bool), reasons (string), updated (GetTime())
-- }
Compliance.roster = {}

-- Seconds before a member's report is considered stale. Tracks Comm's adaptive
-- ping cadence (large guilds ping slower) so a slow report isn't evicted before
-- its replacement arrives; falls back to 300 if Comm isn't up yet.
local function staleAfter()
    return (ns.Comm and ns.Comm.StaleAfter and ns.Comm:StaleAfter()) or 300
end

-- How long a Guild Found gf mismatch must PERSIST at our epoch before we set the
-- "disabled locally" flag. A freshly-logged-in member can briefly report stale/default
-- Guild Found until the equal-epoch reconcile (Comm's "R" handler) corrects them on
-- their REQ->R answer; this grace lets an honest-but-converging member self-correct
-- without ever flashing flagged. A genuine SavedVars opt-out keeps mismatching and is
-- flagged once the grace elapses.
local GF_MISMATCH_GRACE = 120

-- Compact human duration for the played-without-addon reason ("2.4h" / "45m").
local function fmtDuration(seconds)
    seconds = seconds or 0
    if seconds >= 3600 then
        return string.format("%.1fh", seconds / 3600)
    end
    return string.format("%dm", math.floor(seconds / 60))
end

-- Sign-aware money for the wealth-integrity reason. Renders the exact amount down to
-- copper ("+5g 11s 13c" / "-3s"), listing only the nonzero units, so a genuine sub-gold
-- change is never rounded away to a misleading "+0g" (the trigger flags ANY nonzero copper
-- — see Record's moneyHit — so the display must be able to express amounts under 1g).
local function fmtMoney(copper)
    copper = copper or 0
    local sign = (copper < 0) and "-" or "+"
    local abs = math.abs(copper)
    local g = math.floor(abs / 10000)
    local s = math.floor((abs % 10000) / 100)
    local c = abs % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    if #parts == 0 then parts[1] = "0c" end
    return sign .. table.concat(parts, " ")
end

-- Coarse, single-unit "~Ng" for the best-effort wealth-value footnote (0.7.9+). Deliberately
-- imprecise: the value is a vendor-sell-price ESTIMATE, so a rounded magnitude reads honestly
-- where a to-the-copper figure would imply precision the signal doesn't have.
local function fmtApprox(copper)
    copper = copper or 0
    if copper >= 10000 then
        return string.format("~%dg", math.floor(copper / 10000))
    elseif copper >= 100 then
        return string.format("~%ds", math.floor(copper / 100))
    else
        return string.format("~%dc", copper)
    end
end

-- ---------------------------------------------------------------------------
-- Persisted integrity flags (see Core.lua db.global.gfFlags).
--
-- Two kinds of best-effort violation are SAVED so they survive the member
-- toggling their addon / relogging, and can only be cleared by an OFFICER (the
-- clear syncs guild-wide, so a member can't clear their own record):
--
--   gf      — "Guild Found disabled locally": observed from a status ping whose
--             local Guild Found state contradicts the guild's. Sticks even once
--             the member reports clean again (that clean report IS the evasion) —
--             only an officer clears it.
--   noaddon — "Addon not detected": the member was ONLINE for a sustained period
--             with no status ping at all (no addon / addon off / blocking sync).
--             Unlike gf, a real ping is affirmative proof of participation, so
--             this one auto-clears the moment we hear from them (see Record); the
--             officer clear is for dismissing the saved record of someone who
--             stays gone (e.g. offline / left the guild).
--
-- (The Guild Found wealth-integrity discrepancy is NOT a saved flag: like the played
-- gap it is a durable counter in the MEMBER's own SavedVariables, reported every ping
-- until an officer forgives it via Comm "WGF", so it needs no receiver-side record. It
-- is derived live in Record and drives the Clear button through HasWealthGap. See
-- Modules/Integrity.lua.)
--
-- Entry: bucket[lc-name] = { name = <ProperShort>, gf = <time()>, noaddon = <time()> }
-- (a key present ⇒ flagged for that reason). Keyed by lowercased short name so
-- ping / UI / slash lookups agree regardless of case.
-- ---------------------------------------------------------------------------
local function flagKey(name)
    return name and Ambiguate(name, "short"):lower() or nil
end

local function flagsBucket()
    return Addon.db.global.gfFlags[Addon:GuildKey()]
end

-- ---------------------------------------------------------------------------
-- Played-witness high-water store (cross-PC reconciliation, see Playtime.lua).
-- Persisted per guild, keyed by lc short name → highest witnessed /played (seconds).
-- Only ever moves UP (a max), so it can never be used to falsely accuse a member —
-- adopting a peer's value can only RAISE their baseline and forgive, never flag.
-- ---------------------------------------------------------------------------
local function witnessBucket()
    return Addon.db.global.playedWitness[Addon:GuildKey()]
end

-- Fold a member's reported `observed` high-water into the store (monotonic max).
function Compliance:NoteWitness(name, ob)
    if type(ob) ~= "number" or ob <= 0 then return end
    local key = flagKey(name)
    if not key then return end
    local b = witnessBucket()
    if (b[key] or 0) < ob then b[key] = ob end
end

-- Highest witnessed /played we hold for a member (used to answer a "PWQ" query).
function Compliance:GetWitness(name)
    local key = flagKey(name)
    return key and witnessBucket()[key] or nil
end

-- Fetch (optionally create) the flag entry for a name.
local function flagEntry(name, create)
    local k = flagKey(name)
    if not k then return nil end
    local b = flagsBucket()
    if not b[k] and create then
        b[k] = { name = Ambiguate(name, "short") }
    end
    return b[k], k
end

function Compliance:IsGFFlagged(name)
    local e = flagEntry(name)
    return e ~= nil and e.gf ~= nil
end

function Compliance:IsNoAddonFlagged(name)
    local e = flagEntry(name)
    return e ~= nil and e.noaddon ~= nil
end

-- Any saved flag at all — drives the officer "Clear" button on a roster row.
function Compliance:IsFlagged(name)
    local e = flagEntry(name)
    return e ~= nil and (e.gf ~= nil or e.noaddon ~= nil)
end

function Compliance:SetGFFlag(name)
    local e = flagEntry(name, true)
    if e and not e.gf then e.gf = time() end
end

function Compliance:SetNoAddonFlag(name)
    local e = flagEntry(name, true)
    if e and not e.noaddon then e.noaddon = time() end
end

-- Drop just the "addon not detected" flag (the member started pinging again), and
-- the whole entry if nothing is left on it. The gf flag is deliberately untouched.
function Compliance:ClearNoAddonFlag(name)
    local e, k = flagEntry(name)
    if not e then return end
    e.noaddon = nil
    if not e.gf then flagsBucket()[k] = nil end
end

-- Self-heal counterpart to ClearNoAddonFlag: drop just the "Guild Found disabled locally"
-- flag when the member is observed back in sync (matching gf at our epoch), dropping the
-- whole entry if nothing is left. Local-only — every officer's client heals independently as
-- it sees the corrected ping, so unlike the officer Clear action this needs no "GFC" broadcast.
function Compliance:ClearGFFlagAuto(name)
    local e, k = flagEntry(name)
    if not e or not e.gf then return end
    e.gf = nil
    if not e.noaddon then flagsBucket()[k] = nil end
end

-- Remove ALL saved flags for a member (the officer "Clear" action clears the
-- whole record). Callers handle any broadcast.
function Compliance:ClearFlag(name)
    local k = flagKey(name)
    if k then flagsBucket()[k] = nil end
end

-- Record an incoming status report and derive compliance against OUR ruleset.
function Compliance:Record(sender, data)
    if not sender then return end
    local name = Ambiguate(sender, "short")

    -- Hearing from them at all is affirmative proof the addon is running, so any
    -- saved "addon not detected" flag is now false — drop it and stop tracking.
    self:ClearNoAddonFlag(name)
    if self._unreportedSince then self._unreportedSince[flagKey(name)] = nil end

    -- Remember the highest /played their addon has witnessed, so if they later log in
    -- on a fresh/alternate PC they can adopt it instead of false-flagging honest
    -- multi-PC play (see Playtime.lua reconciliation).
    if data.ob then self:NoteWitness(name, data.ob) end

    local reasons = {}
    if data.epoch ~= Addon:GetRuleset().epoch then
        reasons[#reasons + 1] = "out-of-sync ruleset"
    end
    if data.vL == 1 then reasons[#reasons + 1] = "over level cap" end
    if data.vI == 1 then reasons[#reasons + 1] = "in locked instance" end
    if (data.vG or 0) > 0 then reasons[#reasons + 1] = string.format("%d invalid item(s)", data.vG) end
    if (data.vE or 0) > 0 then reasons[#reasons + 1] = string.format("%d later-phase enchant(s)", data.vE) end
    if data.vP == 1 then reasons[#reasons + 1] = "profession over cap" end
    if (data.vQ or 0) > 0 then reasons[#reasons + 1] = string.format("%d quest(s) from later phase", data.vQ) end
    if data.vR == 1 then reasons[#reasons + 1] = "rune from later phase" end
    -- Played-without-addon: the member reports raw cumulative unobserved /played (`up`);
    -- we apply the guild-leader-synced threshold receiver-side (0 = check off). This is
    -- the durable complement to "Addon Not Detected" — see Modules/Playtime.lua.
    local playedThr = Addon:PlayedGapThreshold()
    if playedThr > 0 and (data.up or 0) >= playedThr then
        reasons[#reasons + 1] = string.format("played %s without addon", fmtDuration(data.up))
    end
    -- Guild Found wealth integrity: gold/items that moved across a window the member's
    -- addon was unloaded (see Modules/Integrity.lua). Evaluated only when Guild Found is
    -- active in OUR ruleset (open economy ⇒ nothing to reconcile); a member who hasn't
    -- synced never accumulated (their own Guild Found was off), so they report zero and
    -- can't be false-flagged. No tolerance — in a closed economy no play without the addon
    -- is acceptable, so ANY change flags. Durable like the played gap — reported every ping
    -- until an officer forgives it — so no saved flag is needed.
    if Addon:WealthIntegrityOn() then
        -- 0.7.9+ reports a single estimated-value scalar (`wv`); the authoritative signal is the
        -- /played gap above, so this is a best-effort footnote, deliberately fuzzy ("~5g, est.")
        -- rather than the old false-precision "+5g 11s 13c, 3 item(s)". A pre-0.7.9 member sends
        -- no `wv`; fall back to their legacy wm/wq so a mixed-version officer still sees the flag.
        if data.wv ~= nil then
            -- Floored at ns.WEALTH_VALUE_FLOOR (1g): below that the estimate is noise. See
            -- Addon:WealthValueReportable.
            if Addon:WealthValueReportable(data.wv) then
                reasons[#reasons + 1] = "Guild Found: " .. fmtApprox(data.wv) .. " moved while unmonitored (est.)"
            end
        else
            local moneyHit = (data.wm or 0) ~= 0
            local itemHit  = (data.wq or 0) > 0
            if moneyHit or itemHit then
                local parts = {}
                if moneyHit then parts[#parts + 1] = fmtMoney(data.wm) end
                if itemHit  then parts[#parts + 1] = string.format("%d item(s)", data.wq) end
                reasons[#reasons + 1] = "Guild Found: " .. table.concat(parts, ", ") .. " while addon off"
            end
        end
    end
    -- Tamper signal: a Guild Found restriction the guild has ON, but this member's addon
    -- reports OFF locally — their SavedVariables were edited to opt out.
    --
    -- Gate the whole check on equal epoch: a member who hasn't synced yet (lower epoch — a
    -- stale pre-sync ping, or someone returning after time offline) carries the all-off
    -- defaults and is surfaced as "out-of-sync ruleset" instead. But equal epoch does NOT by
    -- itself prove equal gf: in a mixed-version guild a pre-GuildFound client (≤0.6.x) relays
    -- our epoch WITHOUT the gf payload, leaving a freshly-upgraded 0.7 member at our epoch with
    -- default (all-off) Guild Found through no fault of their own (Comm's "R" handler now
    -- re-syncs to close that window). So this signal must be SELF-HEALING, not sticky: set the
    -- flag while the mismatch persists at our epoch, and CLEAR it the moment the member reports
    -- matching gf. A genuine local edit keeps reporting a mismatch and stays flagged; a rollout
    -- desync clears itself once the member converges. (A code edit can forge a match regardless;
    -- the transient disable→act→re-enable case is covered by wealth integrity, not this flag.)
    if type(data.gf) == "table" and data.epoch == Addon:GetRuleset().epoch then
        local mine = Addon:GetRuleset().guildFound
        local overridden = false
        for _, key in ipairs({ "trade", "mail", "auction" }) do
            if mine[key] and data.gf[key] == false then overridden = true break end
        end
        -- Allowlist tamper: at the same epoch every synced member has an identical trade
        -- allowlist, so a differing count means it was locally widened.
        if not overridden and mine.trade and data.gfxn then
            local myCount = 0
            for _ in pairs(mine.tradeExceptions) do myCount = myCount + 1 end
            if data.gfxn ~= myCount then overridden = true end
        end
        -- Grace before accusing: hold off on the flag until the mismatch has PERSISTED
        -- past GF_MISMATCH_GRACE (transient per-session state), so a member converging
        -- via the equal-epoch reconcile is never briefly flagged. A real opt-out keeps
        -- mismatching and trips it after the grace.
        self._gfMismatchSince = self._gfMismatchSince or {}
        local mk = flagKey(name)
        if overridden then
            local since = self._gfMismatchSince[mk]
            if not since then
                self._gfMismatchSince[mk] = GetTime()
            elseif (GetTime() - since) >= GF_MISMATCH_GRACE then
                self:SetGFFlag(name)
            end
        else
            self._gfMismatchSince[mk] = nil
            self:ClearGFFlagAuto(name)   -- in sync at our epoch → lift any stale flag
        end
    end

    -- (Removed) Master-switch tamper check on `data.en`: it assumed a local "Enable"
    -- box a member could uncheck to evade enforcement, but db.profile.enabled has no
    -- UI toggle or command — it's always true under normal, guild-locked use. The only
    -- way `en` reaches 0 is a stale/hand-edited SavedVar, which false-flagged the guild
    -- leader with a persistent flag that stuck until manually cleared. See PROGRESS.md.

    -- A persisted Guild Found flag holds the member out of compliance even when
    -- this ping is clean (they toggled the addon back on) — only an officer clears it.
    -- Guarded on GuildFoundAny(): if the guild has NO Guild Found restriction active,
    -- "disabled locally" is meaningless, so a stale flag (e.g. left on an offline member
    -- after an officer turned Guild Found off) is never surfaced.
    if self:IsGFFlagged(name) and Addon:GuildFoundAny() then
        reasons[#reasons + 1] = "Guild Found disabled locally"
    end

    -- Over-phase items carried in bags: informational only (bags aren't enforced) and no longer
    -- surfaced in the roster — a member carrying later-phase gear in their bags is not out of
    -- compliance, so it clutters the reasons cell with a non-actionable note. Still stored on the
    -- roster row (and carried on the wire as vBG) in case a future view wants it.
    local bagGear = data.vBG or 0
    local reasonsStr = (#reasons == 0) and "OK" or table.concat(reasons, ", ")

    self.roster[name] = {
        level      = data.lvl,
        phase      = data.phase,
        mode       = data.mode,
        epoch      = data.epoch,
        overLevel  = data.vL == 1,
        instance   = data.vI == 1,
        gear       = data.vG or 0,
        enchant    = data.vE or 0,
        bagGear    = bagGear,        -- informational; over-phase items carried in bags (excluded from reasons/compliant)
        profession = data.vP == 1,
        quest      = data.vQ or 0,
        rune       = data.vR == 1,
        xpLocked   = data.vX == 1,   -- informational; intentionally excluded from reasons/compliant
        version    = data.v,         -- reporter's addon version, for the roster's version column
        unobserved = data.up or 0,   -- reported /played-with-addon-off seconds (drives the Clear/forgive button)
        wealthValue = data.wv,       -- 0.7.9+ estimated net copper value moved across an addon-off gap (nil ⇒ legacy member)
        wealthMoney = data.wm or 0,  -- legacy (pre-0.7.9): signed copper; still shown for a mixed-version member
        wealthItems = data.wq or 0,  -- legacy (pre-0.7.9): quantity of items gained
        wealthLog  = data.wl,        -- legacy (pre-0.7.9): bounded gained-itemID list, for the officer display
        compliant  = (#reasons == 0),
        reasons    = reasonsStr,
        updated    = GetTime(),
        raw        = data,   -- kept so an officer clear can re-derive this row at once
    }

    if ns.RefreshRoster then ns.RefreshRoster() end
end

-- Resolve the properly-cased roster key for a name given in any case (e.g. a
-- slash-command arg), so we can update the live row on a clear.
local function rosterKey(self, name)
    if self.roster[name] then return name end
    local lname = flagKey(name)
    for k in pairs(self.roster) do
        if flagKey(k) == lname then return k end
    end
    return name
end

-- Apply a flag clear locally: drop the persisted flag and re-derive the member's
-- live row so the roster updates immediately (rather than at the next ping). If
-- they are STILL reporting the tamper, re-deriving simply re-flags them — a clear
-- can't whitewash an active violation. Does NOT broadcast (see OfficerClear / the
-- incoming GFC handler, which both call this).
function Compliance:ApplyClear(name)
    self:ClearFlag(name)
    local key = rosterKey(self, name)
    local info = self.roster[key]
    if info and info.raw then
        self:Record(key, info.raw)          -- re-derives + refreshes the roster
    elseif ns.RefreshRoster then
        ns.RefreshRoster()
    end
end

-- Does this member's live roster row currently show a played-without-addon gap over
-- the synced threshold? Drives both the Clear-button visibility and the forgive path.
function Compliance:HasPlayedGap(name)
    local thr = Addon:PlayedGapThreshold()
    if thr <= 0 then return false end
    local info = self.roster[rosterKey(self, name)]
    return info ~= nil and (info.unobserved or 0) >= thr
end

-- Does this member's live row show a Guild Found wealth discrepancy over the synced
-- threshold? Drives the Clear-button visibility and the wealth-forgive path.
function Compliance:HasWealthGap(name)
    if not Addon:WealthIntegrityOn() then return false end
    local info = self.roster[rosterKey(self, name)]
    if not info then return false end
    -- 0.7.9+ uses the value scalar; fall back to legacy money/item fields for a mixed-version member.
    if info.wealthValue ~= nil then return Addon:WealthValueReportable(info.wealthValue) end
    return (info.wealthMoney or 0) ~= 0 or (info.wealthItems or 0) > 0
end

-- Officer action: clear everything an officer can dismiss for a member — the saved
-- integrity flag(s) (Guild Found tamper and/or "addon not detected") AND a
-- played-without-addon gap — and sync it guild-wide so it disappears for every officer
-- (and, for the played gap, so the member resets their own counter). Returns true if
-- there was anything to clear. Gated to officers.
function Compliance:OfficerClear(name)
    if not Addon:IsOfficer() then
        Addon:Print("|cffff3030Only an officer can clear a saved flag.|r")
        return false
    end
    local short   = Ambiguate(name, "short")
    local flagged = self:IsFlagged(name)
    local played  = self:HasPlayedGap(name)
    local wealth  = self:HasWealthGap(name)
    if not flagged and not played and not wealth then return false end
    if flagged then
        self:ApplyClear(name)
        if ns.Comm and ns.Comm.BroadcastGFClear then
            ns.Comm:BroadcastGFClear(short)
        end
    end
    if played and ns.Comm and ns.Comm.BroadcastPlayedForgive then
        -- Reaches the member, who zeroes their counter and re-pings; the row clears on
        -- that ping. Officers take no local action (only the named member does).
        ns.Comm:BroadcastPlayedForgive(short)
    end
    if wealth and ns.Comm and ns.Comm.BroadcastWealthForgive then
        -- Also reset the member's wealth counters — clearing the sticky flag above is not
        -- enough, since their next ping would still report the discrepancy and re-flag them
        -- (same reason the played gap needs a forgive). Only the named member acts.
        ns.Comm:BroadcastWealthForgive(short)
    end
    return true
end

-- Return a sorted array of {name, info} with stale entries dropped, for the UI.
function Compliance:GetSorted()
    local now = GetTime()
    local list = {}
    for name, info in pairs(self.roster) do
        if (now - info.updated) <= staleAfter() then
            list[#list + 1] = { name = name, info = info }
        end
    end
    table.sort(list, function(a, b)
        if a.info.compliant ~= b.info.compliant then
            return not a.info.compliant   -- violators first
        end
        return a.name < b.name
    end)
    return list
end

-- Integrity / attestation signal: guild members we have NOT heard a fresh status
-- ping from — the addon is off, not installed, or blocking the guild addon
-- channel. Cross-references the live guild roster against the ping roster. This is
-- the strongest we can do against "just don't run the addon": prevention is
-- impossible on an untrusted client, so we surface non-participation to officers.
-- Best-effort — a modified addon can still forge pings; see PROGRESS.md → integrity model.

-- Lowercased-name set of members whose status report is still fresh.
local function heardSet(self)
    local now, heard = GetTime(), {}
    for name, info in pairs(self.roster) do
        if (now - info.updated) <= staleAfter() then heard[flagKey(name)] = true end
    end
    return heard
end

-- Map of lc-name → ProperShort for every ONLINE guild member except ourselves.
local function onlineMembers()
    local map = {}
    if not IsInGuild() then return map end
    local me = flagKey(UnitName("player"))
    local total = GetNumGuildMembers() or 0
    for i = 1, total do
        local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if fullName and isOnline then
            local short = Ambiguate(fullName, "short")
            local lc = short:lower()
            if lc ~= me then map[lc] = short end
        end
    end
    return map
end

-- Periodic attestation scan (driven by Comm's status tick). Tracks how long each
-- online member has gone with NO status ping; once that exceeds the stale window
-- they're SAVED as "addon not detected" so the record survives their logout. A
-- member who pings or logs off stops being tracked (and a ping auto-clears any
-- saved flag, in Record), so only sustained online silence persists — which keeps
-- a member still loading in or mid-sync from being flagged.
function Compliance:ScanAttestation()
    if not IsInGuild() then return end
    local now = GetTime()
    local heard = heardSet(self)
    local online = onlineMembers()
    local since = self._unreportedSince
    if not since then since = {}; self._unreportedSince = since end
    local threshold = staleAfter()
    local changed = false

    -- Stop tracking anyone who is no longer online-and-silent.
    for lc in pairs(since) do
        if not online[lc] or heard[lc] then since[lc] = nil end
    end
    for lc, short in pairs(online) do
        if not heard[lc] then
            since[lc] = since[lc] or now
            if (now - since[lc]) >= threshold and not self:IsNoAddonFlagged(short) then
                self:SetNoAddonFlag(short)
                changed = true
            end
        end
    end
    if changed and ns.RefreshRoster then ns.RefreshRoster() end
end

-- Rows for the officer-only "Addon Not Detected" roster section. Each row is
-- { name, online (bool), saved (bool) }. Includes every online member with no
-- fresh ping PLUS any member carrying a saved "addon not detected" flag (even
-- offline), so the record shows after they log off. Members with a fresh ping are
-- excluded — they appear in the compliant/violation list instead.
function Compliance:GetIntegrityRows()
    if not IsInGuild() then return {} end
    local me = flagKey(UnitName("player"))
    local heard = heardSet(self)
    local online = onlineMembers()
    local rows, seen = {}, {}

    for lc, short in pairs(online) do
        if not heard[lc] then
            rows[#rows + 1] = { name = short, online = true, saved = self:IsNoAddonFlagged(short) }
            seen[lc] = true
        end
    end
    for lc, e in pairs(flagsBucket()) do
        if e.noaddon and lc ~= me and not seen[lc] and not heard[lc] then
            rows[#rows + 1] = { name = e.name or lc, online = online[lc] ~= nil, saved = true }
            seen[lc] = true
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end
