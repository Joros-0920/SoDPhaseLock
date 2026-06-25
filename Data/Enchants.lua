local ADDON, ns = ...

-- =========================================================================
-- Each entry is { <spellID>, "<display name>" }
-- =========================================================================

-- Canonical render order for enchantable slots (groups render in this order).
ns.EnchantSlotOrder = {
    "Cloak", "Chest", "Bracer", "Gloves", "Boots", "Shield", "Weapon", "2H Weapon",
}

-- Inventory slot id per enchant slot, used by the tab's "Current" line (what the
-- player has equipped + enchanted right now). Weapon/2H both map to main hand;
-- Shield maps to the off-hand slot. Values are WoW INVSLOT_* ids.
ns.EnchantSlotInv = {
    Cloak = 15, Chest = 5, Bracer = 9, Gloves = 10,
    Boots = 8, Shield = 17, Weapon = 16, ["2H Weapon"] = 16,
}

-- Enchants NEWLY available, keyed by phase. Each entry: { label = <slot>, items = { {id, name}, ... } }.
ns.PhaseEnchants = {
    -- Phase 1 — skill <= 150.
    [1] = {
        { label = "Cloak", items = {
            { 7454,  "Enchant Cloak - Minor Resistance" },
            { 7861,  "Enchant Cloak - Lesser Fire Resistance" },
            { 13419, "Enchant Cloak - Minor Agility" },
            { 13635, "Enchant Cloak - Defense" },
            { 13657, "Enchant Cloak - Fire Resistance" },
            { 13882, "Enchant Cloak - Lesser Agility" },
            { 13746, "Enchant Cloak - Greater Defense" },
        } },
        { label = "Chest", items = {
            { 7420,  "Enchant Chest - Minor Health" },
            { 7443,  "Enchant Chest - Minor Mana" },
            { 7426,  "Enchant Chest - Minor Absorption" },
            { 7748,  "Enchant Chest - Lesser Health" },
            { 7776,  "Enchant Chest - Lesser Mana" },
            { 13626, "Enchant Chest - Minor Stats" },
            { 7857,  "Enchant Chest - Health" },
            { 13607, "Enchant Chest - Mana" },
            { 13700, "Enchant Chest - Lesser Stats" },
        } },
        { label = "Bracer", items = {
            { 7418,  "Enchant Bracer - Minor Health" },
            { 7457,  "Enchant Bracer - Minor Stamina" },
            { 7782,  "Enchant Bracer - Minor Strength" },
            { 7766,  "Enchant Bracer - Minor Spirit" },
            { 7429,  "Enchant Bracer - Minor Deflection" },
            { 7859,  "Enchant Bracer - Lesser Spirit" },
            { 13536, "Enchant Bracer - Lesser Strength" },
            { 13501, "Enchant Bracer - Lesser Stamina" },
            { 13646, "Enchant Bracer - Lesser Deflection" },
            { 13648, "Enchant Bracer - Stamina" },
        } },
        { label = "Gloves", items = {
            { 13612, "Enchant Gloves - Mining" },
            { 13617, "Enchant Gloves - Herbalism" },
            { 13698, "Enchant Gloves - Skinning" },
            { 13841, "Enchant Gloves - Advanced Mining" },
            { 13868, "Enchant Gloves - Advanced Herbalism" },
            { 13947, "Enchant Gloves - Riding Skill" },
        } },
        { label = "Boots", items = {
            { 7863,  "Enchant Boots - Minor Stamina" },
            { 13644, "Enchant Boots - Lesser Stamina" },
            { 13890, "Enchant Boots - Minor Speed" },
            { 13637, "Enchant Boots - Lesser Agility" },
            { 13836, "Enchant Boots - Stamina" },
        } },
        { label = "Shield", items = {
            { 13378, "Enchant Shield - Minor Stamina" },
            { 13631, "Enchant Shield - Lesser Stamina" },
            { 13485, "Enchant Shield - Lesser Spirit" },
            { 13464, "Enchant Shield - Lesser Protection" },
            { 13689, "Enchant Shield - Lesser Block" },
            { 13817, "Enchant Shield - Stamina" },
            { 13659, "Enchant Shield - Spirit" },
        } },
        { label = "Weapon", items = {
            { 7788,  "Enchant Weapon - Minor Striking" },
            { 7786,  "Enchant Weapon - Minor Beastslayer" },
            { 13503, "Enchant Weapon - Lesser Striking" },
            { 13653, "Enchant Weapon - Lesser Beastslayer" },
            { 13655, "Enchant Weapon - Lesser Elemental Slayer" },
            { 13693, "Enchant Weapon - Striking" },
        } },
        { label = "2H Weapon", items = {
            { 7746,  "Enchant 2H Weapon - Minor Impact" },
            { 13380, "Enchant 2H Weapon - Lesser Spirit" },
            { 7793,  "Enchant 2H Weapon - Lesser Intellect" },
            { 13531, "Enchant 2H Weapon - Lesser Impact" },
            { 13695, "Enchant 2H Weapon - Impact" },
        } },
    },

    -- Phase 2 — skill 151-225.
    [2] = {
        { label = "Cloak", items = {
            { 13794, "Enchant Cloak - Resistance" },
        } },
        { label = "Chest", items = {
            { 13538, "Enchant Chest - Lesser Absorption" },
            { 13640, "Enchant Chest - Greater Health" },
            { 13663, "Enchant Chest - Greater Mana" },
            { 13941, "Enchant Chest - Stats" },
            { 13858, "Enchant Chest - Superior Health" },
            { 13917, "Enchant Chest - Superior Mana" },
        } },
        { label = "Bracer", items = {
            { 13661, "Enchant Bracer - Strength" },
            { 13642, "Enchant Bracer - Spirit" },
            { 13822, "Enchant Bracer - Intellect" },
            { 13931, "Enchant Bracer - Deflection" },
            { 13945, "Enchant Bracer - Greater Stamina" },
            { 13846, "Enchant Bracer - Greater Spirit" },
        } },
        { label = "Gloves", items = {
            { 13948, "Enchant Gloves - Minor Haste" },
        } },
        { label = "Boots", items = {
            { 13935, "Enchant Boots - Agility" },
        } },
        { label = "Shield", items = {
            { 13933, "Enchant Shield - Frost Resistance" },
            { 13905, "Enchant Shield - Greater Spirit" },
        } },
        { label = "Weapon", items = {
            { 13943, "Enchant Weapon - Greater Striking" },
            { 13915, "Enchant Weapon - Demonslaying" },
        } },
        { label = "2H Weapon", items = {
            { 13937, "Enchant 2H Weapon - Greater Impact" },
        } },
    },

    -- Phase 3 — skill 226-300.
    [3] = {
        { label = "Cloak", items = {
            { 20014, "Enchant Cloak - Greater Resistance" },
            { 25081, "Enchant Cloak - Greater Fire Resistance" },
            { 25082, "Enchant Cloak - Greater Nature Resistance" },
            { 20015, "Enchant Cloak - Superior Defense" },
            { 25083, "Enchant Cloak - Stealth" },
            { 25084, "Enchant Cloak - Subtlety" },
        } },
        { label = "Chest", items = {
            { 20026, "Enchant Chest - Major Health" },
            { 20028, "Enchant Chest - Major Mana" },
            { 20025, "Enchant Chest - Greater Stats" },
        } },
        { label = "Bracer", items = {
            { 13939, "Enchant Bracer - Greater Strength" },
            { 20010, "Enchant Bracer - Superior Strength" },
            { 20009, "Enchant Bracer - Superior Spirit" },
            { 20011, "Enchant Bracer - Superior Stamina" },
            { 20008, "Enchant Bracer - Greater Intellect" },
            { 23801, "Enchant Bracer - Mana Regeneration" },
            { 23802, "Enchant Bracer - Healing Power" },
        } },
        { label = "Gloves", items = {
            { 13815, "Enchant Gloves - Agility" },
            { 20012, "Enchant Gloves - Greater Agility" },
            { 25080, "Enchant Gloves - Superior Agility" },
            { 20013, "Enchant Gloves - Greater Strength" },
            { 25079, "Enchant Gloves - Healing Power" },
            { 25072, "Enchant Gloves - Threat" },
        } },
        { label = "Boots", items = {
            { 20020, "Enchant Boots - Greater Stamina" },
            { 20023, "Enchant Boots - Greater Agility" },
        } },
        { label = "Shield", items = {
            { 20017, "Enchant Shield - Greater Stamina" },
            { 20016, "Enchant Shield - Superior Spirit" },
        } },
        { label = "Weapon", items = {
            { 20031, "Enchant Weapon - Superior Striking" },
            { 13898, "Enchant Weapon - Fiery Weapon" },
            { 21931, "Enchant Weapon - Winter's Might" },
            { 20034, "Enchant Weapon - Crusader" },
            { 20029, "Enchant Weapon - Icy Chill" },
            { 20033, "Enchant Weapon - Unholy Weapon" },
            { 20032, "Enchant Weapon - Lifestealing" },
            { 22750, "Enchant Weapon - Healing Power" },
            { 22749, "Enchant Weapon - Spell Power" },
            { 23800, "Enchant Weapon - Agility" },
            { 23804, "Enchant Weapon - Mighty Intellect" },
            { 23803, "Enchant Weapon - Mighty Spirit" },
        } },
        { label = "2H Weapon", items = {
            { 20030, "Enchant 2H Weapon - Superior Impact" },
            { 20036, "Enchant 2H Weapon - Major Intellect" },
            { 20035, "Enchant 2H Weapon - Major Spirit" },
            { 27837, "Enchant 2H Weapon - Agility" },
        } },
    },
}
