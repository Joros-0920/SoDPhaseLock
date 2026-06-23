local ADDON, ns = ...
local Addon = ns.Addon

local welcomeFrame

-- Pixel dimensions — both panels use the exact same values.
local PANEL_W   = 270
local PANEL_H   = 230
local PANEL_GAP = 20

local AUTHENTIC_RULES = { "instance", "gear", "profession", "quest", "rune", "runebroker" }

local function applyMode(mode, frame)
    Addon.db.profile.seenWelcome = true

    -- Mirror personal challenges to the chosen mode so the compliance roster
    -- reflects the player's real intent from the start.
    local wantAuthentic = (mode == "authentic")
    local pc = Addon.db.profile.personalChallenges
    for _, rule in ipairs(AUTHENTIC_RULES) do
        pc[rule] = wantAuthentic
    end

    if Addon:IsOfficer() then
        Addon:SetRulesetAsOfficer(Addon:GetActivePhase(), mode)
    else
        Addon.db.global.ruleset.mode = mode
        local e = Addon:GetModule("Enforcement", true)
        if e then e:FullScan() end
        if ns.RefreshOptions then ns.RefreshOptions() end
    end
    frame:Hide()
    welcomeFrame = nil
end

-- Build one mode panel (left or right). anchorPoint and anchorX place it.
local function makePanel(parent, anchorPoint, anchorX, title, desc, btnLabel, mode, frame)
    local p = CreateFrame("Frame", nil, parent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    p:SetSize(PANEL_W, PANEL_H)
    p:SetPoint(anchorPoint, parent, anchorPoint, anchorX, 0)
    if p.SetBackdrop then
        p:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        p:SetBackdropColor(0.05, 0.05, 0.15, 0.85)
        p:SetBackdropBorderColor(0.45, 0.45, 0.6, 1)
    end

    -- Title
    local hdr = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hdr:SetPoint("TOP", p, "TOP", 0, -12)
    hdr:SetText(title)

    -- Description — pinned top and bottom so it fills the panel body.
    local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT",     p, "TOPLEFT",     10, -34)
    lbl:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -10, 38)
    lbl:SetJustifyH("LEFT")
    lbl:SetJustifyV("TOP")
    lbl:SetText(desc)

    -- Button pinned to the bottom of the panel.
    local btn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    btn:SetSize(PANEL_W - 24, 22)
    btn:SetPoint("BOTTOM", p, "BOTTOM", 0, 8)
    btn:SetText(btnLabel)
    btn:SetScript("OnClick", function() applyMode(mode, frame) end)
end

local function buildWelcomeFrame()
    local totalW = PANEL_W * 2 + PANEL_GAP
    local frameW = totalW + 60   -- 30px border on each side

    local f = CreateFrame("Frame", "SoDPhaseLockWelcome", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(frameW, 420)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end

    -- Allow Escape to close.
    table.insert(UISpecialFrames, "SoDPhaseLockWelcome")

    -- Title bar
    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", f, "TOP", 0, -16)
    titleText:SetText("Welcome to SoD Phase Lock")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", function()
        Addon.db.profile.seenWelcome = true
        f:Hide()
        welcomeFrame = nil
    end)

    -- Intro text
    local intro = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    intro:SetPoint("TOPLEFT",  f, "TOPLEFT",  20, -44)
    intro:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -44)
    intro:SetJustifyH("LEFT")
    intro:SetText(
        "SoD Phase Lock keeps your guild synchronized to a Season of Discovery phase. " ..
        "Officers set the active phase; the addon detects violations and reports a " ..
        "live compliance roster.\n\nChoose how strictly it monitors your character:"
    )

    -- ── Two panels, identical size, centred in the frame ─────────────────────
    local panelRow = CreateFrame("Frame", nil, f)
    panelRow:SetSize(totalW, PANEL_H)
    panelRow:SetPoint("TOP", f, "TOP", 0, -140)

    makePanel(panelRow, "LEFT",  0,              "|cffffd100Relaxed|r",
        "Tracks the phase |cffffd100level cap|r only.\n\n" ..
        "Instances, gear, professions, quests, and runes stay freely accessible. " ..
        "A red X marks over-cap items in your bags as a reminder, but nothing is " ..
        "blocked or removed.\n\n" ..
        "Good for guilds that want loose coordination without strict enforcement.",
        "Play Relaxed", "relaxed", f)

    makePanel(panelRow, "RIGHT", 0,              "|cffffd100Authentic|r",
        "Full |cffffd100phase enforcement|r.\n\n" ..
        "Blocks phase-gated instances. Over-phase gear is flagged and auto-removed " ..
        "out of combat; bind-on-equip prompts are cancelled before the item binds. " ..
        "Enforces profession skill caps, blocks quests from future phases " ..
        "(accept dialog declined, quest abandoned if it slips in), and flags later-phase runes.",
        "Play Authentic", "authentic", f)

    -- ── Officer / member notice ───────────────────────────────────────────────
    local noticeText
    if Addon:IsOfficer() then
        noticeText =
            "|cff00ff00You are an officer.|r Your selection will be set as the " ..
            "guild's active mode and broadcast to all members."
    else
        noticeText =
            "|cff888888You are a member.|r Your selection sets your local enforcement " ..
            "mode. Officers control the guild-wide setting and may override this."
    end
    local notice = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    notice:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  20, 22)
    notice:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 22)
    notice:SetJustifyH("CENTER")
    notice:SetText(noticeText)

    welcomeFrame = f
end

function ns.ShowWelcome()
    if Addon.db.profile.seenWelcome then return end
    if not welcomeFrame then buildWelcomeFrame() end
    welcomeFrame:Show()
end
