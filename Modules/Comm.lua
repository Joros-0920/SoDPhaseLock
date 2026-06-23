local ADDON, ns = ...
local Addon = ns.Addon
local Comm = Addon:NewModule("Comm", "AceComm-3.0", "AceTimer-3.0")
ns.Comm = Comm

local LibSerialize = LibStub("LibSerialize")
local LibDeflate   = LibStub("LibDeflate")
local PREFIX       = ns.COMM_PREFIX

-- Message types: "R" ruleset, "REQ" request current ruleset, "S" status
local STATUS_INTERVAL = 60

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
function Comm:OnEnable()
    self:RegisterComm(PREFIX, "OnComm")
    -- On login: ask the guild for the current ruleset, then start status pings.
    self:ScheduleTimer(function() send({ t = "REQ" }) end, 4)
    -- Retry once if nobody answered the first REQ (e.g. guild leader offline,
    -- other members still loading). Only fires when epoch is still 0, so it is
    -- free for anyone who already synced.
    self:ScheduleTimer(function()
        if Addon:GetRuleset().epoch == 0 then
            send({ t = "REQ" })
        end
    end, 30)
    self:ScheduleTimer("SendStatus", 8)
    self.statusTimer = self:ScheduleRepeatingTimer("SendStatus", STATUS_INTERVAL)
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
        mode    = r.mode,
        epoch   = r.epoch,
        by      = r.setBy,
        enforce = r.enforce,
        auto    = r.autoUnequip,
        grace   = r.instanceGrace,
        npd     = r.nextPhaseDate,
    }
end

function Comm:BroadcastRuleset()
    send(rulesetPayload())
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
        vP    = v.profession and 1 or 0,
        vR    = v.rune and 1 or 0,
    })
end

-- ---------------------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------------------
function Comm:OnComm(prefix, message, distribution, sender)
    if prefix ~= PREFIX then return end
    local data = unpack(message)
    if not data or not data.t then return end
    local me = UnitName("player")

    if data.t == "R" then
        -- Authority is tied to whoever ORIGINALLY set the ruleset (data.by),
        -- not the relayer. Reject unless that origin is an officer.
        if not Addon:IsOfficer(data.by) then return end
        Addon:ApplyRuleset(data.phase, data.mode, data.epoch, data.by,
            data.enforce, data.auto, data.grace, data.npd)

    elseif data.t == "REQ" then
        -- Answer with our cached ruleset so newcomers sync. The receiver still
        -- validates data.by, so a non-officer relaying is harmless.
        if sender == me then return end
        if Addon:GetRuleset().epoch > 0 then
            send(rulesetPayload())
        end

    elseif data.t == "S" then
        if ns.Compliance then
            ns.Compliance:Record(sender, data)
        end
    end
end
