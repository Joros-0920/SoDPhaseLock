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
                enforce = {
                    level      = true,
                    instance   = true,   -- authentic only
                    gear       = true,   -- authentic only
                    profession = true,   -- authentic only
                    quest      = true,   -- authentic only
                    rune       = true,   -- authentic only
                    runebroker = true,   -- authentic only: close Rune Broker window on interact
                },
                autoUnequip   = true,    -- auto-remove over-phase gear out of combat
                instanceGrace = 90,      -- seconds in a locked instance before reporting
                nextPhaseDate = "",      -- officer-set free-text unlock date, broadcast to all members
            },
        },
        officerRankIndex = 1,    -- guild ranks 0..this may set/broadcast the ruleset (0 = GM)
    },
    profile = {
        -- Personal preferences (never synced).
        enabled      = true,     -- local master switch / kill switch
        sound        = true,
        minimap      = { hide = false },
        seenWelcome  = false,
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
end

function Addon:GetRuleset()       return self.db.global.rulesets[self:GuildKey()] end
function Addon:GetActivePhase()   return self:GetRuleset().phase end
function Addon:GetMode()          return self:GetRuleset().mode end
function Addon:IsAuthentic()      return self:GetRuleset().mode == "authentic" end
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

-- Apply a ruleset (from local officer action or an incoming broadcast).
-- `enforce`, `autoUnequip` and `instanceGrace` are the guild-controlled
-- enforcement config; they are only present on incoming broadcasts. For local
-- edits they are mutated in the active ruleset bucket directly before committing,
-- so omitting them here leaves the freshly-edited values untouched.
-- Returns true if it was newer than what we had and was applied.
function Addon:ApplyRuleset(phase, mode, epoch, setBy, enforce, autoUnequip, instanceGrace, nextPhaseDate, silent)
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

    if not silent then
        local data = ns.Phases[r.phase]
        self:Print(string.format("Ruleset is now |cff00ff00%s|r mode, %s (set by %s).",
            r.mode, data and data.name or ("Phase " .. r.phase), r.setBy))
    end

    -- Refresh enforcement & UI against the new ruleset.
    local enforcement = self:GetModule("Enforcement", true)
    if enforcement then enforcement:FullScan() end
    if ns.RefreshOptions then ns.RefreshOptions() end
    if ns.RefreshBagOverlays then ns.RefreshBagOverlays() end
    return true
end

-- Officer-driven change: bump epoch, apply locally, broadcast to the guild.
function Addon:SetRulesetAsOfficer(phase, mode, silent)
    local r = self:GetRuleset()
    self:ApplyRuleset(phase, mode, r.epoch + 1, UnitName("player"), nil, nil, nil, nil, silent)
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
    return rankIndex <= self.db.global.officerRankIndex
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
    input = (input or ""):lower():trim()
    if input == "status" then
        local r = self:GetRuleset()
        local data = self:GetPhaseData()
        self:Print(string.format("Mode |cff00ff00%s|r | %s | level cap %d | set by %s (epoch %d)",
            r.mode, data and data.name or "?", data and data.levelCap or 0, r.setBy ~= "" and r.setBy or "—", r.epoch))
        self:Print(self:IsOfficer() and "You are an officer (can set the phase)." or "You are a member (read-only).")
    elseif input == "roster" then
        if ns.ToggleRoster then ns.ToggleRoster() end
    elseif input == "scan" then
        local e = self:GetModule("Enforcement", true)
        if e then e:FullScan(); self:Print("Re-scanned current state.") end
    elseif input == "bag" then
        -- Explain whether the bag X overlay should be showing right now.
        local d = self:GetPhaseData()
        local hasData = d and (next(d.bannedItems) ~= nil) or false
        self:Print("|cffffd100Bag overlay diagnostics:|r")
        self:Print(string.format("  enforcement enabled: %s", self.db.profile.enabled and "|cff00ff00yes|r" or "|cffff3030no|r"))
        self:Print(string.format("  mode: |cff00ff00%s|r  (overlay needs |cffffd100authentic|r)", self:GetMode()))
        self:Print(string.format("  gear rule: %s", self:RuleEnabled("gear") and "|cff00ff00on|r" or "|cffff3030off|r"))
        self:Print(string.format("  phase: %s  (banned-item data: %s)", d and d.name or "?",
            hasData and "|cff00ff00present|r" or "|cffff3030none — only items above level cap are flagged|r"))
        if ns.BagDiagnostics then
            local flagged, scanned = ns.BagDiagnostics()
            self:Print(string.format("  bag items scanned: %d, beyond current phase: |cffffd100%d|r", scanned, flagged))
            if flagged > 0 and not (self:IsAuthentic() and self:RuleEnabled("gear") and self.db.profile.enabled) then
                self:Print("  |cffff8080Items are flaggable but overlays are gated off — switch to authentic mode (and enable the gear rule).|r")
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
    else
        if ns.OpenOptions then ns.OpenOptions() end
    end
end
