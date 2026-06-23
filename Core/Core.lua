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
        -- The active ruleset. Set by officers (phase/mode/rank) and the guild
        -- leader (enforcement config), synced to all members. Highest epoch wins.
        ruleset = {
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
            guildName     = "",      -- guild this ruleset was set/received in; used to detect stale cross-char saves
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

    -- Options + minimap launcher are registered by UI/Options.lua
    if ns.SetupOptions then ns.SetupOptions() end

    self:RegisterChatCommand("sodlock", "HandleSlash")
    self:RegisterChatCommand("sodpl", "HandleSlash")
end

function Addon:OnEnable()
    -- ── Guild-context validation ──────────────────────────────────────────────
    -- db.global is shared across all characters on the account. If a guildless
    -- alt (or a character in a different guild) wrote to it, the saved ruleset
    -- would have a mismatched guildName and a non-zero epoch that blocks the
    -- REQ response from real guild officers from being applied.
    -- Fix: reset epoch to 0 here so the REQ response always wins.
    do
        local r = self.db.global.ruleset
        local myGuild = GetGuildInfo("player") or ""
        if myGuild ~= "" and r.guildName ~= myGuild and r.epoch > 0 then
            self:Print(string.format(
                "|cffff8080Saved ruleset was set in a different guild context (%s); " ..
                "resetting to let your guild sync take over.|r",
                r.guildName ~= "" and ('"' .. r.guildName .. '"') or "no guild"))
            r.epoch = 0
        end
    end

    -- Keep a guild roster handy for officer-rank checks.
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
    self:RegisterEvent("GUILD_ROSTER_UPDATE", function()
        -- nothing to cache eagerly; rank lookups read the roster on demand
    end)

    if ns.ShowWelcome then
        C_Timer.After(1, ns.ShowWelcome)
    end
end

-- ---------------------------------------------------------------------------
-- Ruleset accessors
-- ---------------------------------------------------------------------------
function Addon:GetRuleset()       return self.db.global.ruleset end
function Addon:GetActivePhase()   return self.db.global.ruleset.phase end
function Addon:GetMode()          return self.db.global.ruleset.mode end
function Addon:IsAuthentic()      return self.db.global.ruleset.mode == "authentic" end
function Addon:GetPhaseData()     return ns.Phases[self.db.global.ruleset.phase] end

-- Guild-controlled enforcement config (read by Enforcement / BagOverlay).
-- Personal challenges are ORed in: a player can add restrictions, never remove them.
function Addon:RuleEnabled(rule)
    return self.db.global.ruleset.enforce[rule]
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

function Addon:AutoUnequip()       return self.db.global.ruleset.autoUnequip end
function Addon:InstanceGrace()     return self.db.global.ruleset.instanceGrace or 90 end
function Addon:GetNextPhaseDate()  return self.db.global.ruleset.nextPhaseDate or "" end

-- Apply a ruleset (from local officer action or an incoming broadcast).
-- `enforce`, `autoUnequip` and `instanceGrace` are the guild-controlled
-- enforcement config; they are only present on incoming broadcasts. For local
-- edits they are mutated in `db.global.ruleset` directly before committing, so
-- omitting them here leaves the freshly-edited values untouched.
-- Returns true if it was newer than what we had and was applied.
function Addon:ApplyRuleset(phase, mode, epoch, setBy, enforce, autoUnequip, instanceGrace, nextPhaseDate, silent)
    local r = self.db.global.ruleset
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

    -- Record which guild this ruleset belongs to. On login we compare this against
    -- the character's actual guild so cross-character / guildless-alt contamination
    -- of db.global is detected and cleared before the guild sync REQ fires.
    r.guildName = GetGuildInfo("player") or ""

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
    local r = self.db.global.ruleset
    self:ApplyRuleset(phase, mode, r.epoch + 1, UnitName("player"), nil, nil, nil, nil, silent)
    local comm = self:GetModule("Comm", true)
    if comm then comm:BroadcastRuleset() end
end

-- Guild-leader change to the enforcement config: the caller has already mutated
-- db.global.ruleset (enforce/autoUnequip/instanceGrace); bump epoch + broadcast
-- the whole ruleset so every member adopts it. Reuses the officer commit path.
function Addon:CommitGuildSettings(silent)
    self:SetRulesetAsOfficer(self.db.global.ruleset.phase, self.db.global.ruleset.mode, silent)
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
