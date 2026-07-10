local ADDON, ns = ...
local Addon = ns.Addon
local Compliance = Addon:NewModule("Compliance")
ns.Compliance = Compliance

-- roster[playerName] = {
--   level, phase, mode, epoch, overLevel, instance, gear, enchant, profession,
--   xpLocked (bool, informational — not a violation),
--   compliant (bool), reasons (string), updated (GetTime())
-- }
Compliance.roster = {}

-- Seconds before a member's report is considered stale. Tracks Comm's adaptive
-- ping cadence (large guilds ping slower) so a slow report isn't evicted before
-- its replacement arrives; falls back to 300 if Comm isn't up yet.
local function staleAfter()
    return (ns.Comm and ns.Comm.StaleAfter and ns.Comm:StaleAfter()) or 300
end

-- Compact human duration for the played-without-addon reason ("2.4h" / "45m").
local function fmtDuration(seconds)
    seconds = seconds or 0
    if seconds >= 3600 then
        return string.format("%.1fh", seconds / 3600)
    end
    return string.format("%dm", math.floor(seconds / 60))
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
    -- Tamper signal: a Guild Found restriction the guild has ON, but this member's addon
    -- reports OFF locally — their SavedVariables were edited to opt out. Guild Found is
    -- ONLY ever guild-controlled and always advances with the epoch, so an honest member
    -- AT OUR EPOCH necessarily reports the same gf we hold; only a local edit can differ.
    --
    -- Gate the WHOLE check on equal epoch: a member who simply hasn't synced yet (lower
    -- epoch — a stale pre-sync ping, or someone returning after time offline whose ruleset
    -- is still at its all-off defaults) must NOT be mis-flagged. That case is already
    -- surfaced as "out-of-sync ruleset"; without this gate the default-off gf tripped a
    -- PERSISTED "Guild Found disabled locally" during the login/sync window. A modified
    -- addon can still forge these to match; this only catches the low-effort SavedVars edit.
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
        -- Observing the tamper writes a persisted flag the first time; from then on
        -- it sticks regardless of what this member reports, until an officer clears it.
        if overridden then self:SetGFFlag(name) end
    end

    -- (Removed) Master-switch tamper check on `data.en`: it assumed a local "Enable"
    -- box a member could uncheck to evade enforcement, but db.profile.enabled has no
    -- UI toggle or command — it's always true under normal, guild-locked use. The only
    -- way `en` reaches 0 is a stale/hand-edited SavedVar, which false-flagged the guild
    -- leader with a persistent flag that stuck until manually cleared. See PROGRESS.md.

    -- A persisted Guild Found flag holds the member out of compliance even when
    -- this ping is clean (they toggled the addon back on) — only an officer clears it.
    if self:IsGFFlagged(name) then
        reasons[#reasons + 1] = "Guild Found disabled locally"
    end

    self.roster[name] = {
        level      = data.lvl,
        phase      = data.phase,
        mode       = data.mode,
        epoch      = data.epoch,
        overLevel  = data.vL == 1,
        instance   = data.vI == 1,
        gear       = data.vG or 0,
        enchant    = data.vE or 0,
        profession = data.vP == 1,
        quest      = data.vQ or 0,
        rune       = data.vR == 1,
        xpLocked   = data.vX == 1,   -- informational; intentionally excluded from reasons/compliant
        unobserved = data.up or 0,   -- reported /played-with-addon-off seconds (drives the Clear/forgive button)
        compliant  = (#reasons == 0),
        reasons    = (#reasons == 0) and "OK" or table.concat(reasons, ", "),
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
    if not flagged and not played then return false end
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
