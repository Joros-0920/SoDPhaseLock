local ADDON, ns = ...
local Addon = ns.Addon
local Enforcement = Addon:NewModule("Enforcement", "AceEvent-3.0", "AceTimer-3.0")
ns.Enforcement = Enforcement

-- Live violation state, consumed by the Compliance module for guild reporting.
Enforcement.violations = {
    overLevel  = false,
    instance   = false,   -- currently inside a not-yet-unlocked instance
    gear       = 0,       -- count of equipped over-phase items
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
    self:ScheduleTimer("FullScan", 2)
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
-- ---------------------------------------------------------------------------
-- An item is disallowed if its required level exceeds the phase cap, or it is
-- explicitly listed as sourced from a later phase (authentic mode only).
local function itemViolation(itemID, phase)
    if not itemID then return false end
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
    if enabled("gear") then
        return itemViolation(itemID, phase)
    end
    local reqLevel = select(5, GetItemInfo(itemID))
    return reqLevel ~= nil and reqLevel > phase.levelCap
end

function Enforcement:CheckGear()
    if not Addon.db.profile.enabled then
        self.violations.gear = 0
        return
    end
    local phase = P()
    if not phase then return end
    local block = Addon:AutoUnequip()
    local count = 0
    for slot = INVSLOT_FIRST, INVSLOT_LAST do
        local itemID = GetInventoryItemID("player", slot)
        if itemID and itemViolatesInMode(itemID, phase) then
            count = count + 1
            local link = select(2, GetItemInfo(itemID)) or ("item:" .. itemID)
            if block then
                Addon:Alert(link .. " can't be worn this phase — removing it.", "gear" .. slot)
                self:Unequip(slot)
            else
                Addon:Alert(link .. " is not available at the current phase.", "gear" .. slot)
            end
        end
    end
    -- Report to guild compliance only when the gear rule is enforced (a pure
    -- level-cap removal with the rule off is local-only).
    if enabled("gear") then
        self.violations.gear = count
    else
        self.violations.gear = 0
    end
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

-- Scan all bags (backpack + slots 1-4) for the first empty slot.
-- Returns (bagID, slotIndex) or nil when every bag is full.
local CC = C_Container
local function findFreeBagSlot()
    local numSlots = (CC and CC.GetContainerNumSlots) or GetContainerNumSlots
    local getItemID = (CC and CC.GetContainerItemID)  or GetContainerItemID
    if not (numSlots and getItemID) then return nil end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local n = numSlots(bag) or 0
        for s = 1, n do
            if not getItemID(bag, s) then
                return bag, s
            end
        end
    end
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

function Enforcement:CheckRune()
    if not (Addon.db.profile.enabled and enabled("rune")) then
        self.violations.rune = false
        return
    end
    if not (C_Engraving and C_Engraving.GetRunes) then
        self.violations.rune = false
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
    self.violations.rune = anyViolation
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
