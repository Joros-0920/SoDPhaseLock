local ADDON, ns = ...
local Addon = ns.Addon
local AceGUI = LibStub("AceGUI-3.0")

local frame

-- Relative column widths; each set must sum to ~1.0
-- Guild: Player | Lvl | Phase | Mode | XP | Status | (kick)
local GUILD_COL_W = { 0.22, 0.06, 0.08, 0.10, 0.10, 0.30, 0.14 }
-- Group: Player | Lvl | Class | Range | Status
local GROUP_COL_W = { 0.24, 0.07, 0.15, 0.16, 0.38 }

-- Defined once at load; reused for every kick confirmation
StaticPopupDialogs["SODPHASELOCK_KICK_CONFIRM"] = {
    text = "Remove %s from the guild?",
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function(self, data)
        GuildUninvite(data)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Generic header row from a list of labels + matching relative widths.
local function addHeader(parent, labels, widths)
    local grp = AceGUI:Create("SimpleGroup")
    grp:SetFullWidth(true)
    grp:SetLayout("Flow")
    for i, text in ipairs(labels) do
        local lbl = AceGUI:Create("Label")
        lbl:SetRelativeWidth(widths[i])
        lbl:SetText("|cffffd100" .. text .. "|r")
        grp:AddChild(lbl)
    end
    parent:AddChild(grp)
end

-- A cell that carries its own color code (e.g. an XP/range indicator) is left
-- untouched so it keeps that color even on a red, out-of-compliance row.
local function addCell(grp, text, width, colorCode)
    local lbl = AceGUI:Create("Label")
    lbl:SetRelativeWidth(width)
    text = tostring(text)
    if text:sub(1, 2) == "|c" then
        lbl:SetText(text)
    else
        lbl:SetText(colorCode .. text .. "|r")
    end
    grp:AddChild(lbl)
end

-- Guild data row: labels + a Kick button (officer-only) as the trailing column.
local function addGuildRow(parent, cells, colorCode, playerName)
    local canKick = Addon:IsOfficer() and (playerName ~= UnitName("player"))

    local grp = AceGUI:Create("SimpleGroup")
    grp:SetFullWidth(true)
    grp:SetLayout("Flow")
    for i, text in ipairs(cells) do
        addCell(grp, text, GUILD_COL_W[i], colorCode)
    end

    local btn = AceGUI:Create("Button")
    btn:SetRelativeWidth(GUILD_COL_W[7])
    btn:SetText("Kick")
    btn:SetDisabled(not canKick)
    if canKick then
        btn:SetCallback("OnClick", function()
            StaticPopup_Show("SODPHASELOCK_KICK_CONFIRM", playerName, nil, playerName)
        end)
    end
    grp:AddChild(btn)
    parent:AddChild(grp)
end

local function addSep(parent, text)
    local h = AceGUI:Create("Heading")
    h:SetFullWidth(true)
    h:SetText(text or "")
    parent:AddChild(h)
end

local function addNote(parent, text)
    local lbl = AceGUI:Create("Label")
    lbl:SetFullWidth(true)
    lbl:SetText(text)
    parent:AddChild(lbl)
end

-- ---------------------------------------------------------------------------
-- Guild Compliance tab (synced status pings)
-- ---------------------------------------------------------------------------
local function BuildGuildRows(scroll)
    local list = ns.Compliance and ns.Compliance:GetSorted() or {}
    if #list == 0 then
        addNote(scroll, "\nNo reports yet. Guild members running this addon will appear here within a minute.")
        return
    end

    local nViol = 0
    for _, e in ipairs(list) do
        if not e.info.compliant then nViol = nViol + 1 end
    end
    local nOK = #list - nViol

    addHeader(scroll, { "Player", "Lvl", "Phase", "Mode", "XP", "Status", "" }, GUILD_COL_W)

    if nViol > 0 then
        addSep(scroll, string.format("|cffff4040Out of Compliance (%d)|r", nViol))
    else
        addSep(scroll, string.format("|cff40ff40All Compliant (%d)|r", nOK))
    end

    local shownCompliantHeader = (nViol == 0)
    for _, e in ipairs(list) do
        local i = e.info
        if i.compliant and not shownCompliantHeader then
            addSep(scroll, string.format("|cff40ff40Compliant (%d)|r", nOK))
            shownCompliantHeader = true
        end
        local color = i.compliant and "|cff40ff40" or "|cffff4040"
        addGuildRow(scroll, {
            e.name,
            tostring(i.level or "?"),
            "P" .. tostring(i.phase or "?"),
            i.mode or "?",
            i.xpLocked and "|cff40ff40Locked|r" or "|cff808080—|r",
            i.reasons or "OK",
        }, color, e.name)
    end

    if frame then
        frame:SetStatusText(string.format(
            "%d out of compliance, %d compliant — reports every ~60s", nViol, nOK))
    end
end

-- ---------------------------------------------------------------------------
-- Group Compliance tab (active inspection of the current party/raid)
-- ---------------------------------------------------------------------------
local CLASS_COLORS = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)

local function classCell(info)
    local token = info.class
    if not token then return "?" end
    local c = CLASS_COLORS and CLASS_COLORS[token]
    local label = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
    if c then
        return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, label)
    end
    return label
end

local function rangeCell(info)
    if info.scanned then return "|cff40ff40In range|r" end
    return "|cff808080Out of range|r"
end

-- Detail "why did this player fail" tooltip, shown on hovering the Status cell.
-- Spells out each failing check: level over cap, the actual later-phase item /
-- enchant links, and rune count — so an officer can see exactly what's wrong.
local function fillStatusTooltip(tip, info)
    tip:AddLine(info.name or "Player", 1, 1, 1)
    if not info.scanned then
        tip:AddLine("Not inspected yet — must be online and within ~28 yards.", 0.8, 0.8, 0.8, true)
        return
    end
    if info.compliant then
        tip:AddLine("Passes all checks for the current phase.", 0.25, 1, 0.25, true)
        return
    end
    tip:AddLine("Out of compliance:", 1, 0.82, 0)
    if info.level and info.levelCap and info.level > info.levelCap then
        tip:AddLine(string.format("  Level %d — over the phase cap of %d", info.level, info.levelCap), 1, 0.4, 0.4)
    end
    if info.gearLinks and #info.gearLinks > 0 then
        tip:AddLine(string.format("  Later-phase gear (%d):", #info.gearLinks), 1, 0.4, 0.4)
        for _, link in ipairs(info.gearLinks) do
            tip:AddLine("    " .. link)
        end
    end
    if info.enchantLinks and #info.enchantLinks > 0 then
        tip:AddLine(string.format("  Later-phase enchants (%d):", #info.enchantLinks), 1, 0.4, 0.4)
        for _, e in ipairs(info.enchantLinks) do
            local pname = (ns.Phases[e.phase] and ns.Phases[e.phase].name) or ("Phase " .. tostring(e.phase))
            tip:AddLine(string.format("    %s |cffaaaaaa(enchant unlocks %s)|r", e.link, pname))
        end
    end
    if info.rune and info.rune > 0 then
        tip:AddLine(string.format("  %d later-phase rune(s)", info.rune), 1, 0.4, 0.4)
    end
end

-- A group data row whose Status cell is hoverable for the detail breakdown.
local function addGroupRow(parent, info, name, colorCode)
    local grp = AceGUI:Create("SimpleGroup")
    grp:SetFullWidth(true)
    grp:SetLayout("Flow")
    addCell(grp, name, GROUP_COL_W[1], colorCode)
    addCell(grp, tostring(info.level or "?"), GROUP_COL_W[2], colorCode)
    addCell(grp, classCell(info), GROUP_COL_W[3], colorCode)
    addCell(grp, rangeCell(info), GROUP_COL_W[4], colorCode)

    local status = AceGUI:Create("InteractiveLabel")
    status:SetRelativeWidth(GROUP_COL_W[5])
    status:SetText(colorCode .. (info.scanned and (info.reasons or "OK") or "—") .. "|r")
    status:SetCallback("OnEnter", function(widget)
        GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        fillStatusTooltip(GameTooltip, info)
        GameTooltip:Show()
    end)
    status:SetCallback("OnLeave", function() GameTooltip:Hide() end)
    grp:AddChild(status)

    parent:AddChild(grp)
end

local function BuildGroupRows(scroll)
    local GI = ns.GroupInspect

    -- Inspection runs automatically while this tab is open; the button is just a
    -- manual refresh (e.g. after everyone gathers in range).
    local btn = AceGUI:Create("Button")
    btn:SetText("Rescan")
    btn:SetWidth(120)
    btn:SetDisabled(not (GI and GI:InGroup()))
    btn:SetCallback("OnClick", function() if GI then GI:Scan() end end)
    scroll:AddChild(btn)

    if not (GI and GI:InGroup()) then
        addNote(scroll, "\nYou are not in a party or raid. Group members are checked against the current phase automatically once you join a group and open this tab.")
        if frame then frame:SetStatusText("Not in a group") end
        return
    end

    local list = GI:GetResults()
    if #list == 0 then
        addNote(scroll, "\nInspecting the current party/raid… members are checked one at a time and must be within ~28 yards.")
        if frame then frame:SetStatusText("Inspecting group…") end
        return
    end

    local nViol, nScanned = 0, 0
    for _, e in ipairs(list) do
        if e.info.scanned then
            nScanned = nScanned + 1
            if not e.info.compliant then nViol = nViol + 1 end
        end
    end

    if nViol > 0 then
        addNote(scroll, "|cff808080Hover a flagged player's Status for the exact items, enchants, or runes that failed.|r")
    end

    addHeader(scroll, { "Player", "Lvl", "Class", "Range", "Status" }, GROUP_COL_W)

    for _, e in ipairs(list) do
        local i = e.info
        local color
        if not i.scanned then
            color = "|cff808080"      -- grey: not yet inspected / out of range
        elseif i.compliant then
            color = "|cff40ff40"
        else
            color = "|cffff4040"
        end
        addGroupRow(scroll, i, e.name, color)
    end

    if frame then
        local suffix = GI:IsScanning() and " — inspecting…" or ""
        frame:SetStatusText(string.format(
            "%d out of compliance, %d scanned of %d in group%s", nViol, nScanned, #list, suffix))
    end
end

-- ---------------------------------------------------------------------------
local function rebuildActiveTab()
    if not (frame and frame.scroll) then return end
    frame.scroll:ReleaseChildren()
    if frame.activeTab == "group" then
        BuildGroupRows(frame.scroll)
    else
        BuildGuildRows(frame.scroll)
    end
end

function ns.RefreshRoster()
    rebuildActiveTab()
end

function ns.ToggleRoster()
    if frame then
        frame:Release()
        return
    end
    frame = AceGUI:Create("Frame")
    frame:SetTitle("SoD Phase Lock — Compliance")
    frame:SetLayout("Fill")
    frame:SetWidth(620)
    frame:SetHeight(440)
    frame:SetCallback("OnClose", function(widget)
        if ns.GroupInspect then ns.GroupInspect:SetActive(false) end
        AceGUI:Release(widget)
        frame = nil
    end)

    local tabs = AceGUI:Create("TabGroup")
    tabs:SetLayout("Fill")
    tabs:SetTabs({
        { text = "Guild Compliance", value = "guild" },
        { text = "Group Compliance", value = "group" },
    })
    tabs:SetCallback("OnGroupSelected", function(container, _, group)
        container:ReleaseChildren()
        local scroll = AceGUI:Create("ScrollFrame")
        scroll:SetLayout("List")
        container:AddChild(scroll)
        frame.scroll = scroll
        frame.activeTab = group
        -- Auto-inspect only while the Group tab is the one being viewed.
        if ns.GroupInspect then ns.GroupInspect:SetActive(group == "group") end
        rebuildActiveTab()
    end)
    frame:AddChild(tabs)

    -- Default to the Group tab when the player is actually in a group.
    tabs:SelectTab((ns.GroupInspect and ns.GroupInspect:InGroup()) and "group" or "guild")
end
