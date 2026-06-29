local ADDON, ns = ...
local Addon = ns.Addon
local GroupInspect = Addon:NewModule("GroupInspect", "AceEvent-3.0", "AceTimer-3.0")
ns.GroupInspect = GroupInspect

-- ---------------------------------------------------------------------------
-- Group Compliance: locally INSPECT every current party/raid member and flag
-- anyone outside the active phase on level / gear / enchants / runes. Unlike the
-- guild roster (which relies on members running the addon + broadcasting status),
-- this works for anyone in the group — pugs included — because it reads their data
-- directly via the inspection API.
--
-- WoW only inspects one unit at a time and rate-limits NotifyInspect, and a unit
-- must be ONLINE + within inspect range (~28 yd) to read. So this is an async
-- queue: rows appear immediately (name/class/level need no inspect) and gear/
-- enchant/rune fill in as each unit resolves. Out-of-range members are shown but
-- not judged.
--
-- results[guid] = {
--   name, class, level, inRange (bool), scanned (bool),
--   gear (count), gearLinks, enchant (count), rune (count|nil unknown),
--   compliant (bool), reasons (string)
-- }
-- ---------------------------------------------------------------------------

GroupInspect.results = {}

local INVSLOT_FIRST, INVSLOT_LAST = 1, 19   -- head .. ranged/relic (matches Enforcement)
local TICK         = 1.0    -- seconds between inspect attempts (one unit per tick)
local INSPECT_WAIT = 1.5    -- give up on a unit if INSPECT_READY never arrives
local RETRY        = 10     -- re-try out-of-range members this often (passive refresh)

local function P()  return Addon:GetPhaseData() end

-- Enumerate the current group's units. Includes the player. Empty when solo.
local function groupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, 40 do
            local u = "raid" .. i
            if UnitExists(u) then units[#units + 1] = u end
        end
    elseif IsInGroup() then
        units[#units + 1] = "player"
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) then units[#units + 1] = u end
        end
    end
    return units
end

-- Best-effort: count enchanted gear slots whose applied-enchant ID maps to a
-- LATER phase. The enchant ID in an item link (field 2 of the item: string) is a
-- different namespace from the spell IDs in Data/Enchants.lua, so flagging needs
-- an explicit ns.EnchantApplyPhases[applyID] = unlockPhase map. Until that is
-- seeded this records how many slots are enchanted but flags none (no false
-- positives). Returns (enchantedCount, laterPhaseCount).
local function scanEnchants(unit, activePhase)
    local applyMap = ns.EnchantApplyPhases
    local enchanted, later, details = 0, 0, {}
    for slot = INVSLOT_FIRST, INVSLOT_LAST do
        local link = GetInventoryItemLink and GetInventoryItemLink(unit, slot)
        if link then
            local enchantID = tonumber((link:match("|Hitem:%d+:(%d+)")))
            if enchantID and enchantID > 0 then
                enchanted = enchanted + 1
                local unlock = applyMap and applyMap[enchantID]
                if unlock and unlock > activePhase then
                    later = later + 1
                    details[#details + 1] = { link = link, phase = unlock }
                end
            end
        end
    end
    return enchanted, later, details
end

-- Best-effort: count runes the inspected unit has from a later phase. No reliable
-- per-UNIT rune API is exposed by C_Engraving (GetRunes is self-only), so absent a
-- working call this returns nil = "unknown" and the rune check is skipped (never
-- flagged). Structured so a future inspect-capable API can plug in here.
local function scanRunes(unit, phase)
    if unit == "player" and C_Engraving and C_Engraving.GetRunes and ns.RuneViolatesPhase then
        -- We can authoritatively read our own runes; reuse the shared check.
        local later = 0
        local ok, runes = pcall(C_Engraving.GetRunes)
        if not ok or type(runes) ~= "table" then return nil end
        for _, rune in ipairs(runes) do
            if ns.RuneViolatesPhase(rune, phase) then later = later + 1 end
        end
        return later
    end
    return nil   -- other units: unknown (no inspect API)
end

-- Fill the gear/enchant/rune data + compliance verdict for a unit we just
-- inspected. Mirrors the reasons/compliant shape of Compliance:Record so the UI
-- styles group rows identically to guild rows.
local function evaluate(unit, entry)
    local phase = P()
    if not phase then return end

    -- Gear: reuse the shared per-item phase check (bannedItems + req-level).
    local gearCount, gearLinks = 0, {}
    for slot = INVSLOT_FIRST, INVSLOT_LAST do
        local itemID = GetInventoryItemID and GetInventoryItemID(unit, slot)
        if itemID and ns.ItemViolatesPhase and ns.ItemViolatesPhase(itemID, phase) then
            gearCount = gearCount + 1
            gearLinks[#gearLinks + 1] = select(2, GetItemInfo(itemID)) or ("item:" .. itemID)
        end
    end

    local _, enchLater, enchLinks = scanEnchants(unit, Addon:GetActivePhase())
    local runeLater    = scanRunes(unit, phase)

    entry.level   = UnitLevel(unit) or entry.level
    entry.levelCap = phase.levelCap
    entry.gear    = gearCount
    entry.gearLinks = gearLinks
    entry.enchant = enchLater
    entry.enchantLinks = enchLinks
    entry.rune    = runeLater
    entry.scanned = true
    entry.inRange = true

    local reasons = {}
    if entry.level and entry.level > phase.levelCap then
        reasons[#reasons + 1] = "over level cap"
    end
    if gearCount > 0 then
        reasons[#reasons + 1] = string.format("%d invalid item(s)", gearCount)
    end
    if enchLater > 0 then
        reasons[#reasons + 1] = string.format("%d later-phase enchant(s)", enchLater)
    end
    if runeLater and runeLater > 0 then
        reasons[#reasons + 1] = string.format("%d later-phase rune(s)", runeLater)
    end
    entry.compliant = (#reasons == 0)
    entry.reasons   = (#reasons == 0) and "OK" or table.concat(reasons, ", ")
end

-- ---------------------------------------------------------------------------
-- Inspection queue
-- ---------------------------------------------------------------------------
function GroupInspect:OnEnable()
    self:RegisterEvent("INSPECT_READY", "OnInspectReady")
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnGroupChanged")
end

-- Called by the UI when the Group Compliance tab becomes visible / hidden. We only
-- inspect while the tab is being viewed, so we never interfere with the player's own
-- inspect actions or burn cycles in the background.
function GroupInspect:SetActive(active)
    active = active and true or false
    if active == self.active then return end
    self.active = active
    if active then
        if IsInGroup() then self:Scan() end
    else
        self:StopQueue()
    end
end

-- Rescan (debounced) when the group composition changes; clear when solo. Only
-- auto-rescans while the tab is active.
function GroupInspect:OnGroupChanged()
    if self.rescanTimer then self:CancelTimer(self.rescanTimer) end
    self.rescanTimer = self:ScheduleTimer(function()
        self.rescanTimer = nil
        if not IsInGroup() then
            self:Clear()
        elseif self.active then
            self:Scan()
        end
    end, 1.0)
end

function GroupInspect:Clear()
    self:StopQueue()
    wipe(self.results)
    if ns.RefreshRoster then ns.RefreshRoster() end
end

function GroupInspect:StopQueue()
    if self.tickTimer  then self:CancelTimer(self.tickTimer);  self.tickTimer  = nil end
    if self.waitTimer  then self:CancelTimer(self.waitTimer);  self.waitTimer  = nil end
    if self.retryTimer then self:CancelTimer(self.retryTimer); self.retryTimer = nil end
    self.queue = nil
    self.pending = nil
end

-- True while an inspection pass is actively running (drives the status text).
function GroupInspect:IsScanning()
    return (self.tickTimer ~= nil) or (self.pending ~= nil)
end

-- (Re)build the results table from the current group and start inspecting.
function GroupInspect:Scan()
    self:StopQueue()
    wipe(self.results)

    for _, unit in ipairs(groupUnits()) do
        local guid = UnitGUID(unit)
        if guid then
            local name = Ambiguate(GetUnitName(unit, true) or UnitName(unit) or "?", "short")
            local _, class = UnitClass(unit)
            self.results[guid] = {
                unit = unit, name = name, class = class,
                level = UnitLevel(unit),
                inRange = false, scanned = false,
                gear = 0, enchant = 0, rune = nil,
                compliant = true, reasons = "—",
            }
        end
    end

    self.queue = groupUnits()
    self.tickTimer = self:ScheduleRepeatingTimer("ProcessNext", TICK)
    self:ProcessNext()
    if ns.RefreshRoster then ns.RefreshRoster() end
end

-- Pull the next unit off the queue and request its inspect data.
-- The queue emptied. Stop the tick, but if members are still un-inspected (out of
-- range) and the tab is active, schedule a passive retry so they're picked up
-- automatically once they come into range — no user action required.
function GroupInspect:OnQueueDrained()
    if self.tickTimer then self:CancelTimer(self.tickTimer); self.tickTimer = nil end
    self.queue = nil
    if not (self.active and IsInGroup()) then return end
    for _, info in pairs(self.results) do
        if not info.scanned then
            if self.retryTimer then self:CancelTimer(self.retryTimer) end
            self.retryTimer = self:ScheduleTimer("RetryUnscanned", RETRY)
            return
        end
    end
end

-- Re-queue only the still-unscanned (out-of-range) members; preserves rows we've
-- already inspected so compliant members aren't re-inspected every cycle.
function GroupInspect:RetryUnscanned()
    self.retryTimer = nil
    if not (self.active and IsInGroup()) then return end
    local q = {}
    for _, unit in ipairs(groupUnits()) do
        local guid = UnitGUID(unit)
        local info = guid and self.results[guid]
        if info and not info.scanned then q[#q + 1] = unit end
    end
    if #q == 0 then return end
    self.queue = q
    if not self.tickTimer then
        self.tickTimer = self:ScheduleRepeatingTimer("ProcessNext", TICK)
    end
    self:ProcessNext()
end

function GroupInspect:ProcessNext()
    if self.pending then return end          -- still waiting on INSPECT_READY
    if not self.queue or #self.queue == 0 then
        self:OnQueueDrained()
        return
    end

    local unit = table.remove(self.queue, 1)
    if not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    local entry = guid and self.results[guid]
    if not entry then return end

    -- The player's own data needs no inspection — read it directly.
    if unit == "player" then
        evaluate(unit, entry)
        if ns.RefreshRoster then ns.RefreshRoster() end
        return
    end

    local canInspect = (not CanInspect) or CanInspect(unit)
    if not (UnitIsConnected(unit) and canInspect) then
        entry.inRange = false
        entry.scanned = false
        entry.reasons = "out of range"
        if ns.RefreshRoster then ns.RefreshRoster() end
        return
    end

    self.pending = { unit = unit, guid = guid }
    if NotifyInspect then NotifyInspect(unit) end
    -- Don't let a missing INSPECT_READY stall the queue forever.
    self.waitTimer = self:ScheduleTimer("InspectTimedOut", INSPECT_WAIT)
end

function GroupInspect:InspectTimedOut()
    self.waitTimer = nil
    local p = self.pending
    self.pending = nil
    if p then
        local entry = self.results[p.guid]
        if entry and not entry.scanned then
            entry.inRange = false
            entry.reasons = "out of range"
        end
    end
    if ClearInspectPlayer then ClearInspectPlayer() end
    if ns.RefreshRoster then ns.RefreshRoster() end
end

function GroupInspect:OnInspectReady(_, guid)
    local p = self.pending
    if not (p and guid == p.guid) then return end   -- a stray/foreign inspect
    if self.waitTimer then self:CancelTimer(self.waitTimer); self.waitTimer = nil end
    self.pending = nil

    local entry = self.results[guid]
    if entry then evaluate(p.unit, entry) end
    if ClearInspectPlayer then ClearInspectPlayer() end
    if ns.RefreshRoster then ns.RefreshRoster() end
end

-- Sorted array { {name, info}, ... } for the UI: violators first, then by name.
-- Un-scanned (out of range) members sort after compliant ones.
function GroupInspect:GetResults()
    local list = {}
    for _, info in pairs(self.results) do
        list[#list + 1] = { name = info.name, info = info }
    end
    local function rank(i)
        if i.scanned and not i.compliant then return 1 end   -- violators
        if i.scanned then return 2 end                       -- compliant
        return 3                                             -- unknown/out of range
    end
    table.sort(list, function(a, b)
        local ra, rb = rank(a.info), rank(b.info)
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    return list
end

function GroupInspect:InGroup()
    return IsInGroup() and true or false
end
