local ADDON, ns = ...
local Addon = ns.Addon

local AceConfig       = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigReg    = LibStub("AceConfigRegistry-3.0")
local LDB             = LibStub("LibDataBroker-1.1", true)
local LibDBIcon       = LibStub("LibDBIcon-1.0", true)

local APP = "SoDPhaseLock"

local phaseValues = {}
for i = ns.MIN_PHASE, ns.MAX_PHASE do phaseValues[i] = ns.Phases[i].name end

local function notOfficer()      return not Addon:IsOfficer() end
local function notGuildLeader()  return not Addon:IsGuildLeader() end

-- Commit a guild-config edit (caller already mutated db.global.ruleset).
-- Pass msg to print a targeted confirmation instead of the generic ruleset line.
local function commitGuild(msg)
    if msg then Addon:Print(msg) end
    Addon:CommitGuildSettings(msg ~= nil)
end

local options = {
    type = "group",
    name = "SoD Phase Lock",
    childGroups = "tab",
    args = {
        general = {
            type = "group", order = 10, name = "General",
            args = {
                status = {
                    type = "description", order = 1, fontSize = "medium",
                    name = function()
                        local r = Addon:GetRuleset()
                        local d = Addon:GetPhaseData()
                        return string.format("|cffffd100Active:|r %s  |  mode |cff00ff00%s|r  |  level cap %d\n|cffffd100Set by:|r %s    |cffffd100You are:|r %s",
                            d and d.name or "?", r.mode, d and d.levelCap or 0,
                            r.setBy ~= "" and r.setBy or "—",
                            Addon:IsGuildLeader() and "the guild leader"
                                or (Addon:IsOfficer() and "an officer" or "a member (follows guild config)"))
                    end,
                },
                nextPhaseDate = {
                    type = "description", order = 2, fontSize = "medium",
                    name = function()
                        local d = Addon:GetNextPhaseDate()
                        if d ~= "" then
                            return "|cffffd100Next Phase Unlocks On:|r " .. d
                        end
                        return ""
                    end,
                },
                personal = {
                    type = "group", inline = true, order = 10, name = "Personal preferences",
                    args = {
                        sound = {
                            type = "toggle", order = 2, name = "Play warning sound",
                            get = function() return Addon.db.profile.sound end,
                            set = function(_, v) Addon.db.profile.sound = v end,
                        },
                        minimap = {
                            type = "toggle", order = 3, name = "Show minimap button",
                            get = function() return not Addon.db.profile.minimap.hide end,
                            set = function(_, v)
                                Addon.db.profile.minimap.hide = not v
                                if LibDBIcon then
                                    if v then LibDBIcon:Show(APP) else LibDBIcon:Hide(APP) end
                                end
                            end,
                        },
                    },
                },
                rosterBtn = {
                    type = "execute", order = 20, name = "Open compliance roster",
                    func = function() if ns.ToggleRoster then ns.ToggleRoster() end end,
                },
                personalChallenges = {
                    type = "group", inline = true, order = 30,
                    name = "Personal Challenges",
                    args = {
                        intro = {
                            type = "description", order = 0, fontSize = "medium",
                            name = "Stack extra restrictions on top of the guild ruleset. Guild-enforced rules are shown checked and cannot be turned off — you can only add to them.",
                        },
                    },
                },
            },
        },
        guild = {
            type = "group", order = 20, name = "Guild Settings",
            args = {
                intro = {
                    type = "description", order = 0, fontSize = "medium",
                    name = function()
                        if Addon:IsGuildLeader() then
                            return "|cff00ff00You are the guild leader.|r Settings here are pushed to every guild member, who follow them automatically."
                        elseif Addon:IsOfficer() then
                            return "|cffffd100You are an officer.|r You can set the active phase. The enforcement config is set by the guild leader (read-only below)."
                        end
                        return "|cffff8080These settings are controlled by your guild leader|r and shown read-only. Your client follows them automatically."
                    end,
                },
                ruleset = {
                    type = "group", inline = true, order = 10, name = "Ruleset (officers)",
                    args = {
                        phase = {
                            type = "select", order = 1, name = "Active phase", values = phaseValues,
                            width = "full",
                            disabled = notOfficer,
                            get = function() return Addon:GetActivePhase() end,
                            set = function(_, v) Addon:SetRulesetAsOfficer(v, Addon:GetMode()) end,
                        },
                        sp1 = { type = "description", order = 2, name = " ", width = "full" },
                        nextPhaseDate = {
                            type = "input", order = 3, name = "Next Phase Unlock Date",
                            desc = "Announce when the next phase unlocks — any format, e.g. \"June 30, 2026\". Broadcast to all guild members.",
                            width = "full",
                            disabled = notOfficer,
                            get = function() return Addon:GetNextPhaseDate() end,
                            set = function(_, v)
                                Addon.db.global.ruleset.nextPhaseDate = v or ""
                                commitGuild((v and v ~= "") and ("Next phase date: " .. v) or "Next phase date: cleared")
                            end,
                        },
                        sp2 = { type = "description", order = 4, name = " ", width = "full" },
                        officerRank = {
                            type = "range", order = 5, name = "Officer rank threshold",
                            desc = "Guild rank index (0 = Guild Master) at or below which a member may set the phase/mode.",
                            width = "full",
                            min = 0, max = 9, step = 1, disabled = notOfficer,
                            get = function() return Addon.db.global.officerRankIndex end,
                            set = function(_, v) Addon.db.global.officerRankIndex = v end,
                        },
                    },
                },
                rules = {
                    type = "group", inline = true, order = 20,
                    name = "Enforcement config (guild leader)",
                    args = {},   -- per-rule toggles built below
                },
                behavior = {
                    type = "group", inline = true, order = 30,
                    name = "Enforcement behavior (guild leader)",
                    args = {
                        autoUnequip = {
                            type = "toggle", order = 1, name = "Block over-phase gear",
                            desc = "Authentic mode: prevent equipping items from later phases — declines bind-on-equip prompts and unequips them out of combat. When off, over-phase gear is only flagged (warning + compliance log).",
                            disabled = notGuildLeader,
                            get = function() return Addon:AutoUnequip() end,
                            set = function(_, v)
                                Addon.db.global.ruleset.autoUnequip = v
                                commitGuild("Block over-phase gear: " .. (v and "|cff00ff00enabled|r" or "|cffff8080disabled|r"))
                            end,
                        },
                        instanceGrace = {
                            type = "range", order = 2, name = "Instance grace period (seconds)",
                            desc = "How long a member may stay in a not-yet-unlocked instance before being reported to the compliance log.",
                            min = 0, max = 600, step = 5, disabled = notGuildLeader,
                            get = function() return Addon:InstanceGrace() end,
                            set = function(_, v)
                                Addon.db.global.ruleset.instanceGrace = v
                                commitGuild("Instance grace period: " .. v .. "s")
                            end,
                        },
                    },
                },
            },
        },
    },
}

-- Build the per-rule toggles (guild-leader controlled). Authentic-only rules are
-- shown but greyed out when the active mode is relaxed.
do
    local rules = {
        { key = "level",      name = "Level cap",            authentic = false, order = 1 },
        { key = "instance",   name = "Instance gating",      authentic = true,  order = 2 },
        { key = "gear",       name = "Gear / items",         authentic = true,  order = 3 },
        { key = "profession", name = "Profession skill cap", authentic = true,  order = 4 },
        { key = "quest",      name = "Quests",               authentic = true,  order = 5 },
        { key = "rune",       name = "Runes",                authentic = true,  order = 6 },
        { key = "runebroker", name = "Block Rune Broker",   authentic = true,  order = 7 },
    }
    for _, r in ipairs(rules) do
        options.args.guild.args.rules.args[r.key] = {
            type = "toggle", order = r.order,
            name = r.name .. (r.authentic and " |cff888888|r" or ""),
            disabled = function()
                if notGuildLeader() then return true end
                -- Non-leaders can't edit at all; guild leaders can toggle any rule
                -- regardless of the active mode so they can configure in advance.
                return false
            end,
            get = function() return Addon.db.global.ruleset.enforce[r.key] end,
            set = function(_, v)
                Addon.db.global.ruleset.enforce[r.key] = v
                commitGuild(r.name .. ": " .. (v and "|cff00ff00enabled|r" or "|cffff8080disabled|r"))
            end,
        }
    end
end

-- Personal challenge toggles: same rule list as guild settings, but stored in
-- db.profile. Disabled (locked ON) when the guild already enforces that rule.
do
    local rules = {
        { key = "level",      name = "Level cap",            authentic = false, order = 1 },
        { key = "instance",   name = "Instance gating",      authentic = true,  order = 2 },
        { key = "gear",       name = "Gear / items",         authentic = true,  order = 3 },
        { key = "profession", name = "Profession skill cap", authentic = true,  order = 4 },
        { key = "quest",      name = "Quests",               authentic = true,  order = 5 },
        { key = "rune",       name = "Runes",                authentic = true,  order = 6 },
        { key = "runebroker", name = "Block Rune Broker",    authentic = true,  order = 7 },
    }
    local pcArgs = options.args.general.args.personalChallenges.args
    for _, r in ipairs(rules) do
        local key = r.key
        pcArgs[key] = {
            type = "toggle", order = r.order,
            name = r.name .. (r.authentic and " |cff888888|r" or ""),
            desc = function()
                if Addon.db.global.ruleset.enforce[key] then
                    return "Already enforced by the guild — cannot be disabled."
                end
                return "Enable this restriction for yourself only, regardless of guild mode."
            end,
            -- Greyed out when the guild already has it on; player can't reduce it.
            disabled = function() return Addon.db.global.ruleset.enforce[key] end,
            -- Show effective state so guild-enforced rules appear checked.
            get = function()
                return Addon.db.global.ruleset.enforce[key]
                    or (Addon.db.profile.personalChallenges[key] == true)
            end,
            set = function(_, v)
                Addon.db.profile.personalChallenges[key] = v
                local e = Addon:GetModule("Enforcement", true)
                if e then e:FullScan() end
            end,
        }
    end
end

-- ---------------------------------------------------------------------------
function ns.SetupOptions()
    AceConfig:RegisterOptionsTable(APP, options)
    AceConfigDialog:AddToBlizOptions(APP, "SoD Phase Lock")

    -- Minimap launcher
    if LDB and LibDBIcon then
        local dataobj = LDB:NewDataObject(APP, {
            type = "launcher",
            text = "SoD Phase Lock",
            icon = "Interface\\Icons\\inv_misc_pocketwatch_01",
            OnClick = function(_, button)
                if button == "RightButton" then
                    ns.OpenOptions()
                else
                    if ns.ToggleRoster then ns.ToggleRoster() end
                end
            end,
            OnTooltipShow = function(tt)
                local d = Addon:GetPhaseData()
                tt:AddLine("SoD Phase Lock")
                tt:AddLine(string.format("%s — %s mode", d and d.name or "?", Addon:GetMode()), 1, 1, 1)
                tt:AddLine("Left-click: roster   Right-click: options", 0.7, 0.7, 0.7)
            end,
        })
        LibDBIcon:Register(APP, dataobj, Addon.db.profile.minimap)
    end
end

function ns.OpenOptions()
    AceConfigDialog:Open(APP)
    local f = AceConfigDialog.OpenFrames[APP]
    if f and f.SetStatusText then
        f:SetStatusText("Made by Joros - Wild Growth")
    end
end

function ns.RefreshOptions()
    AceConfigReg:NotifyChange(APP)
end
