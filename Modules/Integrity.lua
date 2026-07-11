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
-- has to detect the gap itself — it just consumes Playtime:OnLoginAttributed. Bags only
-- (bank contents are unreadable unless the bank frame is open, so a bank baseline would
-- be perpetually stale). Best-effort, like everything else: a tier-1 SavedVariables edit
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
-- Bag scan (bags 0..NUM_BAG_SLOTS only). Returns itemID → total count. Uses the
-- modern C_Container namespace with a fallback to the old globals, and tolerates
-- both GetContainerItemInfo signatures (table on modern clients, multi-return on
-- older ones) — same defensive pattern as Enforcement.lua / UI/BagOverlay.lua.
-- ---------------------------------------------------------------------------
local CC = C_Container
local function scanContainers(bags)
    local counts = {}
    local getSlots = (CC and CC.GetContainerNumSlots) or GetContainerNumSlots
    local getID    = (CC and CC.GetContainerItemID)   or GetContainerItemID
    local getInfo  = (CC and CC.GetContainerItemInfo) or GetContainerItemInfo
    if not getSlots or not getID then return counts end
    for _, bag in ipairs(bags) do
        local n = getSlots(bag) or 0
        for s = 1, n do
            local id = getID(bag, s)
            if id then
                local count = 1
                if getInfo then
                    local a, b = getInfo(bag, s)
                    if type(a) == "table" then
                        count = a.stackCount or 1          -- modern: info table
                    else
                        count = b or 1                     -- old: texture, itemCount, ...
                    end
                end
                counts[id] = (counts[id] or 0) + count
            end
        end
    end
    return counts
end

-- Carried bags: backpack (0) + equipped bags (1..NUM_BAG_SLOTS). Always readable.
local function bagContainers()
    local t = {}
    for b = 0, (NUM_BAG_SLOTS or 4) do t[#t + 1] = b end
    return t
end

-- Bank: the main bank container plus its purchased bag slots. Only readable while the
-- bank frame is open (BANKFRAME_OPENED..BANKFRAME_CLOSED); scanned only in that window.
local function bankContainers()
    local t = { BANK_CONTAINER or -1 }
    local first = (NUM_BAG_SLOTS or 4) + 1
    for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do t[#t + 1] = b end
    return t
end

local function scanBags() return scanContainers(bagContainers()) end
local function scanBank() return scanContainers(bankContainers()) end

local function snapshotNow(w)
    w.money = (GetMoney and GetMoney()) or 0
    w.items = scanBags()
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

-- Count distinct itemIDs whose count in `cur` exceeds `base` (items that appeared while
-- unmonitored), logging each. Items appearing is the closed-economy concern; consumption/
-- vendoring dominates the removal side, so only gains count.
local function foldGains(w, base, cur)
    local gained = 0
    for id, cnt in pairs(cur) do
        if cnt > ((base and base[id]) or 0) then
            gained = gained + 1
            addToLog(w, id)
        end
    end
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
    self:RegisterEvent("PLAYER_LOGOUT", "Flush")
    -- Bank: only observable while its frame is open, so it's tracked as a separate
    -- baseline sampled during bank sessions (see OnBankOpened). An item parked in the
    -- bank while the addon was off wouldn't show in bags at login — it's caught the next
    -- time the bank is opened with the addon on.
    self:RegisterEvent("BANKFRAME_OPENED", "OnBankOpened")
    self:RegisterEvent("BANKFRAME_CLOSED", "OnBankClosed")
    self:RegisterEvent("PLAYERBANKSLOTS_CHANGED", "OnBankSlots")
    -- Safety net: if Playtime never attributes a login (e.g. the server never answers
    -- TIME_PLAYED), still take a baseline so steady-state tracking and the logout flush
    -- work. Comfortably after Playtime's reconcile window closes.
    self:ScheduleTimer("ForceReady", 30)
end

function Integrity:ForceReady()
    if self._ready then return end
    snapshotNow(wealth())
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
        local curItems = scanBags()
        -- Signed money delta across the gap. Net-cancelling equal/opposite moves is
        -- acceptable — a closed economy cares that wealth reconciles, not the path.
        w.unaccountedMoney = (w.unaccountedMoney or 0) + (curMoney - w.money)
        -- Bag items that appeared while unmonitored. (An off-radar item parked in the bank
        -- isn't visible here — the bank frame is closed at login — so it's caught later by
        -- the bank-open compare instead.)
        w.unaccountedItems = (w.unaccountedItems or 0) + foldGains(w, w.items, curItems)
        w.money, w.items = curMoney, curItems
        self._ready = true
        -- Flip the member's roster row now rather than waiting a full StatusInterval,
        -- exactly as Playtime does after attributing a played gap.
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

function Integrity:OnBagUpdate()
    if not self._ready or self._bagTimer then return end
    self._bagTimer = self:ScheduleTimer(function()
        self._bagTimer = nil
        if not self._ready then return end
        wealth().items = scanBags()
        -- A bag change while the bank is open is usually a bags↔bank move; refresh the
        -- bank side too so the transfer stays neutral (only counts once the compare below
        -- has run — see OnBankOpened).
        if self._bankOpen and self._bankCompared then wealth().bankItems = scanBank() end
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
    if w.bankItems ~= nil and Addon:WealthIntegrityOn() then
        local gained = foldGains(w, w.bankItems, cur)
        if gained > 0 then
            w.unaccountedItems = (w.unaccountedItems or 0) + gained
            if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
        end
    end
    w.bankItems = cur
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
    snapshotNow(w)
    -- The bank baseline is already current from the last bank observation (the discrepancy
    -- was folded and bankItems updated then); refresh it only if the bank is open right now.
    if self._bankOpen and self._bankCompared then w.bankItems = scanBank() end
    if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
end
