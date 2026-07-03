local ADDON, ns = ...

-- =========================================================================
-- ns.RuneRelicPhases[itemID] = <unlock phase>
--
-- SoD delivers some class runes as relic-slot items (Druid idols, Paladin
-- librams, etc.) rather than as engravings. Unlike the engraving-rune ITEMS
-- surfaced by C_Engraving, these relics have no API that marks them as runes,
-- so they can't be told apart from an ordinary stat relic at runtime — NOT every
-- INVTYPE_RELIC item is a rune. This is the explicit allowlist: only the item IDs
-- below are rune relics, and their legality is governed by the "rune" rule (not
-- the gear rule). The phase is the SoD phase the relic/rune becomes available in;
-- it's a violation only when that phase is LATER than the active phase.
--
-- Source: SOD_RUNE_RELICS_BY_PHASE.md (Druid + Paladin so far; extend per class).
-- =========================================================================

ns.RuneRelicPhases = {
    -- Druid
    [210534] = 1,
    [206954] = 1,
    [208689] = 1,
    [208414] = 1,
    [210195] = 1,
    [213594] = 2,  -- Idol of the Heckler
    [220915] = 3,  -- Idol of the Raging Shambler
    [227444] = 4,  -- Idol of the Huntress

    -- Paladin
    [208849] = 1,
    [205420] = 1,
    [208851] = 1,
    [211472] = 1,
    [213513] = 2,  -- Libram of Deliverance
}
