local ADDON, ns = ...
local Addon = ns.Addon
local AceGUI = LibStub("AceGUI-3.0")

local frame

-- Relative column widths; must sum to 1.0
-- Player | Lvl | Phase | Mode | Status | (kick)
local COL_W = { 0.24, 0.06, 0.09, 0.12, 0.34, 0.15 }

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

local function addHeader(parent)
    local grp = AceGUI:Create("SimpleGroup")
    grp:SetFullWidth(true)
    grp:SetLayout("Flow")
    local labels = { "Player", "Lvl", "Phase", "Mode", "Status", "" }
    for i, text in ipairs(labels) do
        local lbl = AceGUI:Create("Label")
        lbl:SetRelativeWidth(COL_W[i])
        lbl:SetText("|cffffd100" .. text .. "|r")
        grp:AddChild(lbl)
    end
    parent:AddChild(grp)
end

local function addDataRow(parent, cells, colorCode, playerName)
    local canKick = Addon:IsOfficer() and (playerName ~= UnitName("player"))

    local grp = AceGUI:Create("SimpleGroup")
    grp:SetFullWidth(true)
    grp:SetLayout("Flow")
    for i, text in ipairs(cells) do
        local lbl = AceGUI:Create("Label")
        lbl:SetRelativeWidth(COL_W[i])
        lbl:SetText(colorCode .. tostring(text) .. "|r")
        grp:AddChild(lbl)
    end

    local btn = AceGUI:Create("Button")
    btn:SetRelativeWidth(COL_W[6])
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

local function BuildRows()
    if not frame then return end
    local scroll = frame.scroll
    scroll:ReleaseChildren()

    local list = ns.Compliance and ns.Compliance:GetSorted() or {}
    if #list == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetText("\nNo reports yet. Guild members running this addon will appear here within a minute.")
        scroll:AddChild(lbl)
        return
    end

    local nViol = 0
    for _, e in ipairs(list) do
        if not e.info.compliant then nViol = nViol + 1 end
    end
    local nOK = #list - nViol

    addHeader(scroll)

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
        addDataRow(scroll, {
            e.name,
            tostring(i.level or "?"),
            "P" .. tostring(i.phase or "?"),
            i.mode or "?",
            i.reasons or "OK",
        }, color, e.name)
    end

    frame:SetStatusText(string.format(
        "%d out of compliance, %d compliant — reports every ~60s", nViol, nOK))
end

function ns.RefreshRoster()
    if frame then BuildRows() end
end

function ns.ToggleRoster()
    if frame then
        frame:Release()
        return
    end
    frame = AceGUI:Create("Frame")
    frame:SetTitle("SoD Phase Lock — Guild Compliance")
    frame:SetStatusText("Members report every ~60s")
    frame:SetLayout("Fill")
    frame:SetWidth(620)
    frame:SetHeight(440)
    frame:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
        frame = nil
    end)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    frame.scroll = scroll
    frame:AddChild(scroll)

    BuildRows()
end
