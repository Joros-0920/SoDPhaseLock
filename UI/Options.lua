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

-- ---- Overview helpers -----------------------------------------------------
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

-- Left-column summary text for the active phase (headline raid, new instances).
-- Shared by the "This Phase" custom panel widget below.
local function phaseSummaryText()
    local idx = Addon:GetActivePhase()
    local d = ns.Phases[idx]
    if not d then return "" end
    local lines = {}
    lines[#lines + 1] = "|cffffd100Headline raid:|r " .. (d.raid or "\226\128\148")
    if d.event then lines[#lines + 1] = "|cffffd100Event:|r " .. d.event end
    if d.feature then lines[#lines + 1] = "|cffffd100New feature:|r " .. d.feature end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffffd100Newly unlocked this phase:|r"
    lines[#lines + 1] = bulletList(d.instanceUnlocks, "ff40ff40")
    lines[#lines + 1] = ""
    local allInstances = cumulativeInstances(idx)
    lines[#lines + 1] = string.format("|cffffd100All available instances (%d):|r", #allInstances)
    lines[#lines + 1] = bulletList(allInstances, "ffffffff")
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
    if nx.feature then out[#out + 1] = "|cffffd100New feature:|r " .. nx.feature end
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
local PANEL_WIDGET          = "SoDPhasePanel"
local PANEL_WIDGET_NEXT     = "SoDPhasePanelNext"
local PANEL_WIDGET_ENCHANTS = "SoDPhaseEnchantsPanel"
do
    local AceGUI = LibStub("AceGUI-3.0")
    local ICON, GAP, LEFT_FRAC, QMARK = 30, 5, 0.58, 134400

    -- Per-phase background art for the panel box, keyed by phase index. Assets are
    -- TGA (WoW can't load JPG/PNG from disk). Darkened in Lua so the asset stays
    -- clean and the foreground text remains readable. Phases without art show none.
    local PHASE_BG = {
        [1] = "Interface\\AddOns\\SoDPhaseLock\\Assets\\bfd.tga",
        [2] = "Interface\\AddOns\\SoDPhaseLock\\Assets\\gnomeregan.tga",
        [3] = "Interface\\AddOns\\SoDPhaseLock\\Assets\\sunken_temple.tga",
    }

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
    local function makeSubheader(parent)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
        return fs
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
        for _, h in ipairs(self.subheaders) do h:Hide(); h:SetText("") end

        local phase = self.dropsPhaseFn()
        local bgPath = phase and PHASE_BG[phase]
        if bgPath then
            self.bg:SetTexture(bgPath)
            self.bg:SetVertexColor(0.40, 0.40, 0.40)  -- darken so text stays legible
            self.bg:SetAlpha(0.75)
            self.bg:Show()
        else
            self.bg:Hide()
        end

        local y, iconN, subN = 0, 0, 0

        -- Lay out a flat list of item icons starting at the current y; advances y.
        local function layoutIcons(list)
            for i = 1, #list do
                iconN = iconN + 1
                local b = self.icons[iconN]
                if not b then b = makeIcon(frame); self.icons[iconN] = b end
                b.itemID = list[i]
                b.tex:SetTexture((GetItemIcon and GetItemIcon(list[i])) or QMARK)
                local col, row = (i - 1) % per, math.floor((i - 1) / per)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", frame, "TOPLEFT",
                    rightX + col * (ICON + GAP), -(y + row * (ICON + GAP)))
                b:Show()
            end
            y = y + math.ceil(#list / per) * (ICON + GAP) + 8
        end

        for s = 1, #SECTIONS do
            local sec = SECTIONS[s]
            local data = phase and ns[sec.src] and ns[sec.src][phase]
            if data and #data > 0 then
                local hdr = self.headers[s]
                hdr:ClearAllPoints()
                hdr:SetPoint("TOPLEFT", frame, "TOPLEFT", rightX, -y)
                hdr:SetWidth(rightW)
                hdr:SetText(sec.label)
                hdr:Show()
                y = y + hdr:GetStringHeight() + 4
                if type(data[1]) == "table" then
                    -- Grouped: each entry is { profession = "...", items = {...} },
                    -- rendered as a sub-header + its own icon grid (used by the
                    -- Crafted Epics section so epics are split per profession).
                    for g = 1, #data do
                        local grp = data[g]
                        local list = grp.items or grp
                        if list and #list > 0 then
                            subN = subN + 1
                            local sh = self.subheaders[subN]
                            if not sh then sh = makeSubheader(frame); self.subheaders[subN] = sh end
                            sh:ClearAllPoints()
                            sh:SetPoint("TOPLEFT", frame, "TOPLEFT", rightX, -y)
                            sh:SetWidth(rightW)
                            sh:SetText("|cffffe680" .. (grp.profession or grp.label or "?") .. "|r")
                            sh:Show()
                            y = y + sh:GetStringHeight() + 2
                            layoutIcons(list)
                        end
                    end
                else
                    layoutIcons(data)
                end
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
            local bg = frame:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(frame)
            bg:Hide()
            local left = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            left:SetJustifyH("LEFT"); left:SetJustifyV("TOP")
            local headers = {}
            for s = 1, #SECTIONS do
                local hdr = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                hdr:SetJustifyH("LEFT"); hdr:SetJustifyV("TOP")
                headers[s] = hdr
            end
            local widget = {
                frame = frame, type = typeName, left = left, headers = headers,
                subheaders = {}, icons = {},
                bg = bg, summaryFn = summaryFn, dropsPhaseFn = dropsPhaseFn,
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

    -- ---------------------------------------------------------------------
    -- "Available Enchants" panel: a character-screen paper doll. Each gear slot is
    -- drawn in its real character-pane position, showing the equipped item's icon.
    -- Enchantable slots get a coloured outline (green = enchanted, red = needs an
    -- enchant) and a label with the current enchant; hovering one lists every
    -- enchant available up to the active phase. Recomputed each time it renders.
    -- ---------------------------------------------------------------------
    local DOLL_ICON = 28

    -- Standard character-pane layout. `inv` = INVSLOT id; `empty` = Blizzard
    -- empty-slot texture suffix; `ench` = enchant slot label (or "weapon"/"offhand"
    -- for the dynamic weapon slots, resolved from the equipped item type).
    local DOLL_LEFT = {
        { name = "Head",     inv = 1,  empty = "Head" },
        { name = "Neck",     inv = 2,  empty = "Neck" },
        { name = "Shoulder", inv = 3,  empty = "Shoulder" },
        { name = "Back",     inv = 15, empty = "Chest",  ench = "Cloak" },
        { name = "Chest",    inv = 5,  empty = "Chest",  ench = "Chest" },
        { name = "Shirt",    inv = 4,  empty = "Shirt" },
        { name = "Tabard",   inv = 19, empty = "Tabard" },
        { name = "Wrist",    inv = 9,  empty = "Wrist",  ench = "Bracer" },
    }
    local DOLL_RIGHT = {
        { name = "Hands",     inv = 10, empty = "Hands",   ench = "Gloves" },
        { name = "Waist",     inv = 6,  empty = "Waist" },
        { name = "Legs",      inv = 7,  empty = "Legs" },
        { name = "Feet",      inv = 8,  empty = "Feet",    ench = "Boots" },
        { name = "Finger 1",  inv = 11, empty = "Finger" },
        { name = "Finger 2",  inv = 12, empty = "Finger" },
        { name = "Trinket 1", inv = 13, empty = "Trinket" },
        { name = "Trinket 2", inv = 14, empty = "Trinket" },
    }
    local DOLL_BOTTOM = {
        { name = "Main Hand", inv = 16, empty = "MainHand",      ench = "weapon" },
        { name = "Off Hand",  inv = 17, empty = "SecondaryHand", ench = "offhand" },
        { name = "Ranged",    inv = 18, empty = "Ranged" },
    }

    -- Read the green permanent-enchant line off an equipped item's tooltip.
    local scanTip
    local function scanEnchantName(invSlot)
        if not scanTip then
            scanTip = CreateFrame("GameTooltip", "SoDPhaseLockScanTip", nil, "GameTooltipTemplate")
        end
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTip:ClearLines()
        scanTip:SetInventoryItem("player", invSlot)
        for i = 2, scanTip:NumLines() do
            local fs = _G["SoDPhaseLockScanTipTextLeft" .. i]
            local t = fs and fs:GetText()
            if t then
                local r, g, b = fs:GetTextColor()
                if r and g and b and r < 0.2 and g > 0.8 and b < 0.2 then return t end
            end
        end
        return nil
    end

    -- Resolve a slot's enchant label, resolving the dynamic weapon slots from the
    -- equipped item type (2H vs 1H weapon; shield vs off-hand weapon vs held).
    local function resolveEnchLabel(slot, link)
        local e = slot.ench
        if not e or (e ~= "weapon" and e ~= "offhand") then return e end
        local loc = link and select(9, GetItemInfo(link)) or nil
        if e == "weapon" then
            if loc == "INVTYPE_2HWEAPON" then return "2H Weapon" end
            return "Weapon"               -- default/empty main hand
        else -- off-hand
            if loc == "INVTYPE_SHIELD" then return "Shield" end
            if loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONOFFHAND" then return "Weapon" end
            if loc == "INVTYPE_HOLDABLE" then return "Off-Hand" end  -- off-hand frill / tome
            return nil                    -- empty off-hand: not enchantable
        end
    end

    -- Forward declaration: the right-hand "available enchants + shopping list"
    -- pane renderer, defined once the data helpers below are in scope.
    local RenderPane

    local function dollEnter(self)
        local info = self.info
        if not info then return end
        if not info.enchLabel then
            if info.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetInventoryItem("player", info.inv)
                GameTooltip:Show()
            end
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(info.name, 1, 0.82, 0)
        if info.itemName then
            local q = ITEM_QUALITY_COLORS[info.itemQuality or 1]
            GameTooltip:AddLine(info.itemName, q and q.r or 1, q and q.g or 1, q and q.b or 1)
        else
            GameTooltip:AddLine("Nothing equipped", 0.6, 0.6, 0.6)
        end
        if info.enchanted then
            GameTooltip:AddLine("Current: " .. (info.curName or "enchanted"), 0.25, 1, 0.25, true)
        elseif info.link then
            GameTooltip:AddLine("Not enchanted", 1, 0.4, 0.4)
        end
        if info.avail and #info.avail > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Available up to this phase:", 1, 0.82, 0)
            for _, nm in ipairs(info.avail) do
                if info.curName and nm:find(info.curName, 1, true) then
                    GameTooltip:AddLine("  " .. nm, 0.25, 1, 0.25)
                else
                    GameTooltip:AddLine("  " .. nm, 0.8, 0.8, 0.8)
                end
            end
        end
        GameTooltip:Show()
    end
    local function dollLeave() GameTooltip:Hide() end
    -- Left-click an enchantable slot to drive the right-hand pane; otherwise
    -- (non-enchantable slot) fall back to linking the equipped item in chat.
    local function dollClick(self)
        local w = self.widget
        if w and self.info and self.info.enchLabel then
            w.selSlot = self.info.enchLabel
            RenderPane(w)
        elseif self.info and self.info.link and ChatEdit_InsertLink then
            ChatEdit_InsertLink(self.info.link)
        end
    end
    local function makeDollSlot(parent)
        local b = CreateFrame("Button", nil, parent)
        b.widget = parent.obj
        b:SetSize(DOLL_ICON, DOLL_ICON)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetPoint("TOPLEFT", -2, 2); b.bg:SetPoint("BOTTOMRIGHT", 2, -2)
        b.bg:SetColorTexture(0, 0, 0)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.label:SetJustifyV("MIDDLE")
        -- NB: keep word-wrap ON. The label is multi-line (slot / item / enchant);
        -- SetWordWrap(false) collapses it to a single truncated line ("Head...").
        b:SetScript("OnEnter", dollEnter)
        b:SetScript("OnLeave", dollLeave)
        b:SetScript("OnClick", dollClick)
        return b
    end

    -- Merge ns.PhaseEnchants[1..current] into ordered { label, items = { {id,name},... } }
    -- groups, de-duplicating by spell id. Slots emit in ns.EnchantSlotOrder; any label
    -- not listed there is appended after, in first-seen order.
    local function buildCumulativeEnchants()
        local current = Addon:GetActivePhase() or 0
        local bySlot, seenOrder = {}, {}
        for p = 1, current do
            local phaseData = ns.PhaseEnchants and ns.PhaseEnchants[p]
            if phaseData then
                for _, grp in ipairs(phaseData) do
                    local label = grp.label or "?"
                    local bucket = bySlot[label]
                    if not bucket then
                        bucket = { items = {}, seen = {} }
                        bySlot[label] = bucket
                        seenOrder[#seenOrder + 1] = label
                    end
                    for _, e in ipairs(grp.items or {}) do
                        local id = type(e) == "table" and e[1] or e
                        if id and not bucket.seen[id] then
                            bucket.seen[id] = true
                            bucket.items[#bucket.items + 1] =
                                { id = id, name = type(e) == "table" and e[2] or nil }
                        end
                    end
                end
            end
        end
        local order, known = {}, {}
        for _, label in ipairs(ns.EnchantSlotOrder or {}) do order[#order + 1] = label; known[label] = true end
        for _, label in ipairs(seenOrder) do if not known[label] then order[#order + 1] = label end end
        local out = {}
        for _, label in ipairs(order) do
            local b = bySlot[label]
            if b and #b.items > 0 then out[#out + 1] = { label = label, items = b.items } end
        end
        return out
    end

    -- Cumulative available-enchant names keyed by slot label (for the hover list).
    local function buildCumulativeByLabel()
        local out = {}
        for _, grp in ipairs(buildCumulativeEnchants()) do
            local names = {}
            for _, it in ipairs(grp.items) do
                names[#names + 1] = it.name or ("Spell " .. tostring(it.id))
            end
            out[grp.label] = names
        end
        return out
    end

    -- Cumulative available-enchant { id, name } items keyed by slot label
    -- (for the clickable right-hand pane).
    local function buildCumulativeItemsByLabel()
        local out = {}
        for _, grp in ipairs(buildCumulativeEnchants()) do
            out[grp.label] = grp.items
        end
        return out
    end

    -- Populate one paper-doll slot from the live equipped item + enchant state.
    local function fillDollSlot(b, slot, availByLabel)
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot.inv)
        local tex  = GetInventoryItemTexture and GetInventoryItemTexture("player", slot.inv)
        b.tex:SetTexture(tex or ("Interface\\PaperDoll\\UI-PaperDoll-Slot-" .. slot.empty))

        local enchLabel = resolveEnchLabel(slot, link)
        local enchanted, curName
        if enchLabel and link then
            local enchId = tonumber(link:match("item:%d+:(%d+)") or "")
            if enchId and enchId ~= 0 then
                enchanted = true
                curName = scanEnchantName(slot.inv)
            end
        end

        if not enchLabel then
            b.bg:SetColorTexture(0, 0, 0)
        elseif not link then
            b.bg:SetColorTexture(0.3, 0.3, 0.3)
        elseif enchanted then
            b.bg:SetColorTexture(0.15, 0.8, 0.15)
        else
            b.bg:SetColorTexture(0.85, 0.2, 0.2)
        end

        local itemName, itemQuality
        if link then itemName, _, itemQuality = GetItemInfo(link) end
        b.info = {
            name = slot.name, inv = slot.inv, link = link,
            itemName = itemName, itemQuality = itemQuality,
            enchLabel = enchLabel, enchanted = enchanted, curName = curName,
            avail = enchLabel and availByLabel[enchLabel] or nil,
        }

        local txt = "|cffffffff" .. slot.name .. "|r"
        if itemName then
            local q = ITEM_QUALITY_COLORS[itemQuality or 1]
            local hex = q and string.format("ff%02x%02x%02x", q.r * 255, q.g * 255, q.b * 255) or "ffffffff"
            txt = txt .. "\n|c" .. hex .. itemName .. "|r"
        end
        if enchLabel then
            if enchanted then
                txt = txt .. "\n|cff40ff40" .. (curName or "Enchanted") .. "|r"
            elseif link then
                txt = txt .. "\n|cffff6060Not enchanted|r"
            else
                txt = txt .. "\n|cff888888\226\128\148|r"
            end
        end
        b.label:SetText(txt)
    end

    -- ---- Right-hand pane: clickable enchant list + reagent shopping list ----
    local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

    -- Persistent selection: ONE enchant per gear piece (slot label -> enchant
    -- spellID). Selecting another enchant for the same slot replaces the previous
    -- one. Module-scoped so it survives slot/enchant changes and the panel being
    -- closed/reopened within a session (only resets on /reload or logout).
    local selection = {}
    -- Left-click toggles: pick this enchant for its slot, or unpick if already set.
    local function selectionToggle(label, id)
        if selection[label] == id then selection[label] = nil else selection[label] = id end
    end
    local function selectionClear() for k in pairs(selection) do selection[k] = nil end end

    -- Aggregate the reagents of every selected enchant, summing by reagent (keyed
    -- on itemID, falling back to name). Each gear piece contributes one enchant, so
    -- counts are summed straight (no per-enchant quantity). Returns an ordered list
    -- of { id, name, count } plus a count of selections that have no reagent data.
    local function buildSelectionReagents()
        local out, index, missing = {}, {}, 0
        local labels = {}
        for label in pairs(selection) do labels[#labels + 1] = label end
        table.sort(labels)
        for _, label in ipairs(labels) do
            local reagents = ns.EnchantReagents and ns.EnchantReagents[selection[label]]
            if reagents then
                for _, rg in ipairs(reagents) do
                    local key = rg.id or ("n:" .. tostring(rg.name))
                    local e = index[key]
                    if not e then
                        e = { id = rg.id, name = rg.name, count = 0 }
                        index[key] = e; out[#out + 1] = e
                    end
                    e.count = e.count + (rg.count or 0)
                end
            else
                missing = missing + 1
            end
        end
        return out, missing
    end

    -- Strip the "Enchant <Slot> - " prefix for the compact list ("Crusader").
    local function shortEnchName(name)
        if not name then return "?" end
        return name:match("%-%s*(.+)$") or name
    end

    local function enchRowOnClick(self, button)
        if not self.enchId or not self.slotLabel then return end
        if button == "RightButton" then
            if selection[self.slotLabel] == self.enchId then selection[self.slotLabel] = nil end
        else
            selectionToggle(self.slotLabel, self.enchId)
        end
        if self.widget then RenderPane(self.widget) end
    end
    local function enchRowOnEnter(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(self.fullName or "", 1, 0.82, 0)
        local reagents = self.enchId and ns.EnchantReagents and ns.EnchantReagents[self.enchId]
        if reagents then
            for _, rg in ipairs(reagents) do
                GameTooltip:AddLine(string.format("%dx %s", rg.count or 1, rg.name or "?"), 0.8, 0.8, 0.8)
            end
        else
            GameTooltip:AddLine("Reagents not listed yet", 0.6, 0.6, 0.6)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to choose this enchant for the slot (one per piece)", 0.4, 0.6, 1)
        GameTooltip:Show()
    end
    local function makeEnchRow(w)
        local r = CreateFrame("Button", nil, w.frame)
        r.widget = w
        r:SetHeight(14)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.sel = r:CreateTexture(nil, "BACKGROUND")
        r.sel:SetAllPoints(); r.sel:SetColorTexture(0.20, 0.40, 0.90, 0.35); r.sel:Hide()
        r.hl = r:CreateTexture(nil, "HIGHLIGHT")
        r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.10)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", 3, 0); r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
        r:SetScript("OnClick", enchRowOnClick)
        r:SetScript("OnEnter", enchRowOnEnter)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return r
    end

    local function reagentOnEnter(self)
        if not self.itemId then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. self.itemId)
        GameTooltip:Show()
    end
    local function reagentOnLeave() GameTooltip:Hide() end
    local function reagentOnClick(self)
        if self.itemId and ChatEdit_InsertLink then
            local link = select(2, GetItemInfo(self.itemId))
            if link then ChatEdit_InsertLink(link) end
        end
    end
    local function makeReagentRow(w)
        local r = CreateFrame("Button", nil, w.frame)
        r:SetHeight(18)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 0, 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r.icon, "RIGHT", 5, 0); r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
        -- Strike-through line drawn across the text when the player has enough.
        r.strike = r:CreateTexture(nil, "OVERLAY")
        r.strike:SetColorTexture(0.4, 1, 0.4, 0.9); r.strike:SetHeight(1); r.strike:Hide()
        r:SetScript("OnEnter", reagentOnEnter)
        r:SetScript("OnLeave", reagentOnLeave)
        r:SetScript("OnClick", reagentOnClick)
        return r
    end

    -- Lazily create the pane's header/note fontstrings on the frame.
    local function paneFontString(w, key, template)
        if not w[key] then
            w[key] = w.frame:CreateFontString(nil, "OVERLAY", template)
            w[key]:SetJustifyH("LEFT"); w[key]:SetWordWrap(true)
        end
        return w[key]
    end

    -- Lazily create the shopping-list "Clear" button.
    local function ensureClearBtn(w)
        if w.clearBtn then return w.clearBtn end
        local b = CreateFrame("Button", nil, w.frame)
        b:SetSize(40, 14)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 1, 1, 0.10)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetAllPoints(); b.text:SetJustifyH("RIGHT"); b.text:SetText("|cffff8080Clear|r")
        b:SetScript("OnClick", function() selectionClear(); RenderPane(w) end)
        w.clearBtn = b
        return b
    end

    local MAX_ENCH_ROWS    = 24
    local MAX_REAGENT_ROWS = 16

    RenderPane = function(w)
        local frame, x, top = w.frame, w.paneX or 0, w.paneTop or 0
        local pw = w.paneW or 200
        w.enchRows = w.enchRows or {}
        w.reagentRows = w.reagentRows or {}
        for _, r in ipairs(w.enchRows) do r:Hide() end
        for _, r in ipairs(w.reagentRows) do r:Hide() end

        local h1    = paneFontString(w, "h1", "GameFontNormal")
        local note  = paneFontString(w, "note", "GameFontDisableSmall")
        local h2    = paneFontString(w, "h2", "GameFontNormal")
        local empty = paneFontString(w, "emptyNote", "GameFontDisableSmall")
        h1:Hide(); note:Hide(); h2:Hide(); empty:Hide()
        if w.clearBtn then w.clearBtn:Hide() end

        -- ---- Top: available enchants for the selected slot (click = add) ----
        local y = top
        h1:ClearAllPoints(); h1:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
        h1:SetWidth(pw); h1:Show()

        if not w.selSlot then
            h1:SetText("Available Enchants")
            y = y + 18
            note:ClearAllPoints(); note:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
            note:SetWidth(pw)
            note:SetText("Click a gear slot on the left to list its enchants, then click one to choose it for that piece. You can pick one enchant per gear piece; the shopping list below totals the reagents.")
            note:Show()
            y = y + 64
        else
            h1:SetText("|cffffd100" .. w.selSlot .. "|r enchants")
            y = y + 18
            local items = (w.availItems and w.availItems[w.selSlot]) or {}
            local cur = w.curByLabel and w.curByLabel[w.selSlot]
            local chosen = selection[w.selSlot]
            local n = 0
            for _, it in ipairs(items) do
                if n >= MAX_ENCH_ROWS then break end
                n = n + 1
                local r = w.enchRows[n] or makeEnchRow(w)
                w.enchRows[n] = r
                r.enchId = it.id; r.fullName = it.name; r.slotLabel = w.selSlot
                local label = shortEnchName(it.name)
                local color = "|cffcfcfcf"
                if cur and it.name and it.name:find(cur, 1, true) then color = "|cff40ff40" end -- equipped
                r.text:SetText(color .. label .. "|r")
                r.sel:SetShown(it.id == chosen)
                r:ClearAllPoints(); r:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
                r:SetSize(pw, 14); r.text:SetWidth(pw - 6)
                r:Show()
                y = y + 15
            end
            if n == 0 then
                note:ClearAllPoints(); note:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
                note:SetWidth(pw); note:SetText("No enchants available for this slot yet."); note:Show()
                y = y + 16
            end
        end

        -- ---- Bottom: persistent shopping list (one enchant per gear piece) ----
        y = y + 12
        h2:ClearAllPoints(); h2:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
        h2:SetWidth(pw); h2:SetText("Shopping list"); h2:Show()
        if next(selection) then
            local clr = ensureClearBtn(w)
            clr:ClearAllPoints()
            clr:SetPoint("TOPLEFT", frame, "TOPLEFT", x + pw - 40, -y + 1)
            clr:Show()
        end
        y = y + 18

        if not next(selection) then
            empty:ClearAllPoints(); empty:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
            empty:SetWidth(pw)
            empty:SetText("Empty — choose an enchant for a gear piece above.")
            empty:Show()
            y = y + 16
        else
            local agg, missing = buildSelectionReagents()
            local m = 0
            for _, rg in ipairs(agg) do
                if m >= MAX_REAGENT_ROWS then break end
                m = m + 1
                local r = w.reagentRows[m] or makeReagentRow(w)
                w.reagentRows[m] = r
                r.itemId = rg.id
                r.icon:SetTexture((rg.id and GetItemIcon(rg.id)) or QUESTION_ICON)
                local nm = (rg.id and GetItemInfo(rg.id)) or rg.name or ("Item " .. tostring(rg.id))
                -- How many the player carries in bags (nil if the reagent has no
                -- itemID — then we can't query a bag count, so show need only).
                local have = rg.id and GetItemCount(rg.id) or nil
                local enough = have ~= nil and have >= rg.count
                if have ~= nil then
                    local cc = enough and "|cff40ff40" or "|cffffd100"
                    r.text:SetText(string.format("|cffffffff%dx|r %s  %s%d/%d|r",
                        rg.count, nm, cc, have, rg.count))
                else
                    r.text:SetText(string.format("|cffffffff%dx|r %s", rg.count, nm))
                end
                -- "Cross out" reagents the player already has enough of: dim the
                -- icon + draw a strike-through across the (visible) text width.
                r.icon:SetDesaturated(enough); r.icon:SetAlpha(enough and 0.5 or 1)
                if enough then
                    r.strike:ClearAllPoints()
                    r.strike:SetPoint("LEFT", r.text, "LEFT", 0, 0)
                    r.strike:SetWidth(math.min(r.text:GetStringWidth(), pw - 22))
                    r.strike:Show()
                else
                    r.strike:Hide()
                end
                r:ClearAllPoints(); r:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
                r:SetSize(pw, 18); r.text:SetWidth(pw - 22)
                r:Show()
                y = y + 19
            end
            if missing > 0 then
                empty:ClearAllPoints(); empty:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
                empty:SetWidth(pw)
                empty:SetText(string.format("(%d enchant%s in list have no reagent data yet)",
                    missing, missing == 1 and "" or "s"))
                empty:Show()
                y = y + 16
            end
        end
        w.paneBottom = y
    end

    local function RelayoutEnchants(self)
        if self.resizing then return end
        local frame = self.frame
        local W = frame.width or frame:GetWidth() or 560

        for _, b in ipairs(self.slots) do b:Hide(); b.info = nil; b.label:Hide() end

        local availByLabel = buildCumulativeByLabel()
        self.availItems = buildCumulativeItemsByLabel()
        self.curByLabel = {}
        local ROW_H  = DOLL_ICON + 12
        -- Left: the paper doll (two columns) — gets the bulk of the width so the
        -- per-slot item name + current enchant stay readable beside each icon.
        -- Right: a slim interaction pane (enchant list + reagent shopping list);
        -- long reagent names truncate but the row's hover tooltip shows them full.
        local PANEGAP = 16
        local paneW   = math.max(150, math.min(185, W * 0.30))
        local dollW   = math.max(220, W - paneW - PANEGAP)
        local COLGAP  = 16
        local colW    = math.max(120, math.min(215, (dollW - COLGAP) / 2))
        local x0      = 0
        local rightX  = x0 + colW + COLGAP
        local n       = 0
        self.paneX    = W - paneW
        self.paneW    = paneW
        self.paneTop  = 0

        local function place(slot, x, y, textW, below)
            n = n + 1
            local b = self.slots[n]
            if not b then b = makeDollSlot(frame); self.slots[n] = b end
            fillDollSlot(b, slot, availByLabel)
            if b.info.enchLabel and b.info.curName then
                self.curByLabel[b.info.enchLabel] = b.info.curName
            end
            b:ClearAllPoints(); b.label:ClearAllPoints()
            if below then
                b:SetPoint("TOP", frame, "TOPLEFT", x, -y)
                b.label:SetPoint("TOP", b, "BOTTOM", 0, -2)
                b.label:SetJustifyH("CENTER")
            else
                b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
                b.label:SetPoint("LEFT", b, "RIGHT", 6, 0)
                b.label:SetJustifyH("LEFT")
            end
            b.label:SetWidth(textW)
            b.label:Show(); b:Show()
        end

        for i, slot in ipairs(DOLL_LEFT) do
            place(slot, x0, (i - 1) * ROW_H, colW - DOLL_ICON - 12, false)
        end
        for i, slot in ipairs(DOLL_RIGHT) do
            place(slot, rightX, (i - 1) * ROW_H, colW - DOLL_ICON - 12, false)
        end

        local cols = math.max(#DOLL_LEFT, #DOLL_RIGHT) * ROW_H + 14
        -- Weapon row: Main Hand under Wrist (left column), Ranged under Trinket 2
        -- (right column), Off Hand centered between them.
        local half = DOLL_ICON / 2
        local wtextW = colW / 2 - 8
        place(DOLL_BOTTOM[1], x0 + half, cols, wtextW, true)                    -- Main Hand
        place(DOLL_BOTTOM[2], (x0 + rightX) / 2 + half, cols, wtextW, true)     -- Off Hand
        place(DOLL_BOTTOM[3], rightX + half, cols, wtextW, true)                -- Ranged

        local dollH = cols + DOLL_ICON + 34

        -- Reserve enough height for the worst-case pane (largest slot's enchant
        -- list + a full shopping list) so adding/removing/selecting never grows
        -- the frame past what the options scroll-frame already allotted.
        local maxItems = 0
        for _, items in pairs(self.availItems) do
            maxItems = math.max(maxItems, math.min(#items, MAX_ENCH_ROWS))
        end
        local paneMaxH = self.paneTop + 18 + maxItems * 15      -- h1 + enchant rows
                       + 12 + 18                                 -- gap + shopping header
                       + MAX_REAGENT_ROWS * 19 + 16              -- reagent rows + footnote

        self.resizing = true
        local h = math.max(dollH, paneMaxH)
        frame:SetHeight(h); frame.height = h
        self.resizing = nil

        RenderPane(self)
    end

    local enchMethods = {
        OnAcquire = function(self)
            self.selSlot = nil
            self.resizing = true; self:SetWidth(560); self.resizing = nil
            RelayoutEnchants(self)
        end,
        OnRelease = function(self)
            -- NB: the enchant selection is module-scoped and deliberately NOT
            -- cleared here, so it survives the panel being closed and reopened.
            for _, b in ipairs(self.slots) do b:Hide(); b.info = nil; b.label:Hide() end
            for _, r in ipairs(self.enchRows or {}) do r:Hide() end
            for _, r in ipairs(self.reagentRows or {}) do r:Hide() end
            if self.h1 then self.h1:Hide() end
            if self.h2 then self.h2:Hide() end
            if self.note then self.note:Hide() end
            if self.emptyNote then self.emptyNote:Hide() end
            if self.clearBtn then self.clearBtn:Hide() end
            self.selSlot = nil
        end,
        OnWidthSet    = function(self) RelayoutEnchants(self) end,
        SetText       = function(self) RelayoutEnchants(self) end,  -- AceConfig description path
        SetFontObject = function() end,
        SetImage      = function() end,
        SetImageSize  = function() end,
        SetColor      = function() end,
    }

    local function EnchantsConstructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()
        local widget = {
            frame = frame, type = PANEL_WIDGET_ENCHANTS, slots = {},
        }
        for k, v in pairs(enchMethods) do widget[k] = v end
        frame.obj = widget
        -- Keep the shopping list's bag counts / strike-throughs live as the
        -- player's bags change (only while shown and something is selected).
        frame:RegisterEvent("BAG_UPDATE_DELAYED")
        frame:SetScript("OnEvent", function(self)
            if self:IsShown() and self.obj and next(selection) then RenderPane(self.obj) end
        end)
        return AceGUI:RegisterAsWidget(widget)
    end
    AceGUI:RegisterWidgetType(PANEL_WIDGET_ENCHANTS, EnchantsConstructor, 1)
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
                            d and d.name or "?", Addon:GetMode(), d and d.levelCap or 0,
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
        enchants = {
            type = "group", order = 17, name = "Available Enchants",
            args = {
                intro = {
                    type = "description", order = 0, fontSize = "large",
                    name = function()
                        local d = Addon:GetPhaseData()
                        if not d then return "" end
                        return string.format("|cffffd100Available Enchants|r — %s", d.name)
                    end,
                },
                help = {
                    type = "description", order = 1, fontSize = "small",
                    name = "|cff40ff40Green|r|cff888888 = enchanted, |cffff6060red|r|cff888888 = enchantable but missing an enchant.\nClick a gear slot to list its enchants on the right, then choose one enchant per gear piece. The shopping list totals the reagents for everything you've picked.|r",
                },
                panel = {
                    type = "description", order = 10,
                    dialogControl = PANEL_WIDGET_ENCHANTS, width = "full", name = "",
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
                                Addon:GetRuleset().nextPhaseDate = v or ""
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
                                Addon:GetRuleset().autoUnequip = v
                                commitGuild("Block over-phase gear: " .. (v and "|cff00ff00enabled|r" or "|cffff8080disabled|r"))
                            end,
                        },
                        instanceGrace = {
                            type = "range", order = 2, name = "Instance grace period (seconds)",
                            desc = "How long a member may stay in a not-yet-unlocked instance before being reported to the compliance log.",
                            min = 0, max = 600, step = 5, disabled = notGuildLeader,
                            get = function() return Addon:InstanceGrace() end,
                            set = function(_, v)
                                Addon:GetRuleset().instanceGrace = v
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
-- Lists are either flat itemID arrays or grouped { {profession, items}, ... }.
if GetItemInfo then
    local function warm(list)
        for _, v in ipairs(list) do
            if type(v) == "table" then warm(v.items or v) else GetItemInfo(v) end
        end
    end
    for _, tbl in ipairs({ ns.PhaseRaidDrops, ns.PhaseCraftedEpics, ns.PhaseNewConsumes }) do
        for _, list in pairs(tbl or {}) do warm(list) end
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
            get = function() return Addon:GetRuleset().enforce[r.key] end,
            set = function(_, v)
                Addon:GetRuleset().enforce[r.key] = v
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
                if Addon:GetRuleset().enforce[key] then
                    return "Already enforced by the guild — cannot be disabled."
                end
                return "Enable this restriction for yourself only, regardless of guild mode."
            end,
            -- Greyed out when the guild already has it on; player can't reduce it.
            disabled = function() return Addon:GetRuleset().enforce[key] end,
            -- Show effective state so guild-enforced rules appear checked.
            get = function()
                return Addon:GetRuleset().enforce[key]
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
