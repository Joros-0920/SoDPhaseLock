local ADDON, ns = ...
local Addon = ns.Addon

-- Classic Era (1.15) is on the modern client: the old global container
-- functions were removed and live under C_Container. Fall back to the globals
-- for any older client just in case.
local C = C_Container
local GetContainerNumSlots = (C and C.GetContainerNumSlots) or _G.GetContainerNumSlots
local GetContainerItemID   = (C and C.GetContainerItemID)   or _G.GetContainerItemID

-- Cache of overlays already attached to a button. Key = button frame, value = { tint, icon }.
local overlayCache = {}

-- Equip locations that can't carry a classic gear enchant from ns.EnchantApplyPhases.
-- SoD rune-granting relics equip in the relic slot and stash their rune's enchant id
-- in item-link field 2, so a map "match" on these item types is always a rune, not a
-- later-phase enchant — the tooltip must not report it as one.
local RELIC_RANGED_EQUIPLOC = {
    INVTYPE_RELIC       = true,
    INVTYPE_RANGED      = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN      = true,
}

-- SoD engraving rune source items. A rune item lives in the phase bannedItems
-- list (so the gear-rule overlay would flag it), but rune legality is governed by
-- the SEPARATE "rune" rule. When that rule is off the player has opted out of rune
-- restrictions, so a later-phase rune item must not be marked in bags.
--
-- C_Engraving is the authoritative "is this a rune item" signal (no locale-fragile
-- name matching). GetRunes() only returns LEARNED runes, but the flagged item is
-- usually a rune not yet engraved, so enumerate every rune for the class via the
-- category API (onlyKnown = false); fall back to learned-only on older builds.
-- Guarded throughout: on any miss the set is empty and behaviour is unchanged
-- (the X still shows), so this can only ever suppress a genuine rune item.
local runeItemSet   -- itemID -> true, lazily built + cached once non-empty

local function buildRuneItemSet()
    local set = {}
    if not C_Engraving then return set end
    if C_Engraving.GetRuneCategories and C_Engraving.GetRunesForCategory then
        local ok, cats = pcall(C_Engraving.GetRuneCategories, false, false)
        if ok and cats then
            for _, cat in ipairs(cats) do
                local ok2, runes = pcall(C_Engraving.GetRunesForCategory, cat, false)
                if ok2 and runes then
                    for _, rune in ipairs(runes) do
                        if rune.itemID then set[rune.itemID] = true end
                    end
                end
            end
        end
    end
    -- Fallback for builds without the category API: learned runes only.
    if not next(set) and C_Engraving.GetRunes then
        local ok, runes = pcall(C_Engraving.GetRunes)
        if ok and runes then
            for _, rune in ipairs(runes) do
                if rune.itemID then set[rune.itemID] = true end
            end
        end
    end
    return set
end

local function isRuneItem(itemID)
    if not itemID then return false end
    -- Rebuild while empty (engraving data can lag login); cache once populated.
    if not runeItemSet or not next(runeItemSet) then
        runeItemSet = buildRuneItemSet()
    end
    return runeItemSet[itemID] == true
end

-- SoD delivers some class runes as relic-slot items (Druid idols, Paladin librams,
-- etc.). These carry no API that marks them as runes and NOT every relic is one, so
-- there's no runtime signal to tell a rune relic from an ordinary stat relic — the
-- authoritative allowlist lives in ns.RuneRelicPhases (Data/RuneRelics.lua). Like
-- the engraving-rune items above, a rune relic's legality is a RUNE concern, not a
-- gear one, so it's governed by the "rune" rule. Returns its unlock phase, or nil.
local function runeRelicPhase(itemID)
    if not (itemID and ns.RuneRelicPhases) then return nil end
    return ns.RuneRelicPhases[itemID]
end

-- Items whose phase legality is governed by the "rune" rule rather than the gear
-- rule: engraving rune items and rune-granting relics.
local function isRuneGoverned(itemID)
    return isRuneItem(itemID) or runeRelicPhase(itemID) ~= nil
end

-- True when itemID is rune-governed AND the player has the "rune" rule turned off,
-- meaning rune restrictions don't apply and it must not be flagged.
local function runeRestrictionOff(itemID)
    if not isRuneGoverned(itemID) then return false end
    return not Addon:RuleEnabled("rune")
end

-- Returns the earliest phase index at which itemID becomes legal, or nil if always allowed.
local function getItemUnlockPhase(itemID)
    local reqLevel = select(5, GetItemInfo(itemID))
    for i = ns.MIN_PHASE, ns.MAX_PHASE do
        local p = ns.Phases[i]
        if not p.bannedItems[itemID] then
            if not reqLevel or reqLevel <= p.levelCap then
                return i
            end
        end
    end
    return nil
end

-- Returns true if itemID is illegal at the currently active phase.
-- Rune-governed (engraving runes + rune-granting relics): gated by the "rune" rule
--   alone — flagged only when that rule is on AND the item is later-phase. The gear
--   rule never flags them, so a player who opts out of runes sees no X on an idol.
-- Otherwise, gear rule enabled: bannedItems + req-level (full enforcement signal);
--   gear rule off: req-level only (pure level-cap indicator, no enforcement).
local function isBagViolation(itemID)
    if not itemID then return false end
    if not (Addon.db and Addon.db.profile.enabled) then return false end
    local phase = Addon:GetPhaseData()
    if not phase then return false end
    if isRuneGoverned(itemID) then
        if not Addon:RuleEnabled("rune") then return false end
        -- Rune relic: violation iff its rune unlocks LATER than the active phase.
        local relicPhase = runeRelicPhase(itemID)
        if relicPhase then
            local active = Addon:GetActivePhase()
            return active ~= nil and relicPhase > active
        end
        return ns.ItemViolatesPhase(itemID, phase)   -- engraving rune item
    end
    if Addon:RuleEnabled("gear") then
        return ns.ItemViolatesPhase(itemID, phase)
    else
        -- Gear rule off: only flag items whose required level exceeds the phase cap —
        -- and only when the level rule is actually on. This mirrors the same fallback
        -- in Enforcement's itemViolatesInMode; keep the two in step or the overlay and
        -- the violation log disagree about what counts.
        if not Addon:RuleEnabled("level") then return false end
        local reqLevel = select(5, GetItemInfo(itemID))
        return reqLevel ~= nil and reqLevel > phase.levelCap
    end
end

-- Get or lazily create the two overlay layers for a bag-slot button.
local function getOrCreateOverlay(button)
    if overlayCache[button] then return overlayCache[button] end

    -- Semi-transparent red wash over the whole icon.
    local tint = button:CreateTexture(nil, "OVERLAY")
    tint:SetAllPoints()
    tint:SetColorTexture(0.85, 0, 0, 0.45)
    tint:Hide()

    -- Red X icon centred on the slot (uses the raid ready-check "not ready" cross).
    local icon = button:CreateTexture(nil, "OVERLAY")
    icon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:Hide()

    local ov = { tint = tint, icon = icon }
    overlayCache[button] = ov
    return ov
end

-- Decorate a single bag item button. The button's real container slot is
-- button:GetID() (NOT the name-index, which can be mirrored); the bag id comes
-- from the button itself (combined bags) or its owning ContainerFrame.
local function refreshButton(button, bagID)
    if not (button and GetContainerItemID) then return end
    local slot = button.GetID and button:GetID()
    local bag  = (button.GetBagID and button:GetBagID()) or bagID
    if not bag then
        local parent = button.GetParent and button:GetParent()
        bag = parent and parent.GetID and parent:GetID()
    end
    if not (bag and slot) then return end
    local itemID = GetContainerItemID(bag, slot)
    local ov = getOrCreateOverlay(button)
    if isBagViolation(itemID) then
        ov.tint:Show()
        ov.icon:Show()
    else
        ov.tint:Hide()
        ov.icon:Hide()
    end
end

-- Refresh every item button on one container frame (a single open bag, or the
-- combined-bags frame). Uses Blizzard's own item enumeration when available
-- (correct for combined bags); otherwise falls back to named child buttons.
local function refreshFrame(frame)
    if not (frame and frame.IsShown and frame:IsShown()) then return end
    if frame.EnumerateValidItems then
        for _, button in frame:EnumerateValidItems() do
            refreshButton(button)
        end
        return
    end
    if not (frame.GetID and frame:GetName()) then return end
    local bagID = frame:GetID()
    local name  = frame:GetName()
    local numSlots = GetContainerNumSlots and GetContainerNumSlots(bagID) or 0
    for i = 1, numSlots do
        refreshButton(_G[name .. "Item" .. i], bagID)
    end
end

-- Sweep all currently-open bag frames (separate-bag frames + combined frame).
local function updateBagOverlays()
    for bagIndex = 1, NUM_CONTAINER_FRAMES or 13 do
        refreshFrame(_G["ContainerFrame" .. bagIndex])
    end
    refreshFrame(_G.ContainerFrameCombinedBags)
end

-- Reapply overlays whenever Blizzard redraws a bag (items move, bag opens, etc.)
-- if the hook exists on this client build.
if type(ContainerFrame_Update) == "function" then
    hooksecurefunc("ContainerFrame_Update", refreshFrame)
end

-- Bulletproof trigger: opening a bag fires no bag event, and ContainerFrame_Update
-- may not exist on every client build, so drive a throttled refresh while any bag
-- frame is visible. The per-frame IsShown() guard makes this nearly free when bags
-- are closed.
local function anyBagShown()
    for bagIndex = 1, NUM_CONTAINER_FRAMES or 13 do
        local f = _G["ContainerFrame" .. bagIndex]
        if f and f:IsShown() then return true end
    end
    local cb = _G.ContainerFrameCombinedBags
    return cb and cb:IsShown()
end

local driver = CreateFrame("Frame")
local sinceUpdate = 0
driver:SetScript("OnUpdate", function(_, dt)
    sinceUpdate = sinceUpdate + dt
    if sinceUpdate < 0.2 then return end
    sinceUpdate = 0
    if anyBagShown() then updateBagOverlays() end
end)

-- Tooltip decoration: appends which phase the item — and/or its applied enchant —
-- unlocks at. The item and the enchant are reported on separate lines so the
-- player can tell whether it's the gear itself or the enchant on it that's
-- later-phase. Fires for every item tooltip regardless of where it's shown.
GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
    if not (Addon.db and Addon.db.profile.enabled) then return end
    local _, link = tooltip:GetItem()
    if not link then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end

    local phase = Addon:GetPhaseData()
    if not phase then return end

    -- The item itself. A rune-governed item (engraving rune or rune-granting relic)
    -- is restricted only when the "rune" rule is on; suppress otherwise (matches the
    -- bag X). A rune relic reports its authoritative unlock phase as a rune.
    local relicPhase = runeRelicPhase(itemID)
    if relicPhase then
        local active = Addon:GetActivePhase()
        if Addon:RuleEnabled("rune") and active and relicPhase > active then
            tooltip:AddLine(string.format("|cffff4040SoD Phase Lock:|r Rune unlocks in %s.",
                ns.Phases[relicPhase].name))
        end
    elseif not runeRestrictionOff(itemID) and ns.ItemViolatesPhase(itemID, phase) then
        local unlockIdx = getItemUnlockPhase(itemID)
        if unlockIdx then
            tooltip:AddLine(string.format("|cffff4040SoD Phase Lock:|r Item unlocks in %s.",
                ns.Phases[unlockIdx].name))
        else
            tooltip:AddLine("|cffff4040SoD Phase Lock:|r Item not available at the current phase.")
        end
    end

    -- The applied permanent enchant (field 2 of the item link is the apply ID,
    -- a different namespace from the enchant spell IDs; mapped in
    -- Data/EnchantApplyPhases.lua). 0 = no enchant.
    --
    -- SoD engraved runes ride in this same field-2 slot as an enchant. A rune-
    -- granting relic (idol/libram/totem/sigil) or a ranged weapon can never carry
    -- a classic gear enchant from the map, so a match there is always a rune and
    -- must not be reported as a later-phase enchant — suppress the line by equipLoc.
    local activeIdx = Addon:GetActivePhase()
    local enchantID = tonumber(link:match("item:%d+:(%d+)"))
    local equipLoc  = select(9, GetItemInfo(itemID))
    if activeIdx and enchantID and enchantID ~= 0 and not RELIC_RANGED_EQUIPLOC[equipLoc or ""] then
        local enchUnlock = ns.EnchantApplyPhases and ns.EnchantApplyPhases[enchantID]
        if enchUnlock and enchUnlock > activeIdx then
            tooltip:AddLine(string.format("|cffff4040SoD Phase Lock:|r Enchant unlocks in %s.",
                ns.Phases[enchUnlock].name))
        end
    end
end)

-- Listen for bag changes and refresh overlays.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(_, event)
    -- Engraving data can lag login; drop the cache so it rebuilds on next use.
    if event == "PLAYER_ENTERING_WORLD" then runeItemSet = nil end
    updateBagOverlays()
end)

-- ---------------------------------------------------------------------------
-- Baganator integration.
--
-- Baganator (and other bag-replacement addons) hide the default Blizzard bag UI
-- entirely, so the ContainerFrame overlay above never runs for their users.
-- Baganator exposes a corner-widget plugin API; register an "X" icon corner
-- widget so flagged items are marked inside Baganator's bag/bank views too.
-- ---------------------------------------------------------------------------
local BAGANATOR_WIDGET_ID = "sodphaselock_blocked"

local function baganatorItemID(details)
    if not details then return nil end
    if details.itemID then return details.itemID end
    local link = details.itemLink
    return link and tonumber(link:match("item:(%d+)"))
end

-- onInit: create the red-X texture once per item button.
local function baganatorOnInit(itemButton)
    local tex = itemButton:CreateTexture(nil, "OVERLAY")
    tex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    tex:SetSize(16, 16)
    tex.padding = 0
    return tex
end

-- onUpdate: true = show X, false = hide, nil = data not ready (Baganator retries).
local function baganatorOnUpdate(_, details)
    local itemID = baganatorItemID(details)
    if not itemID then return false end
    if isBagViolation(itemID) then return true end
    -- If GetItemInfo isn't cached yet the required-level check returned nil (no
    -- violation recorded) — return nil so Baganator retries when the cache lands.
    if Addon.db and Addon.db.profile.enabled then
        local phase = Addon:GetPhaseData()
        if phase and not GetItemInfo(itemID) then
            return nil
        end
    end
    return false
end

local baganatorRegistered = false
local function registerBaganator()
    local baganator = rawget(_G, "Baganator")
    if not (baganator and baganator.API and baganator.API.RegisterCornerWidget) then return end
    if baganatorRegistered then return end

    -- defaultSettings must include enabled=true so Baganator auto-activates this
    -- widget for users who have no saved setting for our ID yet.  Without it the
    -- widget is registered but Baganator treats it as disabled and never calls onUpdate.
    baganator.API.RegisterCornerWidget(
        "SoD Phase Lock: blocked",   -- label shown in Baganator's icon-corner settings
        BAGANATOR_WIDGET_ID,
        baganatorOnUpdate,
        baganatorOnInit,
        { enabled = true },          -- auto-activate for new users
        true                         -- isFast: cheap, no full tooltip scan
    )
    baganatorRegistered = true

    -- Trigger an immediate refresh so the X appears right away (registration alone
    -- doesn't repaint existing item buttons).
    if baganator.API.RequestItemButtonsRefresh then
        baganator.API.RequestItemButtonsRefresh()
    end
end

-- Force Baganator to re-run our widget (used when the ruleset/phase/mode changes).
local function refreshBaganator()
    if not baganatorRegistered then return end
    local baganator = rawget(_G, "Baganator")
    if baganator and baganator.API and baganator.API.RequestItemButtonsRefresh then
        baganator.API.RequestItemButtonsRefresh()
    end
end

local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
if isLoaded and isLoaded("Baganator") then
    registerBaganator()
else
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    loader:SetScript("OnEvent", function(self, _, addonName)
        if addonName == "Baganator" then
            registerBaganator()
            self:UnregisterEvent("ADDON_LOADED")
        end
    end)
end

-- Called by Core:ApplyRuleset when the phase or mode changes.
ns.RefreshBagOverlays = function()
    runeItemSet = nil      -- rebuild the rune-item set (rune rule may have changed)
    updateBagOverlays()    -- default Blizzard bags
    refreshBaganator()     -- Baganator views, if installed + active
end

-- Diagnostic: scan all bags (open or not) and count items that are *beyond the
-- current phase* per the data, independent of the authentic/gear gating. Used by
-- "/sodlock bag" so the user can see why overlays are or aren't showing.
function ns.BagDiagnostics()
    local phase = Addon:GetPhaseData()
    local flagged, scanned = 0, 0
    if not phase then return flagged, scanned, phase end
    ns.Bags.forEach(ns.Bags.bagIDs(), function(_, _, itemID)
        scanned = scanned + 1
        if ns.ItemViolatesPhase(itemID, phase) then flagged = flagged + 1 end
    end)
    return flagged, scanned, phase
end
