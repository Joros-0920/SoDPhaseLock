local ADDON, ns = ...
local Addon = ns.Addon

-- Guild Found wealth integrity (v2 / schema 2, 0.7.9+): detect VALUE that entered a member's
-- possession across a window the addon was NOT loaded. Guild Found is a closed economy — no
-- value enters or leaves the guild — but its trade/mail/AH gates only work while the addon
-- runs. A member who disables the addon, acquires value with an outsider, and re-enables it
-- leaves no live trace. We close that blind spot the same way Modules/Playtime.lua closes the
-- "played without addon" one: keep a durable wealth snapshot while loaded, and the next time a
-- login is attributed to an addon-off gap, fold the difference into a cumulative counter.
--
-- MODEL: a single conserved wealth-VALUE scalar (copper), NOT per-item tracking. We keep
-- per-container value baselines while loaded:
--     w.money    exact copper (GetMoney)
--     w.vCarried vendor sell-value of bags + equipped gear
--     w.vBank    vendor sell-value of the bank (refreshed only while the bank frame is open)
--     w.vMail    vendor sell-value of inbox items + inbox gold (a CREDIT SOURCE only;
--                GUILDMATE mail only — outsider/AH/system mail is excluded, see below)
-- Total tracked wealth T = money + vCarried + vBank + vMail. Any relocation BETWEEN these
-- buckets leaves T unchanged, so — unlike the old per-item/per-axis ledger — moving gear
-- equip<->bag or item bag<->bag can never read as a gain. This deletes an entire class of
-- historical false positives (0.7.5 equip<->bag, the per-item load races) by construction.
--
-- FOLD: on a login attributed to an addon-off gap we fold the NET rise in the login-visible
-- buckets (money + vCarried) since the last loaded snapshot, crediting a positive net against
-- the last-known bank/mail value (a rise there could be a withdrawal / mail-take that merely
-- relocated value we already owned, not new value). Bank and mail are CREDIT SOURCES ONLY and
-- never fold gains themselves, so the whole deposit/withdrawal ledger the old model needed is
-- gone; the only residual is a rare miss (over-credit), never a false positive — the codebase's
-- standing trade-off. The authoritative /played gap (Playtime.lua) is the headline signal; this
-- value is a best-effort ESTIMATE (vendor sell price; unknown/uncached items contribute 0)
-- surfaced to officers as corroboration, never proof. See PROGRESS.md → integrity model.
--
-- Best-effort, like everything else: a tier-1 SavedVariables edit can zero the counter, a
-- tier-2 code edit can forge the report. Both are unpreventable on an untrusted client.
local Integrity = Addon:NewModule("Integrity", "AceEvent-3.0", "AceTimer-3.0")
ns.Integrity = Integrity

local Bags = ns.Bags

local function wealth() return Addon.db.char.wealth end

-- ---------------------------------------------------------------------------
-- Schema migration (clean slate). The pre-0.7.9 model stored per-item baselines
-- (items/bankItems/mailItems + credit ledgers) and item-COUNT counters that cannot be
-- converted to the value scalar. On the first load of the new model we wipe them and
-- re-baseline fresh, so no stale counter survives as a stuck flag and every accumulated
-- false positive from the buggy 0.7.x/0.8.x versions clears itself with no per-member
-- officer action. Version-agnostic (any old build had schema == nil) and idempotent.
-- ---------------------------------------------------------------------------
local function migrate(w)
    if w.schema == 2 then return end
    for _, k in ipairs({ "items", "bankItems", "mailItems", "mailMoney", "pendingBankCredit",
                         "bankGapPending", "equipInBaseline", "itemLog", "unaccountedItems" }) do
        w[k] = nil
    end
    w.money            = nil   -- re-baseline money fresh too (don't trust a possibly-bogus old baseline)
    w.vCarried         = nil
    w.vBank            = nil
    w.vMail            = nil
    w.unaccountedMoney = 0
    w.unaccountedValue = 0
    w.schema           = 2
end

-- ---------------------------------------------------------------------------
-- Value scanning. Container enumeration is shared via Core/Bags.lua (Enforcement/BagOverlay
-- use it too); here we turn an itemID->count map into a total vendor sell-value (copper).
-- A cache miss (GetItemInfo not yet populated) makes the scan UNRESOLVED so the caller can
-- wait for the data rather than trust an undercount — an unresolved value must never be
-- mistaken for a real drop/gain (the value analogue of the old bag-load-race guard).
-- ---------------------------------------------------------------------------
local INVSLOT_FIRST, INVSLOT_LAST = 1, 19
local function addEquipped(counts)
    local getID = GetInventoryItemID
    if not getID then return counts end
    for slot = INVSLOT_FIRST, INVSLOT_LAST do
        local id = getID("player", slot)
        if id then counts[id] = (counts[id] or 0) + 1 end
    end
    return counts
end

-- Carried = bags + equipped gear (see the MODEL note: their union is invariant under an
-- equip<->bag move). Bank is a separate bucket; equipment isn't tracked against it.
local function carriedCounts() return addEquipped(Bags.counts(Bags.bagIDs())) end
local function bankCounts()    return Bags.counts(Bags.bankIDs()) end

-- itemID->count  ->  (totalSellValue, allResolved). A nil name means the item isn't cached
-- yet (unresolved); a resolved item with no/zero sell price simply contributes 0.
local function valueOf(counts)
    local total, resolved = 0, true
    for id, n in pairs(counts) do
        local name = GetItemInfo(id)
        if not name then
            resolved = false
        else
            local price = select(11, GetItemInfo(id))
            if price and price > 0 then total = total + price * n end
        end
    end
    return total, resolved
end

-- Mail is a credit source (its value offsets a gap gain, on the theory that value seen in the
-- inbox merely RELOCATED into bags/money when collected — not newly acquired). In a closed
-- economy that holds ONLY for mail from a fellow guild member: that is value already inside the
-- guild. Everything else — outsider players, the Auction House, and system/NPC mail — is income
-- from OUTSIDE the guild, which Guild Found forbids, so it must never credit away a gap gain.
-- Otherwise collecting such mail during an addon-off gap (or after merely VIEWING it while
-- loaded, which used to seed vMail) folds to nothing and is never flagged. So: creditable IFF
-- the sender is a current guild member; all other mail is excluded (i.e. counts toward the flag).
--
-- Fail-safe to "creditable" (return false) so a genuine guildmate is never mis-flagged:
--   * sender unreadable (API missing / nil) — can't attribute it, so don't invent a flag; and
--   * we're guilded but the roster hasn't loaded yet (GetNumGuildMembers == 0 at/just after
--     login), which would momentarily read a guildmate as an outsider.
local function mailCreditExcluded(index)
    if not GetInboxHeaderInfo then return false end
    local _, _, sender = GetInboxHeaderInfo(index)
    if not sender then return false end                                    -- sender unknown
    if IsInGuild and IsInGuild()
       and (not GetNumGuildMembers or (GetNumGuildMembers() or 0) == 0) then
        return false                                                       -- roster not loaded yet
    end
    return Addon:GetGuildRankIndex(sender) == nil                          -- not a guildmate → excluded
end

-- Inbox item contents (itemID -> count), readable only while the mail frame is open. Only
-- creditable mail is summed (see mailCreditExcluded) — this feeds the vMail credit source alone.
local ATTACH_MAX = ATTACHMENTS_MAX_RECEIVE or 16
local function mailItemCounts()
    local counts = {}
    local getNum = GetInboxNumItems
    if not getNum then return counts end
    local n = getNum() or 0
    for m = 1, n do
        if not mailCreditExcluded(m) then
            for a = 1, ATTACH_MAX do
                local id
                if GetInboxItem then id = select(2, GetInboxItem(m, a)) end
                if not id and GetInboxItemLink then
                    local link = GetInboxItemLink(m, a)
                    if link then id = tonumber(link:match("item:(%d+)")) end
                end
                if id then
                    local count = 1
                    if GetInboxItem then count = select(4, GetInboxItem(m, a)) or 1 end
                    counts[id] = (counts[id] or 0) + count
                end
            end
        end
    end
    return counts
end

-- Gold sitting in the inbox (summed across messages). CODAmount is excluded (that's gold you
-- would PAY to collect, not gold you hold).
local function mailGold()
    local getNum = GetInboxNumItems
    local getHdr = GetInboxHeaderInfo
    if not getNum or not getHdr then return 0 end
    local n = getNum() or 0
    local total = 0
    for m = 1, n do
        if not mailCreditExcluded(m) then
            local money = select(5, getHdr(m))   -- GetInboxHeaderInfo: ..., money(5), CODAmount(6), ...
            if money then total = total + money end
        end
    end
    return total
end

-- Total value currently in the inbox (items + gold), a credit source. Unresolved item names
-- contribute 0 here — a credit source that under-counts only ever DEFERS/MISSES a flag, never
-- creates one, so it needn't block on the cache the way the carried baseline does.
local function mailValueNow() return (select(1, valueOf(mailItemCounts()))) + mailGold() end

-- Bag-population probe for login readiness — judged on containers only (equipped gear can read
-- ready a moment before the container API populates at login).
local function bagsLoaded() return next(Bags.counts(Bags.bagIDs())) ~= nil end

-- ---------------------------------------------------------------------------
-- Baseline snapshots. Guards mirror the old model's hard-won ones:
--  * money: accept a 0 read only to SEED a first baseline (w.money == nil); never clobber a
--    real positive baseline with a transient login 0 (that made the next gap-login fold the
--    whole balance — the 0.7.4 bug).
--  * vCarried: write only when bags are loaded AND every item value resolved; an empty or
--    half-cached scan must not become the baseline (it would flag the whole inventory later).
-- ---------------------------------------------------------------------------
local function snapshotMoney(w)
    local m = (GetMoney and GetMoney()) or 0
    if m > 0 or w.money == nil then w.money = m end
end

local function snapshotCarried(w)
    local val, resolved = valueOf(carriedCounts())
    if bagsLoaded() and resolved then w.vCarried = val end
end

local function snapshotNow(w)
    snapshotMoney(w)
    snapshotCarried(w)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Integrity:OnEnable()
    migrate(wealth())
    -- Hold baseline maintenance until the first login gap is attributed, so the first
    -- BAG_UPDATE/PLAYER_MONEY of the session can't overwrite the pre-gap snapshot before
    -- Playtime attributes the gap. Mirrors Playtime's reconcile hold.
    self._ready = false
    self:RegisterEvent("PLAYER_MONEY", "OnMoney")
    self:RegisterEvent("BAG_UPDATE", "OnBagUpdate")
    -- Equip/unequip almost always fires BAG_UPDATE, but watch equipment directly too so the
    -- carried baseline stays honest on any pure equipped-slot change while loaded.
    self:RegisterEvent("UNIT_INVENTORY_CHANGED", "OnInventoryChanged")
    self:RegisterEvent("PLAYER_LOGOUT", "Flush")
    -- Bank: observable only while its frame is open, kept current as a credit source.
    self:RegisterEvent("BANKFRAME_OPENED", "OnBankOpened")
    self:RegisterEvent("BANKFRAME_CLOSED", "OnBankClosed")
    self:RegisterEvent("PLAYERBANKSLOTS_CHANGED", "OnBankSlots")
    -- Mail: observable only while its frame is open, kept current as a credit source.
    self:RegisterEvent("MAIL_SHOW", "OnMailShow")
    self:RegisterEvent("MAIL_INBOX_UPDATE", "OnMailInbox")
    self:RegisterEvent("MAIL_CLOSED", "OnMailClosed")
    -- Latch login-instant wealth as early as it can be trusted. Between OnEnable and the fold
    -- (attribution at ~8-11s, plus up to ~10s of FoldWhenReady retries) `_ready` is false, so
    -- steady-state tracking is deaf — anything the player legitimately earns in those ~20s would
    -- otherwise read as a delta against the pre-gap baseline and fold in as unmonitored value.
    -- Sampling early bounds that blind window to the first second or two.
    self._loginMoney, self._loginCarried = nil, nil
    self:SampleLogin(0)
    -- Safety net: if Playtime never attributes a login, still take a baseline so steady-state
    -- tracking and the logout flush work. Must clear Playtime's ~8-11s reconcile window PLUS this
    -- module's own value-fold retry (FoldWhenReady, up to ~10s from attribution), so it can't
    -- overwrite the pre-gap baseline before a real fold finishes — 25s leaves a margin over the
    -- ~21s worst case. (Only fires when attribution never happens; a normal fold flips _ready first.)
    self:ScheduleTimer("ForceReady", 25)
end

-- Poll the login-instant wealth until both halves latch (or we run out of attempts). Money
-- latches on the first POSITIVE read (0 is the signature of an unread GetMoney at login — the
-- 0.7.4 guard); carried latches on the first loaded+fully-resolved scan. Each latches
-- independently, and neither is ever overwritten once set.
local SAMPLE_DELAY, SAMPLE_MAX = 0.5, 24   -- ~12s, comfortably past the fold's own retry budget

function Integrity:SampleLogin(attempt)
    if self._ready then return end
    if self._loginMoney == nil then
        local m = (GetMoney and GetMoney()) or 0
        if m > 0 then self._loginMoney = m end
    end
    if self._loginCarried == nil then
        local val, resolved = valueOf(carriedCounts())
        if bagsLoaded() and resolved then self._loginCarried = val end
    end
    if self._loginMoney ~= nil and self._loginCarried ~= nil then return end
    if attempt < SAMPLE_MAX then
        self:ScheduleTimer(function() self:SampleLogin(attempt + 1) end, SAMPLE_DELAY)
    end
end

function Integrity:ForceReady()
    if self._ready then return end
    snapshotNow(wealth())
    self._ready = true
end

-- ---------------------------------------------------------------------------
-- Core algorithm — called once per login by Playtime:attributeLogin. `wealthAdded` is the
-- tight-tolerance wealth decision (WEALTH_TOLERANCE); falls back to the played `added` flag
-- if called by an older Playtime.
-- ---------------------------------------------------------------------------
function Integrity:OnLoginAttributed(gap, added, wealthAdded)
    if self._ready then return end               -- only the first attribution matters
    if wealthAdded == nil then wealthAdded = added end
    local w = wealth()
    if wealthAdded and w.money ~= nil and Addon:WealthIntegrityOn() then
        -- Money is valid at login but the carried VALUE may still be loading (bags + sell-price
        -- cache), so the whole net-delta fold is retried together in FoldWhenReady.
        self:FoldWhenReady(0)
    else
        -- No gap, integrity off, or first-ever snapshot (nothing to compare): baseline only.
        snapshotNow(w)
        self._ready = true
    end
end

-- Carried value can still be loading a few seconds into login (containers populate late; sell
-- prices arrive via GET_ITEM_INFO_RECEIVED). Retry the compare instead of trusting a one-shot
-- reading, and hold `_ready` false until it resolves so steady-state tracking can't race ahead
-- and silently adopt the post-gap value as the baseline (the class of bug fixed in 0.7.3).
local FOLD_RETRY_DELAY = 1
local FOLD_RETRY_MAX   = 10   -- ~10s; bags + owned-item prices essentially always resolve well inside this

function Integrity:FoldWhenReady(attempt)
    if self._ready then return end   -- ForceReady's safety net already resolved us
    local w = wealth()
    local curVal, resolved = valueOf(carriedCounts())
    local loaded = bagsLoaded()
    -- Require the value to be STABLE across two consecutive attempts (~1s apart), not merely
    -- resolved: a one-shot scan can catch bags mid-load or a stack count still settling. curVal
    -- is a scalar, so a plain == is the stability test.
    local stable = loaded and resolved and self._prevVal ~= nil and self._prevVal == curVal
    -- Fold only against a trustworthy baseline: a populated carried value AND a positive money
    -- baseline (0 is the signature of an unread GetMoney() at login — the 0.7.4 guard).
    local baseReady = (w.vCarried ~= nil) and (w.money ~= nil and w.money > 0)
    if baseReady and stable then
        self._prevVal = nil
        local moneyNow = (GetMoney and GetMoney()) or 0
        -- Diff the LOGIN-INSTANT wealth against the pre-gap baseline, not the wealth as it
        -- stands now: everything earned between login and this fold was played with the addon
        -- loaded and must not be attributed to the unmonitored window. Fall back to the current
        -- reading only if the early sample never latched.
        local moneyDelta   = (self._loginMoney or moneyNow) - w.money
        local carriedDelta = (self._loginCarried or curVal) - w.vCarried
        -- Net rise in the login-visible buckets. A vendor buy (money down, items up) or an
        -- ordinary spend nets toward zero, so it doesn't over-flag; only a genuine net increase
        -- in what the player holds counts.
        local netDelta = moneyDelta + carriedDelta
        if netDelta > 0 then
            -- A positive net could be value pulled from an unseen reservoir (bank withdrawal /
            -- mail-take), not new value. Credit it against the last-known bank + mail value. No
            -- consumption ledger is needed: bank/mail never fold gains and are re-observed fresh
            -- on their next open, so at worst this over-credits (a miss), never under-credits.
            local credit = (w.vBank or 0) + (w.vMail or 0)
            if credit > netDelta then credit = netDelta end
            netDelta = netDelta - credit
        end
        if netDelta > 0 then
            w.unaccountedValue = (w.unaccountedValue or 0) + netDelta
        end
        w.money    = moneyNow
        w.vCarried = curVal
        self._ready = true
        -- Flip the member's roster row now rather than waiting a full StatusInterval.
        if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
        return
    end
    if attempt < FOLD_RETRY_MAX then
        self._prevVal = (loaded and resolved) and curVal or nil
        self:ScheduleTimer(function() self:FoldWhenReady(attempt + 1) end, FOLD_RETRY_DELAY)
        return
    end
    -- Gave up: values never loaded/stabilised (or there was no prior baseline). Take whatever we
    -- have now as the baseline so steady-state tracking can begin; this gap can't be folded
    -- (a missed gain beats a false flag).
    snapshotNow(w)
    self._prevVal = nil
    self._ready = true
end

-- ---------------------------------------------------------------------------
-- Steady state: while loaded, every money/bag change keeps the baseline current so monitored
-- activity never counts as unaccounted. Debounced for BAG_UPDATE, which fires in bursts.
-- ---------------------------------------------------------------------------
function Integrity:OnMoney()
    if not self._ready then return end
    wealth().money = (GetMoney and GetMoney()) or wealth().money
end

-- Equipped-gear change: only the player's own inventory affects our baseline. Routes through
-- the same debounced rescan so carried = bags + equipped stays current.
function Integrity:OnInventoryChanged(_, unit)
    if unit and unit ~= "player" then return end
    self:OnBagUpdate()
end

function Integrity:OnBagUpdate()
    if not self._ready or self._bagTimer then return end
    self._bagTimer = self:ScheduleTimer(function()
        self._bagTimer = nil
        if not self._ready then return end
        local w = wealth()
        local val, resolved = valueOf(carriedCounts())
        if bagsLoaded() and resolved then w.vCarried = val end
        -- A bag change while the bank is open is usually a bags<->bank move; refresh the bank
        -- credit value too so the transfer stays neutral.
        if self._bankOpen then
            local counts = bankCounts()
            if next(counts) ~= nil then
                local bval, bres = valueOf(counts)
                if bres then w.vBank = bval end
            end
        end
    end, 0.5)
end

-- ---------------------------------------------------------------------------
-- Bank sessions. The bank is a CREDIT SOURCE ONLY in this model (never folds gains), so on
-- open/change we just keep w.vBank current. We only ever RAISE toward a real reading and never
-- lower it to a premature empty scan (bank data lands a moment after the frame opens): a
-- stale-high bank value can only over-credit a future login (a miss), while a premature 0 would
-- remove credit and risk a false positive — so we err high.
-- ---------------------------------------------------------------------------
function Integrity:OnBankOpened()
    self._bankOpen = true
    self:ScheduleTimer("RefreshBank", 0.5)
end

function Integrity:RefreshBank()
    if not self._bankOpen then return end
    local counts = bankCounts()
    if next(counts) == nil then return end       -- empty / not yet loaded: don't lower the credit
    local val, resolved = valueOf(counts)
    if resolved then wealth().vBank = val end
end

function Integrity:OnBankSlots()
    if not self._bankOpen or self._bankTimer then return end
    self._bankTimer = self:ScheduleTimer(function()
        self._bankTimer = nil
        if self._bankOpen then self:RefreshBank() end
    end, 0.5)
end

function Integrity:OnBankClosed()
    self._bankOpen = false
end

-- ---------------------------------------------------------------------------
-- Mail sessions. Credit source only. We keep w.vMail at the PEAK value seen across the frame
-- session (per-session running max), not the latest scan: taking an attachment fires its own
-- MAIL_INBOX_UPDATE with the item/gold already gone, and a latest-scan model would then shrink
-- the credit and re-expose a relocation as a phantom gain. The open's first update fires before
-- any attachment is interactable, so the pre-take value is always captured first.
-- ---------------------------------------------------------------------------
function Integrity:OnMailShow()
    self._mailOpen = true
    self._mailPeak = 0   -- fresh per-session peak; w.vMail keeps last session's value until re-sampled
end

function Integrity:OnMailInbox()
    if not self._mailOpen then return end
    local v = mailValueNow()
    if v > (self._mailPeak or 0) then self._mailPeak = v end
    wealth().vMail = self._mailPeak
end

function Integrity:OnMailClosed()
    self._mailOpen = false
end

-- Final snapshot at logout. If we never became ready this session (logged out inside the
-- reconcile window), leave the pre-gap baseline intact so the gap is attributed next session.
function Integrity:Flush()
    if not self._ready then return end
    snapshotNow(wealth())
end

-- ---------------------------------------------------------------------------
-- Reporting / clearing (mirrors Playtime:GetUnobserved / Rebaseline)
-- ---------------------------------------------------------------------------
-- Estimated net value (copper) that entered the player's possession across addon-off gaps.
function Integrity:GetUnaccountedValue()
    return math.floor(wealth().unaccountedValue or 0)
end

-- Officer forgive (received via Comm's "WGF"): zero the counter, re-baseline to now, and push a
-- fresh ping so the member's roster row clears guild-wide. Mirrors Playtime:Rebaseline.
function Integrity:Rebaseline()
    local w = wealth()
    w.unaccountedValue = 0
    w.unaccountedMoney = 0
    snapshotNow(w)
    -- A forgive that lands mid-login (before attribution) must also cancel the pending fold:
    -- its latched pre-gap deltas are exactly what was just forgiven, and re-folding them would
    -- immediately re-flag the member. Baseline is now; steady-state tracking starts here.
    self._loginMoney, self._loginCarried, self._prevVal = nil, nil, nil
    self._ready = true
    -- Refresh the credit-source baselines only if their frame is open right now.
    if self._bankOpen then
        local counts = bankCounts()
        if next(counts) ~= nil then
            local val, resolved = valueOf(counts)
            if resolved then w.vBank = val end
        end
    end
    if self._mailOpen then w.vMail = self._mailPeak or mailValueNow() end
    if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
end
