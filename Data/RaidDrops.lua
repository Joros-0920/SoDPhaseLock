local ADDON, ns = ...

-- =========================================================================
-- Curated "unique" (epic) raid drops per phase, surfaced in the Overview tab's
-- "This Phase" panel. Each entry is an itemID; the UI renders the item's icon
-- and shows the live in-game item tooltip on hover (GameTooltip:SetHyperlink
-- via AceConfig `tooltipHyperlink`).
--
-- Only phases present as keys here show the "Unique Drops" panel. An empty list
-- shows a "pending" note; unknown/uncached IDs are skipped gracefully by the UI
-- (GetItemIcon falls back to a question-mark icon).
-- =========================================================================

ns.PhaseRaidDrops = {
    -- Phase 1 — Blackfathom Deeps (lvl 25 raid). IDs supplied by the user; names
    -- pending in-client verification (no local DB to resolve them against).
    [1] = {
        209561,
        209534,
        209562,
        211491,
        211492,
    },

    -- Phase 2 — Gnomeregan (lvl 40 raid). User-supplied list (de-duplicated).
    -- Names from the bundled sod-item-db / Wowhead where known.
    [2] = {
        213353,  -- Defibrillating Staff
        215380,
        213291,  -- Toxic Revenger II
        213286,  -- Electrocutioner's Needle
        213409,  -- Mekkatorque's Arcano-Shredder
        213416,  -- Thermaplugg's Rocket Cleaver
        213356,  -- Thermaplugg's Custom Blaster
        216608,
        215437,
        13325,   -- Fluorescent Green Mechanostrider (mount)
        213412,  -- Dielectric Safety Shield
    },
}

-- Profession-crafted epic gear per phase, shown under "Unique Drops" in the
-- Overview panel. Same itemID-list shape as ns.PhaseRaidDrops.
ns.PhaseCraftedEpics = {
    -- Phase 1 — Blackfathom Deeps era. User-supplied IDs (range matches P1 loot;
    -- confirm phase in-client).
    [1] = {
        210794,
        210795,
        211423,
        211502,
    },

    -- Phase 2 — Gnomeregan era. User-supplied IDs.
    [2] = {
        215111,  -- Gneuro-Linked Arcano-Filament Monocle
        215163,
        215381,
        215166,
        215114,
        215382,
        215167,
        215161,
        215115,
        213390,  -- Whirling Truesilver Gearwall
        215138,
        215129,
        215141,
    },
}

-- New consumables introduced per phase, shown under "Crafted Epics" in the
-- Overview panel. Same itemID-list shape as ns.PhaseRaidDrops.
ns.PhaseNewConsumes = {
    -- Phase 1 — user-supplied IDs (confirm phase in-client).
    [1] = {
        211845,
        211848,
    },
}
