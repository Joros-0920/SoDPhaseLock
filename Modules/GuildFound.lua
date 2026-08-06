local ADDON, ns = ...
local Addon = ns.Addon
local GuildFound = Addon:NewModule("GuildFound", "AceEvent-3.0")
ns.GuildFound = GuildFound

-- ---------------------------------------------------------------------------
-- "Guild Found" — an optional closed-economy policy set by the guild leader and
-- synced to all members (rides on the ruleset, see Core.lua Addon:GuildFound()).
-- Each restriction is an independent toggle:
--   trade   — trades with fellow guild members are unrestricted; trades with anyone
--             outside your guild (or any trade at all if you have no guild) may carry
--             only allowlisted items and never gold, and enchant/lockpick services
--             (an item in the "will not be traded" slot) are blocked too. See
--             UI/TradeExceptions.lua.
--   mail    — may only send mail to fellow guild members; mail received from anyone
--             outside your guild is locked (can't be opened or looted)
--   auction — may not use the Auction House
-- Enforcement is best-effort client-side (the addon's honor-system model): outbound
-- actions are hard-blocked by cancelling/closing the relevant window (or aborting
-- the global), inbound mail is warned about only. See PROGRESS.md → integrity model.
-- ---------------------------------------------------------------------------

-- A restriction is live only when the local master switch is on AND the guild has
-- that specific toggle enabled. When not in a guild, guildFound reads the "" bucket
-- (all false), so none of the handlers below ever fire for a solo player.
local function active(key)
    return Addon.db.profile.enabled and Addon:GuildFound(key)
end

-- Is `name` a member of our guild? Reuses the roster walk + short-name match in
-- Core.lua (returns nil for non-members and for anyone when we're guildless).
local function isGuildmate(name)
    if not name or name == "" then return false end
    return Addon:GetGuildRankIndex(name) ~= nil
end

-- Turn a localized format-string global (e.g. BIND_TRADE_TIME_REMAINING, an
-- AUCTION_*_MAIL_SUBJECT) into a Lua search pattern: escape the pattern-magic chars and
-- turn each format specifier (%s, %d, positional %1$s, ...) into a wildcard. Matching the
-- result against localized game text is then locale-correct on ANY client, because the
-- pattern is derived from the same localized global the client rendered the text from.
-- This is the project's canonical way to read game strings — never hardcode enUS literals.
local function globalStringPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    return fmt
        :gsub("%%[%d%$]*%a", "\1")                    -- format specifiers -> sentinel
        :gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0")    -- escape pattern magic
        :gsub("\1", ".-")                             -- sentinel -> wildcard
end

-- Is the inbox mail at `index` Auction House mail? Always blocked when the mail rule is
-- active (sale proceeds, won auctions, outbid/expired/cancelled returns) — with the AH
-- disabled we never want any path to open AH mail. The sender NAME is localized free text
-- ("Alliance Auction House" enUS, "Auktionshaus" deDE, ...), so a literal match only works
-- on enUS. Detect it locale-independently instead:
--   1. GetInboxInvoiceInfo returns a non-nil invoiceType for buyer/seller AH mail
--      (sold & won) — pure data, no locale involved.
--   2. The rest (expired / outbid / cancelled) is matched by subject against the
--      AUCTION_*_MAIL_SUBJECT globals, which ARE localized, so patterns built from them
--      match on any client.
--   3. enUS sender literal as a last-resort fallback (covers a build missing the globals).
local ahSubjectPatterns
local function auctionSubjectPatterns()
    if ahSubjectPatterns then return ahSubjectPatterns end
    ahSubjectPatterns = {}
    for _, g in ipairs({
        "AUCTION_SOLD_MAIL_SUBJECT", "AUCTION_EXPIRED_MAIL_SUBJECT",
        "AUCTION_OUTBID_MAIL_SUBJECT", "AUCTION_WON_MAIL_SUBJECT",
        "AUCTION_REMOVED_MAIL_SUBJECT",
    }) do
        local pat = globalStringPattern(_G[g])
        if pat then ahSubjectPatterns[#ahSubjectPatterns + 1] = "^" .. pat end
    end
    return ahSubjectPatterns
end

local function isAuctionHouseMail(index)
    if GetInboxInvoiceInfo then
        local invoiceType = GetInboxInvoiceInfo(index)
        if invoiceType and invoiceType ~= "" then return true end
    end
    local _, _, sender, subject = GetInboxHeaderInfo(index)
    if subject then
        for _, pat in ipairs(auctionSubjectPatterns()) do
            if subject:find(pat) then return true end
        end
    end
    if sender and sender:find("Auction House", 1, true) then return true end  -- enUS fallback
    return false
end

-- Is the inbox mail at `index` blocked by the closed-economy rule?
--   * Auction House mail is ALWAYS blocked when the rule is active (see above).
--   * Otherwise only player-to-player mail from a non-guildmate is blocked. Ordinary
--     NPC/system/quest mail is exempt: some of it carries a sender name (quest rewards,
--     vendor buyback), so a name check alone would wrongly trap it. GetInboxHeaderInfo's
--     `canReply` (field 12) is truthy only for real player mail — the reliable
--     player-vs-NPC discriminator.
local function mailFromOutsider(index)
    if not index then return false end
    if isAuctionHouseMail(index) then return true end
    local _, _, sender, _, _, _, _, _, _, _, _, canReply = GetInboxHeaderInfo(index)
    if not canReply then return false end
    return sender ~= nil and not isGuildmate(sender)
end

-- Can this inbox mail be returned to its sender? Only replyable player mail has a valid
-- return recipient — AH/system mail (which we still block) can't be returned, so its
-- "Return" button must be hidden. `canReply` (field 12) is that signal.
local function mailReturnable(index)
    if not index then return false end
    local canReply = select(12, GetInboxHeaderInfo(index))
    return canReply and true or false
end

-- Up to 6 tradeable slots per side. The 7th "will not be traded" slot never
-- transfers an item, but it IS how an enchant or lockpick is cast on a partner's
-- item — a service across the guild boundary, so under the trade rule it's blocked
-- too (an item parked there with a non-guildmate can't complete the trade).
local TRADE_ITEM_SLOTS = 6
local TRADE_SERVICE_SLOT = 7

-- Conjured items (mage food/water, healthstones, soulstones, …) aren't exposed by
-- GetItemInfo, but they carry the "Conjured Item" line (ITEM_CONJURED) in their
-- tooltip. Scan a private hidden tooltip for it. Items in a trade are in the
-- player's possession, so their tooltip data is cached and resolves synchronously.
local scanTip
local function ensureScanTip()
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "SoDPLGuildFoundScanTip", nil, "GameTooltipTemplate")
    end
    -- Re-own on EVERY scan, not once at creation. A GameTooltip is reset when it hides,
    -- and this frame is shared between the conjured (SetHyperlink) and trade-window
    -- (SetTradePlayerItem/SetTradeTargetItem) scans — an ownerless tooltip's Set* methods
    -- silently populate nothing, which reads as "no BIND_TRADE line" and blocks a drop
    -- that is still inside its group-loot trade window. Enforcement.lua and Options.lua
    -- already re-own per scan; this one didn't. Also clears the previous scan's lines, so
    -- a failed Set* can never be read as the *previous* item's answer.
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    return scanTip
end

-- Left text of scan-tooltip line `i`, or nil.
local function scanLine(i)
    local fs = _G["SoDPLGuildFoundScanTipTextLeft" .. i]
    return fs and fs:GetText()
end

local function isConjuredLink(link)
    if not link or not ITEM_CONJURED then return false end
    local tip = ensureScanTip()
    tip:SetHyperlink(link)
    local lines = tip:NumLines()
    for i = 2, lines do
        if scanLine(i) == ITEM_CONJURED then return true end
    end
    -- Items the trade PARTNER added may not be cached on our client, so the tooltip
    -- comes back empty (a real item tooltip always has a name line + more). We can't
    -- tell it's conjured yet, so it fails safe as "not conjured" → blocked for now;
    -- warm the cache with GetItemInfo (fires GET_ITEM_INFO_RECEIVED → re-EvaluateTrade)
    -- so the decision is corrected once the data arrives, rather than spuriously stuck.
    if lines < 2 and GetItemInfo then GetItemInfo(link) end
    return false
end

-- Items still inside their group-loot trade window (bind-on-pickup drops that may be
-- traded to players who were also eligible to loot them, for ~2h) carry the
-- BIND_TRADE_TIME_REMAINING line ("You may trade this item with players that were also
-- eligible to loot this item for the next %s"). That timer is INSTANCE state, not part
-- of the item link, so — unlike the conjured check — we must scan the live trade SLOT
-- (SetTradePlayerItem/SetTradeTargetItem), not a hyperlink. Build a Lua pattern from the
-- format string once: escape its magic chars, turn the %s placeholder into a wildcard,
-- so the match is locale-correct.
local bindTradePattern = globalStringPattern(BIND_TRADE_TIME_REMAINING)

-- Is the item in trade slot `index` on `side` ("player"/"target") still tradeable via
-- its group-loot window? Scans that slot's tooltip for the BIND_TRADE line.
--   true  — the line is there, the item is still inside its window
--   false — the tooltip was read and carries no such line
--   nil   — UNKNOWN: the slot's tooltip could not be read yet (the partner's item is
--           not cached on our client, so it comes back with no lines). Callers must
--           fail SAFE on nil (treat as blocked) and warm the cache so the verdict is
--           retried on GET_ITEM_INFO_RECEIVED, rather than latching a wrong "no".
local function slotInTradeWindow(side, index)
    if not bindTradePattern then return false end
    local tip = ensureScanTip()
    local setter = (side == "player") and tip.SetTradePlayerItem or tip.SetTradeTargetItem
    if not setter then return false end
    if not pcall(setter, tip, index) then return nil end
    local lines = tip:NumLines() or 0
    if lines < 2 then return nil end       -- a real item tooltip always has a name line + more
    for i = 2, lines do
        local t = scanLine(i)
        if t and t:find(bindTradePattern) then return true end
    end
    return false
end

-- Server-authoritative companion to the tooltip scan above. In trade slots
-- 1..TRADE_ITEM_SLOTS the server refuses an item that has already bound, so a
-- BIND_ON_PICKUP item that IS sitting in one can only have got there via its group-loot
-- trade window — the server already made that ruling for us. bindType is static item
-- data (GetItemInfo field 14): no tooltip, no instance state, no localized string. That
-- is what makes it reliable on the TARGET's side, where the BIND_TRADE timer line is
-- instance state our client may never be sent — in which case slotInTradeWindow reads a
-- perfectly well-formed tooltip, finds no timer line, and returns a confident, wrong
-- `false` (not nil), latching the block for the life of the window.
--
-- LOAD-BEARING: this is only sound because the service slot (TRADE_SERVICE_SLOT) is
-- rejected by tradeHasBlockedContent BEFORE the slot loop, and that loop stops at
-- TRADE_ITEM_SLOTS. Slot 7 legitimately holds SOULBOUND items (enchant/lockpick
-- service), so routing it through here would exempt bound gear. If the service-slot
-- rule is ever relaxed, this must take the slot index and refuse slot 7 itself.
--
--   true / false — bindType known
--   nil          — uncached; caller must fail SAFE and warm, as with the tooltip path
local BIND_ON_PICKUP = 1
local function linkIsBindOnPickup(link)
    if not link or not GetItemInfo then return nil end
    local bindType = select(14, GetItemInfo(link))
    if bindType == nil then return nil end
    return bindType == BIND_ON_PICKUP
end

-- Inspect the live trade window. Returns true (+ a reason key) if it holds anything
-- that may NOT be traded outside the guild: any gold on either side, or any item
-- (either side) that is neither on the allowlist nor an allowed conjured item. Both
-- sides are checked because receiving gold from a non-guildmate is a transfer too.
local function linkNotAllowed(link, ex, side, index)
    if not link then return false end
    local id = tonumber(link:match("item:(%d+)"))
    if id and ex[id] then return false end                                  -- on the allowlist
    if Addon:GuildFound("allowConjured") and isConjuredLink(link) then       -- conjured & permitted
        return false
    end
    -- Still tradeable via its group-loot window & that exemption is on. TWO independent
    -- signals, OR'd, either of which exempts:
    --   1. the item's static bind type — sound on both sides, since the server won't let a
    --      bound item into slots 1..TRADE_ITEM_SLOTS at all (see linkIsBindOnPickup);
    --   2. the slot tooltip's BIND_TRADE timer line — more precise (it names *this* item
    --      instance), but only available when our client actually holds the partner's
    --      instance state, which for the TARGET's side it often does not.
    -- (2) alone used to be the whole test, which made receiving a pug drop from a
    -- non-addon player fail whenever their item rendered without the timer line.
    -- An UNKNOWN bind type stays blocked — fail safe — but warms the item cache so
    -- GET_ITEM_INFO_RECEIVED re-runs EvaluateTrade and the block lifts once the partner's
    -- item data arrives, instead of being stuck for the life of the window.
    if side and Addon:GuildFound("allowTradeWindow") then
        local bop = linkIsBindOnPickup(link)
        if bop then return false end
        if slotInTradeWindow(side, index) then return false end
        if bop == nil and GetItemInfo then GetItemInfo(link) end
    end
    return true
end

local function tradeHasBlockedContent()
    if (GetPlayerTradeMoney() or 0) > 0 or (GetTargetTradeMoney() or 0) > 0 then
        return true, "gold"
    end
    -- Enchant / lockpicking service: an item parked in either side's "will not be
    -- traded" slot is a service performed across the guild boundary, so block it. The
    -- allowlist governs items that *cross* the boundary; a service item never does, so
    -- it isn't exempted by the allowlist or the conjured toggle.
    if (GetTradePlayerItemLink and GetTradePlayerItemLink(TRADE_SERVICE_SLOT))
       or (GetTradeTargetItemLink and GetTradeTargetItemLink(TRADE_SERVICE_SLOT)) then
        return true, "service"
    end
    local ex = Addon:GetRuleset().guildFound.tradeExceptions
    for i = 1, TRADE_ITEM_SLOTS do
        -- Check each side independently — never build {mine, theirs}, since a nil in
        -- the first slot would truncate an ipairs walk and skip the other side.
        if GetTradePlayerItemLink and linkNotAllowed(GetTradePlayerItemLink(i), ex, "player", i) then return true, "item" end
        if GetTradeTargetItemLink and linkNotAllowed(GetTradeTargetItemLink(i), ex, "target", i) then return true, "item" end
    end
    return false
end

-- Block bulk-mail addons (Postal "OpenAll", OpenAllMail, MailboxExplorer, ...) from
-- pulling gold/items out of an outsider's mail. They have no private server channel —
-- an "open all" feature drives the very same extraction globals the default UI does —
-- so wrapping these three is what actually stops them, per-mail via mailFromOutsider.
--
-- Re-asserted on every MAIL_SHOW (not just once at load): if a mail addon loaded after
-- us and *replaced* one of these globals, this re-wraps over its version so we're the
-- outermost check at the moment the inbox is used (and its behaviour still runs, as our
-- captured `orig`, for guildmate mail). The marker set keeps it idempotent — we only
-- re-wrap when something has displaced us, never our own wrapper, so no chain growth on
-- a normal open. Residual gap (best-effort, unpreventable): an addon that upvalue-cached
-- the raw function at load and calls that local directly bypasses us — accepted under
-- the honor-system integrity model (see PROGRESS.md).
-- Set of wrapper fns WE installed, so re-running an installer is a no-op on our own work and
-- only re-wraps when something else has displaced us — no chain growth on a normal open.
local ourWraps = {}

-- Wrap `tbl[name]` so that `guard(...)` returning true ABORTS the call. Idempotent via ourWraps;
-- calling it again after another addon has replaced the function puts us back on the outside,
-- with that addon's version preserved as our captured `orig` so its behaviour still runs for
-- permitted actions. Missing functions are skipped, so this is safe across client builds.
local function installGuard(tbl, name, guard)
    local cur = tbl[name]
    if not cur or ourWraps[cur] then return end
    local orig = cur
    local wrapped = function(...)
        if guard(...) then return end
        return orig(...)
    end
    ourWraps[wrapped] = true
    tbl[name] = wrapped
end

local TAKE_FNS = { "TakeInboxItem", "TakeInboxMoney", "AutoLootMailItem" }
local function installMailTakeGuards()
    for _, name in ipairs(TAKE_FNS) do
        installGuard(_G, name, function(index)
            if active("mail") and mailFromOutsider(index) then
                Addon:Alert("You can't take anything from mail sent by someone outside your guild.", "guildfound-inbox-open")
                return true
            end
            return false
        end)
    end
end

-- Trade completion. AcceptTrade is a plain global, and this is THE enforcement point — we never
-- force the window shut, so a player can still open a trade and exchange allowlisted items (and a
-- solo player with no guild is governed entirely by their own allowlist). Re-asserted rather than
-- installed once: a trade-log or auto-trade addon that loads after us and replaces the global
-- would otherwise silently remove the hard backstop, leaving only the disabled Trade button,
-- which is cosmetic. Same reasoning, and the same idempotency, as the mail take-guards above.
local function installTradeGuard()
    installGuard(_G, "AcceptTrade", function()
        if not active("trade") then return false end
        local partner = UnitName("NPC")
        if partner and partner ~= "" and not isGuildmate(partner) and tradeHasBlockedContent() then
            Addon:Alert("This trade can't be completed outside your guild — only listed items, and never gold.", "guildfound-trade")
            return true
        end
        return false
    end)
end

-- Outbound mail: abort sends to non-guildmates before dispatch. Re-asserted for the same reason
-- as the take-guards — bulk-mail addons replace this global too.
local function installMailSendGuard()
    installGuard(_G, "SendMail", function(recipient)
        if active("mail") and not isGuildmate(recipient) then
            Addon:Alert("You can only mail guild members while Guild Found is active.", "guildfound-mail")
            return true
        end
        return false
    end)
end

-- Auction House (defense in depth): the retail C_AuctionHouse API is present in SoD. Guard both
-- the post AND the buy entry points, so nothing crosses the AH even if the window somehow stays
-- open — for a closed economy gold leaving via a buyout/bid matters as much as posting.
local AH_FNS = {
    "PostItem", "PostCommodity",                                          -- sell side
    "PlaceBid", "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", -- buy side
}
local function installAuctionGuards()
    if not C_AuctionHouse then return end
    for _, fn in ipairs(AH_FNS) do
        installGuard(C_AuctionHouse, fn, function()
            if active("auction") then
                Addon:Alert("The Auction House is disabled while Guild Found is active.", "guildfound-ah")
                return true
            end
            return false
        end)
    end
end

-- ---------------------------------------------------------------------------
function GuildFound:OnEnable()
    -- Trade: partner name is available as unit "NPC" once the window is shown.
    -- Re-evaluate on every content change (items/gold added) and on accept, since
    -- the allowlist decision depends on what is in the window, not just who it's with.
    -- TRADE_SHOW also re-asserts the AcceptTrade backstop (see OnTradeShow), so we are the
    -- outermost check at the moment the window is actually used.
    self:RegisterEvent("TRADE_SHOW",                 "OnTradeShow")
    self:RegisterEvent("TRADE_ACCEPT_UPDATE",        "EvaluateTrade")
    self:RegisterEvent("TRADE_MONEY_CHANGED",        "EvaluateTrade")
    self:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED",  "EvaluateTrade")
    self:RegisterEvent("TRADE_TARGET_ITEM_CHANGED",  "EvaluateTrade")
    self:RegisterEvent("TRADE_CLOSED",               "OnTradeClosed")
    -- A partner's item may resolve asynchronously (uncached tooltip); when its data
    -- arrives, re-evaluate so a conjured item wrongly blocked in the meantime frees up.
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED",     "OnItemInfoReceived")
    -- TRADE_UPDATE is Blizzard's own generic trade refresh (it re-runs TradeFrame_Update
    -- and re-enables the Trade button); mirror it so our block re-asserts on that path too.
    self:RegisterEvent("TRADE_UPDATE",               "EvaluateTrade")

    -- The player changing their OWN offered gold fires NO event we can register for:
    -- TRADE_MONEY_CHANGED reflects only the *target's* money. Worse, Blizzard's
    -- TradeFrame_UpdateMoney re-enables the Trade button whenever the entered amount is
    -- affordable. So dropping gold on your side would leave the Trade button live with
    -- gold in the window — appearing tradeable (the AcceptTrade backstop below still
    -- blocks the actual accept, but the button must reflect the block). Post-hook the two
    -- globals that change the player's offered gold — SetTradeMoney (the money box) and
    -- AddTradeMoney (dragging gold onto the frame) — plus the button's own enable entry
    -- point, to re-run EvaluateTrade with the now-current amount. EvaluateTrade toggles the
    -- widget directly (btn:Enable/Disable), not these wrappers, so there is no recursion.
    -- Hook-once; guard each global's existence per build.
    if not self.tradeMoneyHooked then
        self.tradeMoneyHooked = true
        local function reeval() GuildFound:EvaluateTrade() end
        if SetTradeMoney then hooksecurefunc("SetTradeMoney", reeval) end
        if AddTradeMoney then hooksecurefunc("AddTradeMoney", reeval) end
        if type(TradeFrameTradeButton_Enable) == "function" then
            hooksecurefunc("TradeFrameTradeButton_Enable", reeval)
        end
    end

    -- Auction House: flat block — close it on open.
    for _, ev in ipairs({ "AUCTION_HOUSE_SHOW" }) do
        pcall(self.RegisterEvent, self, ev, "OnAuctionHouseShow")
    end

    -- Inbound mail from outsiders is blocked at open/take time (see the OpenMail and
    -- TakeInbox* hooks below); we do NOT pre-emptively warn just because such mail is
    -- sitting in the inbox.

    -- Inbound mail from outside the guild: prevent it being opened. Hook the
    -- OpenMail frame's OnShow — when a mail is opened, InboxFrame.openMailID is the
    -- inbox index; if that mail is from an outsider, hide the frame again so its body
    -- and attachments can't be viewed. Hook-once; OpenMailFrame is standard FrameXML.
    if not self.mailOpenHooked and OpenMailFrame then
        self.mailOpenHooked = true
        OpenMailFrame:HookScript("OnShow", function()
            if not active("mail") then return end
            local index = InboxFrame and InboxFrame.openMailID
            if mailFromOutsider(index) then
                HideUIPanel(OpenMailFrame)
                Addon:Alert("You can't open mail from outside your guild while Guild Found is active.", "guildfound-inbox-open")
            end
        end)
    end

    -- Inbox visual marker: lay a "Blocked" overlay over any inbox row whose sender is
    -- outside the guild, so the player can see at a glance which mail is locked (the
    -- open/take hooks above remain the actual enforcement). Blizzard runs
    -- InboxFrame_Update on every inbox repaint (open, page turn, new mail arrives), so
    -- hooking it keeps the overlays correct across paging. The per-row `MailItem<i>`
    -- frame is the full-width clickable row; its `MailItem<i>Button` child carries the
    -- absolute inbox `.index`. Hook-once; guard the global's existence per build.
    if not self.inboxOverlayHooked and type(InboxFrame_Update) == "function" then
        self.inboxOverlayHooked = true
        local overlays = {}
        local function getOverlay(row, button)
            if overlays[row] then return overlays[row] end
            -- A dedicated child frame raised above the row (icon included) so the wash
            -- and label sit over everything the row draws.
            local f = CreateFrame("Frame", nil, row)
            f:SetAllPoints(row)
            f:SetFrameLevel((button:GetFrameLevel() or 0) + 5)
            local wash = f:CreateTexture(nil, "BACKGROUND")
            wash:SetAllPoints()
            wash:SetColorTexture(0, 0, 0, 0.55)
            local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("LEFT", 44, 0)
            label:SetText("|cffff3030Blocked|r")
            -- "Return" button: sends the outsider's mail back to its sender. Reads the
            -- row's live inbox index at click time (it changes as the inbox pages), and
            -- only acts while the mail rule is active and the sender is still an outsider.
            -- ReturnInboxItem fires MAIL_INBOX_UPDATE, which repaints the overlays. Only
            -- shown for returnable player mail (see the update loop) — AH/system mail has
            -- no return recipient.
            local ret = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            ret:SetSize(64, 22)
            ret:SetPoint("RIGHT", -8, 0)
            ret:SetText("Return")
            ret:SetScript("OnClick", function()
                local index = button.index
                if not (active("mail") and index and mailFromOutsider(index)) then return end
                if ReturnInboxItem then ReturnInboxItem(index) end
            end)
            f.retButton = ret
            f:Hide()
            overlays[row] = f
            return f
        end
        hooksecurefunc("InboxFrame_Update", function()
            local on = active("mail")
            for i = 1, (INBOXITEMS_TO_DISPLAY or 7) do
                local row    = _G["MailItem" .. i]
                local button = _G["MailItem" .. i .. "Button"]
                if row and button then
                    local ov = getOverlay(row, button)
                    if on and button.index and mailFromOutsider(button.index) then
                        -- Return only makes sense for returnable player mail; AH/system
                        -- mail is blocked but has no sender to return to.
                        ov.retButton:SetShown(mailReturnable(button.index))
                        ov:Show()
                    else
                        ov:Hide()
                    end
                end
            end
        end)
    end

    -- Install every global guard now, and re-assert each on the event that immediately precedes
    -- its use. An addon loading after us and replacing one of these globals would otherwise
    -- silently remove the enforcement — for trade that means only the disabled button is left,
    -- which is cosmetic. The ourWraps marker set makes re-running a no-op unless we have actually
    -- been displaced, so a normal open costs nothing and the wrapper chain never grows.
    --
    -- Residual gap (best-effort, unpreventable): an addon that upvalue-cached the raw function at
    -- load and calls that local directly bypasses us — accepted under the honor-system integrity
    -- model (see PROGRESS.md).
    installTradeGuard()
    installMailTakeGuards()
    installMailSendGuard()
    installAuctionGuards()
    self:RegisterEvent("MAIL_SHOW", "OnMailShow")
end

-- Re-assert the mail guards at the moment the inbox is actually used (both the take-side
-- backstop, which is what stops "open all mail" addons, and the outbound send guard).
function GuildFound:OnMailShow()
    installMailTakeGuards()
    installMailSendGuard()
end

-- Trade window opened: re-assert the accept backstop before anything can be accepted, then
-- judge the (empty) window so the button starts in the right state.
function GuildFound:OnTradeShow()
    installTradeGuard()
    self:EvaluateTrade()
end

-- Should the current trade be blocked from completing? True only when the trade
-- rule is on, the partner is outside your guild (or you have no guild), and the
-- window holds gold or a non-allowlisted item. Guildmates are never blocked.
local function shouldBlockTrade()
    if not active("trade") then return false end
    local partner = UnitName("NPC")
    if not partner or partner == "" then return false end
    if isGuildmate(partner) then return false end
    return tradeHasBlockedContent()
end

-- Which of the three block reasons tradeHasBlockedContent() returned. Naming the actual
-- cause matters here: the old single message said "only listed exception items" even when
-- the block was gold or the enchant slot, which reads as "your item is banned" and sent
-- people looking for a bug in the item rules.
local BLOCK_REASON = {
    gold    = "Gold can't cross the guild boundary — remove it to complete this trade.",
    service = "The 'will not be traded' slot is an enchant/lockpick service — not allowed outside your guild.",
    item    = "Outside your guild you may only trade listed exception items — never gold. (|cffffd100/sodlock trade|r explains this window.)",
}

-- Evaluate the current trade against the policy. The window is never force-closed;
-- instead the default UI's Trade button is disabled while the window holds anything
-- that can't be traded outside your guild, so the trade can't be accepted until it's
-- fixed. (The AcceptTrade wrap above is the hard backstop.) We only ever re-enable a
-- button we disabled, so Blizzard's own accept-handshake state is left alone.
function GuildFound:EvaluateTrade()
    local btn = TradeFrameTradeButton
    local blocked, reason = shouldBlockTrade()
    if blocked then
        if btn then btn:Disable() end
        self.tradeBtnDisabled = true
        Addon:Alert(BLOCK_REASON[reason] or BLOCK_REASON.item, "guildfound-trade-content")
    elseif self.tradeBtnDisabled then
        if btn then btn:Enable() end
        self.tradeBtnDisabled = false
    end
end

-- ---------------------------------------------------------------------------
-- `/sodlock trade` — explain the OPEN trade window, slot by slot.
--
-- "This drop is still inside its 2h group-loot window, why is it blocked?" has several
-- independent gates (master switch, the guild's trade toggle, the allowTradeWindow
-- sub-toggle, and whether the slot's tooltip is even readable on this client), none of
-- which were visible anywhere. Prints every gate plus, for each blocked slot, the raw
-- tooltip lines we scanned — so a missing/renamed BIND_TRADE line shows up immediately
-- instead of being indistinguishable from "the toggle is off".
-- ---------------------------------------------------------------------------
local function yn(v) return v and "|cff00ff00yes|r" or "|cffff3030no|r" end

function GuildFound:TradeDiagnostics()
    local p = function(...) Addon:Print(string.format(...)) end
    Addon:Print("|cffffd100Guild Found trade diagnostics:|r")
    p("  enabled: %s   trade rule: %s   (both needed for ANY trade enforcement)",
        yn(Addon.db.profile.enabled), yn(Addon:GuildFound("trade")))
    p("  exemptions — conjured: %s   trade window (2h pug drops): %s",
        yn(Addon:GuildFound("allowConjured")), yn(Addon:GuildFound("allowTradeWindow")))
    p("  BIND_TRADE_TIME_REMAINING pattern built: %s", yn(bindTradePattern ~= nil))
    if not (TradeFrame and TradeFrame:IsShown()) then
        Addon:Print("  |cffffd100No trade window open — open one with the item in it and re-run.|r")
        return
    end
    local partner = UnitName("NPC")
    p("  partner: |cffffd100%s|r   guildmate: %s%s", partner or "—", yn(isGuildmate(partner)),
        isGuildmate(partner) and " |cff808080(guildmates are never blocked)|r" or "")
    p("  gold — yours: %s  theirs: %s",
        GetCoinTextureString(GetPlayerTradeMoney() or 0), GetCoinTextureString(GetTargetTradeMoney() or 0))

    local ex = Addon:GetRuleset().guildFound.tradeExceptions
    for _, side in ipairs({ "player", "target" }) do
        local getLink = (side == "player") and GetTradePlayerItemLink or GetTradeTargetItemLink
        if getLink then
            for i = 1, TRADE_SERVICE_SLOT do
                local link = getLink(i)
                if link then
                    local label = (side == "player") and "yours" or "theirs"
                    if i == TRADE_SERVICE_SLOT then
                        p("  [%s] service slot: %s |cffff3030blocked (service across the guild boundary)|r",
                            label, link)
                    else
                        local id = tonumber(link:match("item:(%d+)"))
                        local onList = (id and ex[id]) and true or false
                        local win = slotInTradeWindow(side, i)
                        local bop = linkIsBindOnPickup(link)
                        p("  [%s slot %d] %s", label, i, link)
                        p("      allowlisted: %s   conjured: %s", yn(onList), yn(isConjuredLink(link)))
                        -- Both trade-window signals, reported separately: either one alone
                        -- exempts, so seeing WHICH fired is the whole point when a pug drop
                        -- is unexpectedly blocked (a "no" on the timer line with a "yes" on
                        -- bind-on-pickup is the normal, healthy state on the partner's side).
                        p("      trade window — bind-on-pickup: %s   timer line: %s",
                            (bop == nil) and "|cffffd100unknown (item not cached yet)|r" or yn(bop),
                            (win == nil) and "|cffffd100unreadable (item not cached yet)|r" or yn(win))
                        if not linkNotAllowed(link, ex, side, i) then
                            Addon:Print("      |cff00ff00allowed|r")
                        else
                            Addon:Print("      |cffff3030blocked|r — tooltip lines scanned:")
                            ensureScanTip()
                            local setter = (side == "player") and scanTip.SetTradePlayerItem
                                                              or scanTip.SetTradeTargetItem
                            if setter and pcall(setter, scanTip, i) then
                                local n = scanTip:NumLines() or 0
                                if n == 0 then
                                    Addon:Print("        |cffff3030(none — the slot tooltip returned nothing)|r")
                                end
                                for l = 1, n do
                                    local t = scanLine(l)
                                    if t and t ~= "" then Addon:Print("        " .. t) end
                                end
                            else
                                Addon:Print("        |cffff3030(the slot tooltip API refused this slot)|r")
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Trade window closed: clear our disable flag so the next trade starts clean.
function GuildFound:OnTradeClosed()
    self.tradeBtnDisabled = false
end

-- Item data finished loading. GET_ITEM_INFO_RECEIVED fires globally and often, so
-- only re-evaluate while a trade window is actually open (the sole place we read
-- item links); a freshly-cached conjured item can then re-enable the Trade button.
function GuildFound:OnItemInfoReceived()
    if TradeFrame and TradeFrame:IsShown() then
        self:EvaluateTrade()
    end
end

-- Auction House opened → sever the connection and hide the window, warn.
--
-- We defer the close by a frame instead of doing it inline. The AH UI
-- (Blizzard_AuctionUI) is load-on-demand, so on the first auctioneer interaction our
-- permanently-registered AUCTION_HOUSE_SHOW handler can run BEFORE Blizzard has loaded
-- and ShowUIPanel'd AuctionFrame. Closing mid-show severs the server connection but
-- leaves Blizzard to show the frame afterward: an unresponsive AH window that lingers
-- out of range and re-surfaces whenever the UI-panel manager next lays out (opening a
-- vendor or mailbox, or a fresh login). Running a frame later — after Blizzard has
-- shown it — lets us CloseAuctionHouse() AND HideUIPanel() it cleanly so the panel
-- manager stays in sync (a bare :Hide() would not). Handle both the Classic AuctionFrame
-- and the retail-style AuctionHouseFrame, whichever a given build presents.
function GuildFound:OnAuctionHouseShow()
    -- Re-assert the post/bid guards before anything can be posted or bought, in case an auction
    -- addon replaced a C_AuctionHouse function after us.
    installAuctionGuards()
    if not active("auction") then return end
    local function shut()
        if not active("auction") then return end
        if CloseAuctionHouse then CloseAuctionHouse() end
        if AuctionFrame and AuctionFrame:IsShown() then HideUIPanel(AuctionFrame) end
        if AuctionHouseFrame and AuctionHouseFrame:IsShown() then HideUIPanel(AuctionHouseFrame) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, shut) else shut() end
    Addon:Alert("The Auction House is disabled while Guild Found is active.", "guildfound-ah")
end
