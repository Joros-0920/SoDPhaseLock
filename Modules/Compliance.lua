local ADDON, ns = ...
local Addon = ns.Addon
local Compliance = Addon:NewModule("Compliance")
ns.Compliance = Compliance

-- roster[playerName] = {
--   level, phase, mode, epoch, overLevel, instance, gear, profession,
--   xpLocked (bool, informational — not a violation),
--   compliant (bool), reasons (string), updated (GetTime())
-- }
Compliance.roster = {}

local STALE_AFTER = 300   -- seconds before a member's report is considered stale

-- Record an incoming status report and derive compliance against OUR ruleset.
function Compliance:Record(sender, data)
    if not sender then return end
    local name = Ambiguate(sender, "short")

    local reasons = {}
    if data.epoch ~= Addon:GetRuleset().epoch then
        reasons[#reasons + 1] = "out-of-sync ruleset"
    end
    if data.vL == 1 then reasons[#reasons + 1] = "over level cap" end
    if data.vI == 1 then reasons[#reasons + 1] = "in locked instance" end
    if (data.vG or 0) > 0 then reasons[#reasons + 1] = string.format("%d invalid item(s)", data.vG) end
    if data.vP == 1 then reasons[#reasons + 1] = "profession over cap" end
    if (data.vQ or 0) > 0 then reasons[#reasons + 1] = string.format("%d quest(s) from later phase", data.vQ) end
    if data.vR == 1 then reasons[#reasons + 1] = "rune from later phase" end

    self.roster[name] = {
        level      = data.lvl,
        phase      = data.phase,
        mode       = data.mode,
        epoch      = data.epoch,
        overLevel  = data.vL == 1,
        instance   = data.vI == 1,
        gear       = data.vG or 0,
        profession = data.vP == 1,
        quest      = data.vQ or 0,
        rune       = data.vR == 1,
        xpLocked   = data.vX == 1,   -- informational; intentionally excluded from reasons/compliant
        compliant  = (#reasons == 0),
        reasons    = (#reasons == 0) and "OK" or table.concat(reasons, ", "),
        updated    = GetTime(),
    }

    if ns.RefreshRoster then ns.RefreshRoster() end
end

-- Return a sorted array of {name, info} with stale entries dropped, for the UI.
function Compliance:GetSorted()
    local now = GetTime()
    local list = {}
    for name, info in pairs(self.roster) do
        if (now - info.updated) <= STALE_AFTER then
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
