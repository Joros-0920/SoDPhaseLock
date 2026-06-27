local ADDON, ns = ...

-- =========================================================================
-- Reagents required to apply each enchant, keyed by the enchant SPELL id used
-- in Data/Enchants.lua. Each reagent is { id = <itemID>, count = N, name = "..." }.
--   - `name`  is authoritative - shown verbatim (sourced from Wowhead Classic).
--   - `id`    drives the icon, item link and hover tooltip; optional (a missing
--             id just renders a generic icon).
--   - `count` is the quantity for ONE application.
-- Enchanting rods (tools) are intentionally excluded.
-- Generated from Wowhead Classic spell data; reagent item IDs verified for the
-- common enchanting materials. A few rare SoD mats ship name-only (no id).
-- =========================================================================

ns.EnchantReagents = {
    -- Phase 1 - Cloak
    [7454] = { { id = 10940, count = 1, name = "Strange Dust" }, { id = 10938, count = 2, name = "Lesser Magic Essence" } },
    [7771] = { { id = 10940, count = 3, name = "Strange Dust" }, { id = 10939, count = 1, name = "Greater Magic Essence" } },
    [7861] = { { count = 1, name = "Fire Oil" }, { id = 10998, count = 1, name = "Lesser Astral Essence" } },
    [13419] = { { id = 10998, count = 1, name = "Lesser Astral Essence" } },
    [13421] = { { id = 10940, count = 6, name = "Strange Dust" }, { id = 10978, count = 1, name = "Small Glimmering Shard" } },
    [13522] = { { id = 11082, count = 1, name = "Greater Astral Essence" }, { count = 1, name = "Shadow Protection Potion" } },
    -- Phase 1 - Chest
    [7420] = { { id = 10940, count = 1, name = "Strange Dust" } },
    [7426] = { { id = 10940, count = 2, name = "Strange Dust" }, { id = 10938, count = 1, name = "Lesser Magic Essence" } },
    [7443] = { { id = 10938, count = 1, name = "Lesser Magic Essence" } },
    [7748] = { { id = 10940, count = 2, name = "Strange Dust" }, { id = 10938, count = 2, name = "Lesser Magic Essence" } },
    [7776] = { { id = 10939, count = 1, name = "Greater Magic Essence" }, { id = 10938, count = 1, name = "Lesser Magic Essence" } },
    [7857] = { { id = 10940, count = 4, name = "Strange Dust" }, { id = 10998, count = 1, name = "Lesser Astral Essence" } },
    [13538] = { { id = 10940, count = 2, name = "Strange Dust" }, { id = 11082, count = 1, name = "Greater Astral Essence" }, { id = 11084, count = 1, name = "Large Glimmering Shard" } },
    [13607] = { { id = 11082, count = 1, name = "Greater Astral Essence" }, { id = 10998, count = 2, name = "Lesser Astral Essence" } },
    -- Phase 1 - Bracer
    [7418] = { { id = 10940, count = 1, name = "Strange Dust" } },
    [7428] = { { id = 10938, count = 1, name = "Lesser Magic Essence" }, { id = 10940, count = 1, name = "Strange Dust" } },
    [7457] = { { id = 10940, count = 3, name = "Strange Dust" } },
    [7766] = { { id = 10938, count = 2, name = "Lesser Magic Essence" } },
    [7779] = { { id = 10940, count = 2, name = "Strange Dust" }, { id = 10939, count = 1, name = "Greater Magic Essence" } },
    [7782] = { { id = 10940, count = 5, name = "Strange Dust" } },
    [7859] = { { id = 10998, count = 2, name = "Lesser Astral Essence" } },
    [13622] = { { id = 11082, count = 2, name = "Greater Astral Essence" } },
    -- Phase 1 - Boots
    [7863] = { { id = 10940, count = 8, name = "Strange Dust" } },
    [7867] = { { id = 10940, count = 6, name = "Strange Dust" }, { id = 10998, count = 2, name = "Lesser Astral Essence" } },
    -- Phase 1 - Shield
    [13378] = { { id = 10998, count = 1, name = "Lesser Astral Essence" }, { id = 10940, count = 2, name = "Strange Dust" } },
    [13464] = { { id = 10998, count = 1, name = "Lesser Astral Essence" }, { id = 10940, count = 1, name = "Strange Dust" }, { id = 10978, count = 1, name = "Small Glimmering Shard" } },
    [13485] = { { id = 10998, count = 2, name = "Lesser Astral Essence" }, { id = 10940, count = 4, name = "Strange Dust" } },
    -- Phase 1 - Weapon
    [7786] = { { id = 10940, count = 4, name = "Strange Dust" }, { id = 10939, count = 2, name = "Greater Magic Essence" } },
    [7788] = { { id = 10940, count = 2, name = "Strange Dust" }, { id = 10939, count = 1, name = "Greater Magic Essence" }, { id = 10978, count = 1, name = "Small Glimmering Shard" } },
    -- Phase 1 - 2H Weapon
    [7745] = { { id = 10940, count = 4, name = "Strange Dust" }, { id = 10978, count = 1, name = "Small Glimmering Shard" } },
    [7793] = { { id = 10939, count = 3, name = "Greater Magic Essence" } },
    [13380] = { { id = 10998, count = 1, name = "Lesser Astral Essence" }, { id = 10940, count = 6, name = "Strange Dust" } },
    -- Phase 2 - Cloak
    [13635] = { { id = 11138, count = 1, name = "Small Glowing Shard" }, { id = 11083, count = 3, name = "Soul Dust" } },
    [13657] = { { id = 11134, count = 1, name = "Lesser Mystic Essence" }, { count = 1, name = "Elemental Fire" } },
    [13746] = { { id = 11137, count = 3, name = "Vision Dust" } },
    [13794] = { { id = 11174, count = 1, name = "Lesser Nether Essence" } },
    [13882] = { { id = 11174, count = 2, name = "Lesser Nether Essence" } },
    -- Phase 2 - Chest
    [13626] = { { id = 11082, count = 1, name = "Greater Astral Essence" }, { id = 11083, count = 1, name = "Soul Dust" }, { id = 11084, count = 1, name = "Large Glimmering Shard" } },
    [13640] = { { id = 11083, count = 3, name = "Soul Dust" } },
    [13663] = { { id = 11135, count = 1, name = "Greater Mystic Essence" } },
    [13700] = { { id = 11135, count = 2, name = "Greater Mystic Essence" }, { id = 11137, count = 2, name = "Vision Dust" }, { id = 11139, count = 1, name = "Large Glowing Shard" } },
    [13858] = { { id = 11137, count = 6, name = "Vision Dust" } },
    -- Phase 2 - Bracer
    [13501] = { { id = 11083, count = 2, name = "Soul Dust" } },
    [13536] = { { id = 11083, count = 2, name = "Soul Dust" } },
    [13642] = { { id = 11134, count = 1, name = "Lesser Mystic Essence" } },
    [13646] = { { id = 11134, count = 1, name = "Lesser Mystic Essence" }, { id = 11083, count = 2, name = "Soul Dust" } },
    [13648] = { { id = 11083, count = 6, name = "Soul Dust" } },
    [13661] = { { id = 11137, count = 1, name = "Vision Dust" } },
    [13822] = { { id = 11174, count = 2, name = "Lesser Nether Essence" } },
    [13846] = { { id = 11174, count = 3, name = "Lesser Nether Essence" }, { id = 11137, count = 1, name = "Vision Dust" } },
    -- Phase 2 - Gloves
    [13612] = { { id = 11083, count = 1, name = "Soul Dust" }, { id = 2772, count = 3, name = "Iron Ore" } },
    [13617] = { { id = 11083, count = 1, name = "Soul Dust" }, { id = 3356, count = 3, name = "Kingsblood" } },
    [13620] = { { id = 11083, count = 1, name = "Soul Dust" }, { count = 3, name = "Blackmouth Oil" } },
    [13698] = { { id = 11137, count = 1, name = "Vision Dust" }, { count = 3, name = "Green Whelp Scale" } },
    [13815] = { { id = 11174, count = 1, name = "Lesser Nether Essence" }, { id = 11137, count = 1, name = "Vision Dust" } },
    [13841] = { { id = 11137, count = 3, name = "Vision Dust" }, { id = 6037, count = 3, name = "Truesilver Bar" } },
    [13868] = { { id = 11137, count = 3, name = "Vision Dust" }, { id = 8838, count = 3, name = "Sungrass" } },
    [13887] = { { id = 11174, count = 2, name = "Lesser Nether Essence" }, { id = 11137, count = 3, name = "Vision Dust" } },
    -- Phase 2 - Boots
    [13637] = { { id = 11083, count = 1, name = "Soul Dust" }, { id = 11134, count = 1, name = "Lesser Mystic Essence" } },
    [13644] = { { id = 11083, count = 4, name = "Soul Dust" } },
    [13687] = { { id = 11135, count = 1, name = "Greater Mystic Essence" }, { id = 11134, count = 2, name = "Lesser Mystic Essence" } },
    [13836] = { { id = 11137, count = 5, name = "Vision Dust" } },
    -- Phase 2 - Shield
    [13631] = { { id = 11134, count = 1, name = "Lesser Mystic Essence" }, { id = 11083, count = 1, name = "Soul Dust" } },
    [13659] = { { id = 11135, count = 1, name = "Greater Mystic Essence" }, { id = 11137, count = 1, name = "Vision Dust" } },
    [13689] = { { id = 11135, count = 2, name = "Greater Mystic Essence" }, { id = 11137, count = 2, name = "Vision Dust" }, { id = 11139, count = 1, name = "Large Glowing Shard" } },
    [13817] = { { id = 11137, count = 5, name = "Vision Dust" } },
    -- Phase 2 - Weapon
    [13503] = { { id = 11083, count = 2, name = "Soul Dust" }, { id = 11084, count = 1, name = "Large Glimmering Shard" } },
    [13653] = { { id = 11134, count = 1, name = "Lesser Mystic Essence" }, { count = 2, name = "Large Fang" }, { id = 11138, count = 1, name = "Small Glowing Shard" } },
    [13655] = { { id = 11134, count = 1, name = "Lesser Mystic Essence" }, { count = 1, name = "Elemental Earth" }, { id = 11138, count = 1, name = "Small Glowing Shard" } },
    [13693] = { { id = 11135, count = 2, name = "Greater Mystic Essence" }, { id = 11139, count = 1, name = "Large Glowing Shard" } },
    [21931] = { { id = 11135, count = 3, name = "Greater Mystic Essence" }, { id = 11137, count = 3, name = "Vision Dust" }, { id = 11139, count = 1, name = "Large Glowing Shard" }, { count = 2, name = "Wintersbite" } },
    -- Phase 2 - 2H Weapon
    [13529] = { { id = 11083, count = 3, name = "Soul Dust" }, { id = 11084, count = 1, name = "Large Glimmering Shard" } },
    [13695] = { { id = 11137, count = 4, name = "Vision Dust" }, { id = 11139, count = 1, name = "Large Glowing Shard" } },
    -- Phase 3 - Cloak
    [20014] = { { id = 16202, count = 2, name = "Lesser Eternal Essence" }, { id = 7077, count = 1, name = "Heart of Fire" }, { id = 7075, count = 1, name = "Core of Earth" }, { id = 7079, count = 1, name = "Globe of Water" }, { id = 7081, count = 1, name = "Breath of Wind" }, { count = 1, name = "Ichor of Undeath" } },
    [20015] = { { id = 16204, count = 8, name = "Illusion Dust" } },
    [25081] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 14344, count = 8, name = "Large Brilliant Shard" }, { id = 7078, count = 4, name = "Essence of Fire" } },
    [25082] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 14344, count = 8, name = "Large Brilliant Shard" }, { id = 12803, count = 4, name = "Living Essence" } },
    [25083] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 14344, count = 8, name = "Large Brilliant Shard" }, { id = 13468, count = 2, name = "Black Lotus" } },
    [25084] = { { id = 20725, count = 4, name = "Nexus Crystal" }, { id = 14344, count = 6, name = "Large Brilliant Shard" }, { id = 11754, count = 2, name = "Black Diamond" } },
    [25086] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 14344, count = 8, name = "Large Brilliant Shard" }, { count = 8, name = "Guardian Stone" } },
    -- Phase 3 - Chest
    [13917] = { { id = 11175, count = 1, name = "Greater Nether Essence" }, { id = 11174, count = 2, name = "Lesser Nether Essence" } },
    [13941] = { { id = 11178, count = 1, name = "Large Radiant Shard" }, { id = 11176, count = 3, name = "Dream Dust" }, { id = 11175, count = 2, name = "Greater Nether Essence" } },
    [20025] = { { id = 14344, count = 4, name = "Large Brilliant Shard" }, { id = 16204, count = 15, name = "Illusion Dust" }, { id = 16203, count = 10, name = "Greater Eternal Essence" } },
    [20026] = { { id = 16204, count = 6, name = "Illusion Dust" }, { id = 14343, count = 1, name = "Small Brilliant Shard" } },
    [20028] = { { id = 16203, count = 3, name = "Greater Eternal Essence" }, { id = 14343, count = 1, name = "Small Brilliant Shard" } },
    -- Phase 3 - Bracer
    [13931] = { { id = 11175, count = 1, name = "Greater Nether Essence" }, { id = 11176, count = 2, name = "Dream Dust" } },
    [13939] = { { id = 11176, count = 2, name = "Dream Dust" }, { id = 11175, count = 1, name = "Greater Nether Essence" } },
    [13945] = { { id = 11176, count = 5, name = "Dream Dust" } },
    [20008] = { { id = 16202, count = 3, name = "Lesser Eternal Essence" } },
    [20009] = { { id = 16202, count = 3, name = "Lesser Eternal Essence" }, { id = 11176, count = 10, name = "Dream Dust" } },
    [20010] = { { id = 16204, count = 6, name = "Illusion Dust" }, { id = 16203, count = 6, name = "Greater Eternal Essence" } },
    [20011] = { { id = 16204, count = 15, name = "Illusion Dust" } },
    [23801] = { { id = 16204, count = 16, name = "Illusion Dust" }, { id = 16203, count = 4, name = "Greater Eternal Essence" }, { id = 7080, count = 2, name = "Essence of Water" } },
    [23802] = { { id = 14344, count = 2, name = "Large Brilliant Shard" }, { id = 16204, count = 20, name = "Illusion Dust" }, { id = 16203, count = 4, name = "Greater Eternal Essence" }, { id = 12803, count = 6, name = "Living Essence" } },
    -- Phase 3 - Gloves
    [13947] = { { id = 11178, count = 2, name = "Large Radiant Shard" }, { id = 11176, count = 3, name = "Dream Dust" } },
    [13948] = { { id = 11178, count = 2, name = "Large Radiant Shard" }, { id = 8153, count = 2, name = "Wildvine" } },
    [20012] = { { id = 16202, count = 3, name = "Lesser Eternal Essence" }, { id = 16204, count = 3, name = "Illusion Dust" } },
    [20013] = { { id = 16203, count = 4, name = "Greater Eternal Essence" }, { id = 16204, count = 4, name = "Illusion Dust" } },
    [25072] = { { id = 20725, count = 4, name = "Nexus Crystal" }, { id = 14344, count = 6, name = "Large Brilliant Shard" }, { count = 8, name = "Larval Acid" } },
    [25073] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 14344, count = 10, name = "Large Brilliant Shard" }, { id = 12808, count = 6, name = "Essence of Undeath" } },
    [25074] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 14344, count = 10, name = "Large Brilliant Shard" }, { id = 7080, count = 4, name = "Essence of Water" } },
    [25078] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 14344, count = 10, name = "Large Brilliant Shard" }, { id = 7078, count = 4, name = "Essence of Fire" } },
    [25079] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 14344, count = 8, name = "Large Brilliant Shard" }, { id = 12811, count = 1, name = "Righteous Orb" } },
    [25080] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 14344, count = 8, name = "Large Brilliant Shard" }, { id = 7082, count = 4, name = "Essence of Air" } },
    -- Phase 3 - Boots
    [13890] = { { id = 11177, count = 1, name = "Small Radiant Shard" }, { id = 7909, count = 1, name = "Aquamarine" }, { id = 11174, count = 1, name = "Lesser Nether Essence" } },
    [13935] = { { id = 11175, count = 2, name = "Greater Nether Essence" } },
    [20020] = { { id = 11176, count = 10, name = "Dream Dust" } },
    [20023] = { { id = 16203, count = 8, name = "Greater Eternal Essence" } },
    [20024] = { { id = 16203, count = 2, name = "Greater Eternal Essence" }, { id = 16202, count = 1, name = "Lesser Eternal Essence" } },
    -- Phase 3 - Shield
    [13905] = { { id = 11175, count = 1, name = "Greater Nether Essence" }, { id = 11176, count = 2, name = "Dream Dust" } },
    [13933] = { { id = 11178, count = 1, name = "Large Radiant Shard" }, { id = 3829, count = 1, name = "Frost Oil" } },
    [20016] = { { id = 16203, count = 2, name = "Greater Eternal Essence" }, { id = 16204, count = 4, name = "Illusion Dust" } },
    [20017] = { { id = 11176, count = 10, name = "Dream Dust" } },
    -- Phase 3 - Weapon
    [13898] = { { id = 11177, count = 4, name = "Small Radiant Shard" }, { id = 7078, count = 1, name = "Essence of Fire" } },
    [13915] = { { id = 11177, count = 1, name = "Small Radiant Shard" }, { id = 11176, count = 2, name = "Dream Dust" }, { id = 9224, count = 1, name = "Elixir of Demonslaying" } },
    [13943] = { { id = 11178, count = 2, name = "Large Radiant Shard" }, { id = 11175, count = 2, name = "Greater Nether Essence" } },
    [20029] = { { id = 14343, count = 4, name = "Small Brilliant Shard" }, { id = 7080, count = 1, name = "Essence of Water" }, { id = 7082, count = 1, name = "Essence of Air" }, { count = 1, name = "Icecap" } },
    [20031] = { { id = 14344, count = 2, name = "Large Brilliant Shard" }, { id = 16203, count = 10, name = "Greater Eternal Essence" } },
    [20032] = { { id = 14344, count = 6, name = "Large Brilliant Shard" }, { id = 12808, count = 6, name = "Essence of Undeath" }, { id = 12803, count = 6, name = "Living Essence" } },
    [20033] = { { id = 14344, count = 4, name = "Large Brilliant Shard" }, { id = 12808, count = 4, name = "Essence of Undeath" } },
    [20034] = { { id = 14344, count = 4, name = "Large Brilliant Shard" }, { id = 12811, count = 2, name = "Righteous Orb" } },
    [22749] = { { id = 14344, count = 4, name = "Large Brilliant Shard" }, { id = 16203, count = 12, name = "Greater Eternal Essence" }, { id = 7078, count = 4, name = "Essence of Fire" }, { id = 7080, count = 4, name = "Essence of Water" }, { id = 7082, count = 4, name = "Essence of Air" }, { id = 13926, count = 2, name = "Golden Pearl" } },
    [22750] = { { id = 14344, count = 4, name = "Large Brilliant Shard" }, { id = 16203, count = 8, name = "Greater Eternal Essence" }, { id = 12803, count = 6, name = "Living Essence" }, { id = 7080, count = 6, name = "Essence of Water" }, { id = 12811, count = 1, name = "Righteous Orb" } },
    [23799] = { { id = 14344, count = 6, name = "Large Brilliant Shard" }, { id = 16203, count = 6, name = "Greater Eternal Essence" }, { id = 16204, count = 4, name = "Illusion Dust" }, { id = 7076, count = 2, name = "Essence of Earth" } },
    [23800] = { { id = 14344, count = 6, name = "Large Brilliant Shard" }, { id = 16203, count = 6, name = "Greater Eternal Essence" }, { id = 16204, count = 4, name = "Illusion Dust" }, { id = 7082, count = 2, name = "Essence of Air" } },
    [23803] = { { id = 14344, count = 10, name = "Large Brilliant Shard" }, { id = 16203, count = 8, name = "Greater Eternal Essence" }, { id = 16204, count = 15, name = "Illusion Dust" } },
    [23804] = { { id = 14344, count = 15, name = "Large Brilliant Shard" }, { id = 16203, count = 12, name = "Greater Eternal Essence" }, { id = 16204, count = 20, name = "Illusion Dust" } },
    -- Phase 3 - 2H Weapon
    [13937] = { { id = 11178, count = 2, name = "Large Radiant Shard" }, { id = 11176, count = 2, name = "Dream Dust" } },
    [20030] = { { id = 14344, count = 4, name = "Large Brilliant Shard" }, { id = 16204, count = 10, name = "Illusion Dust" } },
    [20035] = { { id = 16203, count = 12, name = "Greater Eternal Essence" }, { id = 14344, count = 2, name = "Large Brilliant Shard" } },
    [20036] = { { id = 16203, count = 12, name = "Greater Eternal Essence" }, { id = 14344, count = 2, name = "Large Brilliant Shard" } },
    [27837] = { { id = 14344, count = 10, name = "Large Brilliant Shard" }, { id = 16203, count = 6, name = "Greater Eternal Essence" }, { id = 16204, count = 14, name = "Illusion Dust" }, { id = 7082, count = 4, name = "Essence of Air" } },
    -- Phase 4 - Cloak
    [1219587] = { { id = 16203, count = 3, name = "Greater Eternal Essence" }, { id = 16204, count = 9, name = "Illusion Dust" }, { id = 7078, count = 1, name = "Essence of Fire" } },
    -- Phase 4 - Chest
    [435903] = { { id = 11177, count = 1, name = "Small Radiant Shard" }, { id = 11176, count = 2, name = "Dream Dust" } },
    [1213616] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 16204, count = 8, name = "Illusion Dust" }, { id = 16203, count = 5, name = "Greater Eternal Essence" }, { id = 13458, count = 10, name = "Greater Nature Protection Potion" }, { count = 2, name = "Qiraji Stalker Venom" }, { count = 2, name = "Ancient Sandworm Bile" } },
    -- Phase 4 - Bracer
    [1217189] = { { id = 14344, count = 2, name = "Large Brilliant Shard" }, { id = 16204, count = 20, name = "Illusion Dust" }, { id = 16203, count = 4, name = "Greater Eternal Essence" }, { id = 7080, count = 2, name = "Essence of Water" }, { id = 7078, count = 2, name = "Essence of Fire" }, { id = 7082, count = 2, name = "Essence of Air" } },
    [1217203] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 16204, count = 10, name = "Illusion Dust" }, { id = 16203, count = 2, name = "Greater Eternal Essence" }, { id = 7082, count = 2, name = "Essence of Air" } },
    [1220624] = { { id = 16203, count = 3, name = "Greater Eternal Essence" }, { id = 16204, count = 9, name = "Illusion Dust" }, { id = 12808, count = 12, name = "Essence of Undeath" }, { id = 8831, count = 2, name = "Purple Lotus" } },
    -- Phase 4 - Gloves
    [1213622] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 14344, count = 5, name = "Large Brilliant Shard" }, { count = 5, name = "Stratholme Holy Water" }, { count = 2, name = "Frayed Abomination Stitching" } },
    [1213626] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 14344, count = 5, name = "Large Brilliant Shard" }, { count = 2, name = "Skin of Shadow" } },
    [1219586] = { { id = 16203, count = 7, name = "Greater Eternal Essence" }, { id = 16204, count = 21, name = "Illusion Dust" }, { id = 7078, count = 2, name = "Essence of Fire" } },
    -- Phase 4 - Shield
    [463871] = { { id = 14344, count = 4, name = "Large Brilliant Shard" }, { id = 16203, count = 12, name = "Greater Eternal Essence" }, { id = 7078, count = 4, name = "Essence of Fire" }, { id = 7080, count = 4, name = "Essence of Water" }, { id = 7076, count = 1, name = "Essence of Earth" }, { id = 12811, count = 1, name = "Righteous Orb" } },
    [1219581] = { { id = 14344, count = 6, name = "Large Brilliant Shard" }, { id = 16204, count = 18, name = "Illusion Dust" }, { id = 7076, count = 2, name = "Essence of Earth" } },
    [1220623] = { { id = 14344, count = 5, name = "Large Brilliant Shard" }, { id = 16204, count = 15, name = "Illusion Dust" }, { count = 1, name = "Blood of Heroes" } },
    -- Phase 4 - Off-Hand
    [1219577] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 16204, count = 18, name = "Illusion Dust" }, { id = 7082, count = 2, name = "Essence of Air" } },
    [1219578] = { { id = 20725, count = 2, name = "Nexus Crystal" }, { id = 16204, count = 18, name = "Illusion Dust" }, { id = 7080, count = 2, name = "Essence of Water" } },
    [1219579] = { { id = 14344, count = 6, name = "Large Brilliant Shard" }, { id = 16204, count = 18, name = "Illusion Dust" }, { id = 7082, count = 1, name = "Essence of Air" }, { id = 7080, count = 1, name = "Essence of Water" } },
    -- Phase 4 - Weapon
    [435481] = { { id = 11174, count = 4, name = "Lesser Nether Essence" }, { count = 2, name = "Large Fang" }, { id = 11177, count = 2, name = "Small Radiant Shard" } },
    [1231128] = { { id = 14344, count = 5, name = "Large Brilliant Shard" }, { id = 12811, count = 2, name = "Righteous Orb" }, { id = 20725, count = 2, name = "Nexus Crystal" }, { count = 1, name = "Blood of Heroes" } },
    [1231164] = { { id = 14344, count = 6, name = "Large Brilliant Shard" }, { id = 12811, count = 3, name = "Righteous Orb" }, { id = 20725, count = 2, name = "Nexus Crystal" }, { count = 1, name = "Blood of Heroes" } },
    -- Phase 4 - 2H Weapon
    [1219580] = { { id = 20725, count = 3, name = "Nexus Crystal" }, { id = 16204, count = 24, name = "Illusion Dust" }, { count = 1, name = "Blood of Heroes" }, { id = 8831, count = 6, name = "Purple Lotus" } },
    [1231139] = { { id = 14344, count = 10, name = "Large Brilliant Shard" }, { id = 12811, count = 4, name = "Righteous Orb" }, { id = 20725, count = 4, name = "Nexus Crystal" }, { count = 1, name = "Blood of Heroes" } },
    [1232172] = { { id = 14344, count = 10, name = "Large Brilliant Shard" }, { id = 12811, count = 6, name = "Righteous Orb" }, { id = 20725, count = 4, name = "Nexus Crystal" }, { count = 1, name = "Blood of Heroes" } },
}
