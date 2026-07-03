local ADDON, ns = ...
local Addon = ns.Addon

-- Guild population by class. Everything here is read from the LOCAL guild roster
-- (GetGuildRosterInfo) — the class of every guild member is already on the client,
-- so this needs no AceComm traffic. It refreshes off GUILD_ROSTER_UPDATE, the same
-- event the game fires whenever the roster changes.
local GuildPopulation = Addon:NewModule("GuildPopulation", "AceEvent-3.0")
ns.GuildPopulation = GuildPopulation

local CLASS_COLORS = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)

local counts = {}       -- classToken -> member count
local ordered = {}      -- { { token = , count = }, ... } sorted count-desc
local total = 0
local scanPending

local function requestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- Recount the whole roster by class. Cheap (a few hundred iterations at worst)
-- and only ever touched when the population tab is open or the roster changes.
function GuildPopulation:Rescan()
    wipe(counts)
    total = 0
    if IsInGuild() then
        local n = GetNumGuildMembers() or 0
        for i = 1, n do
            -- classFileName (the locale-independent token, e.g. "MAGE") is the
            -- 11th return of GetGuildRosterInfo.
            local classToken = select(11, GetGuildRosterInfo(i))
            if classToken then
                counts[classToken] = (counts[classToken] or 0) + 1
                total = total + 1
            end
        end
    end

    wipe(ordered)
    for token, c in pairs(counts) do
        ordered[#ordered + 1] = { token = token, count = c }
    end
    table.sort(ordered, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.token < b.token
    end)

    if ns.OnGuildPopulationChanged then ns.OnGuildPopulationChanged() end
end

-- ordered list (count-desc) + total. Callers treat these as read-only.
function GuildPopulation:GetData()
    return ordered, total
end

function GuildPopulation:ClassColor(token)
    local c = CLASS_COLORS and CLASS_COLORS[token]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end

function GuildPopulation:ClassName(token)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
end

function GuildPopulation:OnEnable()
    requestRoster()
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnRosterUpdate")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "OnRosterUpdate")
    -- Roster is usually empty for the first second after login; seed once it loads.
    C_Timer.After(2, function() self:Rescan() end)
end

-- GUILD_ROSTER_UPDATE can arrive in bursts (one per roster page); debounce so a
-- big guild recounts once per settle, not per event.
function GuildPopulation:OnRosterUpdate()
    if scanPending then return end
    scanPending = true
    C_Timer.After(1, function()
        scanPending = false
        self:Rescan()
    end)
end
