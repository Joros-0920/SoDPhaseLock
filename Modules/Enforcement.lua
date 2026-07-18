local ADDON, ns = ...
local Addon = ns.Addon
local Enforcement = Addon:NewModule("Enforcement", "AceEvent-3.0", "AceTimer-3.0")
ns.Enforcement = Enforcement

-- Live violation state, consumed by the Compliance module for guild reporting.
Enforcement.violations = {
    overLevel  = false,
    instance   = false,   -- currently inside a not-yet-unlocked instance
    gear       = 0,       -- count of equipped over-phase items
    enchant    = 0,       -- count of equipped items carrying a later-phase enchant
    bagGear    = 0,       -- count of over-phase items CARRIED in bags (informational; bags aren't enforced)
    profession = false,
    quest      = 0,       -- count of accepted quests from a later phase (authentic only)
    rune       = false,   -- learned at least one rune from a later phase (authentic only)
}

local INVSLOT_FIRST, INVSLOT_LAST = 1, 19   -- head .. ranged/relic
local pendingUnequip = {}                    -- slots queued to unequip after combat

local function P()            return Addon:GetPhaseData() end
-- A rule is enforced whenever it is checked — guild enforcement config OR the
-- player's personal challenges (RuleEnabled ORs them). There is no separate
-- "authentic mode" gate: enabling the rule IS the intent to enforce it. "Mode"
-- (relaxed/authentic) is a derived label, not a precondition (see Core.lua).
local function enabled(rule)  return Addon:RuleEnabled(rule) end

-- ---------------------------------------------------------------------------
function Enforcement:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD",     "OnZoneChanged")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA",     "OnZoneChanged")
    self:RegisterEvent("PLAYER_LEVEL_UP",           "CheckLevel")
    self:RegisterEvent("PLAYER_XP_UPDATE",          "CheckLevel")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED",  "CheckGear")
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED",    "CheckGear")
    self:RegisterEvent("BAG_UPDATE",                "OnBagChanged")
    self:RegisterEvent("SKILL_LINES_CHANGED",       "CheckProfessions")
    self:RegisterEvent("QUEST_DETAIL",              "OnQuestDetail")
    self:RegisterEvent("QUEST_ACCEPTED",            "OnQuestAccepted")
    self:RegisterEvent("QUEST_PROGRESS",            "OnQuestInteract")
    self:RegisterEvent("QUEST_COMPLETE",            "OnQuestInteract")
    self:RegisterEvent("PLAYER_REGEN_ENABLED",      "FlushUnequip")
    self:RegisterEvent("MERCHANT_SHOW",             "OnInteractNPC")
    self:RegisterEvent("GOSSIP_SHOW",               "OnInteractNPC")
    if C_Engraving then
        self:RegisterEvent("LEARNED_SPELL_IN_TAB", "CheckRune")
        -- RUNE_UPDATED fires when a rune is engraved/changed in a slot; wrap in
        -- pcall so an unknown event name on older builds can't abort OnEnable.
        pcall(self.RegisterEvent, self, "RUNE_UPDATED", "CheckRune")
        -- Engraving a rune onto a slot routes through C_Engraving.CastRune. Post-hook
        -- it so we can abort the cast for later-phase runes before it completes
        -- (the rune analogue of the gear auto-unequip block). hooksecurefunc only
        -- observes — it can't prevent the call — so OnRuneCast cancels the cast.
        if C_Engraving.CastRune and not self.runeCastHooked then
            self.runeCastHooked = true
            pcall(hooksecurefunc, C_Engraving, "CastRune", function(...)
                Enforcement:OnRuneCast(...)
            end)
        end
    end
    -- Bind-on-equip confirmation popups: cancel them for over-phase items so the
    -- item never binds/equips. These event names vary by client build, so register
    -- defensively — an unknown event must not abort OnEnable (it would also stop the
    -- FullScan/combat-flush below and cascade into other modules failing to enable).
    for _, ev in ipairs({ "EQUIP_BIND_CONFIRM", "AUTOEQUIP_BIND_CONFIRM", "USE_BIND_CONFIRM" }) do
        pcall(self.RegisterEvent, self, ev, "OnBindConfirm")
    end
    -- XP gain toggled at the NPC (Grendag Brightbeard). Informational only — push a
    -- status ping so officers see the change within seconds rather than waiting for
    -- the next ~60s heartbeat. Event names vary by build; register defensively.
    for _, ev in ipairs({ "ENABLE_XP_GAIN", "DISABLE_XP_GAIN" }) do
        pcall(self.RegisterEvent, self, ev, "OnXPToggled")
    end
    -- Block training a profession proficiency (Expert/Artisan/Master) that would
    -- raise the skill past the phase cap. hooksecurefunc only observes and can't
    -- prevent the purchase, so we wrap the global BuyTrainerService. Trainer
    -- purchases are not combat-protected, so replacing it is safe (best-effort).
    if not self.trainerHooked and BuyTrainerService then
        self.trainerHooked = true
        local origBuy = BuyTrainerService
        BuyTrainerService = function(index, ...)
            if Enforcement:TrainerProficiencyBlocked(index) then return end
            return origBuy(index, ...)
        end
    end
    self:ScheduleTimer("LoginScan", 2)
end

-- Seconds between guild-context readiness re-checks, and how long to wait before
-- scanning anyway (a roster that never lands must not disable enforcement forever).
local LOGIN_SCAN_RETRY   = 1
local LOGIN_SCAN_TIMEOUT = 30

-- First scan of the session. Deferred until the guild context resolves: until then
-- Addon:GuildKey() reads the guildless "" bucket, whose ruleset is the unsynced
-- default (phase 1, epoch 0). Guild enforce flags are all off there, but personal
-- challenges are profile-scoped and RuleEnabled ORs them in regardless of guild — so
-- scanning early flags an authentic player's whole kit against phase 1 until the real
-- ruleset arrives. Addon:OnGuildChanged runs its own FullScan the moment the key
-- resolves; this path covers the genuinely guildless case and the timeout fallback.
function Enforcement:LoginScan(waited)
    waited = waited or 0
    if not Addon:GuildContextReady() and waited < LOGIN_SCAN_TIMEOUT then
        self:ScheduleTimer("LoginScan", LOGIN_SCAN_RETRY, waited + LOGIN_SCAN_RETRY)
        return
    end
    self:FullScan()
end

-- XP gain enabled/disabled at the NPC; report the new state immediately.
function Enforcement:OnXPToggled()
    if ns.Comm then ns.Comm:SendStatus() end
end

-- Run every applicable check at once (login, ruleset change, /sodlock scan).
function Enforcement:FullScan()
    if not Addon.db.profile.enabled then return end
    self:CheckLevel()
    self:OnZoneChanged()
    self:CheckGear()
    self:CheckBags()
    self:CheckProfessions()
    self:CheckQuestLog()
    self:CheckRune()
end

-- ---------------------------------------------------------------------------
-- Level cap (both modes)
-- ---------------------------------------------------------------------------
function Enforcement:CheckLevel()
    if not (Addon.db.profile.enabled and enabled("level")) then return end
    local cap = P() and P().levelCap or 60
    local lvl = UnitLevel("player")
    self.violations.overLevel = lvl > cap
    -- Once the player has disabled XP gains, the reminder is moot — suppress it.
    if lvl >= cap and not IsXPUserDisabled() then
        Addon:Alert(string.format(
            "You are at the phase level cap (%d). Visit Grendag Brightbead in Ironforge to stop gaining XP.",
            cap), "level")
    end
end

-- ---------------------------------------------------------------------------
-- Instances (authentic only) — open-world zones are never gated
--
-- Entering a not-yet-unlocked instance fires a warning immediately, but the
-- player is only flagged in the compliance log if they REMAIN past the grace
-- period. Leaving (or zoning out) within the grace window clears everything.
-- ---------------------------------------------------------------------------
-- Are we currently standing inside a locked (not-yet-unlocked) dungeon/raid?
-- Only when the instance rule is enabled.
local function inLockedInstance()
    if not (Addon.db.profile.enabled and enabled("instance")) then return false end
    local inInstance, instanceType = IsInInstance()
    if not inInstance or (instanceType ~= "party" and instanceType ~= "raid") then
        return false
    end
    local name = GetInstanceInfo()
    if ns.IsInstanceAllowed(Addon:GetActivePhase(), name) then return false end
    return true, name
end

function Enforcement:ClearInstanceViolation()
    if self.instanceGraceTimer then
        self:CancelTimer(self.instanceGraceTimer)
        self.instanceGraceTimer = nil
    end
    self.violations.instance = false
end

function Enforcement:OnZoneChanged()
    local locked, name = inLockedInstance()
    if not locked then
        self:ClearInstanceViolation()
        return
    end

    -- Warn on entry (throttled by Alert). Don't reset the grace clock on repeat
    -- ZONE_CHANGED_NEW_AREA events fired while already inside, and don't downgrade
    -- a player who is already flagged.
    local grace = Addon:InstanceGrace()
    Addon:Alert(string.format(
        "“%s” is not unlocked at the current phase. Leave within %d seconds or you will be reported to your guild's compliance log.",
        name or "this instance", grace), "instance")
    if not self.violations.instance and not self.instanceGraceTimer then
        self.instanceGraceTimer = self:ScheduleTimer("FlagInstanceViolation", grace)
    end
end

-- Grace period elapsed: if still inside the locked instance, mark the violation
-- and push it to the guild immediately rather than waiting for the next ping.
function Enforcement:FlagInstanceViolation()
    self.instanceGraceTimer = nil
    local locked, name = inLockedInstance()
    if not locked then
        self.violations.instance = false
        return
    end
    self.violations.instance = true
    Addon:Alert(string.format(
        "You remained in “%s” — you have been reported to your guild's compliance log.",
        name or "this instance"), "instance-flagged")
    if ns.Comm then ns.Comm:SendStatus() end
end

-- ---------------------------------------------------------------------------
-- Gear — block equipping over-phase items (both modes)
--
-- WoW cannot hard-cancel a protected equip, so "blocking" is two mechanisms:
--   1. OnBindConfirm: decline bind-on-equip popups so a BoE item never binds.
--   2. CheckGear: instantly unequip anything over-phase that did get equipped
--      (out of combat; queued during combat and flushed on PLAYER_REGEN_ENABLED).
-- Both are gated behind the guild "block" setting (Addon:AutoUnequip()).
--
-- Authentic + gear rule: full check (bannedItems + req-level).
-- Relaxed mode: req-level check only — same signal as the bag overlay red X.
-- Guild compliance violations are only counted in authentic mode.
--
-- LATER-PHASE ENCHANTS: an item can be phase-legal but carry an enchant from a
-- later phase. The enchant can't be stripped, so the enforcement action is to
-- unequip the whole enchanted piece (same as an over-phase item). Only checked
-- when the gear rule is on (there is no level-cap analog for enchants); reported
-- to guild compliance as a separate `enchant` count so officers can tell an
-- illegal item apart from a legal item bearing an illegal enchant.
-- ---------------------------------------------------------------------------
-- Rune-granting relics (Druid idols, Paladin librams, etc.) deliver a class rune
-- via the relic slot. Their legality is a RUNE concern, governed by the "rune"
-- rule (see Data/RuneRelics.lua + CheckGear's rune-relic branch below), NOT the
-- gear rule. They sit in bannedItems from the bulk sod-item-db import, so without
-- this guard the gear rule would flag/auto-unequip a legal relic even when the
-- player has the rune rule off.
local function isRuneRelic(itemID)
    return itemID ~= nil and ns.RuneRelicPhases ~= nil and ns.RuneRelicPhases[itemID] ~= nil
end

-- An item is disallowed if its required level exceeds the phase cap, or it is
-- explicitly listed as sourced from a later phase (authentic mode only).
local function itemViolation(itemID, phase)
    if not itemID then return false end
    if isRuneRelic(itemID) then return false end   -- rune rule governs these, not gear
    if phase.bannedItems[itemID] then return true end
    local reqLevel = select(5, GetItemInfo(itemID))   -- may be nil until cached
    if reqLevel and reqLevel > phase.levelCap then return true end
    return false
end
-- Shared with UI/BagOverlay for bag-slot overlay and tooltip decoration.
ns.ItemViolatesPhase = itemViolation

-- Violation check used for auto-unequip and bind-confirm blocking.
-- Gear rule enabled: full bannedItems + req-level check.
-- Gear rule off: req-level only (matches the bag overlay level-cap indicator).
local function itemViolatesInMode(itemID, phase)
    if not itemID then return false end
    if isRuneRelic(itemID) then return false end   -- rune rule governs these, not gear
    if enabled("gear") then
        return itemViolation(itemID, phase)
    end
    local reqLevel = select(5, GetItemInfo(itemID))
    return reqLevel ~= nil and reqLevel > phase.levelCap
end

-- SoD engraved runes ride in the SAME item-link field (field 2) as a classic
-- permanent enchant, but their SpellItemEnchantment IDs are a DIFFERENT namespace
-- that can numerically collide with the classic apply IDs in ns.EnchantApplyPhases.
-- A single slot can carry BOTH a rune and a normal enchant, so we can't just skip
-- any runed slot — that would miss a real later-phase enchant sharing the slot.
-- Instead we identify the rune's own enchant id and ignore field 2 only when it IS
-- that rune. The ranged/relic slot (18) is special: no enchant in the map applies
-- there and a rune-granting idol/libram/totem/sigil parks its rune id in field 2
-- (e.g. the Lunar Idol grants Fury of Stormrage), so that slot is always skipped.
local INVSLOT_RELIC = 18   -- ranged/relic slot (shares the ranged slot id)

-- The engraved rune on this slot, as (item-link enchant id, rune name), or nil
-- if the slot carries no rune. The id lets us tell a rune apart from a genuine
-- enchant in item-link field 2; the name lets the tooltip fallback ignore the
-- rune's own green line (some runes share a display name with an enchant, e.g.
-- the mage "Spell Power" rune vs. "Enchant Weapon/Bracer - Spell Power").
local function slotRuneInfo(slot)
    if not (C_Engraving and C_Engraving.GetRuneForEquipmentSlot) then return nil end
    local ok, info = pcall(C_Engraving.GetRuneForEquipmentSlot, slot)
    if ok and info then return info.itemEnchantmentID, info.name end
    return nil
end

-- Reverse map: normalized applied-enchant name -> earliest phase it appears in.
-- Built lazily from ns.PhaseEnchants (the same data the Available Enchants tab
-- uses). Powers the tooltip fallback below, which phase-checks an enchant by NAME
-- when it isn't visible in item-link field 2.
local enchantPhaseByName
local function normalizeEnchName(s)
    if not s then return nil end
    s = s:gsub("^[Ee]nchanted:%s*", "")   -- some tooltips prefix the green line
    s = s:gsub("^%+", "")                 -- and/or a leading "+"
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s:lower()
end
local function buildEnchantPhaseByName()
    local map = {}
    -- Ascending phase order so the EARLIEST occurrence wins (never over-flag a
    -- name that also exists at/earlier than the active phase).
    for phase = ns.MIN_PHASE or 1, ns.MAX_PHASE or 8 do
        local groups = ns.PhaseEnchants and ns.PhaseEnchants[phase]
        if groups then
            for _, group in ipairs(groups) do
                for _, entry in ipairs(group.items or {}) do
                    local name = entry[2]
                    -- Strip the "Enchant <Slot> - " prefix down to the applied name
                    -- (what the item tooltip's green line actually shows).
                    local short = name and name:match("^[Ee]nchant .- %- (.+)$")
                    local key = normalizeEnchName(short or name)
                    if key and map[key] == nil then map[key] = phase end
                end
            end
        end
    end
    return map
end

-- Fallback: read every green permanent-enchant line off the equipped item's
-- tooltip and return the LATEST recognized enchant phase (nil if none matched).
-- Needed because an engraved rune can occupy item-link field 2, hiding a
-- coexisting profession enchant from the apply-id read; the tooltip still shows
-- the enchant, so we phase-check it by name. Best-effort: names that don't match
-- our data are simply skipped.
--
-- `runeName` is the engraved rune's own display name (this fallback only runs on
-- runed slots). We MUST skip a green line matching it: some runes share a name
-- with an enchant in our data — e.g. the mage "Spell Power" rune vs. "Enchant
-- Weapon/Bracer - Spell Power" (P3/P6) — so without this the rune's own line
-- would be misread as a later-phase enchant and the piece wrongly unequipped.
local enchScanTip
local function tooltipEnchantPhase(slot, runeName)
    if not CreateFrame then return nil end
    if not enchScanTip then
        enchScanTip = CreateFrame("GameTooltip", "SoDPhaseLockEnchScanTip", nil, "GameTooltipTemplate")
    end
    enchScanTip:SetOwner(UIParent, "ANCHOR_NONE")
    enchScanTip:ClearLines()
    if not pcall(enchScanTip.SetInventoryItem, enchScanTip, "player", slot) then return nil end
    enchantPhaseByName = enchantPhaseByName or buildEnchantPhaseByName()
    local runeKey = normalizeEnchName(runeName)
    local latest
    for i = 2, enchScanTip:NumLines() do
        local fs = _G["SoDPhaseLockEnchScanTipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t then
            local r, g, b = fs:GetTextColor()
            if r and g and b and r < 0.2 and g > 0.8 and b < 0.2 then
                local key = normalizeEnchName(t)
                -- Ignore the rune's own line — it isn't an enchant even when its
                -- name collides with one in our data.
                if key and key ~= runeKey then
                    local phase = enchantPhaseByName[key]
                    if phase and (not latest or phase > latest) then latest = phase end
                end
            end
        end
    end
    return latest
end

-- If the equipped item in `slot` carries a permanent enchant that unlocks in a
-- phase LATER than `activePhase`, return that unlock phase; else nil. The apply
-- ID (field 2 of the item link) is a different namespace from the enchant spell
-- IDs in Data/Enchants.lua, so this maps through ns.EnchantApplyPhases (the same
-- data the Group Compliance tab uses).
local function enchantViolationPhase(slot, activePhase)
    if not GetInventoryItemLink then return nil end
    if slot == INVSLOT_RELIC then return nil end   -- field 2 is a rune here, never a gear enchant
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local runeEnchID, runeName = slotRuneInfo(slot)

    -- 1) Fast path: field 2 of the item link carries the enchant apply id. Skip it
    -- when it IS the engraved rune (compare, not blanket-skip, so a coexisting
    -- enchant that occupies field 2 is still judged).
    local map = ns.EnchantApplyPhases
    local applyID = tonumber((link:match("|Hitem:%d+:(%d+)")))
    if map and applyID and applyID > 0 and applyID ~= runeEnchID then
        local unlock = map[applyID]
        if unlock and unlock > activePhase then return unlock end
    end

    -- 2) Tooltip fallback: only when this slot has a rune (the rune may occupy
    -- field 2 and hide a coexisting enchant from step 1). Phase-check by name,
    -- passing the rune name so its own green line is ignored.
    if runeEnchID then
        local byName = tooltipEnchantPhase(slot, runeName)
        if byName and byName > activePhase then return byName end
    end
    return nil
end

function Enforcement:CheckGear()
    if not Addon.db.profile.enabled then
        self.violations.gear = 0
        self.violations.enchant = 0
        return
    end
    local phase = P()
    if not phase then return end
    local block    = Addon:AutoUnequip()
    local gearRule = enabled("gear")
    local runeRule = enabled("rune")
    local active   = Addon:GetActivePhase()
    local count, enchantCount = 0, 0
    local runeRelicViol = false
    for slot = INVSLOT_FIRST, INVSLOT_LAST do
        local itemID = GetInventoryItemID("player", slot)
        if itemID then
            local link = select(2, GetItemInfo(itemID)) or ("item:" .. itemID)
            local relicPhase = ns.RuneRelicPhases and ns.RuneRelicPhases[itemID]
            if relicPhase then
                -- Rune-granting relic: governed by the RUNE rule, never the gear
                -- rule. A violation only when its rune unlocks LATER than active.
                if runeRule and active and relicPhase > active then
                    runeRelicViol = true
                    if block then
                        Addon:Alert(link .. " grants a rune from a later phase — removing it.", "gear" .. slot)
                        self:Unequip(slot)
                    else
                        Addon:Alert(link .. " grants a rune from a later phase.", "gear" .. slot)
                    end
                end
            elseif itemViolatesInMode(itemID, phase) then
                -- The item itself is over-phase — the enchant is moot, it's leaving.
                count = count + 1
                if block then
                    Addon:Alert(link .. " can't be worn this phase — removing it.", "gear" .. slot)
                    self:Unequip(slot)
                else
                    Addon:Alert(link .. " is not available at the current phase.", "gear" .. slot)
                end
            elseif gearRule and enchantViolationPhase(slot, active) then
                -- Phase-legal item carrying a later-phase enchant: can't strip the
                -- enchant, so unequip the whole piece.
                enchantCount = enchantCount + 1
                if block then
                    Addon:Alert(link .. " carries an enchant from a later phase — removing it.", "gear" .. slot)
                    self:Unequip(slot)
                else
                    Addon:Alert(link .. " carries an enchant from a later phase.", "gear" .. slot)
                end
            end
        end
    end
    -- Report to guild compliance only when the gear rule is enforced (a pure
    -- level-cap removal with the rule off is local-only). The enchant check only
    -- runs under the gear rule, so its count is already 0 when the rule is off.
    if gearRule then
        self.violations.gear    = count
        self.violations.enchant = enchantCount
    else
        self.violations.gear    = 0
        self.violations.enchant = 0
    end
    -- Equipped rune-relic result is a "rune" violation. CheckGear and CheckRune
    -- fire on different events, so each stores its own half and recombines them
    -- (OR) to avoid clobbering the other's contribution to violations.rune.
    self._runeRelicViol   = runeRelicViol
    self.violations.rune  = self._runeRelicViol or self._engraveRuneViol or false
end

-- Over-phase items CARRIED in bags. Purely informational — bags aren't enforced, so nothing is
-- unequipped/removed; it just surfaces to officers that a member is holding gear from a later
-- phase (the same best-effort, social-accountability framing as the integrity signals). Gated on
-- the gear rule being enforced: a guild not locking gear has no reason to nag about bag contents.
-- Rune relics are excluded (itemViolatesInMode handles that — they're rune-governed, not gear).
function Enforcement:CheckBags()
    if not (Addon.db.profile.enabled and enabled("gear")) then
        self.violations.bagGear = 0
        return
    end
    local phase = P()
    if not phase then return end
    local count = 0
    ns.Bags.forEach(ns.Bags.bagIDs(), function(_, _, itemID)
        if itemViolatesInMode(itemID, phase) then count = count + 1 end
    end)
    self.violations.bagGear = count
end

-- BAG_UPDATE fires in bursts (looting, moving stacks); debounce the bag re-scan.
function Enforcement:OnBagChanged()
    if self._bagScanTimer then return end
    self._bagScanTimer = self:ScheduleTimer(function()
        self._bagScanTimer = nil
        self:CheckBags()
    end, 0.5)
end

-- Bind-on-equip confirmation popups. If the item awaiting confirmation is
-- over-phase, cancel the popup (and clear the cursor) so it never binds/equips.
-- The pending item is on the cursor for the drag-onto-slot case; right-click /
-- use auto-equips with an empty cursor are caught afterwards by CheckGear.
local BIND_POPUPS = { "EQUIP_BIND", "AUTOEQUIP_BIND", "USE_BIND", "USE_NO_REFUND_CONFIRM" }
function Enforcement:OnBindConfirm()
    if not (Addon.db.profile.enabled and Addon:AutoUnequip()) then return end
    local phase = P()
    if not phase then return end

    local ctype, a1, a2 = GetCursorInfo()
    local itemID
    if ctype == "item" then
        itemID = tonumber(a1)
            or (type(a1) == "string" and tonumber(a1:match("item:(%d+)")))
            or (type(a2) == "string" and tonumber(a2:match("item:(%d+)")))
    end
    if not (itemID and itemViolatesInMode(itemID, phase)) then return end

    for _, p in ipairs(BIND_POPUPS) do
        if StaticPopup_Hide then StaticPopup_Hide(p) end
    end
    if ClearCursor then ClearCursor() end
    local link = select(2, GetItemInfo(itemID)) or ("item:" .. itemID)
    Addon:Alert("Blocked equipping " .. link .. " — not available until a later phase.", "blockequip")
end

-- First empty bag slot (backpack + slots 1-4), as (bagID, slotIndex) or nil when full.
-- Container enumeration is shared via Core/Bags.lua.
local CC = C_Container
local function findFreeBagSlot()
    return ns.Bags.firstFreeSlot(ns.Bags.bagIDs())
end

function Enforcement:Unequip(slot)
    if InCombatLockdown() then
        pendingUnequip[slot] = true
        return
    end
    -- Check for a free slot before touching the equipment so WoW never gets a
    -- chance to print "That bag is full".
    local freeBag, freeSlot = findFreeBagSlot()
    if not freeBag then
        Addon:Alert("Couldn't auto-unequip — make room in your bags.", "unequipfail")
        return
    end
    PickupInventoryItem(slot)
    if not CursorHasItem() then return end  -- slot was already empty
    local putItem = (CC and CC.PickupContainerItem) or PickupContainerItem
    putItem(freeBag, freeSlot)
    if CursorHasItem() then
        -- Free slot was filled between the scan and the put (extremely rare race).
        -- Fall back to the generic backpack insert as a last resort.
        PutItemInBackpack()
    end
    if CursorHasItem() then
        ClearCursor()  -- returns item to equipment slot
        Addon:Alert("Couldn't auto-unequip — make room in your bags.", "unequipfail")
    end
end

function Enforcement:FlushUnequip()
    if not next(pendingUnequip) then return end
    for slot in pairs(pendingUnequip) do
        pendingUnequip[slot] = nil
        self:Unequip(slot)
    end
end

-- ---------------------------------------------------------------------------
-- Rune Broker (authentic only) — close the merchant/gossip window on interact
--
-- Wowhead NPC IDs (both faction variants added in SoD Phase 4):
--   233428 — Horde starting zones (Durotar, Tirisfal, Mulgore …)
--   233335 — Alliance starting zones (Elwynn, Dun Morogh, Teldrassil …)
-- Name fallback catches any additional variants Blizzard may add later.
-- ---------------------------------------------------------------------------
local RUNE_BROKER_IDS = { [233428] = true, [233335] = true }

local function getTargetNPCID()
    local guid = UnitGUID("target")
    if not guid then return nil end
    -- GUID format: "Creature-0-ServerID-InstanceID-ZoneUID-NPCID-SpawnUID"
    -- Parentheses around select() force single-value context so tonumber never
    -- receives the trailing SpawnUID as its base argument.
    return tonumber((select(6, strsplit("-", guid))))
end

local function isRuneBroker()
    local npcID = getTargetNPCID()
    if npcID and RUNE_BROKER_IDS[npcID] then return true end
    return UnitName("target") == "Rune Broker"
end

function Enforcement:OnInteractNPC(event)
    if not (Addon.db.profile.enabled and enabled("runebroker")) then return end
    if not isRuneBroker() then return end
    if event == "MERCHANT_SHOW" then
        CloseMerchant()
    elseif event == "GOSSIP_SHOW" then
        if C_GossipInfo and C_GossipInfo.CloseGossip then
            C_GossipInfo.CloseGossip()
        else
            CloseGossip()
        end
    end
    Addon:Alert("The Rune Broker is not available in authentic mode — runes must be discovered.", "runebroker")
end

-- ---------------------------------------------------------------------------
-- Professions (authentic only)
-- ---------------------------------------------------------------------------

-- Each proficiency tier raises a profession's MAX skill to the value below.
-- Training a tier whose ceiling exceeds the phase cap is blocked at the trainer.
-- Apprentice (75) / Journeyman (150) never exceed the lowest phase cap (150), so
-- they are intentionally omitted. Tier words use Blizzard's localized globals
-- where present, falling back to enUS (locale-fragile — see PROGRESS open items).
local PROFICIENCY_CEILING = {
    [EXPERT  or "Expert"]  = 225,
    [ARTISAN or "Artisan"] = 300,
    [MASTER  or "Master"]  = 375,
}

-- If a trainer service name names a blockable proficiency tier, return the max
-- skill that tier would unlock; otherwise nil.
local function proficiencyCeiling(serviceName)
    if not serviceName then return nil end
    for word, ceiling in pairs(PROFICIENCY_CEILING) do
        if type(word) == "string" and serviceName:find(word, 1, true) then
            return ceiling
        end
    end
    return nil
end

-- True (and warns) when buying trainer service `index` would push a profession
-- proficiency above the active phase's skill cap. Gated on the "profession" rule.
function Enforcement:TrainerProficiencyBlocked(index)
    if not (Addon.db.profile.enabled and enabled("profession")) then return false end
    if not (index and GetTrainerServiceInfo) then return false end
    local cap = (P() and P().profCap) or 300
    local name = GetTrainerServiceInfo(index)
    local ceiling = proficiencyCeiling(name)
    if ceiling and ceiling > cap then
        Addon:Alert(string.format(
            "%s can't be trained this phase — it would raise your skill past the cap of %d.",
            name, cap), "proftrain")
        return true
    end
    return false
end

local profWarned = {}
function Enforcement:CheckProfessions()
    if not (Addon.db.profile.enabled and enabled("profession")) then
        self.violations.profession = false
        return
    end
    local cap = P() and P().profCap or 300
    local anyOver = false
    -- Track the current section header so we can skip the Languages group.
    -- Language skills (Common, Orcish, etc.) are always 300 and never enforced.
    local inLanguages = false
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank = GetSkillLineInfo(i)
        if isHeader then
            inLanguages = (name == (LANGUAGES or "Languages"))
        elseif name and not inLanguages and rank and rank > cap then
            anyOver = true
            if not profWarned[name] then
                profWarned[name] = true
                Addon:Alert(string.format("%s (%d) is above the phase cap of %d.", name, rank, cap),
                    "prof" .. name)
            end
        end
    end
    self.violations.profession = anyOver
end

-- ---------------------------------------------------------------------------
-- Quests (authentic only) — hard-block content from a later phase.
--
-- WoW can't hard-cancel a quest server-side, so "blocking" is layered:
--   1. QUEST_DETAIL  -> DeclineQuest(): close the accept dialog (true pre-accept
--      block for the normal talk-to-NPC case).
--   2. QUEST_ACCEPTED -> abandon: catch quests that slipped in via quest sharing,
--      auto-accept addons, or right-click auto-accept.
--   3. QUEST_PROGRESS / QUEST_COMPLETE -> CloseQuest(): block turn-in.
--   4. CheckQuestLog (login / ruleset change / scan): abandon any banned quest
--      already in the log and report the count to guild compliance.
-- The authentic-mode quest rule toggle is the on/off switch.
-- ---------------------------------------------------------------------------
local function isQuestBlocked(questID)
    if not (Addon.db.profile.enabled and enabled("quest")) then return false end
    return ns.QuestBlockedAtPhase(questID, Addon:GetActivePhase())
end

local function questName(questID)
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
    return title or "That quest"
end

local function unlockLabel(questID)
    local p = ns.GetQuestUnlockPhase(questID)
    local data = p and ns.Phases[p]
    return data and data.name or "a later phase"
end

-- action: "block" (declined / turn-in blocked) or "abandon" (removed from log).
local function questAlert(questID, action, key)
    local msg
    if action == "abandon" then
        msg = string.format("Removed %s — not available until %s.", questName(questID), unlockLabel(questID))
    else
        msg = string.format("%s is not available until %s — blocked.", questName(questID), unlockLabel(questID))
    end
    Addon:Alert(msg, key or ("quest" .. tostring(questID)))
end

-- Abandon a quest by ID (modern C_QuestLog; safe to call when not in the log).
local function abandonQuestByID(questID)
    if not (questID and C_QuestLog and C_QuestLog.GetLogIndexForQuestID) then return end
    if not C_QuestLog.GetLogIndexForQuestID(questID) then return end  -- not in the log
    if C_QuestLog.SetSelectedQuest then C_QuestLog.SetSelectedQuest(questID) end
    if C_QuestLog.SetAbandonQuest then C_QuestLog.SetAbandonQuest() end
    if C_QuestLog.AbandonQuest then C_QuestLog.AbandonQuest() end
end

-- QUEST_DETAIL: the quest-giver accept dialog is open for GetQuestID().
function Enforcement:OnQuestDetail()
    local questID = GetQuestID and GetQuestID()
    if isQuestBlocked(questID) then
        if DeclineQuest then DeclineQuest() end
        questAlert(questID, "block")
    end
end

-- QUEST_PROGRESS / QUEST_COMPLETE: turn-in dialog open for GetQuestID().
function Enforcement:OnQuestInteract()
    local questID = GetQuestID and GetQuestID()
    if isQuestBlocked(questID) then
        if CloseQuest then CloseQuest() end
        questAlert(questID, "block")
    end
end

-- QUEST_ACCEPTED(questLogIndex, questID) — slipped past the dialog block.
function Enforcement:OnQuestAccepted(_, _, questID)
    if isQuestBlocked(questID) then
        questAlert(questID, "abandon")
        abandonQuestByID(questID)
    end
end

-- Scan the quest log for banned quests (e.g. accepted before the lock, or shared
-- in), abandon them, and report the count to guild compliance.
function Enforcement:CheckQuestLog()
    if not (Addon.db.profile.enabled and enabled("quest")) then
        self.violations.quest = 0
        return
    end
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then
        self.violations.quest = 0
        return
    end
    local activePhase = Addon:GetActivePhase()
    -- Collect first: abandoning mutates the log, so don't abandon mid-iteration.
    local blocked = {}
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and ns.QuestBlockedAtPhase(info.questID, activePhase) then
            blocked[#blocked + 1] = info.questID
        end
    end
    self.violations.quest = #blocked
    for _, questID in ipairs(blocked) do
        questAlert(questID, "abandon", "questlog" .. questID)
        abandonQuestByID(questID)
    end
end

-- ---------------------------------------------------------------------------
-- Runes (authentic only).
--
-- Two enforcement points:
--   * CheckRune (login / ruleset change / RUNE_UPDATED) audits every rune the
--     player has LEARNED and flags any from a later phase for guild compliance.
--   * OnRuneCast blocks the act of ENGRAVING a later-phase rune onto a slot from
--     the character-sheet engraving panel — the rune analogue of gear blocking.
--
-- Violation check (`runeViolatesPhase`, two strategies, first available wins):
--   1. If phase.runes is seeded (explicit allowlist): any rune whose spellID is
--      absent from the allowlist is from a later phase.
--   2. Fallback: check the rune's source-item required level against the phase
--      level cap. Works without a hardcoded database as long as the rune token
--      items carry the correct required level.
-- ---------------------------------------------------------------------------
local function runeSpellID(rune)
    return rune and (rune.skillLineAbilityID or rune.learnedAbilitySpellID)
end

local function runeViolatesPhase(rune, phase)
    if not (rune and phase) then return false end
    if next(phase.runes) then  -- explicit per-phase allowlist
        local spellID = runeSpellID(rune)
        return spellID ~= nil and not phase.runes[spellID]
    end
    if rune.itemID then
        -- Fallback: rune token item reqLevel > phase cap → later-phase rune.
        local reqLevel = select(5, GetItemInfo(rune.itemID))
        return reqLevel ~= nil and reqLevel > phase.levelCap
    end
    return false
end
-- Shared with the UI for engraving-panel decoration.
ns.RuneViolatesPhase = runeViolatesPhase

-- Recombine the two independently-computed halves of the "rune" violation:
-- engraving runes (this function) and equipped rune relics (CheckGear).
local function combineRune(self)
    self.violations.rune = self._runeRelicViol or self._engraveRuneViol or false
end

function Enforcement:CheckRune()
    if not (Addon.db.profile.enabled and enabled("rune")) then
        self._engraveRuneViol = false
        combineRune(self)
        return
    end
    if not (C_Engraving and C_Engraving.GetRunes) then
        -- Engraving API missing, but equipped rune relics still count (CheckGear).
        self._engraveRuneViol = false
        combineRune(self)
        return
    end
    local phase = P()
    if not phase then return end

    local anyViolation = false
    for _, rune in ipairs(C_Engraving.GetRunes() or {}) do
        if runeViolatesPhase(rune, phase) then
            anyViolation = true
            local spellID = runeSpellID(rune)
            local label = rune.name or (spellID and ("spell:" .. spellID)) or "Unknown Rune"
            Addon:Alert(label .. " is a rune from a later phase.", "rune" .. tostring(spellID or label))
        end
    end
    self._engraveRuneViol = anyViolation
    combineRune(self)
end

-- Resolve the rune being engraved. C_Engraving.CastRune's argument differs by
-- build (skillLineAbilityID on some, the learned spellID on others), so prefer
-- the authoritative GetCurrentRuneCast() and fall back to matching either id
-- field against the learned rune list. Returns nil when it can't be resolved
-- (we then decline to block, to avoid false positives).
local function resolveCastRune(arg)
    if C_Engraving.GetCurrentRuneCast then
        local cur = C_Engraving.GetCurrentRuneCast()
        if cur then return cur end
    end
    if arg ~= nil and C_Engraving.GetRunes then
        for _, rune in ipairs(C_Engraving.GetRunes() or {}) do
            if rune.skillLineAbilityID == arg or rune.learnedAbilitySpellID == arg then
                return rune
            end
        end
    end
    return nil
end

-- Post-hook of C_Engraving.CastRune: the engraving cast has already started by
-- the time we run, so for a later-phase rune we abort the in-progress cast (and
-- clear the pending selection) before it can apply to the slot. Gated on the
-- guild "block over-phase gear" setting; warn-only when blocking is off.
function Enforcement:OnRuneCast(arg)
    if not (Addon.db.profile.enabled and enabled("rune")) then return end
    local phase = P()
    if not phase then return end
    local rune = resolveCastRune(arg)
    if not runeViolatesPhase(rune, phase) then return end

    local label = (rune and rune.name) or "That rune"
    if Addon:AutoUnequip() then
        -- Abort the engraving cast. SpellStopCasting may be protected on some
        -- builds, so guard it; ClearCurrentRuneCast drops the queued selection so
        -- the panel doesn't keep trying to apply it.
        if SpellStopCasting then pcall(SpellStopCasting) end
        if C_Engraving.ClearCurrentRuneCast then pcall(C_Engraving.ClearCurrentRuneCast) end
        Addon:Alert(label .. " can't be engraved this phase — engraving cancelled.", "runecast")
    else
        Addon:Alert(label .. " is a rune from a later phase and shouldn't be engraved.", "runecast")
    end
end
