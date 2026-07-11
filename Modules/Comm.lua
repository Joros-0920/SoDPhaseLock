local ADDON, ns = ...
local Addon = ns.Addon
local Comm = Addon:NewModule("Comm", "AceComm-3.0", "AceTimer-3.0")
ns.Comm = Comm

local LibSerialize = LibStub("LibSerialize")
local LibDeflate   = LibStub("LibDeflate")
local PREFIX       = ns.COMM_PREFIX

-- Our own version, read from the .toc. Rides along on the status/ruleset messages
-- that already flow guild-wide (no extra traffic), so peers can tell each other
-- when a newer build is out. C_AddOns is the modern namespace; fall back for older
-- clients.
local VERSION = (((C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata)(ADDON, "Version")) or "0"
ns.Version = VERSION

-- Parse a version string into a list of numeric components ("0.5.3" -> {0,5,3}),
-- ignoring any non-numeric suffix. Component-wise numeric compare so 0.5.10 > 0.5.3.
local function parseVersion(s)
    local t = {}
    for num in tostring(s):gmatch("%d+") do
        t[#t + 1] = tonumber(num)
    end
    return t
end

-- -1 if a < b, 0 if equal, 1 if a > b.
local function compareVersions(a, b)
    local pa, pb = parseVersion(a), parseVersion(b)
    local n = math.max(#pa, #pb)
    for i = 1, n do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return (x < y) and -1 or 1 end
    end
    return 0
end

-- Message types: "R" ruleset, "REQ" request current ruleset, "S" status,
--                "GFC" officer-cleared a persisted Guild Found tamper flag,
--                "PGF" officer forgave a played-without-addon gap,
--                "WGF" officer forgave a Guild Found wealth-integrity discrepancy,
--                "PWQ"/"PWA" played-witness query/answer
--
-- Traffic budget: WoW's server drops guild addon messages above a low aggregate
-- rate, so everything below is designed to keep guild-wide chatter bounded even
-- at ~1000 members (see PROGRESS.md → scaling notes).
local STATUS_MIN     = 60     -- floor interval; small guilds keep the old cadence
local STATUS_MAX     = 300    -- ceiling interval for very large guilds
local TARGET_CPS     = 4      -- target guild-wide status msgs/sec (interval = online / this)
local REQ_SPREAD     = 6      -- window (s) a queued REQ reply is jittered across
local REQ_SUPPRESS   = 8      -- don't re-answer a REQ within this long of the last ruleset seen/sent
local PWA_SUPPRESS   = 8      -- don't re-answer a played-witness query if one was seen this recently

-- ---------------------------------------------------------------------------
local function pack(tbl)
    local serialized = LibSerialize:Serialize(tbl)
    local compressed = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

local function unpack(encoded)
    local compressed = LibDeflate:DecodeForWoWAddonChannel(encoded)
    if not compressed then return nil end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil end
    local ok, tbl = LibSerialize:Deserialize(serialized)
    if not ok then return nil end
    return tbl
end

local function send(tbl)
    if not IsInGuild() then return end
    Comm:SendCommMessage(PREFIX, pack(tbl), "GUILD")
end

-- ---------------------------------------------------------------------------
-- Ask the current guild to send us its ruleset (login + on guild change).
function Comm:RequestSync()
    send({ t = "REQ" })
end

-- A peer's status ping reports a newer ruleset epoch than ours: we missed a
-- broadcast (were loading, out of comm range, or the "R" got rate-limited) and
-- would otherwise show as "out-of-sync" forever, since the login REQ retry only
-- fires while epoch is still 0. Ask the guild to resend.
--
-- Throttled to one in-flight request, jittered, and suppressed right after we've
-- heard an authoritative ruleset so a wave of stragglers doesn't storm the
-- channel. The reply is officer-validated and epochs are monotonic
-- (ApplyRuleset rejects anything <= ours), so a stale answer can't set us back.
function Comm:MaybeResync()
    if self.resyncTimer then return end                                        -- already asking
    if self.lastRulesetSeen and (GetTime() - self.lastRulesetSeen) < REQ_SUPPRESS then
        return                                                                 -- just heard one; give it a beat
    end
    self.resyncTimer = self:ScheduleTimer(function()
        self.resyncTimer = nil
        -- An "R" may have caught us up while we waited — only ask if still quiet.
        if self.lastRulesetSeen and (GetTime() - self.lastRulesetSeen) < REQ_SUPPRESS then
            return
        end
        self:RequestSync()
    end, 1 + math.random() * REQ_SPREAD)
end

-- Count of *online* guild members — the number of clients actually sending, and
-- the driver for our adaptive cadence. Returns nil until the roster has loaded
-- (GetNumGuildMembers is 0 pre-load) so callers can fall back conservatively.
local function onlineGuildCount()
    if not IsInGuild() then return 1 end
    local total = GetNumGuildMembers() or 0
    if total == 0 then return nil end
    local online = 0
    for i = 1, total do
        local isOnline = select(9, GetGuildRosterInfo(i))
        if isOnline then online = online + 1 end
    end
    return online > 0 and online or 1
end

-- Status cadence scaled so the whole guild emits ~TARGET_CPS status msgs/sec.
-- Small guilds stay at the 60s floor; a 1000-online guild stretches to ~250s.
function Comm:StatusInterval()
    local n = onlineGuildCount()
    if not n then
        -- Roster not loaded yet — nudge it and assume a large guild until we know.
        if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
        elseif GuildRoster then GuildRoster() end
        n = 200
    end
    local t = n / TARGET_CPS
    if t < STATUS_MIN then t = STATUS_MIN end
    if t > STATUS_MAX then t = STATUS_MAX end
    return t
end

-- Staleness window scales with cadence so a slower large-guild ping isn't
-- evicted from the roster before its next report arrives.
function Comm:StaleAfter()
    return math.max(300, self:StatusInterval() * 3)
end

-- Self-rescheduling status timer with per-cycle jitter (0.5x..1.5x the base
-- interval). Independent random offsets across clients de-phase the herd so
-- reports arrive spread out rather than in 60s-boundary bursts.
function Comm:StatusTick()
    self:SendStatus()
    -- Piggyback the attestation scan on the same periodic beat: notice members who
    -- have been online a sustained time with no ping and save an "addon not
    -- detected" record for them (see Compliance:ScanAttestation).
    if ns.Compliance and ns.Compliance.ScanAttestation then ns.Compliance:ScanAttestation() end
    self:ScheduleStatus()
end

function Comm:ScheduleStatus()
    local delay = self:StatusInterval() * (0.5 + math.random())
    self.statusTimer = self:ScheduleTimer("StatusTick", delay)
end

function Comm:OnEnable()
    -- WoW's Lua sandbox has no math.randomseed (math.random is auto-seeded per
    -- session). To keep clients that share the generator's state from jittering
    -- in lockstep, advance the sequence a per-client number of steps derived from
    -- the player name + local uptime before we draw any jitter below.
    local advance = math.floor((GetTime() * 1000) % 97)
    local name = UnitName("player") or ""
    for i = 1, #name do advance = advance + name:byte(i) * i end
    for _ = 1, (advance % 251) + 1 do math.random() end

    self:RegisterComm(PREFIX, "OnComm")
    -- On login: ask the guild for the current ruleset (jittered to avoid a
    -- mass-login REQ burst), then start status pings.
    self:ScheduleTimer("RequestSync", 2 + math.random() * 6)
    -- Ask the guild for our own witnessed-/played high-water so an alternate PC adopts
    -- it before Playtime attributes any login gap (see Modules/Playtime.lua). Jittered
    -- like REQ, and well inside Playtime's reconciliation window.
    self:ScheduleTimer("RequestPlayedWitness", 2 + math.random() * 6)
    -- Retry once if nobody answered the first REQ (e.g. guild leader offline,
    -- other members still loading). Only fires when epoch is still 0, so it is
    -- free for anyone who already synced.
    self:ScheduleTimer(function()
        if Addon:GetRuleset().epoch == 0 then self:RequestSync() end
    end, 25 + math.random() * 20)
    -- First status shortly after login (jittered), then self-reschedule.
    self:ScheduleTimer("StatusTick", 6 + math.random() * 8)
end

-- ---------------------------------------------------------------------------
-- Outgoing
-- ---------------------------------------------------------------------------
-- Build the "R" (ruleset) payload from our current ruleset, including the
-- guild-controlled enforcement config so members adopt the whole thing.
local function rulesetPayload()
    local r = Addon:GetRuleset()
    return {
        t       = "R",
        phase   = r.phase,
        mode    = Addon:GetEffectiveMode(),  -- derived; the enforce table is authoritative
        epoch   = r.epoch,
        by      = r.setBy,
        enforce = r.enforce,
        auto    = r.autoUnequip,
        grace   = r.instanceGrace,
        npd     = r.nextPhaseDate,
        gf      = r.guildFound,
        pgc     = r.playedGapCheck,   -- played-without-addon check on/off (guild leader)
        pgg     = r.playedGapGrace,   -- tolerated unobserved-play minutes before flagging
        orank   = r.officerRankIndex, -- guild-rank threshold for officer authority (0 = GM)
        v       = VERSION,
    }
end

function Comm:BroadcastRuleset()
    -- Mark that the guild just heard an authoritative ruleset, so we suppress
    -- any REQ replies for a beat (REQ_SUPPRESS) instead of piling on.
    self.lastRulesetSeen = GetTime()
    send(rulesetPayload())
end

-- Number of item IDs on our local trade allowlist. Members synced to the same
-- epoch must have an identical allowlist, so a differing count at equal epoch means
-- the SavedVariables were edited to widen what's tradeable (see integrity model).
local function gfExceptionCount()
    local n = 0
    for _ in pairs(Addon:GetRuleset().guildFound.tradeExceptions) do n = n + 1 end
    return n
end

function Comm:SendStatus()
    if not IsInGuild() then return end
    local v = ns.Enforcement and ns.Enforcement.violations or {}
    send({
        t     = "S",
        lvl   = UnitLevel("player"),
        phase = Addon:GetActivePhase(),
        mode  = Addon:GetEffectiveMode(),
        epoch = Addon:GetRuleset().epoch,
        vL    = v.overLevel and 1 or 0,
        vI    = v.instance and 1 or 0,
        vG    = v.gear or 0,
        vE    = v.enchant or 0,
        vP    = v.profession and 1 or 0,
        vQ    = v.quest or 0,
        vR    = v.rune and 1 or 0,
        vX    = IsXPUserDisabled() and 1 or 0,   -- XP gains disabled at NPC (informational, not a violation)
        -- Local Guild Found state, for tamper detection vs the authoritative ruleset.
        gf    = {
            trade   = Addon:GuildFound("trade"),
            mail    = Addon:GuildFound("mail"),
            auction = Addon:GuildFound("auction"),
        },
        gfxn  = gfExceptionCount(),              -- size of local trade allowlist (tamper check vs authoritative at same epoch)
        en    = Addon.db.profile.enabled and 1 or 0,  -- local master switch; 0 ⇒ NOTHING is enforced (Guild Found included)
        up    = (ns.Playtime and ns.Playtime:GetUnobserved()) or 0,  -- cumulative /played seconds accrued with the addon NOT loaded
        ob    = ns.Playtime and ns.Playtime:GetObserved() or nil,    -- witnessed-/played high-water, so peers can reconcile our alternate PCs
        -- Guild Found wealth integrity: cumulative gold/items that moved across an
        -- addon-off gap (see Modules/Integrity.lua). Receivers evaluate against the
        -- synced threshold and set a sticky flag, like the played gap above.
        wm    = (ns.Integrity and ns.Integrity:GetUnaccountedMoney()) or 0,  -- signed copper
        wq    = (ns.Integrity and ns.Integrity:GetUnaccountedItems()) or 0,  -- distinct itemIDs gained
        wl    = ns.Integrity and ns.Integrity:GetItemLog() or nil,           -- bounded gained-itemID list (display)
        v     = VERSION,                         -- addon version, for out-of-date detection
    })
end

-- An officer cleared a member's saved integrity flag(s) (Guild Found tamper and/or
-- "addon not detected"). Broadcast it guild-wide so the clear lands on every
-- officer's client, not just the one who issued it. Carries the clearing officer's
-- name (`by`) for authority validation on receipt — same trust model as "R".
function Comm:BroadcastGFClear(player)
    if not player or player == "" then return end
    send({ t = "GFC", player = player, by = UnitName("player"), v = VERSION })
end

-- An officer forgave a member's played-without-addon gap. Broadcast guild-wide so it
-- reaches the flagged MEMBER (who resets their local counter) as well as every officer.
-- Carries the officer's name (`by`) for authority validation on receipt, like "GFC".
function Comm:BroadcastPlayedForgive(player)
    if not player or player == "" then return end
    send({ t = "PGF", player = player, by = UnitName("player"), v = VERSION })
end

-- An officer forgave a member's Guild Found wealth-integrity discrepancy. Broadcast
-- guild-wide so it reaches the flagged MEMBER (who zeroes their counters and re-snapshots)
-- as well as every officer. Carries the officer's name (`by`) for authority validation on
-- receipt, exactly like "PGF".
function Comm:BroadcastWealthForgive(player)
    if not player or player == "" then return end
    send({ t = "WGF", player = player, by = UnitName("player"), v = VERSION })
end

-- Ask the guild what /played high-water it has witnessed for US, so an alternate PC
-- (whose local record only knows its own sessions) adopts the shared value and doesn't
-- mistake honest multi-PC play for playing without the addon. Peers answer with "PWA".
function Comm:RequestPlayedWitness()
    if not IsInGuild() then return end
    send({ t = "PWQ", who = UnitName("player"), v = VERSION })
end

-- ---------------------------------------------------------------------------
-- Out-of-date detection
-- ---------------------------------------------------------------------------
-- The highest peer version we've seen this session that is newer than ours
-- (nil while we're up to date). Read by /sodlock status and the options panel.
function Comm:NewerVersion()
    return self.newerVersion
end

-- Fold in a version string reported by a guildmate. If it's newer than ours (and
-- newer than any we've already flagged), remember it and tell the player once —
-- a plain chat notice, not a red Alert, since being behind isn't a rule violation.
function Comm:NotePeerVersion(their)
    if type(their) ~= "string" or their == "" then return end
    if compareVersions(their, VERSION) <= 0 then return end                       -- not newer than us
    if self.newerVersion and compareVersions(their, self.newerVersion) <= 0 then  -- already flagged this (or newer)
        return
    end
    self.newerVersion = their
    Addon:Print(string.format(
        "a newer version |cff00ff00%s|r is available (you have |cffffd100%s|r). Update SoD Phase Lock so you stay in sync with your guild.",
        their, VERSION))
end

-- ---------------------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------------------
function Comm:OnComm(prefix, message, distribution, sender)
    if prefix ~= PREFIX then return end
    local data = unpack(message)
    if not data or not data.t then return end
    local me = UnitName("player")
    if sender ~= me then self:NotePeerVersion(data.v) end

    if data.t == "R" then
        -- Authority is tied to whoever ORIGINALLY set the ruleset (data.by),
        -- not the relayer. Reject unless that origin is an officer.
        if not Addon:IsOfficer(data.by) then return end
        -- Someone authoritative just answered — drop any REQ reply we had queued
        -- and note the sighting so we stay quiet for REQ_SUPPRESS.
        self.lastRulesetSeen = GetTime()
        if self.reqAnswerTimer then
            self:CancelTimer(self.reqAnswerTimer)
            self.reqAnswerTimer = nil
        end
        -- Apply silently: members are not notified in chat when a ruleset is broadcast
        -- to them. The officer who made the change still sees their own local confirmation
        -- (printed on their client by ApplyRuleset / commitGuild).
        local beforeEpoch = Addon:GetRuleset().epoch
        Addon:ApplyRuleset(data.phase, data.mode, data.epoch, data.by,
            data.enforce, data.auto, data.grace, data.npd, data.gf, data.pgc, data.pgg, data.orank, true)
        -- Mixed-version rollout: a pre-GuildFound client (≤0.6.x) relays the ruleset with
        -- NO `gf` payload, so ApplyRuleset can't touch our guildFound (it only writes it when
        -- a gf table is present). If such a relay just ADVANCED our epoch, we now sit at the
        -- guild's current epoch carrying stale/default (all-off) Guild Found — which both
        -- mis-enforces locally AND trips the officer-side "Guild Found disabled locally" tamper
        -- flag (an honest member is falsely accused, since epoch-equality no longer implies
        -- gf-equality). Re-request sync so a gf-bearing ruleset from the leader / any 0.7+ peer
        -- corrects us. One in flight at a time; harmless (idempotent) if we were already synced.
        if data.gf == nil and Addon:GetRuleset().epoch > beforeEpoch and not self.gfResyncTimer then
            self.gfResyncTimer = self:ScheduleTimer(function()
                self.gfResyncTimer = nil
                self:RequestSync()
            end, 1 + math.random() * REQ_SPREAD)
        end

    elseif data.t == "REQ" then
        -- Answer with our cached ruleset so newcomers sync. The receiver still
        -- validates data.by, so a non-officer relaying is harmless.
        --
        -- Gossip suppression: instead of every member replying (an O(N) storm
        -- per REQ, O(N^2) on a mass login), schedule a single jittered reply and
        -- cancel it the moment we see anyone else's "R". A REQ then draws ~1
        -- reply guild-wide, not N.
        if sender == me then return end
        if Addon:GetRuleset().epoch == 0 then return end          -- nothing to share
        if self.reqAnswerTimer then return end                    -- already planning to answer
        if self.lastRulesetSeen and (GetTime() - self.lastRulesetSeen) < REQ_SUPPRESS then
            return                                                -- guild just heard it; requester has it too
        end
        self.reqAnswerTimer = self:ScheduleTimer(function()
            self.reqAnswerTimer = nil
            self:BroadcastRuleset()
        end, math.random() * REQ_SPREAD)

    elseif data.t == "GFC" then
        -- Officer cleared a member's saved integrity flag(s). Authority is tied to
        -- the clearer (data.by), not the relayer — reject unless that origin is an
        -- officer (mirrors the "R" branch; a non-officer relaying is harmless).
        if not Addon:IsOfficer(data.by) then return end
        if data.player and ns.Compliance then
            ns.Compliance:ApplyClear(data.player)
        end

    elseif data.t == "PGF" then
        -- Officer forgave a member's played-without-addon gap. Authority is tied to the
        -- clearer (data.by), like "GFC". Only the named member acts on it — they reset
        -- their local counter and re-baseline, then push a fresh ping so the row clears.
        if not Addon:IsOfficer(data.by) then return end
        if data.player and ns.Playtime
           and Ambiguate(data.player, "short") == me then
            ns.Playtime:Rebaseline()
        end

    elseif data.t == "WGF" then
        -- Officer forgave a member's Guild Found wealth discrepancy. Authority is tied to
        -- the clearer (data.by), like "PGF". Only the named member acts on it — they zero
        -- their counters and re-snapshot, then push a fresh ping so the row clears.
        if not Addon:IsOfficer(data.by) then return end
        if data.player and ns.Integrity
           and Ambiguate(data.player, "short") == me then
            ns.Integrity:Rebaseline()
        end

    elseif data.t == "PWQ" then
        -- A guildmate is asking for the highest /played our records have witnessed for
        -- them, so a fresh/alternate PC of theirs can adopt it instead of false-flagging
        -- honest multi-PC play. Reconciliation can only ever RAISE their baseline (never
        -- accuse), so relaying is safe. Answer with a single jittered, gossip-suppressed
        -- reply keyed per player (mirrors the REQ gossip pattern) so a mass login doesn't
        -- draw O(N) replies each.
        if sender == me then return end
        local who = data.who
        if not who or not ns.Compliance then return end
        local stored = ns.Compliance:GetWitness(who)
        if not stored or stored <= 0 then return end             -- nothing to share
        local key = Ambiguate(who, "short"):lower()
        self._pwaTimers = self._pwaTimers or {}
        self._pwaSeen   = self._pwaSeen or {}
        if self._pwaTimers[key] then return end                  -- already planning to answer
        if self._pwaSeen[key] and (GetTime() - self._pwaSeen[key]) < PWA_SUPPRESS then
            return                                               -- someone just answered
        end
        self._pwaTimers[key] = self:ScheduleTimer(function()
            self._pwaTimers[key] = nil
            local cur = ns.Compliance:GetWitness(who)            -- re-read; may have grown
            if cur and cur > 0 then
                send({ t = "PWA", who = who, ob = math.floor(cur), v = VERSION })
            end
        end, math.random() * REQ_SPREAD)

    elseif data.t == "PWA" then
        -- Answer to a played-witness query. Note the sighting so other peers suppress
        -- their duplicate replies; if it's for US, adopt it (capped at our real /played
        -- inside Playtime, so a forged value can't baseline us beyond what we've played).
        local who = data.who
        if not who then return end
        local key = Ambiguate(who, "short"):lower()
        self._pwaSeen = self._pwaSeen or {}
        self._pwaSeen[key] = GetTime()
        if self._pwaTimers and self._pwaTimers[key] then
            self:CancelTimer(self._pwaTimers[key])
            self._pwaTimers[key] = nil
        end
        if ns.Playtime and Ambiguate(who, "short") == me then
            ns.Playtime:AdoptWitness(data.ob)
        end

    elseif data.t == "S" then
        -- Someone reports a newer ruleset than we hold: we're a straggler that
        -- missed a broadcast. Self-heal by requesting a resend instead of sitting
        -- flagged out-of-sync until relog.
        if sender ~= me and (data.epoch or 0) > Addon:GetRuleset().epoch then
            self:MaybeResync()
        end
        if ns.Compliance then
            ns.Compliance:Record(sender, data)
        end
    end
end
