local ADDON, ns = ...
local Addon = ns.Addon

-- Two mutually-exclusive first-run windows, each built once and cached:
--   choiceFrame — "pick Relaxed or Authentic". Only meaningful when NOBODY has decided
--                 yet (ruleset epoch 0), which is the genuine first run for this guild
--                 (or this account, if guildless).
--   infoFrame   — read-only summary of the decision already in force. What an alt of an
--                 existing member/leader gets, since asking them to choose a mode is
--                 asking a question that has an answer: for a member it would only churn
--                 their personal challenges, and for the guild leader picking "Relaxed"
--                 silently overwrote the guild's whole enforcement config and broadcast
--                 it to every member.
local choiceFrame, infoFrame

-- Pixel dimensions — both panels use the exact same values.
local PANEL_W   = 270
local PANEL_H   = 230
local PANEL_GAP = 20

local INFO_W, INFO_H = 460, 350

local AUTHENTIC_RULES = { "instance", "gear", "profession", "quest", "rune", "runebroker" }

-- Display names for the enforcement rules, for the read-only summary. (UI/Options.lua
-- carries its own copy for the two option-table builders; see PROGRESS open items.)
local RULE_LABELS = {
    { key = "level",      name = "Level cap" },
    { key = "instance",   name = "Instance gating" },
    { key = "gear",       name = "Gear / items" },
    { key = "profession", name = "Profession skill cap" },
    { key = "quest",      name = "Quests" },
    { key = "rune",       name = "Runes" },
    { key = "runebroker", name = "Rune Broker blocked" },
}

-- Choosing a mode is just a shortcut that sets the underlying rules — "mode" itself
-- is derived from which rules are on (see Core.lua). Relaxed = level cap only;
-- Authentic = level cap + all authentic rules. A guild leader writes the guild
-- enforcement config and broadcasts it; everyone else sets their personal challenges.
local function applyMode(mode, frame)
    Addon.db.char.seenWelcome = true
    local wantAuthentic = (mode == "authentic")

    if Addon:IsGuildLeader() then
        local r = Addon:GetRuleset()
        r.mode = mode                 -- broadcast hint / display seed
        r.enforce.level = true        -- both modes track the level cap
        for _, rule in ipairs(AUTHENTIC_RULES) do
            r.enforce[rule] = wantAuthentic
        end
        Addon:CommitGuildSettings()   -- bump epoch + broadcast to the guild
    else
        local pc = Addon.db.profile.personalChallenges
        pc.level = true
        for _, rule in ipairs(AUTHENTIC_RULES) do
            pc[rule] = wantAuthentic
        end
        local e = Addon:GetModule("Enforcement", true)
        if e then e:FullScan() end
        if ns.RefreshOptions then ns.RefreshOptions() end
        -- Personal challenges are live immediately, but there may be no phase to
        -- enforce against yet (no officer broadcast received / guildless and no phase
        -- picked). RuleEnabled holds everything off until then; without a word here a
        -- level 60 either sees nothing happen, or — once the phase lands — a sudden
        -- wall of violations. Say which it is.
        if not Addon:RulesetKnown() then
            if IsInGuild() then
                Addon:Print("Your challenges are saved. Nothing is enforced yet — they start once an officer sets the guild's phase.")
            else
                Addon:Print("Your challenges are saved. Nothing is enforced yet — pick an Active phase in |cff00ff00/sodlock|r to start.")
            end
        end
    end
    frame:Hide()
    -- Keep the cached frame: nil'ing it made a later ShowWelcome build a SECOND frame
    -- under the same global name, orphaning the first and double-registering it in
    -- UISpecialFrames. Hiding is enough — seenWelcome stops it reopening.
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

local function buildChoiceFrame()
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
        Addon.db.char.seenWelcome = true
        f:Hide()
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
        "(accept dialog declined, quest abandoned if it slips in), and blocks engraving "  ..
        "later-phase runes onto gear.",
        "Play Authentic", "authentic", f)

    -- ── Officer / member notice ───────────────────────────────────────────────
    -- Text is filled in by refreshNotice() at SHOW time, not here: the frame is built
    -- once and cached, so baking the role in at construction leaves it wrong forever if
    -- the guild context resolved afterwards (see ns.ShowWelcome).
    local notice = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    notice:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  20, 22)
    notice:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 22)
    notice:SetJustifyH("CENTER")
    f.notice = notice

    choiceFrame = f
end

-- Which role blurb applies right now. Re-read on every show so a frame built before the
-- guild data landed can't keep claiming the wrong one.
local function refreshNotice(f)
    if not (f and f.notice) then return end
    if Addon:IsGuildLeader() then
        f.notice:SetText(
            "|cff00ff00You are the guild leader.|r Your selection sets the guild's " ..
            "enforcement config and is broadcast to all members.")
    else
        f.notice:SetText(
            "|cff888888You are a member.|r Your selection sets your personal challenges. " ..
            "The guild leader controls the guild-wide config and may add to this.")
    end
end

-- ---------------------------------------------------------------------------
-- Read-only summary window (shown instead of the mode choice once a ruleset exists)
-- ---------------------------------------------------------------------------
-- What is actually in force, rendered from the active ruleset bucket. `enforce` is the
-- GUILD's config; the mode line is the effective one (Addon:GetMode ORs in personal
-- challenges), so an alt carrying challenges from a shared profile reads honestly.
local function guildSetupText()
    local r    = Addon:GetRuleset()
    local data = Addon:GetPhaseData()
    local mode = Addon:GetMode()
    local out  = {}

    out[#out + 1] = string.format("|cffffd100Phase:|r %s  (level cap %d)",
        data and data.name or ("Phase " .. tostring(r.phase)), (data and data.levelCap) or 0)
    out[#out + 1] = string.format("|cffffd100Mode:|r %s",
        mode:sub(1, 1):upper() .. mode:sub(2))
    if r.nextPhaseDate and r.nextPhaseDate ~= "" then
        out[#out + 1] = string.format("|cffffd100Next phase unlocks:|r %s", r.nextPhaseDate)
    end

    local on = {}
    for _, rule in ipairs(RULE_LABELS) do
        if r.enforce[rule.key] then on[#on + 1] = rule.name end
    end
    if Addon:GuildFoundAny() then
        local gf, parts = r.guildFound, {}
        if gf.trade   then parts[#parts + 1] = "trade"   end
        if gf.mail    then parts[#parts + 1] = "mail"    end
        if gf.auction then parts[#parts + 1] = "auction" end
        on[#on + 1] = "Guild Found — closed economy (" .. table.concat(parts, ", ") .. ")"
    end

    out[#out + 1] = ""
    if #on == 0 then
        out[#out + 1] = "|cffffd100Enforced:|r |cff888888nothing yet.|r"
    else
        out[#out + 1] = "|cffffd100Enforced:|r"
        for _, name in ipairs(on) do
            out[#out + 1] = "  |cff00ff00\226\128\162|r " .. name
        end
    end
    return table.concat(out, "\n")
end

local function buildInfoFrame()
    local f = CreateFrame("Frame", "SoDPhaseLockGuildInfo", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(INFO_W, INFO_H)
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
    table.insert(UISpecialFrames, "SoDPhaseLockGuildInfo")

    local function dismiss()
        Addon.db.char.seenWelcome = true
        f:Hide()
    end

    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", f, "TOP", 0, -16)
    titleText:SetText("SoD Phase Lock")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", dismiss)

    local intro = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    intro:SetPoint("TOPLEFT",  f, "TOPLEFT",  22, -46)
    intro:SetPoint("TOPRIGHT", f, "TOPRIGHT", -22, -46)
    intro:SetJustifyH("LEFT")
    f.intro = intro

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT",     f, "TOPLEFT",     22, -108)
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 60)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    f.body = body

    local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ok:SetSize(140, 24)
    ok:SetPoint("BOTTOM", f, "BOTTOM", 0, 22)
    ok:SetText("Got it")
    ok:SetScript("OnClick", dismiss)

    infoFrame = f
end

-- ---------------------------------------------------------------------------
-- Show logic
-- ---------------------------------------------------------------------------
local showChoice, showInfo   -- forward declarations (showChoice can swap to showInfo)

-- While the choice window is up, watch for a ruleset landing late and swap. Comm's login
-- REQ retry runs out to ~45s, so a member on a quiet guild can be handed an answer after
-- we gave up waiting for one — and a question that has just been answered must stop being
-- asked, especially for the guild leader (see the choiceFrame/infoFrame note at the top).
local swapTicker
local function stopSwapWatch()
    if swapTicker then swapTicker:Cancel(); swapTicker = nil end
end

showInfo = function()
    stopSwapWatch()
    if not infoFrame then buildInfoFrame() end
    infoFrame.intro:SetText(IsInGuild()
        and ("Your guild has already set this up, so there is nothing to choose here — "
             .. "your character follows the settings below automatically.")
        or  ("You have already set this up on this account, so there is nothing to choose "
             .. "here — this character follows the settings below."))
    infoFrame.body:SetText(guildSetupText())
    infoFrame:Show()
end

showChoice = function()
    if not choiceFrame then buildChoiceFrame() end
    refreshNotice(choiceFrame)
    choiceFrame:Show()
    stopSwapWatch()
    if C_Timer and C_Timer.NewTicker then
        swapTicker = C_Timer.NewTicker(1, function()
            if Addon.db.char.seenWelcome or not (choiceFrame and choiceFrame:IsShown()) then
                stopSwapWatch()
            elseif Addon:RulesetKnown() then
                stopSwapWatch()
                choiceFrame:Hide()
                showInfo()
            end
        end)
    end
end

-- Is the state we branch on settled enough to pick a window? Core schedules this a second
-- after login, when IsInGuild()/GetGuildInfo("player") are routinely still false/nil — and
-- Addon:IsGuildLeader() reads `not IsInGuild()` as "solo, you own your own config", so an
-- ordinary guild member was told they were the guild leader (and a click in that window
-- pointed applyMode at the guildless "" ruleset bucket). In a guild we additionally wait
-- for the ruleset itself, since that is what decides choice-vs-summary.
local function welcomeReady()
    if not Addon:GuildContextReady() then return false end
    if IsInGuild() and not Addon:RulesetKnown() then return false end
    return true
end

-- Long enough to cover Comm's login REQ retry (25-45s) so a member on a quiet guild
-- usually gets the summary first time; the swap watch above covers the tail.
local WELCOME_RETRY   = 1
local WELCOME_TIMEOUT = 45

function ns.ShowWelcome(waited)
    if Addon.db.char.seenWelcome then return end
    waited = waited or 0
    if not welcomeReady() and waited < WELCOME_TIMEOUT then
        C_Timer.After(WELCOME_RETRY, function() ns.ShowWelcome(waited + WELCOME_RETRY) end)
        return
    end
    -- A ruleset exists ⇒ the decision is made; show it read-only. Only a genuine first run
    -- (epoch 0 — nobody has ever set a phase for this context) gets the mode choice.
    if Addon:RulesetKnown() then showInfo() else showChoice() end
end
