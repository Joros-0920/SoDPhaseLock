local ADDON, ns = ...

-- =========================================================================
-- ns.EnchantApplyPhases[applyID] = <unlock phase>
--
-- The number in field 2 of an item link (item:<itemID>:<applyID>:...) is the
-- SpellItemEnchantment ("apply") ID — a DIFFERENT namespace from the enchant
-- *spell* IDs in Data/Enchants.lua. Modules/GroupInspect.lua reads this apply
-- ID off each inspected unit's gear and flags any slot whose mapped phase is
-- LATER than the active phase.
--
-- Source: each enchant spell's Wowhead Classic page ("Enchant Item: <name>
-- (NNNN)" in Spell Details). Covers phases 2-8 (Phase 1 omitted — a P1 enchant
-- can never be "later phase" than any active phase, so it can never violate).
--
-- EARLIEST-WINS on shared IDs: in Classic one SpellItemEnchantment record is
-- reused by same-effect enchants across slots (e.g. Lesser Stamina on bracer/
-- boots/shield all apply 724) and occasionally across phases (e.g. 904 Agility
-- = P2 gloves + P3 boots; 1897 = P2 2H Impact + P3 Superior Striking). Because
-- the item link only carries the apply ID, an entry is mapped to the EARLIEST
-- phase it appears, so a legal lower-tier enchant is never false-flagged (the
-- trade-off is we under-flag the later-phase twin — safe, no false positives).
-- Comments list every enchant sharing each ID.
-- =========================================================================

ns.EnchantApplyPhases = {
    [241] = 2,  -- Weapon-LesserStriking
    [255] = 2,  -- Boots-LesserSpirit
    [724] = 2,  -- Bracer-LesserStamina, Boots-LesserStamina, Shield-LesserStamina
    [803] = 3,  -- Weapon-FieryWeapon
    [805] = 3,  -- Weapon-GreaterStriking
    [823] = 2,  -- Bracer-LesserStrength
    [844] = 2,  -- Gloves-Mining
    [845] = 2,  -- Gloves-Herbalism
    [846] = 2,  -- Gloves-Fishing
    [847] = 2,  -- Chest-MinorStats
    [848] = 2,  -- Cloak-Defense
    [849] = 2,  -- Cloak-LesserAgility, Boots-LesserAgility
    [850] = 2,  -- Chest-GreaterHealth
    [851] = 2,  -- Bracer-Spirit, Shield-Spirit, Boots-Spirit
    [852] = 2,  -- Bracer-Stamina, Boots-Stamina, Shield-Stamina
    [853] = 2,  -- Weapon-LesserBeastslayer
    [854] = 2,  -- Weapon-LesserElementalSlayer
    [856] = 2,  -- Bracer-Strength, Gloves-Strength
    [857] = 2,  -- Chest-GreaterMana
    [863] = 2,  -- Shield-LesserBlock
    [865] = 2,  -- Gloves-Skinning
    [866] = 2,  -- Chest-LesserStats
    [884] = 2,  -- Cloak-GreaterDefense
    [903] = 2,  -- Cloak-Resistance
    [904] = 2,  -- Gloves-Agility, Boots-Agility
    [905] = 2,  -- Bracer-Intellect
    [906] = 2,  -- Gloves-AdvancedMining
    [907] = 2,  -- Bracer-GreaterSpirit, Shield-GreaterSpirit
    [908] = 2,  -- Chest-SuperiorHealth
    [909] = 2,  -- Gloves-AdvancedHerbalism
    [910] = 3,  -- Cloak-Stealth
    [911] = 3,  -- Boots-MinorSpeed
    [912] = 3,  -- Weapon-Demonslaying
    [913] = 3,  -- Chest-SuperiorMana
    [923] = 3,  -- Bracer-Deflection
    [925] = 2,  -- Bracer-LesserDeflection
    [926] = 3,  -- Shield-FrostResistance
    [927] = 3,  -- Bracer-GreaterStrength, Gloves-GreaterStrength
    [928] = 3,  -- Chest-Stats
    [929] = 3,  -- Bracer-GreaterStamina, Boots-GreaterStamina, Shield-GreaterStamina
    [930] = 3,  -- Gloves-RidingSkill
    [931] = 3,  -- Gloves-MinorHaste
    [943] = 2,  -- Weapon-Striking, 2HWeapon-LesserImpact
    [963] = 3,  -- 2HWeapon-GreaterImpact
    [1883] = 3,  -- Bracer-GreaterIntellect
    [1884] = 3,  -- Bracer-SuperiorSpirit
    [1885] = 3,  -- Bracer-SuperiorStrength
    [1886] = 3,  -- Bracer-SuperiorStamina
    [1887] = 3,  -- Gloves-GreaterAgility, Boots-GreaterAgility
    [1888] = 3,  -- Cloak-GreaterResistance
    [1889] = 3,  -- Cloak-SuperiorDefense
    [1890] = 3,  -- Shield-SuperiorSpirit
    [1891] = 3,  -- Chest-GreaterStats
    [1892] = 3,  -- Chest-MajorHealth
    [1893] = 3,  -- Chest-MajorMana
    [1894] = 3,  -- Weapon-IcyChill
    [1896] = 3,  -- 2HWeapon-SuperiorImpact
    [1897] = 2,  -- 2HWeapon-Impact, Weapon-SuperiorStriking
    [1898] = 3,  -- Weapon-Lifestealing
    [1899] = 3,  -- Weapon-UnholyWeapon
    [1900] = 3,  -- Weapon-Crusader
    [1903] = 3,  -- 2HWeapon-MajorSpirit
    [1904] = 3,  -- 2HWeapon-MajorIntellect
    [2443] = 2,  -- Weapon-WintersMight
    [2463] = 2,  -- Cloak-FireResistance
    [2504] = 3,  -- Weapon-SpellPower
    [2505] = 3,  -- Weapon-HealingPower
    [2563] = 3,  -- Weapon-Strength
    [2564] = 3,  -- Gloves-SuperiorAgility, Weapon-Agility
    [2565] = 3,  -- Bracer-ManaRegeneration
    [2566] = 3,  -- Bracer-HealingPower
    [2567] = 3,  -- Weapon-MightySpirit
    [2568] = 3,  -- Weapon-MightyIntellect
    [2613] = 3,  -- Gloves-Threat
    [2614] = 3,  -- Gloves-ShadowPower
    [2615] = 3,  -- Gloves-FrostPower
    [2616] = 3,  -- Gloves-FirePower
    [2617] = 3,  -- Gloves-HealingPower
    [2619] = 3,  -- Cloak-GreaterFireResistance
    [2620] = 3,  -- Cloak-GreaterNatureResistance
    [2621] = 3,  -- Cloak-Subtlety
    [2622] = 3,  -- Cloak-Dodge
    [2646] = 3,  -- 2HWeapon-Agility
    [7210] = 2,  -- Weapon-Dismantle (SoD)
    [7223] = 2,  -- Chest-Retricutioner (SoD)
    [7603] = 4,  -- Shield-LawOfNature (SoD)
    [7645] = 6,  -- Chest-LivingStats (SoD)
    [7646] = 6,  -- Gloves-HolyPower (SoD)
    [7647] = 6,  -- Gloves-ArcanePower (SoD)
    [7655] = 6,  -- Bracer-SpellPower (SoD)
    [7656] = 6,  -- Bracer-Agility (SoD)
    [7659] = 8,  -- OffHand-SuperiorIntellect (SoD)
    [7660] = 8,  -- OffHand-ExcellentSpirit (SoD)
    [7661] = 8,  -- OffHand-Wisdom (SoD)
    [7662] = 8,  -- 2HWeapon-Spellblasting (SoD)
    [7663] = 8,  -- Shield-ExcellentStamina (SoD)
    [7664] = 8,  -- Shield-CriticalStrike (SoD)
    [7665] = 8,  -- Bracer-GreaterSpellpower (SoD)
    [7666] = 8,  -- Gloves-SuperiorStrength (SoD)
    [7667] = 8,  -- Cloak-Agility (SoD)
    [7940] = 8,  -- Weapon-GrandCrusader (SoD)
    [7941] = 8,  -- 2HWeapon-GrandArcanist (SoD)
    [7942] = 8,  -- Weapon-GrandSorceror (SoD)
    [7943] = 8,  -- 2HWeapon-GrandInquisitor (SoD)
}
