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

-- ---- Overview helpers -----------------------------------------------------
-- Number of quests that first unlock at the given phase index.
local function newQuestCount(phaseIndex)
    local n = 0
    if ns.QuestPhases then
        for _, p in pairs(ns.QuestPhases) do
            if p == phaseIndex then n = n + 1 end
        end
    end
    return n
end

-- Ordered, de-duplicated list of every instance enterable up to `phaseIndex`
-- (original casing preserved; ns.Phases[*].allowedInstances is lowercased).
local function cumulativeInstances(phaseIndex)
    local list, seen = {}, {}
    for i = ns.MIN_PHASE, phaseIndex do
        local phase = ns.Phases[i]
        if phase then
            for _, name in ipairs(phase.instanceUnlocks) do
                local key = name:lower()
                if not seen[key] then
                    seen[key] = true
                    list[#list + 1] = name
                end
            end
        end
    end
    return list
end

-- Render a list as colored bullet lines, or a grey "(none)" placeholder.
local function bulletList(items, color)
    if not items or #items == 0 then return "|cff888888(none)|r" end
    color = color or "ffffffff"
    local out = {}
    for _, v in ipairs(items) do
        out[#out + 1] = "|c" .. color .. "\226\128\162|r " .. v
    end
    return table.concat(out, "\n")
end

-- Left-column summary text for the active phase (headline raid, new instances,
-- quest count). Shared by the "This Phase" custom panel widget below.
local function phaseSummaryText()
    local idx = Addon:GetActivePhase()
    local d = ns.Phases[idx]
    if not d then return "" end
    local lines = {}
    lines[#lines + 1] = "|cffffd100Headline raid:|r " .. (d.raid or "\226\128\148")
    if d.event then lines[#lines + 1] = "|cffffd100Event:|r " .. d.event end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffffd100Newly unlocked this phase:|r"
    lines[#lines + 1] = bulletList(d.instanceUnlocks, "ff40ff40")
    lines[#lines + 1] = ""
    local nq = newQuestCount(idx)
    if nq > 0 then
        lines[#lines + 1] = string.format("|cffffd100Quests unlocking this phase:|r |cff40ff40%d|r", nq)
    elseif idx == ns.MIN_PHASE then
        lines[#lines + 1] = "|cff888888All starting-zone quests are available.|r"
    else
        lines[#lines + 1] = "|cff888888No phase-gated quests recorded for this phase.|r"
    end
    return table.concat(lines, "\n")
end

-- Left-column summary text for the NEXT phase (Coming Next box).
local function nextPhaseSummaryText()
    local nx = ns.Phases[Addon:GetActivePhase() + 1]
    if not nx then
        return "|cff00ff00You're on the final phase.|r The Season of Discovery journey is complete \226\128\148 nothing further to unlock."
    end
    local out = {}
    out[#out + 1] = "|cffffd100" .. nx.name .. "|r"
    local date = Addon:GetNextPhaseDate()
    if date ~= "" then out[#out + 1] = "|cffffd100Unlocks on:|r " .. date end
    out[#out + 1] = ""
    out[#out + 1] = "|cffffd100New raid:|r " .. (nx.raid or "\226\128\148")
    if nx.event then out[#out + 1] = "|cffffd100New Event:|r " .. nx.event end
    out[#out + 1] = "|cffffd100New dungeons & raids:|r"
    out[#out + 1] = bulletList(nx.instanceUnlocks, "ffffd100")
    out[#out + 1] = string.format(
        "|cffffd100Raises level cap to|r |cff00ff00%d|r|cffffd100, profession cap to|r |cff00ff00%d|r.",
        nx.levelCap, nx.profCap)
    return table.concat(out, "\n")
end

-- Custom AceGUI widget for the Overview "This Phase" box: a two-column panel
-- with the phase summary on the left and a "Unique Drops" header + epic-loot icon
-- grid pinned to the upper-right (in line with the headline raid). Built as one
-- widget so the columns top-align — AceConfig's flow layout vertically centers
-- separate side-by-side widgets, which is why the icons can't be done declaratively.
-- Each icon shows the real item tooltip on hover and links the item into chat on click.
-- Two registered variants: the active phase ("This Phase") and the next phase
-- ("Coming Next"). Each carries its own left-text provider (summaryFn) and a
-- phase-index provider (dropsPhaseFn) for which PhaseRaidDrops list to render.
local PANEL_WIDGET      = "SoDPhasePanel"
local PANEL_WIDGET_NEXT = "SoDPhasePanelNext"
do
    local AceGUI = LibStub("AceGUI-3.0")
    local ICON, GAP, LEFT_FRAC, QMARK = 30, 5, 0.58, 134400

    local function iconEnter(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. self.itemID)
        GameTooltip:Show()
    end
    local function iconLeave() GameTooltip:Hide() end
    local function iconClick(self)
        local _, link = GetItemInfo(self.itemID)
        if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
    end
    local function makeIcon(parent)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(ICON, ICON)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetPoint("TOPLEFT", -1, 1); bg:SetPoint("BOTTOMRIGHT", 1, -1)
        bg:SetColorTexture(0, 0, 0)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- trim default icon border
        b:SetScript("OnEnter", iconEnter)
        b:SetScript("OnLeave", iconLeave)
        b:SetScript("OnClick", iconClick)
        return b
    end

    -- Right-column sections rendered top-to-bottom: {label, source table}.
    local SECTIONS = {
        { label = "|cffffd100Unique Drops|r\n|cff888888Epic raid loot \226\128\148 hover for details.|r",
          src = "PhaseRaidDrops" },
        { label = "|cffffd100Crafted Epics|r\n|cff888888Crafted gear \226\128\148 hover for details.|r",
          src = "PhaseCraftedEpics" },
        { label = "|cffffd100New Consumes|r\n|cff888888New consumables \226\128\148 hover for details.|r",
          src = "PhaseNewConsumes" },
    }

    local function Relayout(self)
        if self.resizing then return end
        local frame = self.frame
        local W = frame.width or frame:GetWidth() or 400
        local rightX = W * LEFT_FRAC
        local rightW = math.max(ICON, W - rightX)
        local per = math.max(1, math.floor((rightW + GAP) / (ICON + GAP)))

        self.left:ClearAllPoints()
        self.left:SetPoint("TOPLEFT")
        self.left:SetWidth(math.max(50, rightX - 10))
        self.left:SetText(self.summaryFn())

        for _, b in ipairs(self.icons) do b:Hide(); b.itemID = nil end
        for _, h in ipairs(self.headers) do h:Hide(); h:SetText("") end

        local phase = self.dropsPhaseFn()
        local y, iconN = 0, 0
        for s = 1, #SECTIONS do
            local sec = SECTIONS[s]
            local items = phase and ns[sec.src] and ns[sec.src][phase]
            if items and #items > 0 then
                local hdr = self.headers[s]
                hdr:ClearAllPoints()
                hdr:SetPoint("TOPLEFT", frame, "TOPLEFT", rightX, -y)
                hdr:SetWidth(rightW)
                hdr:SetText(sec.label)
                hdr:Show()
                y = y + hdr:GetStringHeight() + 4
                for i = 1, #items do
                    iconN = iconN + 1
                    local b = self.icons[iconN]
                    if not b then b = makeIcon(frame); self.icons[iconN] = b end
                    b.itemID = items[i]
                    b.tex:SetTexture((GetItemIcon and GetItemIcon(items[i])) or QMARK)
                    local col, row = (i - 1) % per, math.floor((i - 1) / per)
                    b:ClearAllPoints()
                    b:SetPoint("TOPLEFT", frame, "TOPLEFT",
                        rightX + col * (ICON + GAP), -(y + row * (ICON + GAP)))
                    b:Show()
                end
                y = y + math.ceil(#items / per) * (ICON + GAP) + 8
            end
        end

        local h = math.max(self.left:GetStringHeight(), y)
        if h < 1 then h = 1 end
        self.resizing = true
        frame:SetHeight(h)
        frame.height = h
        self.resizing = nil
    end

    local methods = {
        OnAcquire = function(self)
            self.resizing = true
            self:SetWidth(400)
            self.resizing = nil
            Relayout(self)
        end,
        OnRelease = function(self)
            for _, b in ipairs(self.icons) do b:Hide(); b.itemID = nil end
        end,
        OnWidthSet     = function(self) Relayout(self) end,
        SetText        = function(self) Relayout(self) end,  -- AceConfig description path
        SetFontObject  = function(self, font) self.left:SetFontObject(font or GameFontHighlight) end,
        SetImage       = function() end,
        SetImageSize   = function() end,
        SetColor       = function() end,
    }

    -- Register a panel variant bound to its own text + drops-phase providers.
    local function registerPanel(typeName, summaryFn, dropsPhaseFn)
        local function Constructor()
            local frame = CreateFrame("Frame", nil, UIParent)
            frame:Hide()
            local left = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            left:SetJustifyH("LEFT"); left:SetJustifyV("TOP")
            local headers = {}
            for s = 1, #SECTIONS do
                local hdr = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                hdr:SetJustifyH("LEFT"); hdr:SetJustifyV("TOP")
                headers[s] = hdr
            end
            local widget = {
                frame = frame, type = typeName, left = left, headers = headers, icons = {},
                summaryFn = summaryFn, dropsPhaseFn = dropsPhaseFn,
            }
            for k, v in pairs(methods) do widget[k] = v end
            frame.obj = widget
            return AceGUI:RegisterAsWidget(widget)
        end
        AceGUI:RegisterWidgetType(typeName, Constructor, 1)
    end

    registerPanel(PANEL_WIDGET, phaseSummaryText,
        function() return Addon:GetActivePhase() end)
    registerPanel(PANEL_WIDGET_NEXT, nextPhaseSummaryText,
        function()
            local n = Addon:GetActivePhase() + 1
            return ns.Phases[n] and n or nil
        end)
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
        overview = {
            type = "group", order = 15, name = "Overview",
            args = {
                intro = {
                    type = "description", order = 0, fontSize = "large",
                    name = function()
                        local d = Addon:GetPhaseData()
                        if not d then return "" end
                        return string.format(
                            "|cffffd100%s|r\n\nLevel cap |cff00ff00%d|r    Profession cap |cff00ff00%d|r    Mode |cff00ff00%s|r",
                            d.name, d.levelCap, d.profCap, Addon:GetMode())
                    end,
                },
                current = {
                    type = "group", inline = true, order = 10, name = "This Phase",
                    args = {
                        panel = {
                            type = "description", order = 1, fontSize = "medium",
                            dialogControl = PANEL_WIDGET, width = "full", name = "",
                        },
                    },
                },
                available = {
                    type = "group", inline = true, order = 20, name = "All Available Instances",
                    args = {
                        body = {
                            type = "description", order = 1, fontSize = "medium",
                            name = function()
                                local list = cumulativeInstances(Addon:GetActivePhase())
                                return string.format("|cffffd100%d dungeons & raids enterable:|r\n", #list)
                                    .. bulletList(list, "ffffffff")
                            end,
                        },
                    },
                },
                comingNext = {
                    type = "group", inline = true, order = 30, name = "Coming Next",
                    args = {
                        panel = {
                            type = "description", order = 1, fontSize = "medium",
                            dialogControl = PANEL_WIDGET_NEXT, width = "full", name = "",
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

-- Warm the item cache so drop icons/tooltips resolve on first panel open.
if GetItemInfo then
    for _, tbl in ipairs({ ns.PhaseRaidDrops, ns.PhaseCraftedEpics, ns.PhaseNewConsumes }) do
        for _, list in pairs(tbl or {}) do
            for _, itemID in ipairs(list) do GetItemInfo(itemID) end
        end
    end
end

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
