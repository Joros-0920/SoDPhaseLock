local ADDON, ns = ...

local Addon = LibStub("AceAddon-3.0"):NewAddon(
    "SoDPhaseLock",
    "AceEvent-3.0", "AceConsole-3.0", "AceComm-3.0", "AceTimer-3.0"
)
ns.Addon = Addon

local PREFIX = "SoDPL"
ns.COMM_PREFIX = PREFIX

-- ---------------------------------------------------------------------------
-- Saved-variable defaults
-- ---------------------------------------------------------------------------
local defaults = {
    global = {
        -- The active ruleset, keyed by guild context. db.global is shared across
        -- ALL characters on the account, so a single shared ruleset table lets a
        -- guildless alt's edits bleed into a guilded main (and one guild's config
        -- into another). Instead we bucket per guild name ("" = no guild), so each
        -- guild context — and the guildless/solo context — has its own ruleset.
        -- Set by officers (phase/mode/rank) and the guild leader (enforcement
        -- config), synced to all members of that guild. Highest epoch wins.
        rulesets = {
            ["*"] = {
                phase = 1,
                mode  = "relaxed",   -- "relaxed" | "authentic"
                epoch = 0,           -- monotonically increasing; highest wins
                setBy = "",          -- player name of whoever last set it
                -- Guild-controlled enforcement config (guild leader tunes these).
                -- All off by default: nothing is enforced until a guild leader
                -- explicitly enables rules and broadcasts them. A fresh install (or
                -- an unsynced member) thus imposes no restrictions on its own.
                enforce = {
                    level      = false,
                    instance   = false,   -- authentic only
                    gear       = false,   -- authentic only
                    profession = false,   -- authentic only
                    quest      = false,   -- authentic only
                    rune       = false,   -- authentic only
                    runebroker = false,   -- authentic only: close Rune Broker window on interact
                },
                autoUnequip   = false,   -- auto-remove over-phase gear out of combat
                instanceGrace = 90,      -- seconds in a locked instance before reporting
                nextPhaseDate = "",      -- officer-set free-text unlock date, broadcast to all members
                -- Guild ranks 0..this may set/broadcast the ruleset (0 = GM). Synced
                -- with the ruleset so every client agrees on who counts as an officer
                -- (the receiver-side authority check reads this value). Editable by any
                -- officer, but an officer can never lower it below their OWN rank index
                -- (which would lock themselves out) — enforced in the options set handler.
                officerRankIndex = 1,
                -- Played-without-addon check (guild leader). When on, a member whose
                -- server /played grew by more than `playedGapGrace` minutes while the
                -- addon was NOT loaded is flagged out of compliance. Off by default
                -- (nothing enforced until a guild leader turns it on). See Modules/Playtime.lua.
                playedGapCheck = false,
                playedGapGrace = 5,      -- minutes of unobserved /played tolerated before flagging
                -- Guild Found: a closed-economy policy (guild leader). Each restriction
                -- is independent so a guild can, e.g., lock trades but still allow the AH.
                guildFound = {
                    trade   = false,   -- may only trade fellow guild members
                    mail    = false,   -- may only mail fellow guild members
                    auction = false,   -- may not use the Auction House
                    allowConjured = false,  -- exempt conjured items (mage food, healthstones…) from the trade rule
                    allowTradeWindow = false,  -- exempt items still in their group-loot trade window (BIND_TRADE_TIME_REMAINING) from the trade rule
                    -- Wealth integrity: when Guild Found is on, flag gold/items that
                    -- appeared (or left) across a window the addon was unloaded — the
                    -- closed-economy blind spot when a member disables the addon, moves
                    -- value with an outsider, and re-enables it. Auto-active whenever any
                    -- restriction above is on; `integrity` lets a guild leader opt out.
                    -- No tolerance: in a closed economy no play without the addon is
                    -- acceptable, so ANY change flags. See Modules/Integrity.lua.
                    integrity = true,
                    -- Trade allowlist: item IDs that MAY be traded cross-guild even
                    -- when `trade` is on. If non-empty, a cross-guild trade is allowed
                    -- as long as it contains only these items and no gold. Keyed by
                    -- itemID → true. Guild-leader controlled, synced with the ruleset.
                    tradeExceptions = {},
                },
            },
        },
        -- (officerRankIndex moved into each per-guild ruleset bucket so it syncs; see
        --  the migration in OnInitialize for the legacy global value.)
        -- Persisted integrity flags, bucketed per guild context (same keying as
        -- rulesets; "" = no guild). Two kinds, both saved so they survive a member
        -- toggling their addon / relogging, and cleared only by an officer (synced
        -- guild-wide): `gf` = "Guild Found disabled locally" (SavedVars tamper), and
        -- `noaddon` = "addon not detected" (sustained online with no status ping).
        -- [guildKey][lc-short-name] = { name=<ProperShort>, gf=<time()>, noaddon=<time()> }.
        -- See Modules/Compliance.lua.
        gfFlags = {
            ["*"] = {},
        },
        -- Guild-shared high-water mark of the /played each member's addon has WITNESSED
        -- (the highest `observed` we've heard on their status ping), bucketed per guild.
        -- A member on a fresh/alternate PC queries the guild for their own value and
        -- adopts it, so honest multi-PC play isn't mistaken for playing without the addon.
        -- [guildKey][lc-short-name] = <seconds>. See Modules/Playtime.lua reconciliation.
        playedWitness = {
            ["*"] = {},
        },
    },
    char = {
        -- Strictly per-character, never shared across profiles: whether this
        -- character has seen the first-run welcome. Lives in `char` (not `profile`)
        -- so assigning a shared profile can't suppress the welcome on a new alt.
        seenWelcome = false,
        -- Playtime-gap tracking (per realm-character, exactly like server /played).
        -- `observed` = server /played (seconds) as of the last moment the addon was
        -- confirmed loaded and observing (nil until the first TIME_PLAYED_MSG ever).
        -- `unobserved` = cumulative /played growth while the addon was NOT loaded —
        -- the dishonesty metric reported in the status ping. See Modules/Playtime.lua.
        playtime = {
            unobserved = 0,
        },
        -- Guild Found wealth-integrity baseline (per realm-character). `money`/`items`
        -- are the last observed snapshot (copper, and bag itemID→count) the addon saw
        -- while loaded; on a login that Playtime attributes to an addon-off gap, the
        -- difference from this snapshot is folded into the `unaccounted*` counters (the
        -- metric reported in the status ping) before the snapshot is refreshed. `bankItems`
        -- is the parallel bank baseline, sampled only while the bank frame is open and
        -- compared on the next open (an off-radar deposit isn't visible in bags at login).
        -- Reset by an officer forgive. See Modules/Integrity.lua.
        wealth = {
            money            = nil,   -- copper baseline (nil until first snapshot)
            items            = {},    -- itemID → count baseline (bags)
            -- bankItems     = nil,   -- itemID → count baseline (bank); added lazily on first bank open
            unaccountedMoney = 0,     -- signed copper accrued across unmonitored gaps
            unaccountedItems = 0,     -- count of distinct itemIDs gained across gaps (bags + bank)
            itemLog          = {},    -- bounded set of gained itemIDs, for the officer display
        },
    },
    profile = {
        -- Personal preferences (never synced).
        enabled      = true,     -- local master switch / kill switch
        sound        = true,
        minimap      = { hide = false },
        -- Per-player opt-in restrictions. These are ORed with the guild enforce
        -- table in RuleEnabled(), so a player can add restrictions but never
        -- remove guild-imposed ones.
        personalChallenges = {
            level      = false,
            instance   = false,
            gear       = false,
            profession = false,
            quest      = false,
            rune       = false,
            runebroker = false,
        },
    },
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Addon:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("SoDPhaseLockDB", defaults, true)

    -- Migrate the legacy single `db.global.ruleset` (pre per-guild buckets) into
    -- the bucket for the guild it was set in. The old table carried a `guildName`
    -- field for exactly this; "" if it was set with no guild. Only migrate when the
    -- target bucket is still untouched (epoch 0) so we never clobber newer data.
    do
        local g = self.db.global
        local legacy = rawget(g, "ruleset")
        if type(legacy) == "table" then
            local b = g.rulesets[legacy.guildName or ""]
            if (b.epoch or 0) == 0 then
                b.phase         = legacy.phase or b.phase
                b.mode          = legacy.mode or b.mode
                b.epoch         = legacy.epoch or b.epoch
                b.setBy         = legacy.setBy or b.setBy
                b.instanceGrace = legacy.instanceGrace or b.instanceGrace
                b.nextPhaseDate = legacy.nextPhaseDate or b.nextPhaseDate
                if legacy.autoUnequip ~= nil then b.autoUnequip = legacy.autoUnequip end
                if type(legacy.enforce) == "table" then
                    for k in pairs(b.enforce) do
                        if legacy.enforce[k] ~= nil then
                            b.enforce[k] = legacy.enforce[k] and true or false
                        end
                    end
                end
            end
            g.ruleset = nil
        end
    end

    -- Migrate the legacy global officer-rank threshold (it used to live in
    -- db.global, unsynced) into the per-guild ruleset buckets, which are now the
    -- synced source of truth. Only seed buckets still at the default so we never
    -- clobber a value an officer has already broadcast at a higher epoch.
    do
        local g = self.db.global
        local legacyRank = rawget(g, "officerRankIndex")
        if type(legacyRank) == "number" and legacyRank ~= 1 then
            for _, b in pairs(g.rulesets) do
                if b.officerRankIndex == 1 then
                    b.officerRankIndex = legacyRank
                end
            end
        end
        g.officerRankIndex = nil
    end

    -- Options + minimap launcher are registered by UI/Options.lua
    if ns.SetupOptions then ns.SetupOptions() end

    self:RegisterChatCommand("sodlock", "HandleSlash")
    self:RegisterChatCommand("sodpl", "HandleSlash")
end

function Addon:OnEnable()
    -- Resolve and cache the guild context this character belongs to. The active
    -- ruleset is the bucket for this key, so a guildless alt and a guilded main on
    -- the same account never share one (the cause of cross-character bleed).
    self._guildKey = GetGuildInfo("player") or ""

    -- Keep a guild roster handy for officer-rank checks.
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
    self:RegisterEvent("GUILD_ROSTER_UPDATE", function()
        -- nothing to cache eagerly; rank lookups read the roster on demand
    end)

    -- Joining/leaving/changing guild mid-session switches which bucket is active.
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "OnGuildChanged")

    if ns.ShowWelcome then
        C_Timer.After(1, ns.ShowWelcome)
    end
end

-- ---------------------------------------------------------------------------
-- Ruleset accessors
-- ---------------------------------------------------------------------------
-- The guild context whose ruleset bucket is active for this character ("" = no
-- guild). Cached in OnEnable and refreshed on PLAYER_GUILD_UPDATE; we fall back
-- to a live lookup if accessed before OnEnable (e.g. options built at init).
function Addon:GuildKey()
    if self._guildKey == nil then
        self._guildKey = GetGuildInfo("player") or ""
    end
    return self._guildKey
end

-- Re-resolve the active bucket when the player joins, leaves, or changes guild.
function Addon:OnGuildChanged()
    local newKey = GetGuildInfo("player") or ""
    if newKey == self._guildKey then return end
    self._guildKey = newKey
    -- Adopt the new context's ruleset locally and ask that guild to sync us up.
    if ns.RefreshOptions then ns.RefreshOptions() end
    if ns.RefreshBagOverlays then ns.RefreshBagOverlays() end
    local enforcement = self:GetModule("Enforcement", true)
    if enforcement then enforcement:FullScan() end
    local comm = self:GetModule("Comm", true)
    if comm and comm.RequestSync then comm:RequestSync() end
    -- Re-ping with the corrected guild context and rebuild the roster NOW, rather than
    -- waiting for the next scheduled status tick. Right after a login/reload GetGuildInfo
    -- is often nil for a few seconds, so OnEnable cached a guildless "" bucket where Guild
    -- Found reads as off; any status ping in that window derived no wealth/GF reason. Once
    -- the real guild resolves here, push a fresh ping so those flags reappear immediately
    -- instead of a full status interval (60-300s) later.
    if comm and comm.SendStatus then comm:SendStatus() end
    if ns.RefreshRoster then ns.RefreshRoster() end
end

function Addon:GetRuleset()       return self.db.global.rulesets[self:GuildKey()] end
function Addon:GetActivePhase()   return self:GetRuleset().phase end
-- "mode" is DERIVED from which rules are enabled, not a stored field: a player is
-- authentic exactly when every authentic rule is enforced (guild config OR personal
-- challenges). The stored ruleset.mode is only a broadcast hint / first-run seed.
-- See GetEffectiveMode below.
function Addon:GetMode()          return self:GetEffectiveMode() end
function Addon:IsAuthentic()      return self:GetEffectiveMode() == "authentic" end
function Addon:GetPhaseData()     return ns.Phases[self:GetRuleset().phase] end

-- Guild-controlled enforcement config (read by Enforcement / BagOverlay).
-- Personal challenges are ORed in: a player can add restrictions, never remove them.
function Addon:RuleEnabled(rule)
    return self:GetRuleset().enforce[rule]
        or (self.db.profile.personalChallenges[rule] == true)
end

-- The rules that together define "authentic" mode. All must be enabled for the
-- effective mode to be authentic; any off → relaxed.
local AUTHENTIC_RULES = { "instance", "gear", "profession", "quest", "rune", "runebroker" }

-- Effective mode based on what is actually enforced (guild + personal challenges).
-- Used by Comm:SendStatus so the compliance roster reflects each player's real state.
function Addon:GetEffectiveMode()
    for _, rule in ipairs(AUTHENTIC_RULES) do
        if not self:RuleEnabled(rule) then return "relaxed" end
    end
    return "authentic"
end

function Addon:AutoUnequip()       return self:GetRuleset().autoUnequip end
function Addon:InstanceGrace()     return self:GetRuleset().instanceGrace or 90 end
function Addon:GetNextPhaseDate()  return self:GetRuleset().nextPhaseDate or "" end
-- Played-without-addon threshold in SECONDS (0 = the check is off). Reads the
-- synced ruleset so every client evaluates a member's reported gap against the
-- same guild-leader-set tolerance.
function Addon:PlayedGapThreshold()
    local r = self:GetRuleset()
    if not r.playedGapCheck then return 0 end
    local m = r.playedGapGrace or 5
    return (m > 0) and (m * 60) or 0
end
-- Guild Found: each restriction (trade/mail/auction) is an independent toggle.
function Addon:GuildFound(key)     return self:GetRuleset().guildFound[key] and true or false end
function Addon:GuildFoundAny()
    local gf = self:GetRuleset().guildFound
    return (gf.trade or gf.mail or gf.auction) and true or false
end

-- Wealth integrity is active only inside a closed economy (some Guild Found
-- restriction on) and unless a guild leader has opted out. A member with no Guild
-- Found restriction has an open economy, so there's nothing to reconcile.
function Addon:WealthIntegrityOn()
    return self:GuildFoundAny() and (self:GetRuleset().guildFound.integrity ~= false)
end

-- Adopt an authoritative guildFound table into our active ruleset bucket. Shared by
-- ApplyRuleset (normal apply) and Comm's equal-epoch reconcile (a member parked at
-- the current epoch with stale/default Guild Found — an old-client relay that stripped
-- `gf`, or a login/bucket race — which ApplyRuleset's epoch gate can never correct).
-- Returns true if any field actually changed, so callers can skip refresh churn.
function Addon:ReconcileGuildFound(gf)
    if type(gf) ~= "table" then return false end
    local dst = self:GetRuleset().guildFound
    local changed = false
    local function setBool(k, v)
        v = v and true or false
        if dst[k] ~= v then dst[k] = v; changed = true end
    end
    setBool("trade",   gf.trade)
    setBool("mail",    gf.mail)
    setBool("auction", gf.auction)
    setBool("allowConjured",    gf.allowConjured)
    setBool("allowTradeWindow", gf.allowTradeWindow)
    -- Wealth integrity (default on if absent, so an older officer's broadcast that
    -- predates the field doesn't silently disable it on newer clients).
    if gf.integrity ~= nil then setBool("integrity", gf.integrity) end
    -- Trade allowlist: replace wholesale (a list of item IDs, not a boolean).
    if type(gf.tradeExceptions) == "table" then
        local ex, newset = dst.tradeExceptions, {}
        for id in pairs(gf.tradeExceptions) do newset[tonumber(id) or id] = true end
        for id in pairs(ex)     do if not newset[id] then changed = true end end
        for id in pairs(newset) do if not ex[id]     then changed = true end end
        for id in pairs(ex) do ex[id] = nil end
        for id in pairs(newset) do ex[id] = true end
    end
    return changed
end

-- Apply a ruleset (from local officer action or an incoming broadcast).
-- `enforce`, `autoUnequip` and `instanceGrace` are the guild-controlled
-- enforcement config; they are only present on incoming broadcasts. For local
-- edits they are mutated in the active ruleset bucket directly before committing,
-- so omitting them here leaves the freshly-edited values untouched.
-- Returns true if it was newer than what we had and was applied.
function Addon:ApplyRuleset(phase, mode, epoch, setBy, enforce, autoUnequip, instanceGrace, nextPhaseDate, guildFound, playedGapCheck, playedGapGrace, officerRankIndex, silent)
    local r = self:GetRuleset()
    if epoch and epoch <= r.epoch then
        return false
    end
    r.phase = phase
    r.mode  = mode
    r.epoch = epoch or (r.epoch + 1)
    r.setBy = setBy or UnitName("player")

    if enforce then
        for k in pairs(r.enforce) do
            r.enforce[k] = enforce[k] and true or false
        end
    end
    if autoUnequip ~= nil then r.autoUnequip = autoUnequip and true or false end
    if instanceGrace ~= nil then r.instanceGrace = instanceGrace end
    if nextPhaseDate ~= nil then r.nextPhaseDate = nextPhaseDate end
    if playedGapCheck ~= nil then r.playedGapCheck = playedGapCheck and true or false end
    if playedGapGrace ~= nil then r.playedGapGrace = playedGapGrace end
    if officerRankIndex ~= nil then r.officerRankIndex = officerRankIndex end
    if guildFound then self:ReconcileGuildFound(guildFound) end

    if not silent then
        local data = ns.Phases[r.phase]
        self:Print(string.format("Ruleset is now |cff00ff00%s|r mode, %s (set by %s).",
            self:GetMode(), data and data.name or ("Phase " .. r.phase), r.setBy))
    end

    -- Refresh enforcement & UI against the new ruleset.
    local enforcement = self:GetModule("Enforcement", true)
    if enforcement then enforcement:FullScan() end
    if ns.RefreshOptions then ns.RefreshOptions() end
    if ns.RefreshBagOverlays then ns.RefreshBagOverlays() end
    if ns.RefreshTradeExceptions then ns.RefreshTradeExceptions() end
    return true
end

-- Officer-driven change: bump epoch, apply locally, broadcast to the guild. Members
-- are not notified in chat on receipt; the officer's own confirmation is printed
-- locally (a non-silent ApplyRuleset here, or the commitGuild caller's own print).
function Addon:SetRulesetAsOfficer(phase, mode, silent)
    local r = self:GetRuleset()
    self:ApplyRuleset(phase, mode, r.epoch + 1, UnitName("player"), nil, nil, nil, nil, nil, nil, nil, nil, silent)
    local comm = self:GetModule("Comm", true)
    if comm then comm:BroadcastRuleset() end
end

-- Guild-leader change to the enforcement config: the caller has already mutated
-- the active ruleset bucket (enforce/autoUnequip/instanceGrace); bump epoch +
-- broadcast the whole ruleset so every member adopts it. Reuses the officer path.
function Addon:CommitGuildSettings(silent)
    local r = self:GetRuleset()
    self:SetRulesetAsOfficer(r.phase, r.mode, silent)
end

-- ---------------------------------------------------------------------------
-- Guild rank / officer checks
-- ---------------------------------------------------------------------------
-- Returns the guild rank index for a player name (0 = GM), or nil if not found.
function Addon:GetGuildRankIndex(name)
    if not IsInGuild() or not name then return nil end
    local short = Ambiguate(name, "short"):lower()
    local total = GetNumGuildMembers()
    for i = 1, total do
        local fullName, _, rankIndex = GetGuildRosterInfo(i)
        if fullName and Ambiguate(fullName, "short"):lower() == short then
            return rankIndex
        end
    end
    return nil
end

-- May this player edit the guild enforcement config? Guild leader only (or a
-- solo/no-guild player controlling their own local config).
function Addon:IsGuildLeader()
    if not IsInGuild() then return true end
    return IsGuildLeader and IsGuildLeader() or false
end

-- May this player set/broadcast the ruleset?
function Addon:IsOfficer(name)
    name = name or UnitName("player")
    -- Not in a guild (solo / testing): you control your own local ruleset.
    if name == UnitName("player") and not IsInGuild() then
        return true
    end
    if IsGuildLeader and name == UnitName("player") and IsGuildLeader() then
        return true
    end
    local rankIndex = self:GetGuildRankIndex(name)
    if not rankIndex then return false end
    return rankIndex <= (self:GetRuleset().officerRankIndex or 1)
end

-- ---------------------------------------------------------------------------
-- Alerts
-- ---------------------------------------------------------------------------
-- Throttle identical messages so events that fire in bursts don't spam.
local lastAlert = {}
function Addon:Alert(msg, key)
    key = key or msg
    local now = GetTime()
    if lastAlert[key] and (now - lastAlert[key]) < 5 then return end
    lastAlert[key] = now

    self:Print("|cffff3030" .. msg .. "|r")
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "SoD Phase Lock: " .. msg, ChatTypeInfo["RAID_WARNING"])
    end
    if self.db.profile.sound then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
    end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------
function Addon:HandleSlash(input)
    local raw = (input or ""):trim()          -- original case preserved (player names)
    input = raw:lower()
    if input == "status" then
        local r = self:GetRuleset()
        local data = self:GetPhaseData()
        self:Print(string.format("Mode |cff00ff00%s|r | %s | level cap %d | set by %s (epoch %d)",
            self:GetMode(), data and data.name or "?", data and data.levelCap or 0, r.setBy ~= "" and r.setBy or "—", r.epoch))
        self:Print(self:IsOfficer() and "You are an officer (can set the phase)." or "You are a member (read-only).")
        local comm = self:GetModule("Comm", true)
        local newer = comm and comm:NewerVersion()
        if newer then
            self:Print(string.format("Version |cffffd100%s|r — |cff00ff00%s|r is available; update to stay in sync.", ns.Version or "?", newer))
        else
            self:Print(string.format("Version |cff00ff00%s|r (up to date, as far as your guild has reported).", ns.Version or "?"))
        end
    elseif input == "roster" then
        if ns.ToggleRoster then ns.ToggleRoster() end
    elseif input == "clearflag" or input:match("^clearflag%s") then
        -- Officer-only: clear a member's saved integrity flags (Guild Found tamper
        -- and/or "addon not detected") and sync the clear to the guild. Name is
        -- taken from the original-case input.
        local name = raw:match("^%S+%s+(.+)$")
        if not name or name == "" then
            self:Print("Usage: /sodlock clearflag <player> — clears a member's saved flag(s) (officer only).")
        elseif not self:IsOfficer() then
            self:Print("|cffff3030Only an officer can clear a saved flag.|r")
        else
            local c = self:GetModule("Compliance", true)
            if c and c.OfficerClear and c:OfficerClear(name) then
                self:Print(string.format("Cleared saved flag(s) on |cffffd100%s|r (synced to the guild).", name))
            else
                self:Print(string.format("No saved flag on |cffffd100%s|r.", name))
            end
        end
    elseif input == "scan" then
        local e = self:GetModule("Enforcement", true)
        if e then e:FullScan(); self:Print("Re-scanned current state.") end
    elseif input == "bag" then
        -- Explain whether the bag X overlay should be showing right now.
        local d = self:GetPhaseData()
        local hasData = d and (next(d.bannedItems) ~= nil) or false
        self:Print("|cffffd100Bag overlay diagnostics:|r")
        self:Print(string.format("  enforcement enabled: %s", self.db.profile.enabled and "|cff00ff00yes|r" or "|cffff3030no|r"))
        self:Print(string.format("  mode: |cff00ff00%s|r", self:GetMode()))
        self:Print(string.format("  gear rule: %s  (full bannedItems overlay needs this on)", self:RuleEnabled("gear") and "|cff00ff00on|r" or "|cffff3030off|r"))
        self:Print(string.format("  phase: %s  (banned-item data: %s)", d and d.name or "?",
            hasData and "|cff00ff00present|r" or "|cffff3030none — only items above level cap are flagged|r"))
        if ns.BagDiagnostics then
            local flagged, scanned = ns.BagDiagnostics()
            self:Print(string.format("  bag items scanned: %d, beyond current phase: |cffffd100%d|r", scanned, flagged))
            if flagged > 0 and not (self:RuleEnabled("gear") and self.db.profile.enabled) then
                self:Print("  |cffff8080Items are flaggable but the full overlay is gated off — enable the gear rule.|r")
            end
        end
        -- Bag addon: Baganator replaces the Blizzard bags; report its widget state.
        local bag = rawget(_G, "Baganator")
        if bag and bag.API then
            local active = bag.API.IsCornerWidgetActive and bag.API.IsCornerWidgetActive("sodphaselock_blocked")
            self:Print(string.format("  Baganator: |cff00ff00detected|r, X widget %s",
                active and "|cff00ff00active|r" or "|cffff3030inactive — enable 'SoD Phase Lock: blocked' in Baganator → Icon Settings → Icon Corners|r"))
        else
            self:Print("  Baganator: not detected (using default Blizzard bag overlay)")
        end
    elseif input == "wealth" then
        -- Explain whether the Guild Found wealth-integrity check (Modules/Integrity.lua)
        -- is actually evaluating for this character right now, and what it currently holds
        -- — the "why didn't a trade get flagged" question has several independent gates
        -- (Guild Found active, the leader's integrity toggle, and whether a baseline has
        -- been established this session), none of which were visible anywhere before.
        local r = self:GetRuleset()
        local gf = r.guildFound
        self:Print("|cffffd100Guild Found wealth-integrity diagnostics:|r")
        self:Print(string.format("  Guild Found active: %s  (trade:%s mail:%s auction:%s)",
            self:GuildFoundAny() and "|cff00ff00yes|r" or "|cffff3030no|r",
            gf.trade and "on" or "off", gf.mail and "on" or "off", gf.auction and "on" or "off"))
        self:Print(string.format("  \"Flag off-radar gold/items\" (leader toggle): %s",
            (gf.integrity ~= false) and "|cff00ff00on|r" or "|cffff3030off|r"))
        self:Print(string.format("  wealth integrity evaluated: %s  (needs both of the above)",
            self:WealthIntegrityOn() and "|cff00ff00yes|r" or "|cffff3030no|r"))
        local integrity = self:GetModule("Integrity", true)
        local w = self.db.char.wealth or {}
        local itemCount, bankCount = 0, 0
        if w.items then for _ in pairs(w.items) do itemCount = itemCount + 1 end end
        if w.bankItems then for _ in pairs(w.bankItems) do bankCount = bankCount + 1 end end
        self:Print(string.format("  session baseline established: %s  (money:%s items:%d distinct, bank:%d distinct)",
            (integrity and integrity._ready) and "|cff00ff00yes|r" or "|cffff3030not yet|r",
            w.money and GetCoinTextureString(w.money) or "—", itemCount, bankCount))
        local money = integrity and integrity:GetUnaccountedMoney() or 0
        local items = integrity and integrity:GetUnaccountedItems() or 0
        self:Print(string.format("  reported so far: %+dc, %d distinct item(s) gained while off",
            money, items))
        local log = integrity and integrity:GetItemLog()
        if log then
            self:Print("  logged item IDs: " .. table.concat(log, ", "))
        end
    else
        if ns.OpenOptions then ns.OpenOptions() end
    end
end
