local ADDON, ns = ...
local Addon = ns.Addon

-- Playtime-gap detection: measure how much server /played ("total time played")
-- accrued while THIS addon was NOT loaded, and report that as a durable, retroactive
-- integrity signal. Server /played is authoritative and monotonic (a player cannot
-- lower it, and it accrues exactly while the character is in-world), so a member who
-- disables the addon for a raid and re-enables it after leaves a gap baked into
-- /played that we compute the next time they log in with the addon — no officer has
-- to witness it live (unlike "Addon Not Detected"). See PROGRESS.md → integrity model.
--
-- Threat tier (best-effort, like everything else): this closes tier-0 ("just don't
-- run it") much more thoroughly. A tier-1 SavedVariables edit (bump the local counter
-- to match the server) still defeats it; a tier-2 code edit can forge up=0. Both are
-- unpreventable on an untrusted client and accepted.
local Playtime = Addon:NewModule("Playtime", "AceEvent-3.0", "AceTimer-3.0")
ns.Playtime = Playtime

-- Slop absorbed before any cross-session growth counts as "played with addon off":
-- logout/login processing, loading screens, and up to ADVANCE_INTERVAL of `observed`
-- advancement lost to a hard crash (no PLAYER_LOGOUT). Each such slip is < TOLERANCE,
-- so none is miscounted.
local TOLERANCE = 180
local ADVANCE_INTERVAL = 60
-- How long after login we let the guild answer our high-water query (Comm sends the
-- "PWQ" a few seconds in) before attributing any cross-session gap. Must comfortably
-- exceed Comm's PWQ send + reply jitter so an honest alternate PC adopts its shared
-- witness value first. The /played request is issued only once this window closes.
local RECONCILE_WINDOW = 15

-- Session-only anchors (NEVER persisted). GetTime() is seconds since the client
-- process started and RESETS on a full client restart, so it is not comparable across
-- sessions and must not be saved — cross-session detection keys entirely on the server
-- /played value (db.char.playtime.observed).
local anchorServer   -- server /played at the last TIME_PLAYED_MSG this session
local anchorLocal    -- GetTime() at that instant

local function pt()
    return Addon.db.char.playtime
end

-- ---------------------------------------------------------------------------
-- Chat suppression for the "Total time played:" line we trigger ourselves.
-- We request /played once per login (and on a forgive), and Blizzard's default
-- UI prints the total-time line in response. Override the printer to swallow any
-- print within a short window after our own request. Existence-guarded — if the
-- global isn't present on this build, worst case is one printed line.
-- ---------------------------------------------------------------------------
local origDisplay
local function installSuppression()
    if origDisplay ~= nil then return end
    if type(ChatFrame_DisplayTimePlayed) ~= "function" then
        origDisplay = false
        return
    end
    origDisplay = ChatFrame_DisplayTimePlayed
    ChatFrame_DisplayTimePlayed = function(...)
        if Playtime._suppressUntil and GetTime() < Playtime._suppressUntil then
            return
        end
        return origDisplay(...)
    end
end

-- Ask the server for /played, suppressing the resulting chat line.
local function requestPlayed()
    Playtime._suppressUntil = GetTime() + 5
    if RequestTimePlayed then RequestTimePlayed() end
end

-- First-of-session gap attribution. `base` is the max of our own saved high-water and
-- any value the guild reconciled for us (a member on an alternate PC), capped at our
-- real /played so a forged peer value can never baseline us beyond what we've played.
-- Everything /played grew beyond that base happened with the addon NOT loaded ANYWHERE.
local function attributeLogin(serverNow)
    local p = pt()
    local base = p.observed
    if Playtime._reconciledOb then
        base = math.max(base, math.min(Playtime._reconciledOb, serverNow))
    end
    local gap = serverNow - base
    local added = gap > TOLERANCE
    if added then
        p.unobserved = (p.unobserved or 0) + gap
    end
    p.observed = serverNow
    anchorServer = serverNow
    anchorLocal  = GetTime()
    Playtime._reconciledOb  = nil
    Playtime._pendingServer = nil
    -- The first status ping fires (6-14s in) BEFORE this attribution completes
    -- (the reconcile window holds it ~15-20s), so that ping reported up=0 and the
    -- member reads "compliant". Push a fresh ping the moment a login gap is found so
    -- the roster flips to the violation now, instead of waiting a full StatusInterval
    -- (>=60s) for the next scheduled tick. Mirrors Rebaseline()'s re-ping after a forgive.
    if added and ns.Comm and ns.Comm.SendStatus then
        ns.Comm:SendStatus()
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Playtime:OnEnable()
    installSuppression()
    self:RegisterEvent("TIME_PLAYED_MSG", "OnTimePlayed")
    self:RegisterEvent("PLAYER_LOGOUT", "AdvanceObserved")
    self._reconcileDone = false
    -- Hold cross-session attribution until the guild has had a chance to answer our
    -- high-water query (Comm sends "PWQ" ~2-8s in); the /played read is issued when the
    -- window closes. One server read per session catches the gap; during the session we
    -- self-account with GetTime (see AdvanceObserved), so no further polling is needed.
    self:ScheduleTimer("FinishReconcile", RECONCILE_WINDOW + math.random() * 4)
    -- Keep `observed` current so a crash loses at most ADVANCE_INTERVAL of it.
    self.advanceTimer = self:ScheduleRepeatingTimer("AdvanceObserved", ADVANCE_INTERVAL)
end

-- Reconciliation window closed: attribute a login gap we deferred (an early/unsolicited
-- TIME_PLAYED_MSG), or, if none arrived yet, request /played now (its reply lands after
-- the window, so it attributes immediately).
function Playtime:FinishReconcile()
    self._reconcileDone = true
    if self._pendingServer then
        attributeLogin(self._pendingServer)
    else
        requestPlayed()
    end
end

-- ---------------------------------------------------------------------------
-- Core algorithm
-- ---------------------------------------------------------------------------
function Playtime:OnTimePlayed(_, totalTime)
    local serverNow = totalTime
    if type(serverNow) ~= "number" then return end
    local p = pt()

    if p.observed == nil then
        -- First TIME_PLAYED ever on this character: baseline. All pre-install
        -- playtime is intentionally never counted.
        p.observed = serverNow
        p.unobserved = p.unobserved or 0
        anchorServer = serverNow
        anchorLocal  = GetTime()
    elseif anchorServer == nil then
        -- First message of THIS session (login). Defer attribution until the guild
        -- reconciliation window has closed so an honest alternate PC can adopt its
        -- shared high-water first; an early/unsolicited message is stashed for it.
        if not self._reconcileDone then
            self._pendingServer = serverNow
            return
        end
        attributeLogin(serverNow)
    else
        -- In-session refresh (a forgive re-request, or the player typed /played):
        -- re-anchor to the authoritative value, never add a gap.
        p.observed = serverNow
        anchorServer = serverNow
        anchorLocal  = GetTime()
    end
end

-- Advance `observed` by in-session wall-clock. While the addon is loaded the character
-- is in-world, so elapsed real time == /played growth; no server call is needed. Runs
-- on the repeating timer and on PLAYER_LOGOUT (final flush).
function Playtime:AdvanceObserved()
    if anchorServer then
        pt().observed = anchorServer + (GetTime() - anchorLocal)
    end
end

-- ---------------------------------------------------------------------------
-- Reporting / clearing
-- ---------------------------------------------------------------------------
-- Cumulative unobserved playtime (seconds) reported in the status ping. Each receiver
-- compares this against its own synced Addon:PlayedGapThreshold().
function Playtime:GetUnobserved()
    return math.floor(pt().unobserved or 0)
end

-- Our witnessed-/played high-water (seconds), broadcast in the ping so the guild can
-- remember it and hand it back to us on an alternate PC. nil until first baselined.
function Playtime:GetObserved()
    local o = pt().observed
    return o and math.floor(o) or nil
end

-- A guildmate (peer) answered our high-water query: fold it into the value we'll use
-- for this session's login attribution. Taken as a max, and later capped at our real
-- /played in attributeLogin, so this can only ever RAISE the baseline (forgive), never
-- create a gap. Only meaningful during the reconciliation window, before attribution.
function Playtime:AdoptWitness(ob)
    if type(ob) == "number" and ob > 0 then
        self._reconciledOb = math.max(self._reconciledOb or 0, ob)
    end
end

-- Officer forgive (received via Comm's "PGF"): zero the counter and re-baseline
-- `observed` to now so we don't recount, then push a fresh status ping so the member's
-- roster row clears guild-wide. `anchorServer` is set by the ~10s login request well
-- before any officer could forgive, so the re-request below hits the in-session branch
-- (no gap re-added).
function Playtime:Rebaseline()
    local p = pt()
    p.unobserved = 0
    if anchorServer then
        p.observed = anchorServer + (GetTime() - anchorLocal)
    end
    requestPlayed()
    if ns.Comm and ns.Comm.SendStatus then ns.Comm:SendStatus() end
end
