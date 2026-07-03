local ADDON, ns = ...

-- =========================================================================
-- Fel Portal "Otherworldly Treasures" BoE drops.
--
-- This content was ADDED in a later phase, but the individual BoE items fall
-- into LOWER required-level ranges and are intended to be usable from the phase
-- listed below onward. The bulk import in Data/Phases.lua
-- lumped every one of these into the Phase 1 AND Phase 2 banned lists (i.e.
-- treated them as strictly "later phase"), which is wrong: a guild locked to the
-- item's own phase should be allowed to use it.
--
-- ns.FelPortalDrops[legalPhase] = { itemID, ... } — the EARLIEST phase each item
-- is legal. Source: OTHERWORLDLY_TREASURES_OVERRIDE.md. Consumed two ways:
--   1. Reconcile Phases.lua bannedItems below so gear/bag/compliance checks treat
--      each item as a phase-`legalPhase` item — banned in phases < legalPhase,
--      allowed in phases >= legalPhase — overriding the incorrect bulk import.
--   2. UI/Options.lua renders a per-phase "Fel Portal Drops" section in the
--      Overview panel from this table.
-- =========================================================================

ns.FelPortalDrops = {
    [1] = { 223215, 223219, 223221, 223222, 223239, 223237, 223216, 223238 },
    [2] = { 223218, 223251, 223249, 223250, 223248, 223217, 223240, 223241, 223242 },
    [3] = { 223263, 223198, 223262, 223214, 223261 },
}

-- Reconcile bannedItems against the correct phase: ban each item in every phase
-- before its legal phase, unban it in that phase and all later ones. Self-
-- correcting and idempotent against whatever the Phases.lua import left behind.
do
    local maxPhase = ns.MAX_PHASE or #ns.Phases
    for legalPhase, ids in pairs(ns.FelPortalDrops) do
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
