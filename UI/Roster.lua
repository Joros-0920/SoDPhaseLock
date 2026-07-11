local ADDON, ns = ...
local Addon = ns.Addon
local AceGUI = LibStub("AceGUI-3.0")

local frame

-- Relative column widths; each set must sum to ~1.0
-- Guild: Player | Lvl | Phase | Mode | XP | Ver | Status | (audit) | (clear) | (kick)
-- Sum kept a touch under 1.0 so the extra (10th) cell's Flow spacing can't wrap the
-- trailing buttons onto a second line.
local GUILD_COL_W = { 0.165, 0.05, 0.05, 0.07, 0.06, 0.065, 0.19, 0.10, 0.10, 0.10 }
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

-- Officer-only clear of a member's saved integrity flag(s) — Guild Found tamper,
-- "addon not detected", and/or a played-without-addon gap. The clear syncs to the
-- whole guild (see Compliance:OfficerClear), so the record is dismissed everywhere
-- — a played gap is forgiven (the member's counter resets), the others until the
-- member is next caught.
StaticPopupDialogs["SODPHASELOCK_GFCLEAR_CONFIRM"] = {
    text = "Clear the saved flag(s) on %s?\n\nThe record is dismissed guild-wide: a played-without-addon gap is forgiven (their counter resets), other flags return only if they are next caught (Guild Found disabled locally, or online with no addon).",
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function(self, data)
        if ns.Compliance and ns.Compliance.OfficerClear then
            ns.Compliance:OfficerClear(data)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Guild Found wealth "Audit" window: itemises the gold and items a member's status
-- ping reported as having moved while their addon was off (Modules/Integrity.lua).
-- The item IDs ride the ping as `wl` and are stored on the roster row as `wealthLog`;
-- money as `wealthMoney`. Opened from the officer/self "Audit" button on a flagged row.
-- ---------------------------------------------------------------------------
local auditFrame
local auditPlayer

-- Full-width note line (local copy so the audit window, defined above the shared
-- addNote helper, doesn't depend on its declaration order).
local function addNoteInline(parent, text)
    local lbl = AceGUI:Create("Label")
    lbl:SetFullWidth(true)
    lbl:SetText(text)
    parent:AddChild(lbl)
end

-- Signed copper → readable money. Uses Blizzard's coin-icon string when present.
local function fmtAuditMoney(copper)
    copper = copper or 0
    if copper == 0 then return "|cff808080none|r" end
    local sign = (copper < 0) and "-" or "+"
    local abs  = math.abs(copper)
    local body = (GetCoinTextureString and GetCoinTextureString(abs))
                 or (string.format("%dg", math.floor(abs / 10000)))
    return sign .. " " .. body
end

local function ShowAudit(playerName, isRetry)
    auditPlayer = playerName
    if auditFrame then auditFrame:Release() end
    auditFrame = AceGUI:Create("Frame")
    auditFrame:SetTitle("Audit — " .. tostring(playerName))
    auditFrame:SetStatusText("Gold and items reported")
    auditFrame:SetWidth(360)
    auditFrame:SetHeight(360)
    auditFrame:SetLayout("Fill")
    auditFrame:EnableResize(false)
    auditFrame:SetCallback("OnClose", function(w)
        AceGUI:Release(w)
        if auditFrame == w then auditFrame = nil end
    end)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    auditFrame:AddChild(scroll)

    local info = ns.Compliance and ns.Compliance.roster and ns.Compliance.roster[playerName]
    if not info then
        addNoteInline(scroll, "No current report for this member (they may have logged off or been cleared).")
        return
    end

    local money = AceGUI:Create("Label")
    money:SetFullWidth(true)
    money:SetText("|cffffd100Gold moved:|r " .. fmtAuditMoney(info.wealthMoney))
    scroll:AddChild(money)

    local count = info.wealthItems or 0
    local hdr = AceGUI:Create("Label")
    hdr:SetFullWidth(true)
    hdr:SetText(string.format("\n|cffffd100Items gained while addon off: %d|r", count))
    scroll:AddChild(hdr)

    local log = info.wealthLog or {}
    if #log == 0 then
        addNoteInline(scroll, (count > 0)
            and "|cff808080The specific item IDs weren't included in the report.|r"
            or  "|cff808080No items reported.|r")
    else
        local anyUncached = false
        for _, id in ipairs(log) do
            local name, link, _, _, _, _, _, _, _, tex = GetItemInfo(id)
            if not link then anyUncached = true end
            local row = AceGUI:Create("InteractiveLabel")
            row:SetFullWidth(true)
            row:SetText(link or string.format("|cffffffffItem #%s (loading…)|r", tostring(id)))
            if tex then row:SetImage(tex) end
            row:SetCallback("OnEnter", function(widget)
                GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("item:" .. tostring(id))
                GameTooltip:Show()
            end)
            row:SetCallback("OnLeave", function() GameTooltip:Hide() end)
            scroll:AddChild(row)
        end
        if count > #log then
            addNoteInline(scroll, string.format(
                "|cff808080…and %d more item(s) not individually listed (the report caps the list).|r", count - #log))
        end
        -- Item names/textures resolve asynchronously; rebuild once if any weren't cached.
        if anyUncached and not isRetry and C_Timer and C_Timer.After then
            C_Timer.After(0.6, function()
                if auditFrame and auditPlayer == playerName then ShowAudit(playerName, true) end
            end)
        end
    end
end

-- A reported addon version for the "Ver" column. Peers on a pre-version build (or
-- yet to report one) send nil / "0"; show a grey dash rather than a bogus "v0".
local function versionCell(v)
    if not v or v == "0" or v == "" then return "|cff808080—|r" end
    return "v" .. tostring(v)
end

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

-- Guild data row: labels + an Audit button (officer or self, only when the member has
-- reported off-radar wealth), a Clear button (officer-only, only for a flagged member),
-- and a Kick button (officer-only) as the trailing columns.
local function addGuildRow(parent, cells, colorCode, playerName, flagged, auditable)
    local isSelf   = (playerName == UnitName("player"))
    local officer  = Addon:IsOfficer()
    local canKick  = officer and not isSelf
    -- Clear is allowed on yourself: the "can't self-clear" rule is about untrusted
    -- MEMBERS (who never get this button), not officers — an officer clearing their own
    -- stale flag is legitimate. OfficerClear only gates on the caller being an officer,
    -- and its clear/forgive syncs guild-wide for self exactly as for anyone else.
    local canClear = officer and flagged
    -- Audit just reads data already broadcast to everyone; show it to officers (judging
    -- any member) and to the member themselves (understanding their own flag).
    local canAudit = auditable and (officer or isSelf)

    local grp = AceGUI:Create("SimpleGroup")
    grp:SetFullWidth(true)
    grp:SetLayout("Flow")
    for i, text in ipairs(cells) do
        addCell(grp, text, GUILD_COL_W[i], colorCode)
    end

    -- The three trailing button columns are always the last three widths, so the data
    -- cells above can grow/shrink without re-indexing these.
    local auditW = GUILD_COL_W[#GUILD_COL_W - 2]
    local clearW = GUILD_COL_W[#GUILD_COL_W - 1]
    local kickW  = GUILD_COL_W[#GUILD_COL_W]

    -- Audit column: a button when the member has reported off-radar wealth, else a spacer.
    if canAudit then
        local aud = AceGUI:Create("Button")
        aud:SetRelativeWidth(auditW)
        aud:SetText("Audit")
        aud:SetCallback("OnClick", function() ShowAudit(playerName) end)
        grp:AddChild(aud)
    else
        addCell(grp, "", auditW, colorCode)
    end

    -- Clear column: an officer-only button on a flagged row, otherwise an empty
    -- spacer of the same width so every row's columns stay aligned.
    if canClear then
        local clr = AceGUI:Create("Button")
        clr:SetRelativeWidth(clearW)
        clr:SetText("Clear")
        clr:SetCallback("OnClick", function()
            StaticPopup_Show("SODPHASELOCK_GFCLEAR_CONFIRM", playerName, nil, playerName)
        end)
        grp:AddChild(clr)
    else
        addCell(grp, "", clearW, colorCode)
    end

    local btn = AceGUI:Create("Button")
    btn:SetRelativeWidth(kickW)
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
-- Cap on names listed in the "Addon Not Detected" section, so a low-adoption or
-- huge guild can't render a wall of rows. Extra members collapse to a count.
local NOT_DETECTED_CAP = 25

local function BuildGuildRows(scroll)
    local list = ns.Compliance and ns.Compliance:GetSorted() or {}
    -- Integrity view ("Addon Not Detected") is officer-only.
    local unreported = (Addon:IsOfficer() and ns.Compliance and ns.Compliance:GetIntegrityRows()) or {}

    if #list == 0 and #unreported == 0 then
        addNote(scroll, "\nNo reports yet. Guild members running this addon will appear here within a minute.")
        return
    end

    local nViol = 0
    for _, e in ipairs(list) do
        if not e.info.compliant then nViol = nViol + 1 end
    end
    local nOK = #list - nViol

    addHeader(scroll, { "Player", "Lvl", "Phase", "Mode", "XP", "Ver", "Status", "", "", "" }, GUILD_COL_W)

    if #list > 0 then
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
                versionCell(i.version),
                i.reasons or "OK",
            }, color, e.name, ns.Compliance and
                (ns.Compliance:IsFlagged(e.name) or ns.Compliance:HasPlayedGap(e.name)
                 or ns.Compliance:HasWealthGap(e.name)),
                ns.Compliance and ns.Compliance:HasWealthGap(e.name))
        end
    end

    -- Integrity: guildmates not reporting in. Orange, kept visually distinct from
    -- red rule-violations — non-participation is an accountability signal, not a
    -- measured violation, and can't be told apart from "hasn't installed it yet".
    -- Includes online members with no fresh ping AND saved "addon not detected"
    -- records (which persist after the member logs off, until an officer clears them).
    if #unreported > 0 then
        addSep(scroll, string.format("|cffff8000Addon Not Detected (%d)|r", #unreported))
        addNote(scroll, "|cff808080Guild members with no recent status ping — the addon is off, not installed, or blocking guild sync. A member seen online without pinging for a sustained period is saved here (marked \"saved\") so the record survives their logout; clear it with the Clear button or /sodlock clearflag. Best-effort only: a modified addon can still report in. Allow a minute after someone logs in.|r")
        for idx, r in ipairs(unreported) do
            if idx > NOT_DETECTED_CAP then
                addNote(scroll, string.format("|cff808080…and %d more member(s) not detected.|r", #unreported - NOT_DETECTED_CAP))
                break
            end
            local statusText
            if r.saved then
                statusText = r.online and "|cffff8000Addon not detected (saved)|r"
                                       or  "|cffff8000Addon not detected (saved, offline)|r"
            else
                statusText = "|cffff8000Addon not detected|r"
            end
            addGuildRow(scroll, {
                r.name, "—", "—", "—", "—", "—", statusText,
            }, "|cffff8000", r.name, r.saved)
        end
    end

    if frame then
        local interval = math.floor((ns.Comm and ns.Comm.StatusInterval and ns.Comm:StatusInterval()) or 60)
        local extra = (#unreported > 0) and string.format(", %d not detected", #unreported) or ""
        frame:SetStatusText(string.format(
            "%d out of compliance, %d compliant%s — reports every ~%ds", nViol, nOK, extra, interval))
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
-- Preserve scroll position across a rebuild. A rebuild releases + re-adds every
-- row; during the relayout the momentarily-short content makes the ScrollFrame
-- hide its scrollbar and SetValue(0), which zeroes the stored offset — so the
-- list snaps to the top. We capture the scroll value before rebuilding and
-- restore it once layout has settled (SetScroll / FixScroll are inverse via the
-- offset, so a restore at final height is stable). Without this, a status ping
-- from any guildmate (~every heartbeat) would yank the list up mid-read.
local function scrollValue(scroll)
    local status = scroll and (scroll.status or scroll.localstatus)
    return (status and status.scrollvalue) or 0
end

local function restoreScroll(scroll, value)
    if not (scroll and value and value > 0) then return end
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(0, function()
        -- Bail if the window closed or the tab was swapped out meanwhile.
        if not (frame and frame.scroll == scroll and scroll.frame) then return end
        scroll:SetScroll(value)
        if scroll.scrollbar then scroll.scrollbar:SetValue(value) end
    end)
end

-- Signature of the data that is actually visible on the active tab. A status ping
-- arrives roughly every heartbeat, but the vast majority don't change anything on
-- screen (same level / phase / status), so rebuilding on every one just makes the
-- list flicker. We compare this signature and skip the teardown when it's
-- unchanged, so a rebuild (and its momentary flicker) only happens on a real
-- change. \1 separates fields, \2 separates rows — neither appears in the data.
local function contentSignature()
    if not frame then return "" end
    local parts = {}
    if frame.activeTab == "group" then
        local GI = ns.GroupInspect
        parts[#parts + 1] = "grp"
        parts[#parts + 1] = (GI and GI:InGroup()) and "1" or "0"
        parts[#parts + 1] = (GI and GI:IsScanning()) and "s" or ""
        local list = (GI and GI:GetResults()) or {}
        for _, e in ipairs(list) do
            local i = e.info
            parts[#parts + 1] = table.concat({
                e.name, tostring(i.level or "?"), tostring(i.class or "?"),
                i.scanned and "1" or "0", i.compliant and "1" or "0",
                i.reasons or "",
            }, "\1")
        end
    else
        parts[#parts + 1] = "gld"
        local list = (ns.Compliance and ns.Compliance:GetSorted()) or {}
        for _, e in ipairs(list) do
            local i = e.info
            parts[#parts + 1] = table.concat({
                e.name, tostring(i.level or "?"), tostring(i.phase or "?"),
                tostring(i.mode or "?"), i.xpLocked and "1" or "0",
                tostring(i.version or ""),
                i.compliant and "1" or "0", i.reasons or "",
            }, "\1")
        end
        -- Presence of the "not detected" set feeds the view too, so a member
        -- dropping off (or coming back) rebuilds the roster. Officer-only, to match
        -- the display path above.
        local unreported = (Addon:IsOfficer() and ns.Compliance and ns.Compliance:GetIntegrityRows()) or {}
        parts[#parts + 1] = "u"
        -- Fold each row's online/saved state in so a change (a member logging off, a
        -- flag being saved or cleared) rebuilds the section and its Clear buttons.
        for _, r in ipairs(unreported) do
            parts[#parts + 1] = r.name .. (r.online and "O" or "o") .. (r.saved and "S" or "s")
        end
    end
    return table.concat(parts, "\2")
end

local function rebuildActiveTab(force)
    if not (frame and frame.scroll) then return end
    local sig = contentSignature()
    if not force and sig == frame.lastSig then return end   -- nothing visible changed
    local scroll = frame.scroll
    local prev = scrollValue(scroll)
    scroll:ReleaseChildren()
    if frame.activeTab == "group" then
        BuildGroupRows(scroll)
    else
        BuildGuildRows(scroll)
    end
    frame.lastSig = sig
    restoreScroll(scroll, prev)
end

-- Coalesce bursts of refresh requests (e.g. many guildmates reporting at once)
-- into a single rebuild, so a ping storm can't rebuild the list many times a
-- second. Combined with the signature check above, a steady stream of unchanged
-- pings produces no rebuilds at all.
function ns.RefreshRoster()
    if not frame then return end
    if not (C_Timer and C_Timer.After) then rebuildActiveTab(); return end
    if frame.refreshPending then return end
    frame.refreshPending = true
    C_Timer.After(0.2, function()
        if not frame then return end
        frame.refreshPending = false
        rebuildActiveTab()
    end)
end

function ns.ToggleRoster()
    if frame then
        frame:Release()
        return
    end
    frame = AceGUI:Create("Frame")
    frame:SetTitle("SoD Phase Lock — Compliance")
    frame:SetLayout("Fill")
    frame:SetWidth(820)
    frame:SetHeight(440)
    -- Non-resizable on purpose. Our rows are Flow-layout Labels whose height
    -- depends on width (long, color-coded status text wraps), so a live
    -- drag-resize drives the AceGUI ScrollFrame into a scrollbar show/hide
    -- oscillation: each toggle shifts content.width by 20px, re-wraps every row,
    -- re-runs DoLayout, and re-fires OnSizeChanged — a per-frame relayout loop
    -- that freezes/crashes the client. Hiding the sizer handles removes the
    -- vector entirely; the fixed 820×440 window scrolls its content instead.
    frame:EnableResize(false)
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
        frame.activeTab = group
        local scroll = AceGUI:Create("ScrollFrame")
        scroll:SetLayout("List")
        container:AddChild(scroll)
        frame.scroll = scroll
        -- Auto-inspect only while the Group tab is the one being viewed.
        if ns.GroupInspect then ns.GroupInspect:SetActive(group == "group") end
        rebuildActiveTab(true)   -- fresh scroll frame — always build
    end)
    frame:AddChild(tabs)

    -- Default to the Group tab when the player is actually in a group.
    tabs:SelectTab((ns.GroupInspect and ns.GroupInspect:InGroup()) and "group" or "guild")
end
