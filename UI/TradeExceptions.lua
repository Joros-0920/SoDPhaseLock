local ADDON, ns = ...
local Addon = ns.Addon
local AceGUI = LibStub("AceGUI-3.0")

-- ---------------------------------------------------------------------------
-- Guild Found → Trade Exceptions editor.
-- Guild-leader-controlled allowlist of item IDs that may be traded with players
-- outside the guild (gold never can). Type an ID to preview the item, add it to
-- the list; the list is part of the synced ruleset. Non-leaders see it read-only.
-- ---------------------------------------------------------------------------

local frame          -- the AceGUI Frame, or nil when closed
local ui = {}        -- persistent widget refs (editbox, preview, add button, scroll)
local currentID      -- the item ID currently parsed from the editbox, or nil

-- Item info for display: an inline-icon + quality-colored name string, plus link.
-- Icon resolves instantly (GetItemInfoInstant); name/quality/link may load async.
local function itemDisplay(id)
    local link, name, quality
    name, link, quality = GetItemInfo(id)
    local icon = select(5, GetItemInfoInstant(id))
    local text
    if name then
        local q = ITEM_QUALITY_COLORS[quality or 1]
        text = (q and q.hex or "|cffffffff") .. name .. "|r"
    else
        text = "|cffaaaaaaItem #" .. tostring(id) .. " (loading…)|r"
    end
    if icon then text = "|T" .. icon .. ":18:18:0:0|t " .. text end
    return text, link, (name ~= nil)
end

local function showItemTooltip(owner, id, link)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if link then
        GameTooltip:SetHyperlink(link)
    elseif GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(id)
    end
    GameTooltip:Show()
end

local function sortedIDs()
    local ex = Addon:GetRuleset().guildFound.tradeExceptions
    local ids = {}
    for id in pairs(ex) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- Mutations go through the shared guild-leader commit path (bump epoch + broadcast).
local function addException(id)
    if not id then return end
    Addon:GetRuleset().guildFound.tradeExceptions[id] = true
    local text = itemDisplay(id)
    Addon:CommitGuildSettings(true)
    Addon:Print("Trade exception added: " .. text)
end

local function removeException(id)
    local text = itemDisplay(id)
    Addon:GetRuleset().guildFound.tradeExceptions[id] = nil
    Addon:CommitGuildSettings(true)
    Addon:Print("Trade exception removed: " .. text)
end

-- ---------------------------------------------------------------------------
-- Preview: reflect whatever is typed in the editbox (no list rebuild, so focus
-- and caret are preserved while typing).
local function updatePreview()
    if not ui.preview then return end
    local canEdit = Addon:IsGuildLeader()
    if not currentID then
        ui.preview:SetText("|cff808080Enter an item ID above.|r")
        ui.preview:SetCallback("OnEnter", nil)
        if ui.add then ui.add:SetDisabled(true) end
        return
    end
    local text, link = itemDisplay(currentID)
    ui.preview:SetText(text)
    ui.preview:SetCallback("OnEnter", function(w) showItemTooltip(w.frame, currentID, link) end)
    ui.preview:SetCallback("OnLeave", function() GameTooltip:Hide() end)
    local already = Addon:GetRuleset().guildFound.tradeExceptions[currentID]
    if ui.add then ui.add:SetDisabled(not canEdit or already ~= nil) end
end

-- ---------------------------------------------------------------------------
-- Rebuild the current-exceptions list (called on add/remove and item-info load).
local function refreshList()
    if not (frame and ui.scroll) then return end
    local scroll = ui.scroll
    scroll:ReleaseChildren()

    local canEdit = Addon:IsGuildLeader()
    local ids = sortedIDs()

    if #ids == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetFullWidth(true)
        lbl:SetText("\n|cffff8080No exceptions.|r While Trade Between Guild Members is on, no items can be traded outside the guild.")
        scroll:AddChild(lbl)
    else
        for _, id in ipairs(ids) do
            local row = AceGUI:Create("SimpleGroup")
            row:SetFullWidth(true)
            row:SetLayout("Flow")

            local text, link = itemDisplay(id)
            local name = AceGUI:Create("InteractiveLabel")
            name:SetRelativeWidth(canEdit and 0.75 or 1.0)
            name:SetText(text)
            name:SetCallback("OnEnter", function(w) showItemTooltip(w.frame, id, link) end)
            name:SetCallback("OnLeave", function() GameTooltip:Hide() end)
            row:AddChild(name)

            if canEdit then
                local rm = AceGUI:Create("Button")
                rm:SetRelativeWidth(0.25)
                rm:SetText("Remove")
                rm:SetCallback("OnClick", function()
                    removeException(id)
                    refreshList()
                    updatePreview()
                end)
                row:AddChild(rm)
            end
            scroll:AddChild(row)
        end
    end
    if frame then
        frame:SetStatusText(string.format("%d exception item(s)%s", #ids,
            Addon:IsGuildLeader() and "" or " - read-only"))
    end
end

-- Refresh hook so an incoming broadcast (another officer's edit) updates a window
-- that happens to be open. Called from Core's ApplyRuleset.
function ns.RefreshTradeExceptions()
    if not frame then return end
    refreshList()
    updatePreview()
end

-- ---------------------------------------------------------------------------
-- Item data loading: names/icons for uncached IDs arrive later; refresh when they do.
local infoWatcher = CreateFrame("Frame")
infoWatcher:Hide()
infoWatcher:SetScript("OnEvent", function()
    if not frame then return end
    updatePreview()
    refreshList()
end)

-- ---------------------------------------------------------------------------
function ns.ToggleTradeExceptions()
    if frame then
        frame:Release()
        return
    end
    local canEdit = Addon:IsGuildLeader()

    frame = AceGUI:Create("Frame")
    frame:SetTitle("Guild Found — Trade Exceptions")
    frame:SetLayout("List")
    frame:SetWidth(460)
    frame:SetHeight(480)
    frame:SetCallback("OnClose", function(widget)
        infoWatcher:UnregisterAllEvents()
        infoWatcher:Hide()
        AceGUI:Release(widget)
        frame = nil
        ui = {}
        currentID = nil
    end)

    local intro = AceGUI:Create("Label")
    intro:SetFullWidth(true)
    intro:SetText("Items on this list may be traded with players outside your guild, or with anyone if you're not in a guild, as long as the trade contains only listed items. Trades between guild members are always unrestricted. If the list is empty, no such trades can be completed.\n")
    frame:AddChild(intro)

    -- The blanket exemptions (conjured items, trade-window drops) live in the main
    -- options panel, nested under the Trade toggle — not here.

    -- Input row: item ID editbox + live preview.
    local inputGroup = AceGUI:Create("SimpleGroup")
    inputGroup:SetFullWidth(true)
    inputGroup:SetLayout("Flow")
    frame:AddChild(inputGroup)

    local edit = AceGUI:Create("EditBox")
    edit:SetLabel("Add item by ID")
    edit:SetRelativeWidth(0.55)
    edit:SetDisabled(not canEdit)
    edit:SetCallback("OnTextChanged", function(_, _, text)
        currentID = tonumber((text or ""):match("%d+"))
        updatePreview()
    end)
    edit:SetCallback("OnEnterPressed", function(widget, _, text)
        currentID = tonumber((text or ""):match("%d+"))
        if canEdit and currentID and not Addon:GetRuleset().guildFound.tradeExceptions[currentID] then
            addException(currentID)
            widget:SetText("")
            currentID = nil
            refreshList()
            updatePreview()
        end
    end)
    inputGroup:AddChild(edit)
    ui.edit = edit

    local add = AceGUI:Create("Button")
    add:SetText("Add")
    add:SetRelativeWidth(0.20)
    add:SetDisabled(true)
    add:SetCallback("OnClick", function()
        if canEdit and currentID and not Addon:GetRuleset().guildFound.tradeExceptions[currentID] then
            addException(currentID)
            edit:SetText("")
            currentID = nil
            refreshList()
            updatePreview()
        end
    end)
    inputGroup:AddChild(add)
    ui.add = add

    local preview = AceGUI:Create("InteractiveLabel")
    preview:SetFullWidth(true)
    ui.preview = preview
    inputGroup:AddChild(preview)

    -- Scrollable list of current exceptions.
    local scrollContainer = AceGUI:Create("SimpleGroup")
    scrollContainer:SetFullWidth(true)
    scrollContainer:SetLayout("Fill")
    scrollContainer:SetHeight(300)
    frame:AddChild(scrollContainer)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scrollContainer:AddChild(scroll)
    ui.scroll = scroll

    infoWatcher:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    infoWatcher:Show()

    updatePreview()
    refreshList()
end
