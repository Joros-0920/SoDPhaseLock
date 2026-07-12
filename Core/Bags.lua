local ADDON, ns = ...

-- ---------------------------------------------------------------------------
-- Shared low-level bag/bank container scanning. The single home for the
-- C_Container-vs-globals fallback (WoW 10.x moved GetContainer* under C_Container)
-- and the two GetContainerItemInfo signatures (modern info table vs old
-- multi-return). Previously reimplemented, with subtle drift, in Integrity.lua
-- (wealth scan), Enforcement.lua (free-slot search) and UI/BagOverlay.lua
-- (bag diagnostics). Callers pass a container-id list from bagIDs()/bankIDs().
-- ---------------------------------------------------------------------------
local Bags = {}
ns.Bags = Bags

local CC = C_Container

-- Resolve the scan primitives on each call — they can read nil very early at
-- login before the container API is ready (fail-safe: callers see empty scans).
local function api()
    return (CC and CC.GetContainerNumSlots) or GetContainerNumSlots,
           (CC and CC.GetContainerItemID)   or GetContainerItemID,
           (CC and CC.GetContainerItemInfo) or GetContainerItemInfo
end

-- Carried bags: backpack (0) + equipped bag slots (1..NUM_BAG_SLOTS). Always readable.
function Bags.bagIDs()
    local t = {}
    for b = 0, (NUM_BAG_SLOTS or 4) do t[#t + 1] = b end
    return t
end

-- Bank: the main bank container plus its purchased bag slots. Only readable while
-- the bank frame is open (BANKFRAME_OPENED..BANKFRAME_CLOSED).
function Bags.bankIDs()
    local t = { BANK_CONTAINER or -1 }
    local first = (NUM_BAG_SLOTS or 4) + 1
    for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do t[#t + 1] = b end
    return t
end

-- Iterate every OCCUPIED slot of the given container ids, calling
-- fn(bag, slot, itemID, count). Empty slots are skipped. `count` is the stack size,
-- normalised across both GetContainerItemInfo signatures (defaults to 1 when the
-- info isn't available yet).
function Bags.forEach(ids, fn)
    local getSlots, getID, getInfo = api()
    if not (getSlots and getID) then return end
    for _, bag in ipairs(ids) do
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
                fn(bag, s, id, count)
            end
        end
    end
end

-- itemID → total count across the given containers.
function Bags.counts(ids)
    local counts = {}
    Bags.forEach(ids, function(_, _, id, count)
        counts[id] = (counts[id] or 0) + count
    end)
    return counts
end

-- First EMPTY slot across the given containers, as (bag, slot); nil when all full.
-- Its own loop (not forEach, which skips empty slots).
function Bags.firstFreeSlot(ids)
    local getSlots, getID = api()
    if not (getSlots and getID) then return nil end
    for _, bag in ipairs(ids) do
        local n = getSlots(bag) or 0
        for s = 1, n do
            if not getID(bag, s) then return bag, s end
        end
    end
end
