local ADDON, ns = ...

-- =========================================================================
-- Each entry is { <spellID>, "<display name>" }
-- Names + reagents sourced from Wowhead Classic (spell tooltip endpoint).
-- Phase buckets: vanilla enchants by reagent tier (skill band);
-- SoD-custom enchants (spell id >= 400000) bucketed per ENCHANTS_BY_PHASE.md
-- (P2 Dismantle/Retricutioner, P4 Law of Nature, P6 and P8 sets).
-- BEST-EFFORT phase assignment - verify/split phases 4+ in-client.
-- =========================================================================

-- Canonical render order for enchantable slots (groups render in this order).
ns.EnchantSlotOrder = {
    "Cloak", "Chest", "Bracer", "Gloves", "Boots", "Shield", "Off-Hand", "Weapon", "2H Weapon",
}

-- Enchants NEWLY available, keyed by phase. Each entry: { label = <slot>, items = { {id, name}, ... } }.
ns.PhaseEnchants = {
    -- Phase 1 -- skill <= 150.
    [1] = {
        { label = "Cloak", items = {
            { 7454, "Enchant Cloak - Minor Resistance" },
            { 7771, "Enchant Cloak - Minor Protection" },
            { 7861, "Enchant Cloak - Lesser Fire Resistance" },
            { 13419, "Enchant Cloak - Minor Agility" },
            { 13421, "Enchant Cloak - Lesser Protection" },
            { 13522, "Enchant Cloak - Lesser Shadow Resistance" },
        } },
        { label = "Chest", items = {
            { 7420, "Enchant Chest - Minor Health" },
            { 7426, "Enchant Chest - Minor Absorption" },
            { 7443, "Enchant Chest - Minor Mana" },
            { 7748, "Enchant Chest - Lesser Health" },
            { 7776, "Enchant Chest - Lesser Mana" },
            { 7857, "Enchant Chest - Health" },
            { 13538, "Enchant Chest - Lesser Absorption" },
            { 13607, "Enchant Chest - Mana" },
        } },
        { label = "Bracer", items = {
            { 7418, "Enchant Bracer - Minor Health" },
            { 7428, "Enchant Bracer - Minor Deflect" },
            { 7457, "Enchant Bracer - Minor Stamina" },
            { 7766, "Enchant Bracer - Minor Spirit" },
            { 7779, "Enchant Bracer - Minor Agility" },
            { 7782, "Enchant Bracer - Minor Strength" },
            { 7859, "Enchant Bracer - Lesser Spirit" },
            { 13622, "Enchant Bracer - Lesser Intellect" },
        } },
        { label = "Boots", items = {
            { 7863, "Enchant Boots - Minor Stamina" },
            { 7867, "Enchant Boots - Minor Agility" },
        } },
        { label = "Shield", items = {
            { 13378, "Enchant Shield - Minor Stamina" },
            { 13464, "Enchant Shield - Lesser Protection" },
            { 13485, "Enchant Shield - Lesser Spirit" },
        } },
        { label = "Weapon", items = {
            { 7786, "Enchant Weapon - Minor Beastslayer" },
            { 7788, "Enchant Weapon - Minor Striking" },
        } },
        { label = "2H Weapon", items = {
            { 7745, "Enchant 2H Weapon - Minor Impact" },
            { 7793, "Enchant 2H Weapon - Lesser Intellect" },
            { 13380, "Enchant 2H Weapon - Lesser Spirit" },
        } },
    },

    -- Phase 2 -- skill 151-225.
    [2] = {
        { label = "Cloak", items = {
            { 13635, "Enchant Cloak - Defense" },
            { 13657, "Enchant Cloak - Fire Resistance" },
            { 13746, "Enchant Cloak - Greater Defense" },
            { 13794, "Enchant Cloak - Resistance" },
            { 13882, "Enchant Cloak - Lesser Agility" },
        } },
        { label = "Chest", items = {
            { 13626, "Enchant Chest - Minor Stats" },
            { 13640, "Enchant Chest - Greater Health" },
            { 13663, "Enchant Chest - Greater Mana" },
            { 13700, "Enchant Chest - Lesser Stats" },
            { 13858, "Enchant Chest - Superior Health" },
            { 435903, "Enchant Chest - Retricutioner" },  -- SoD (Formula spell 435902)
        } },
        { label = "Bracer", items = {
            { 13501, "Enchant Bracer - Lesser Stamina" },
            { 13536, "Enchant Bracer - Lesser Strength" },
            { 13642, "Enchant Bracer - Spirit" },
            { 13646, "Enchant Bracer - Lesser Deflection" },
            { 13648, "Enchant Bracer - Stamina" },
            { 13661, "Enchant Bracer - Strength" },
            { 13822, "Enchant Bracer - Intellect" },
            { 13846, "Enchant Bracer - Greater Spirit" },
        } },
        { label = "Gloves", items = {
            { 13612, "Enchant Gloves - Mining" },
            { 13617, "Enchant Gloves - Herbalism" },
            { 13620, "Enchant Gloves - Fishing" },
            { 13698, "Enchant Gloves - Skinning" },
            { 13815, "Enchant Gloves - Agility" },
            { 13841, "Enchant Gloves - Advanced Mining" },
            { 13868, "Enchant Gloves - Advanced Herbalism" },
            { 13887, "Enchant Gloves - Strength" },
        } },
        { label = "Boots", items = {
            { 13637, "Enchant Boots - Lesser Agility" },
            { 13644, "Enchant Boots - Lesser Stamina" },
            { 13687, "Enchant Boots - Lesser Spirit" },
            { 13836, "Enchant Boots - Stamina" },
        } },
        { label = "Shield", items = {
            { 13631, "Enchant Shield - Lesser Stamina" },
            { 13659, "Enchant Shield - Spirit" },
            { 13689, "Enchant Shield - Lesser Block" },
            { 13817, "Enchant Shield - Stamina" },
        } },
        { label = "Weapon", items = {
            { 13503, "Enchant Weapon - Lesser Striking" },
            { 13653, "Enchant Weapon - Lesser Beastslayer" },
            { 13655, "Enchant Weapon - Lesser Elemental Slayer" },
            { 13693, "Enchant Weapon - Striking" },
            { 21931, "Enchant Weapon - Winter's Might" },
            { 435481, "Enchant Weapon - Dismantle" },  -- SoD (Formula spell 435484)
        } },
        { label = "2H Weapon", items = {
            { 13529, "Enchant 2H Weapon - Lesser Impact" },
            { 13695, "Enchant 2H Weapon - Impact" },
        } },
    },

    -- Phase 3 -- skill 226-300.
    [3] = {
        { label = "Cloak", items = {
            { 20014, "Enchant Cloak - Greater Resistance" },
            { 20015, "Enchant Cloak - Superior Defense" },
            { 25081, "Enchant Cloak - Greater Fire Resistance" },
            { 25082, "Enchant Cloak - Greater Nature Resistance" },
            { 25083, "Enchant Cloak - Stealth" },
            { 25084, "Enchant Cloak - Subtlety" },
            { 25086, "Enchant Cloak - Dodge" },
        } },
        { label = "Chest", items = {
            { 13917, "Enchant Chest - Superior Mana" },
            { 13941, "Enchant Chest - Stats" },
            { 20025, "Enchant Chest - Greater Stats" },
            { 20026, "Enchant Chest - Major Health" },
            { 20028, "Enchant Chest - Major Mana" },
        } },
        { label = "Bracer", items = {
            { 13931, "Enchant Bracer - Deflection" },
            { 13939, "Enchant Bracer - Greater Strength" },
            { 13945, "Enchant Bracer - Greater Stamina" },
            { 20008, "Enchant Bracer - Greater Intellect" },
            { 20009, "Enchant Bracer - Superior Spirit" },
            { 20010, "Enchant Bracer - Superior Strength" },
            { 20011, "Enchant Bracer - Superior Stamina" },
            { 23801, "Enchant Bracer - Mana Regeneration" },
            { 23802, "Enchant Bracer - Healing Power" },
        } },
        { label = "Gloves", items = {
            { 13947, "Enchant Gloves - Riding Skill" },
            { 13948, "Enchant Gloves - Minor Haste" },
            { 20012, "Enchant Gloves - Greater Agility" },
            { 20013, "Enchant Gloves - Greater Strength" },
            { 25072, "Enchant Gloves - Threat" },
            { 25073, "Enchant Gloves - Shadow Power" },
            { 25074, "Enchant Gloves - Frost Power" },
            { 25078, "Enchant Gloves - Fire Power" },
            { 25079, "Enchant Gloves - Healing Power" },
            { 25080, "Enchant Gloves - Superior Agility" },
        } },
        { label = "Boots", items = {
            { 13890, "Enchant Boots - Minor Speed" },
            { 13935, "Enchant Boots - Agility" },
            { 20020, "Enchant Boots - Greater Stamina" },
            { 20023, "Enchant Boots - Greater Agility" },
            { 20024, "Enchant Boots - Spirit" },
        } },
        { label = "Shield", items = {
            { 13905, "Enchant Shield - Greater Spirit" },
            { 13933, "Enchant Shield - Frost Resistance" },
            { 20016, "Enchant Shield - Superior Spirit" },
            { 20017, "Enchant Shield - Greater Stamina" },
        } },
        { label = "Weapon", items = {
            { 13898, "Enchant Weapon - Fiery Weapon" },
            { 13915, "Enchant Weapon - Demonslaying" },
            { 13943, "Enchant Weapon - Greater Striking" },
            { 20029, "Enchant Weapon - Icy Chill" },
            { 20031, "Enchant Weapon - Superior Striking" },
            { 20032, "Enchant Weapon - Lifestealing" },
            { 20033, "Enchant Weapon - Unholy Weapon" },
            { 20034, "Enchant Weapon - Crusader" },
            { 22749, "Enchant Weapon - Spell Power" },
            { 22750, "Enchant Weapon - Healing Power" },
            { 23799, "Enchant Weapon - Strength" },
            { 23800, "Enchant Weapon - Agility" },
            { 23803, "Enchant Weapon - Mighty Spirit" },
            { 23804, "Enchant Weapon - Mighty Intellect" },
        } },
        { label = "2H Weapon", items = {
            { 13937, "Enchant 2H Weapon - Greater Impact" },
            { 20030, "Enchant 2H Weapon - Superior Impact" },
            { 20035, "Enchant 2H Weapon - Major Spirit" },
            { 20036, "Enchant 2H Weapon - Major Intellect" },
            { 27837, "Enchant 2H Weapon - Agility" },
        } },
    },

    -- Phase 4 -- SoD level-60 / custom enchants (best-effort).
    [4] = {
        { label = "Shield", items = {
            { 463871, "Enchant Shield - Law of Nature" },
        } },
    },

    -- Phase 6 -- SoD custom enchants (per ENCHANTS_BY_PHASE.md).
    [6] = {
        { label = "Chest", items = {
            { 1213616, "Enchant Chest - Living Stats" },
        } },
        { label = "Bracer", items = {
            { 1217189, "Enchant Bracer - Spell Power" },
            { 1217203, "Enchant Bracer - Agility" },
        } },
        { label = "Gloves", items = {
            { 1213622, "Enchant Gloves - Holy Power" },
            { 1213626, "Enchant Gloves - Arcane Power" },
        } },
    },

    -- Phase 8 -- SoD custom enchants (per ENCHANTS_BY_PHASE.md).
    [8] = {
        { label = "Cloak", items = {
            { 1219587, "Enchant Cloak - Agility" },
        } },
        { label = "Bracer", items = {
            { 1220624, "Enchant Bracer - Greater Spellpower" },
        } },
        { label = "Gloves", items = {
            { 1219586, "Enchant Gloves - Superior Strength" },
        } },
        { label = "Shield", items = {
            { 1219581, "Enchant Shield - Excellent Stamina" },
            { 1220623, "Enchant Shield - Critical Strike" },
        } },
        { label = "Off-Hand", items = {
            { 1219577, "Enchant Off-Hand - Superior Intellect" },
            { 1219578, "Enchant Off-Hand - Excellent Spirit" },
            { 1219579, "Enchant Off-Hand - Wisdom" },
        } },
        { label = "Weapon", items = {
            { 1231128, "Enchant Weapon - Grand Crusader" },
            { 1231164, "Enchant Weapon - Grand Sorceror" },
        } },
        { label = "2H Weapon", items = {
            { 1219580, "Enchant 2H Weapon - Spellblasting" },
            { 1231139, "Enchant 2H Weapon - Grand Arcanist" },
            { 1232172, "Enchant 2H Weapon - Grand Inquisitor" },
        } },
    },

}
