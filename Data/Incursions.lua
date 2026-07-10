local ADDON, ns = ...

-- =========================================================================
-- Zul'Gurub / Nightmare Incursion items.
--
-- Like the Fel Portal "Otherworldly Treasures" (see Data/OtherworldlyTreasures.lua),
-- these items were ADDED in a later phase but fall into LOWER required-level ranges
-- and are intended to be usable from the phase listed below onward. The bulk import
-- in Data/Phases.lua lumped them into earlier phases' banned lists (treated as
-- strictly "later phase"), which is wrong: a guild locked to the item's own phase
-- should be allowed to use it.
--
-- ns.IncursionDrops[legalPhase] = { itemID, ... } — the EARLIEST phase each item is
-- legal. Source: INCURSION_OVERRIDES.md. Reconciles Phases.lua bannedItems so
-- gear/bag/compliance checks treat each item as a phase-`legalPhase` item — banned in
-- phases < legalPhase, allowed in phases >= legalPhase — overriding the import.
-- =========================================================================

ns.IncursionDrops = {
    [1] = { 224006, 221193, 221369 },
    [2] = { 221374 },
}

-- Reconcile bannedItems against the correct phase: ban each item in every phase
-- before its legal phase, unban it in that phase and all later ones. Self-
-- correcting and idempotent against whatever the Phases.lua import left behind.
do
    local maxPhase = ns.MAX_PHASE or #ns.Phases
    for legalPhase, ids in pairs(ns.IncursionDrops) do
        for _, itemID in ipairs(ids) do
            for p = 1, maxPhase do
                local phase = ns.Phases[p]
                if phase and phase.bannedItems then
                    if p < legalPhase then
                        phase.bannedItems[itemID] = true
                    else
                        phase.bannedItems[itemID] = nil
                    end
                end
            end
        end
    end
end
