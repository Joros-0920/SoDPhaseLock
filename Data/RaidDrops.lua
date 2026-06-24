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

    -- Phase 3 — Sunken Temple (lvl 50 raid). User-supplied list.
    [3] = {
        220620,
        221484,
        220638,
        220635,
        220627,
        220630,
        220626,
        220629,
        220628,
    },
}

-- Profession-crafted epic gear per phase, shown under "Crafted Epics" in the
-- Overview panel. A phase's value is EITHER a flat itemID array (rendered as one
-- grid) OR a list of profession groups { profession = "Name", items = { id, ... } }
-- (rendered as a sub-header per profession + its own grid). The UI auto-detects
-- the shape, so flat and grouped phases can coexist.
ns.PhaseCraftedEpics = {
    -- Phase 1 — Blackfathom Deeps era. Grouped by profession (source: PHASE_1.md).
    [1] = {
        { profession = "Blacksmithing",  items = { 210794, 210773 } },
        { profession = "Leatherworking", items = { 211423, 211502 } },
        { profession = "Tailoring",      items = { 210795, 210781, 215365, 215366 } },
    },

    -- Phase 2 — Gnomeregan era. Grouped by profession (user-supplied).
    [2] = {
        { profession = "Alchemy",        items = { 215163 } },
        { profession = "Blacksmithing",  items = { 215167, 215161 } },
        { profession = "Enchanting",     items = { 215138, 215129 } },
        { profession = "Engineering",    items = { 215432, 215431, 215156 } },
        { profession = "Leatherworking", items = { 215166, 215114, 215381, 215382 } },
        { profession = "Tailoring",      items = { 215111 } },
    },

    -- Phase 3 — Sunken Temple era. Grouped by profession (user-supplied), so the
    -- panel renders a sub-header per profession above its crafted epics.
    [3] = {
        { profession = "Alchemy",        items = { 222952, 221024 } },
        { profession = "Blacksmithing",  items = { 220738, 220740, 220739 } },
        { profession = "Enchanting",     items = { 221028, 220792 } },
        { profession = "Engineering",    items = { 221025, 221026, 221027 } },
        { profession = "Leatherworking", items = { 220747, 220748, 220745, 220742, 220744, 220743 } },
        { profession = "Tailoring",      items = { 220749, 220750, 220751 } },
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
