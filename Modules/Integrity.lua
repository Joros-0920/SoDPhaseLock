local ADDON, ns = ...
local Addon = ns.Addon

-- Guild Found wealth integrity: detect gold or items that moved across a window the
-- addon was NOT loaded. Guild Found is a closed economy — no value enters or leaves
-- the guild — but its trade/mail/AH gates only work while the addon runs. A member who
-- disables the addon, trades/mails value with an outsider, and re-enables it leaves no
-- live trace. We close that blind spot the same way Modules/Playtime.lua closes the
-- "played without addon" one: keep a durable snapshot of wealth while loaded, and the
-- next time a login is attributed to an addon-off gap, fold the difference from that
-- snapshot into a cumulative, reportable counter.
--
-- The gap TRIGGER is Playtime's (authoritative server /played), so this module never
-- has to detect the gap itself — it just consumes Playtime:OnLoginAttributed. Bags+equipped
-- are the login-visible axis; bank and mail are only readable while their frames are open, so
-- they're sampled during those sessions and reconciled against bags via a credit ledger (see the
-- gain-folding section). Best-effort, like everything else: a tier-1 SavedVariables edit
-- can zero the counter (the receiver-side sticky flag in Compliance.lua blunts that once
-- an officer has seen it), a tier-2 code edit can forge the report. See PROGRESS.md.
local Integrity = Addon:NewModule("Integrity", "AceEvent-3.0", "AceTimer-3.0")
ns.Integrity = Integrity

-- Distinct gained itemIDs remembered for the officer display. Bounded so a long
-- unmonitored session can't bloat SavedVariables or the status-ping payload.
local LOG_CAP = 20

local function wealth()
    return Addon.db.char.wealth
end

-- ---------------------------------------------------------------------------
-- Item scanning. Low-level container enumeration lives in Core/Bags.lua (shared
-- with Enforcement/BagOverlay); here we build the wealth-integrity baselines on
-- top of it: carried = bags + equipped gear, with the bank as a separate axis.
-- ---------------------------------------------------------------------------
local Bags = ns.Bags

-- Equipped gear (INVSLOT 1..19, same range as Enforcement.lua). Counted INTO the carried
-- inventory alongside bags so a gear piece moved between an equipped slot and a bag nets
-- out: its itemID total across {bags ∪ equipped} is unchanged, so it never reads as a bag
-- "gain". Without this, unequipping an already-owned item into your bags while the addon is
-- off flags it as value that appeared from nowhere — a false positive, since nothing entered
-- the closed economy. Empty slots return nil and are skipped.
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

-- Carried inventory baseline = bag contents + equipped gear (see addEquipped). Bank stays
-- bags-only: equipment isn't tracked against the bank axis, and the bank compare is separate.
local function scanBags() return addEquipped(Bags.counts(Bags.bagIDs())) end
local function scanBank() return Bags.counts(Bags.bankIDs()) end

-- Shallow copy of an itemID→count scan, so a migration/credit step can add to a copy without
-- mutating the persisted baseline in place.
local function copyCounts(t)
    local c = {}
    if t then for id, n in pairs(t) do c[id] = n end end
    return c
end

-- Inbox item contents (itemID → count), readable only while the mail frame is open. Used as a
-- CREDIT SOURCE only (see foldBagGainsAtLogin): taking your own item from the mailbox to your
-- bags while the addon was off would otherwise read as a bag gain from nowhere. We do NOT fold
-- mail-side gains — an item merely sitting in the inbox isn't in your possession yet, and inbound
-- outsider mail we already block on take — so mail only nets out bag↔mail relocation, never flags.
local ATTACH_MAX = ATTACHMENTS_MAX_RECEIVE or 16
local function scanMail()
    local counts = {}
    local getNum = GetInboxNumItems
    if not getNum then return counts end
    local n = getNum() or 0
    for m = 1, n do
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
    return counts
end

-- Gold sitting in the inbox (summed across messages), readable only while the mail frame is open.
-- The scalar mirror of scanMail and a CREDIT SOURCE for the money fold: taking your own mailed gold
-- into your bags across an addon-off gap would otherwise read as money appearing from nowhere (the
-- money twin of the bag→mail item relocation). CODAmount is deliberately excluded — that's gold you
-- would PAY to collect a package, not gold you already hold.
local function scanMailMoney()
    local getNum = GetInboxNumItems
    local getHdr = GetInboxHeaderInfo
    if not getNum or not getHdr then return 0 end
    local n = getNum() or 0
    local total = 0
    for m = 1, n do
        local money = select(5, getHdr(m))   -- GetInboxHeaderInfo: ..., money(5), CODAmount(6), ...
        if money then total = total + money end
    end
    return total
end

-- Deep-equality of two itemID→count scans, for the stable-scan readiness guard below.
local function scansEqual(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for id, c in pairs(a) do if b[id] ~= c then return false end end
    for id, c in pairs(b) do if a[id] ~= c then return false end end
    return true
end

-- Bag-population probe used for login READINESS decisions — deliberately judged on the
-- containers ONLY, never the merged carried set. Equipped gear (GetInventoryItemID) can read
-- ready a moment before the container API populates at login, so a merged scan can look
-- non-empty while bags are still unloaded; persisting or folding on that would drop the
-- not-yet-loaded bag items and mis-count them as gains on the next scan. Keying readiness on
-- bags preserves the existing "don't accept a pre-load scan" guarantee unchanged.
local function bagsLoaded() return next(Bags.counts(Bags.bagIDs())) ~= nil end

local function snapshotNow(w)
    -- Money guard, the mirror of the item guard below. GetMoney() was long assumed to read valid
    -- the instant we log in, but it can momentarily return 0 while money data loads (the same lag
    -- the container API has for bags). Persisting a spurious 0 as the baseline makes the next
    -- gap-login fold the player's ENTIRE balance as "off-radar" (curMoney - 0), stacking on every
    -- relog. So don't clobber a real positive baseline with a 0 read — accept 0 only to seed a
    -- first-ever baseline (w.money == nil). A legitimate spend-to-zero is recorded by steady-state
    -- OnMoney once the session is ready.
    local m = (GetMoney and GetMoney()) or 0
    if m > 0 or w.money == nil then w.money = m end
    -- Never overwrite a populated item baseline with an EMPTY scan. The container API populates a
    -- few seconds after login, so a scan run before bags load returns {} even for a full
    -- inventory. Persisting that empty table as the baseline turns the next gap-fold into a
    -- whole-inventory false flag (every item reads as "gained" against an empty base). A
    -- genuinely-empty scan only establishes the baseline when there isn't one yet.
    local scanned = scanBags()
    if bagsLoaded() or w.items == nil or next(w.items) == nil then
        w.items = scanned
        w.equipInBaseline = true   -- scanBags() includes equipped, so this baseline is migration-clean
    end
end

-- Remember a gained itemID (set semantics, capped at LOG_CAP distinct entries).
local function addToLog(w, id)
    local log = w.itemLog
    if not log then log = {}; w.itemLog = log end
    if log[id] then return end
    local n = 0
    for _ in pairs(log) do n = n + 1 end
    if n >= LOG_CAP then return end
    log[id] = true
end

-- ---------------------------------------------------------------------------
-- Gain folding. The counter is a QUANTITY (total number of items that appeared), not a
-- distinct-itemID count — 3 of a stack looted off-radar reports 3, not 1. Items appearing is
-- the closed-economy concern; consumption/vendoring dominates the removal side, so only gains
-- count. `w.itemLog` stays a bounded distinct-itemID set for the officer display.
--
-- Relocation between an untracked container and bags is the wrinkle: at login the bank and mail
-- frames are closed, so a move lands on whichever side we can't see, and a pure relocation (total
-- holdings unchanged) would false-flag. We reconcile with a credit that flows across the
-- visibility windows:
--   * bank/mail → bag: a bag gain at login is credited against the last-known bank AND mail
--     holdings and CONSUMED from them, so a withdrawal / mail-take isn't re-counted later. (Bank
--     is a full gain axis; mail is credit-source-only — see scanMail.)
--   * bag → bank: a bag LOSS at login is remembered in w.pendingBankCredit (a candidate deposit);
--     the next bank open credits matching bank gains against it and consumes it.
-- Where the guess is wrong (a real external gain of an itemID that also sits in the bank), the
-- flag isn't lost — it resurfaces at the bank's next compare. We favour a deferred/occasionally-
-- missed flag over a false positive, consistent with the money guard.
-- ---------------------------------------------------------------------------

-- Credit `delta` of `id` against each source table in order, consuming in place. Returns the
-- uncredited remainder. Nil sources are pre-filtered by the caller (a nil hole would stop ipairs).
local function creditFrom(id, delta, sources)
    for _, src in ipairs(sources) do
        if delta <= 0 then break end
        local have = src[id] or 0
        if have > 0 then
            local take = (have < delta) and have or delta
            src[id] = (have - take > 0) and (have - take) or nil
            delta = delta - take
        end
    end
    return delta
end

-- Login (bag-side) fold. `base` = last monitored bags∪equipped, `cur` = current bags∪equipped.
local function foldBagGainsAtLogin(w, base, cur)
    -- Bank first, then mail — a bag increase covered by either is a withdrawal / mail-take.
    local sources = {}
    if w.bankItems then sources[#sources + 1] = w.bankItems end
    if w.mailItems then sources[#sources + 1] = w.mailItems end
    local gained = 0
    for id, cnt in pairs(cur) do
        local delta = cnt - ((base and base[id]) or 0)
        if delta > 0 then
            delta = creditFrom(id, delta, sources)
            if delta > 0 then
                gained = gained + delta        -- quantity that appeared from nowhere
                addToLog(w, id)
            end
        end
    end
    -- Remember bag losses across the gap as candidate bank deposits. Rebuilt fresh each gap-login
    -- so it can't accumulate stale credit that would mask a later real bank gain (a deposit is
    -- normally reconciled at the very next bank open). A no-gap relog doesn't reach this path, so
    -- a deposit made during a gap survives ordinary logins until the bank is opened.
    local pending
    if base then
        for id, prev in pairs(base) do
            local lost = prev - (cur[id] or 0)
            if lost > 0 then
                pending = pending or {}
                pending[id] = lost
            end
        end
    end
    w.pendingBankCredit = pending
    return gained
end

-- Bank-open fold. `base` = last monitored bank, `cur` = current bank. Credits bank gains against
-- pending deposits captured at the last gap-login (see above) and consumes them. Quantity-counted.
local function foldBankGains(w, base, cur)
    local pending = w.pendingBankCredit
    local sources = pending and { pending } or {}
    local gained = 0
    for id, cnt in pairs(cur) do
        local delta = cnt - ((base and base[id]) or 0)
        if delta > 0 then
            delta = creditFrom(id, delta, sources)
            if delta > 0 then
                gained = gained + delta
                addToLog(w, id)
            end
        end
    end
    if pending and next(pending) == nil then w.pendingBankCredit = nil end
    return gained
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Integrity:OnEnable()
    -- Hold baseline maintenance until the first login gap is attributed. Otherwise the
    -- first BAG_UPDATE/PLAYER_MONEY of the session (bags load a few seconds in) would
    -- overwrite the pre-gap snapshot before Playtime attributes the gap (~15-20s in),
    -- destroying the very evidence we compare against. Mirrors Playtime's reconcile hold.
    self._ready = false
    self:RegisterEvent("PLAYER_MONEY", "OnMoney")
    self:RegisterEvent("BAG_UPDATE", "OnBagUpdate")
    -- Equip/unequip almost always fires BAG_UPDATE (the item enters/leaves a bag slot), but
    -- watch equipment directly too so the carried baseline (bags + equipped) stays honest on
    -- any pure equipped-slot change while loaded — otherwise steady-state gear moves could
    -- drift the baseline and surface as a phantom gain on the next fold.
    self:RegisterEvent("UNIT_INVENTORY_CHANGED", "OnInventoryChanged")
    self:RegisterEvent("PLAYER_LOGOUT", "Flush")
    -- Bank: only observable while its frame is open, so it's tracked as a separate
    -- baseline sampled during bank sessions (see OnBankOpened). An item parked in the
    -- bank while the addon was off wouldn't show in bags at login — it's caught the next
    -- time the bank is opened with the addon on.
    self:RegisterEvent("BANKFRAME_OPENED", "OnBankOpened")
    self:RegisterEvent("BANKFRAME_CLOSED", "OnBankClosed")
    self:RegisterEvent("PLAYERBANKSLOTS_CHANGED", "OnBankSlots")
    -- Mail: like the bank, only observable while its frame is open. Sampled as a credit source
    -- (w.mailItems + w.mailMoney) so taking your own mailed item OR gold into your bags across an
    -- addon-off gap nets out instead of reading as a bag/money gain. Inbox data lands on
    -- MAIL_INBOX_UPDATE, not MAIL_SHOW.
    self:RegisterEvent("MAIL_SHOW", "OnMailShow")
    self:RegisterEvent("MAIL_INBOX_UPDATE", "OnMailInbox")
    self:RegisterEvent("MAIL_CLOSED", "OnMailClosed")
    -- Safety net: if Playtime never attributes a login (e.g. the server never answers
    -- TIME_PLAYED), still take a baseline so steady-state tracking and the logout flush
    -- work. Comfortably after Playtime's ~8-11s reconcile window PLUS this module's own
    -- ~6s item-fold retry (FoldItemsWhenReady) — both tightened 2026-07-11 — so 20s still
    -- leaves a several-second margin over the worst normal case.
    self:ScheduleTimer("ForceReady", 20)
end

function Integrity:ForceReady()
    if self._ready then return end
    snapshotNow(wealth())
    self._ready = true
end

-- Bags can still be loading a few seconds into login. Retry the item compare instead of
-- accepting a one-shot empty scan: if we gave up immediately and flipped `_ready` true, the
-- very next BAG_UPDATE (steady-state tracking, once bags actually populate) would silently
-- overwrite `w.items` with the POST-gap scan with no comparison ever happening — quietly
-- swallowing a genuine gain. `_ready` stays false (holding off OnMoney/OnBagUpdate) until
-- this resolves, so there's no window for steady-state tracking to race ahead of it.
local BAG_RETRY_DELAY = 1
local BAG_RETRY_MAX   = 6   -- ~6s of retrying; bags essentially never take this long to load

function Integrity:FoldItemsWhenReady(attempt)
    if self._ready then return end   -- ForceReady's safety net already resolved us
    local w = wealth()
    local baseReady = w.items ~= nil and next(w.items) ~= nil
    local curItems  = scanBags()
    local loaded    = bagsLoaded()   -- bags-only readiness; equipped gear alone isn't "ready"
    -- Require the scan to be STABLE across two consecutive attempts (~1s apart), not just
    -- non-empty. A one-shot scan can catch bags mid-load (some equipped bags not populated yet,
    -- undercounting the base) or a stack count still settling (the old GetContainerItemInfo
    -- signature can read a transient low count). Waiting for two identical scans lets loading
    -- quiesce before we trust the numbers, covering both the partial-load and count-read races.
    local stable = loaded and self._prevScan ~= nil and scansEqual(self._prevScan, curItems)
    if baseReady and stable then
        self._prevScan = nil
        -- One-time migration for baselines written before equipped gear was folded into the
        -- carried inventory (v0.7.5): those hold BAG items only, so a bags∪equipped current scan
        -- reads every worn piece as an off-radar "gain" on the first post-upgrade gap-login. Credit
        -- the currently-equipped set into a copy of the old base so worn gear nets to zero; genuine
        -- bag gains this login are still caught. A real off-radar GEAR swap during this single gap
        -- is missed once — conservative, same trade-off as the money 0-baseline guard — and only for
        -- the one migrating login. Cleared thereafter via the equipInBaseline flag.
        local base = w.items
        if not w.equipInBaseline then base = addEquipped(copyCounts(base)) end
        w.unaccountedItems = (w.unaccountedItems or 0) + foldBagGainsAtLogin(w, base, curItems)
        w.items = curItems
        w.equipInBaseline = true
        self._ready = true
        if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
        return
    end
    if attempt < BAG_RETRY_MAX then
        self._prevScan = curItems   -- remember for the stability compare on the next attempt
        self:ScheduleTimer(function() self:FoldItemsWhenReady(attempt + 1) end, BAG_RETRY_DELAY)
        return
    end
    -- Gave up: bags never populated / never stabilised (or there was genuinely no prior baseline
    -- to compare against). Take whatever we have now as the baseline so steady-state tracking can
    -- begin; this login's gap simply can't be folded (conservative — a missed gain beats a false flag).
    if loaded then w.items = curItems; w.equipInBaseline = true end
    self._prevScan = nil
    self._ready = true
end

-- ---------------------------------------------------------------------------
-- Core algorithm — called once per login by Playtime:attributeLogin. `added` is the
-- played-without-addon decision (180s tolerance); `wealthAdded` is the tighter wealth
-- decision (WEALTH_TOLERANCE, ~45s) — a closed economy tolerates far less unmonitored
-- play, and the wealth diff is crash-safe (see Playtime's WEALTH_TOLERANCE note), so we
-- fold on the shorter gap. Falls back to `added` if called by an older Playtime.
-- ---------------------------------------------------------------------------
function Integrity:OnLoginAttributed(gap, added, wealthAdded)
    if self._ready then return end               -- only the first attribution matters
    if wealthAdded == nil then wealthAdded = added end
    local w = wealth()
    local hadBaseline = (w.money ~= nil)          -- money/items are always snapshotted together
    if wealthAdded and hadBaseline and Addon:WealthIntegrityOn() then
        local curMoney = (GetMoney and GetMoney()) or 0
        -- Signed money delta across the gap. Net-cancelling equal/opposite moves is
        -- acceptable — a closed economy cares that wealth reconciles, not the path.
        -- Fold ONLY against a trustworthy prior baseline. A baseline of 0 is the signature of an
        -- unread GetMoney() at login (see snapshotNow) — NOT a genuinely-broke player often enough
        -- to matter — and folding a 0 → N jump (re)counts the player's ENTIRE balance as off-radar
        -- on every gap-login, stacking on each relog (observed: +5g11s → +10g22s → …). Same guard
        -- as the empty-item-baseline path in FoldItemsWhenReady. Trade-off: a genuinely-broke
        -- player (0 copper) who received gold while the addon was off is missed once — conservative,
        -- and far better than repeatedly flagging every member's whole balance.
        if w.money > 0 then
            local delta = curMoney - w.money
            -- Credit a positive (gain) delta against gold last seen sitting in the player's OWN
            -- mailbox (w.mailMoney): taking your own mailed gold into your bags across the gap is a
            -- relocation, not new value entering the closed economy. The scalar mirror of the bag→
            -- mail item credit in foldBagGainsAtLogin. Consume what we use so the same mail gold
            -- can't re-credit on a later gap-login before the next mail open re-samples it. Negative
            -- deltas (a spend) still fold through unchanged — a closed economy cares that wealth
            -- reconciles, not the path — and, like the item side, a wrong guess (a real off-radar
            -- gain equal to gold that also sat in the mailbox) is a deferred/occasional miss, which
            -- we prefer over a false positive.
            if delta > 0 then
                local credit = w.mailMoney or 0
                local used = (credit < delta) and credit or delta
                delta = delta - used
                w.mailMoney = credit - used
            end
            w.unaccountedMoney = (w.unaccountedMoney or 0) + delta
        end
        w.money = curMoney
        -- Bag items that appeared while unmonitored. (An off-radar item parked in the bank
        -- isn't visible here — the bank frame is closed at login — so it's caught later by
        -- the bank-open compare instead.) The container API can lag login by a few seconds,
        -- so this is retried rather than compared once — see FoldItemsWhenReady.
        self:FoldItemsWhenReady(0)
        -- Flip the member's roster row now rather than waiting a full StatusInterval,
        -- exactly as Playtime does after attributing a played gap. (Item count may still be
        -- settling via the retry above; the money change alone is enough to surface a reason.)
        if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
    else
        -- No gap, integrity off, or first-ever snapshot (nothing to compare): just
        -- take a fresh baseline.
        snapshotNow(w)
        self._ready = true
    end
end

-- ---------------------------------------------------------------------------
-- Steady state: while loaded, every money/bag change keeps the baseline current so
-- monitored activity never counts as unaccounted. Debounced for BAG_UPDATE, which
-- fires in bursts.
-- ---------------------------------------------------------------------------
function Integrity:OnMoney()
    if not self._ready then return end
    wealth().money = (GetMoney and GetMoney()) or wealth().money
end

-- Equipped-gear change (payload unit): only the player's own inventory affects our baseline.
-- Routes through the same debounced bag-rescan path so carried = bags + equipped stays current.
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
        w.items = scanBags()
        w.equipInBaseline = true   -- scanBags() includes equipped; keep the migration flag set
        -- A bag change while the bank is open is usually a bags↔bank move; refresh the
        -- bank side too so the transfer stays neutral (only counts once the compare below
        -- has run — see OnBankOpened).
        if self._bankOpen and self._bankCompared then w.bankItems = scanBank() end
    end, 0.5)
end

-- ---------------------------------------------------------------------------
-- Bank sessions. On open we compare the bank against the last monitored bank state to
-- catch items deposited while the addon was off, then keep the bank baseline current for
-- the rest of the session so ordinary (monitored) deposits/withdrawals never count.
-- ---------------------------------------------------------------------------
function Integrity:OnBankOpened()
    self._bankOpen = true
    self._bankCompared = false
    -- Bank container data populates a moment after the frame opens; compare once it's
    -- there. Until the compare runs, in-session refreshes are held off (_bankCompared)
    -- so an early BAG_UPDATE can't overwrite the pre-open baseline first.
    self:ScheduleTimer("BankScanCompare", 0.5)
end

function Integrity:BankScanCompare()
    if not self._bankOpen then return end          -- closed again already
    local w = wealth()
    local cur = scanBank()
    -- Only fold gains once we have a prior bank baseline AND Guild Found is active; the
    -- first bank observation just establishes the reference. No /played-gap gating is
    -- needed — the bank only changes while open, so any difference from the last monitored
    -- bank state necessarily happened while the bank was open but unmonitored (addon off).
    -- Only fold against a POPULATED prior bank baseline, and only when this scan is
    -- populated too — bank container data lands a moment after the frame opens, so an
    -- early empty scan must not become the baseline (it would flag the whole bank on the
    -- next open) nor be diffed as a total loss/gain. Same guard as the bag path above.
    local baseReady = w.bankItems ~= nil and next(w.bankItems) ~= nil
    local curReady  = next(cur) ~= nil
    if baseReady and curReady and Addon:WealthIntegrityOn() then
        local gained = foldBankGains(w, w.bankItems, cur)
        if gained > 0 then
            w.unaccountedItems = (w.unaccountedItems or 0) + gained
            if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
        end
    end
    if curReady then
        w.bankItems = cur
        -- Deposit credit is valid only until the next time we can see the bank: a bag→bank
        -- deposit made across the last gap is visible at THIS open, so whatever wasn't
        -- consumed above (or a first-ever baseline that folds nothing) is discarded now
        -- rather than lingering to mask an unrelated future bank gain of the same itemID.
        w.pendingBankCredit = nil
    end
    self._bankCompared = true
end

function Integrity:OnBankSlots()
    -- A bank slot changed during a session: keep the baseline current (post-compare only).
    if not self._bankOpen or not self._bankCompared or self._bankTimer then return end
    self._bankTimer = self:ScheduleTimer(function()
        self._bankTimer = nil
        if self._bankOpen then wealth().bankItems = scanBank() end
    end, 0.5)
end

function Integrity:OnBankClosed()
    self._bankOpen = false
    self._bankCompared = false
end

-- ---------------------------------------------------------------------------
-- Mail sessions. The inbox is a credit source only (see scanMail / scanMailMoney): we keep
-- w.mailItems and w.mailMoney current while the mail frame is open so a login-time bag/gold gain
-- can be credited against the items and gold the player took from their own mailbox. No gains are
-- folded on the mail side.
--
-- We accumulate the PEAK holdings seen across the frame session (per-item max for items, running
-- max for gold), not the latest scan. Taking an attachment fires its own MAIL_INBOX_UPDATE with
-- the item/gold already gone; a latest-scan model would then shrink the credit and re-expose the
-- relocation as a phantom gain. Sampling synchronously on every update (no debounce) also closes
-- the old race where a take within the 0.5s debounce landed before the one-shot sample ran — the
-- open fires MAIL_INBOX_UPDATE before any attachment is interactable, so the pre-take state is
-- always captured first, and the peak accumulator retains it thereafter.
-- ---------------------------------------------------------------------------
function Integrity:OnMailShow()
    self._mailOpen = true
    -- Fresh per-session peak accumulators. Prior-session w.mailItems/w.mailMoney (from SavedVars)
    -- stay intact until the first fresh sample in OnMailInbox re-populates them, so a member who
    -- opens mail on a gap-login still has last session's credit available for the fold in between.
    self._mailSeen = {}
    self._mailMoneySeen = 0
    -- Inbox items/gold arrive via MAIL_INBOX_UPDATE; the snapshot is taken there once populated.
end

function Integrity:OnMailInbox()
    if not self._mailOpen then return end
    local seen = self._mailSeen
    if not seen then seen = {}; self._mailSeen = seen end   -- update without a preceding MAIL_SHOW
    -- Union current inbox items into the peak set (per-item max), then max the gold. Synchronous by
    -- design — see the section header for why there's no debounce.
    for id, c in pairs(scanMail()) do
        if (seen[id] or 0) < c then seen[id] = c end
    end
    local money = scanMailMoney()
    if money > (self._mailMoneySeen or 0) then self._mailMoneySeen = money end
    local w = wealth()
    w.mailItems = seen
    w.mailMoney = self._mailMoneySeen
end

function Integrity:OnMailClosed()
    self._mailOpen = false
end

-- Final snapshot at logout — the value compared on next login. If we never became
-- ready this session (logged out inside the reconcile window), leave the pre-gap
-- baseline intact so the gap is attributed next session instead of being clobbered.
function Integrity:Flush()
    if not self._ready then return end
    snapshotNow(wealth())
end

-- ---------------------------------------------------------------------------
-- Reporting / clearing (mirrors Playtime:GetUnobserved / Rebaseline)
-- ---------------------------------------------------------------------------
function Integrity:GetUnaccountedMoney()
    return math.floor(wealth().unaccountedMoney or 0)
end

function Integrity:GetUnaccountedItems()
    return math.floor(wealth().unaccountedItems or 0)
end

-- Bounded list of gained itemIDs for the officer display; nil when empty so the ping
-- field is omitted. Capped tighter than storage to keep the guild-comm payload small.
function Integrity:GetItemLog()
    local out = {}
    for id in pairs(wealth().itemLog or {}) do
        out[#out + 1] = id
        if #out >= 10 then break end
    end
    return (#out > 0) and out or nil
end

-- Officer forgive (received via Comm's "WGF"): zero the counters, re-baseline to now,
-- and push a fresh ping so the member's roster row clears guild-wide. Mirrors
-- Playtime:Rebaseline — the two are cleared together by Compliance:OfficerClear.
function Integrity:Rebaseline()
    local w = wealth()
    w.unaccountedMoney = 0
    w.unaccountedItems = 0
    w.itemLog = {}
    w.pendingBankCredit = nil   -- drop any unconsumed deposit credit so it can't mask a post-forgive gain
    snapshotNow(w)
    -- The bank/mail baselines are already current from their last observation; refresh them
    -- only if their frame is open right now.
    if self._bankOpen and self._bankCompared then w.bankItems = scanBank() end
    if self._mailOpen then
        w.mailItems = self._mailSeen or scanMail()
        w.mailMoney = self._mailMoneySeen or scanMailMoney()
    end
    if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
end
