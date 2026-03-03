local addonFrame = CreateFrame("Frame")
local openDialog

local state = {
    debug = true,
    entries = {},
    guildUiHooked = false,
    buttonRetryPending = false,
    communitiesDisplayHooked = false,
    lastButtonVisible = nil,
    ui = {
        dialog = nil,
        rows = {},
        filtered = {},
        sortKey = "timeSort",
        sortAsc = false,
    },
}

local function log(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffGuildLootList|r " .. tostring(message))
end

local function debugLog(message)
    if state.debug then
        log("[DEBUG] " .. tostring(message))
    end
end

local function setupSlashCommands()
    SLASH_GUILDLOOTLIST1 = "/gll"
    SlashCmdList.GUILDLOOTLIST = function(msg)
        local command = string.lower(strtrim(msg or ""))
        if command == "debug" then
            state.debug = not state.debug
            log("Debug " .. (state.debug and "enabled" or "disabled"))
        else
            log("Commands: /gll debug")
        end
    end
end

local function safeNumber(value, fallback)
    local num = tonumber(value)
    if num then
        return num
    end
    return fallback
end

local function normalizePlayerName(name)
    if not name or name == "" then
        return "Unknown"
    end
    return Ambiguate(name, "short")
end

local function getItemLinkFromText(text)
    if not text then
        return nil
    end
    return string.match(text, "(|Hitem:[^|]+|h%[[^%]]+%]|h)")
end

local function getItemName(itemLink)
    if not itemLink then
        return ""
    end
    return C_Item.GetItemNameByID(itemLink) or itemLink
end

local function getItemQualityColor(itemLink)
    if not itemLink then
        return nil
    end

    local quality = C_Item.GetItemQualityByID(itemLink)
    if quality == nil then
        return nil
    end

    local _, _, _, colorHex = C_Item.GetItemQualityColor(quality)
    if colorHex and colorHex ~= "" then
        return colorHex
    end
    return nil
end

local function colorizeText(colorHex, text)
    if not colorHex or not text then
        return text
    end
    local normalizedHex = string.gsub(colorHex, "^|c", "")
    if string.sub(normalizedHex, 1, 2) ~= "ff" and string.len(normalizedHex) == 6 then
        normalizedHex = "ff" .. normalizedHex
    end
    return "|c" .. normalizedHex .. tostring(text) .. "|r"
end

local function formatCharacterText(entry)
    local baseName = entry.player or "Unknown"
    local withLevel = baseName
    if safeNumber(entry.level, 0) > 0 then
        withLevel = string.format("%d %s", entry.level, baseName)
    end

    if entry.classFile and entry.classFile ~= "" then
        local _, _, _, classHex = GetClassColor(entry.classFile)
        if classHex and classHex ~= "" then
            return colorizeText(classHex, withLevel)
        end
    end

    return withLevel
end

local function formatItemText(entry)
    local itemName = entry.itemName or getItemName(entry.itemLink)
    return colorizeText(entry.itemQualityHex, itemName)
end

local function getItemLevel(itemLink)
    if not itemLink then
        return 0
    end
    local level = C_Item.GetDetailedItemLevelInfo(itemLink)
    return safeNumber(level, 0)
end

local function buildDateTextAndSortValue(newsInfo)
    local year = safeNumber(newsInfo.year, 0)
    local month = safeNumber(newsInfo.month, 0) + 1
    local day = safeNumber(newsInfo.day, 0) + 1

    if year > 0 and year < 100 then
        year = year + 2000
    end

    if year > 0 and month >= 1 and month <= 12 and day >= 1 and day <= 31 then
        local sortValue = (year * 10000) + (month * 100) + day
        return string.format("%04d-%02d-%02d", year, month, day), sortValue
    end

    return "Unknown", 0
end

local function rebuildEntriesFromGuildNews()
    wipe(state.entries)

    if not IsInGuild() or type(GetNumGuildNews) ~= "function" then
        debugLog("Skipping guild news rebuild (not in guild or GetNumGuildNews unavailable)")
        return
    end

    local rosterByName = {}
    local memberCount = safeNumber(GetNumGuildMembers(), 0)
    for rosterIndex = 1, memberCount do
        local rosterName, _, _, level, _, _, _, _, _, _, classFile = GetGuildRosterInfo(rosterIndex)
        if rosterName and rosterName ~= "" then
            local normalizedName = normalizePlayerName(rosterName)
            rosterByName[normalizedName] = {
                level = safeNumber(level, 0),
                classFile = classFile,
            }
        end
    end

    local totalNews = safeNumber(GetNumGuildNews(), 0)
    debugLog("Rebuilding from guild news. totalNews=" .. tostring(totalNews))
    for index = 1, totalNews do
        local newsInfo = C_GuildInfo.GetGuildNewsInfo(index)
        if newsInfo then
            local itemLink = getItemLinkFromText(newsInfo.whatText)
            if itemLink then
                local dateText, dateSort = buildDateTextAndSortValue(newsInfo)
                local playerName = normalizePlayerName(newsInfo.whoText)
                local rosterMeta = rosterByName[playerName]
                table.insert(state.entries, {
                    player = playerName,
                    level = rosterMeta and rosterMeta.level or 0,
                    classFile = rosterMeta and rosterMeta.classFile or nil,
                    itemLink = itemLink,
                    itemName = getItemName(itemLink),
                    itemQualityHex = getItemQualityColor(itemLink),
                    itemLevel = getItemLevel(itemLink),
                    timeText = dateText,
                    timeSort = dateSort,
                })
            end
        end
    end
    debugLog("Guild news loot entries collected=" .. tostring(#state.entries))
end

local function refreshTable()
    local dialog = state.ui.dialog
    if not dialog or not dialog:IsShown() then
        return
    end

    local charFilter = string.lower(strtrim(dialog.charFilterBox:GetText() or ""))
    local itemFilter = string.lower(strtrim(dialog.itemFilterBox:GetText() or ""))
    local minIlvl = safeNumber(dialog.minIlvlBox:GetText(), 0)

    wipe(state.ui.filtered)

    for _, entry in ipairs(state.entries) do
        local playerMatch = true
        local itemMatch = true
        local ilvlMatch = true

        if charFilter ~= "" then
            playerMatch = string.find(string.lower(entry.player or ""), charFilter, 1, true) ~= nil
        end

        if itemFilter ~= "" then
            local itemName = entry.itemName or getItemName(entry.itemLink)
            itemMatch = string.find(string.lower(itemName), itemFilter, 1, true) ~= nil
        end

        if minIlvl > 0 then
            ilvlMatch = (entry.itemLevel or 0) >= minIlvl
        end

        if playerMatch and itemMatch and ilvlMatch then
            table.insert(state.ui.filtered, entry)
        end
    end

    table.sort(state.ui.filtered, function(a, b)
        local key = state.ui.sortKey
        local av = a[key]
        local bv = b[key]

        if key == "itemLink" then
            av = a.itemName or getItemName(a.itemLink)
            bv = b.itemName or getItemName(b.itemLink)
        end

        if av == bv then
            return (a.timeSort or 0) > (b.timeSort or 0)
        end

        if state.ui.sortAsc then
            return av < bv
        end

        return av > bv
    end)

    local total = #state.ui.filtered
    local visibleRows = #state.ui.rows
    local rowHeight = 22
    local scrollMax = math.max(0, (total - visibleRows) * rowHeight)

    dialog.scrollFrame.ScrollBar:SetMinMaxValues(0, scrollMax)
    local offset = math.floor(dialog.scrollFrame.ScrollBar:GetValue() / rowHeight)

    for rowIndex = 1, visibleRows do
        local dataIndex = rowIndex + offset
        local row = state.ui.rows[rowIndex]
        local entry = state.ui.filtered[dataIndex]

        if entry then
            row.character:SetText(formatCharacterText(entry))
            row.item:SetText(formatItemText(entry))
            row.ilvl:SetText(tostring(entry.itemLevel or 0))
            row.time:SetText(entry.timeText or "Unknown")
            row:Show()
        else
            row:Hide()
        end
    end

    dialog.countText:SetText(string.format("%d entries", total))
end

local function toggleSort(key)
    if state.ui.sortKey == key then
        state.ui.sortAsc = not state.ui.sortAsc
    else
        state.ui.sortKey = key
        state.ui.sortAsc = false
    end
    refreshTable()
end

local function createHeaderButton(parent, text, width, anchorTo, relativeTo, anchorPoint, x, y, sortKey)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 20)
    button:SetPoint(anchorTo, relativeTo, anchorPoint, x, y)
    button:SetText(text)
    button:SetScript("OnClick", function()
        toggleSort(sortKey)
    end)
    return button
end

local function createDialog()
    if state.ui.dialog then
        return state.ui.dialog
    end

    local dialog = CreateFrame("Frame", "GuildLootListDialog", UIParent, "BasicFrameTemplateWithInset")
    dialog:SetSize(760, 520)
    dialog:SetPoint("CENTER")
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()

    dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dialog.title:SetPoint("CENTER", dialog.TitleBg, "CENTER", 0, 0)
    dialog.title:SetText("Guild Loot List")

    local closeButton = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -2, -2)

    dialog.charFilterLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.charFilterLabel:SetPoint("TOPLEFT", dialog, "TOPLEFT", 18, -36)
    dialog.charFilterLabel:SetText("Character")

    dialog.charFilterBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    dialog.charFilterBox:SetSize(160, 20)
    dialog.charFilterBox:SetPoint("LEFT", dialog.charFilterLabel, "RIGHT", 8, 0)
    dialog.charFilterBox:SetAutoFocus(false)

    dialog.itemFilterLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.itemFilterLabel:SetPoint("LEFT", dialog.charFilterBox, "RIGHT", 18, 0)
    dialog.itemFilterLabel:SetText("Item")

    dialog.itemFilterBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    dialog.itemFilterBox:SetSize(180, 20)
    dialog.itemFilterBox:SetPoint("LEFT", dialog.itemFilterLabel, "RIGHT", 8, 0)
    dialog.itemFilterBox:SetAutoFocus(false)

    dialog.minIlvlLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.minIlvlLabel:SetPoint("LEFT", dialog.itemFilterBox, "RIGHT", 18, 0)
    dialog.minIlvlLabel:SetText("Min ilvl")

    dialog.minIlvlBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    dialog.minIlvlBox:SetSize(60, 20)
    dialog.minIlvlBox:SetPoint("LEFT", dialog.minIlvlLabel, "RIGHT", 8, 0)
    dialog.minIlvlBox:SetNumeric(true)
    dialog.minIlvlBox:SetAutoFocus(false)

    local applyFilterButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    applyFilterButton:SetSize(70, 20)
    applyFilterButton:SetPoint("LEFT", dialog.minIlvlBox, "RIGHT", 12, 0)
    applyFilterButton:SetText("Apply")
    applyFilterButton:SetScript("OnClick", refreshTable)

    local resetFilterButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    resetFilterButton:SetSize(70, 20)
    resetFilterButton:SetPoint("LEFT", applyFilterButton, "RIGHT", 6, 0)
    resetFilterButton:SetText("Reset")
    resetFilterButton:SetScript("OnClick", function()
        dialog.charFilterBox:SetText("")
        dialog.itemFilterBox:SetText("")
        dialog.minIlvlBox:SetText("")
        refreshTable()
    end)

    local tableFrame = CreateFrame("Frame", nil, dialog, "InsetFrameTemplate")
    tableFrame:SetPoint("TOPLEFT", dialog, "TOPLEFT", 16, -68)
    tableFrame:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -36, 40)

    createHeaderButton(tableFrame, "Character", 140, "TOPLEFT", tableFrame, "TOPLEFT", 6, -6, "player")
    createHeaderButton(tableFrame, "Item", 300, "TOPLEFT", tableFrame, "TOPLEFT", 150, -6, "itemLink")
    createHeaderButton(tableFrame, "iLvl", 80, "TOPLEFT", tableFrame, "TOPLEFT", 454, -6, "itemLevel")
    createHeaderButton(tableFrame, "Time", 180, "TOPLEFT", tableFrame, "TOPLEFT", 538, -6, "timeSort")

    dialog.scrollFrame = CreateFrame("ScrollFrame", nil, tableFrame, "UIPanelScrollFrameTemplate")
    dialog.scrollFrame:SetPoint("TOPLEFT", tableFrame, "TOPLEFT", 6, -30)
    dialog.scrollFrame:SetPoint("BOTTOMRIGHT", tableFrame, "BOTTOMRIGHT", -26, 6)

    local content = CreateFrame("Frame", nil, dialog.scrollFrame)
    content:SetSize(680, 1)
    dialog.scrollFrame:SetScrollChild(content)
    dialog.content = content

    local rowHeight = 22
    local maxVisibleRows = 16

    for i = 1, maxVisibleRows do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(680, rowHeight)
        if i == 1 then
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", state.ui.rows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        row.background = row:CreateTexture(nil, "BACKGROUND")
        row.background:SetAllPoints()
        if i % 2 == 0 then
            row.background:SetColorTexture(1, 1, 1, 0.04)
        else
            row.background:SetColorTexture(1, 1, 1, 0.01)
        end

        row.character = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.character:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.character:SetWidth(140)
        row.character:SetJustifyH("LEFT")

        row.item = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.item:SetPoint("LEFT", row.character, "RIGHT", 4, 0)
        row.item:SetWidth(300)
        row.item:SetJustifyH("LEFT")

        row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.ilvl:SetPoint("LEFT", row.item, "RIGHT", 4, 0)
        row.ilvl:SetWidth(80)
        row.ilvl:SetJustifyH("LEFT")

        row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.time:SetPoint("LEFT", row.ilvl, "RIGHT", 4, 0)
        row.time:SetWidth(180)
        row.time:SetJustifyH("LEFT")

        table.insert(state.ui.rows, row)
    end

    dialog.scrollFrame.ScrollBar:SetScript("OnValueChanged", refreshTable)

    dialog.countText = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dialog.countText:SetPoint("BOTTOMLEFT", dialog, "BOTTOMLEFT", 18, 16)
    dialog.countText:SetText("0 entries")

    local clearButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    clearButton:SetSize(90, 22)
    clearButton:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -18, 12)
    clearButton:SetText("Clear All")
    clearButton:SetScript("OnClick", function()
        wipe(state.entries)
        refreshTable()
    end)

    dialog.charFilterBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        refreshTable()
    end)
    dialog.itemFilterBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        refreshTable()
    end)
    dialog.minIlvlBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        refreshTable()
    end)

    dialog:SetScript("OnShow", refreshTable)

    state.ui.dialog = dialog
    return dialog
end

openDialog = function()
    local dialog = createDialog()
    if dialog then
        rebuildEntriesFromGuildNews()
        dialog:Show()
        refreshTable()
    end
end

local function isAddonLoaded(addonName)
    if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function" then
        return C_AddOns.IsAddOnLoaded(addonName)
    end
    local legacyIsAddonLoaded = rawget(_G, "IsAddOnLoaded")
    if type(legacyIsAddonLoaded) == "function" then
        return legacyIsAddonLoaded(addonName)
    end
    return false
end

local function getGuildUiLoadState()
    local guildUiLoaded = isAddonLoaded("Blizzard_GuildUI")
    local communitiesLoaded = isAddonLoaded("Blizzard_Communities")
    return guildUiLoaded, communitiesLoaded
end

local function getGuildButtonParent()
    local guildInfoFrame = rawget(_G, "GuildInfoFrame")
    if guildInfoFrame then
        return guildInfoFrame, "GuildInfoFrame"
    end

    local communitiesFrame = rawget(_G, "CommunitiesFrame")
    if communitiesFrame then
        return communitiesFrame, "CommunitiesFrame"
    end

    local guildFrame = rawget(_G, "GuildFrame")
    if guildFrame then
        return guildFrame, "GuildFrame"
    end

    return nil, "none"
end

local function isGuildInfoDisplayModeActive()
    local communitiesFrame = rawget(_G, "CommunitiesFrame")
    if communitiesFrame and communitiesFrame:IsShown() then
        local displayModes = rawget(_G, "COMMUNITIES_FRAME_DISPLAY_MODES")
        if displayModes and communitiesFrame.GetDisplayMode then
            return communitiesFrame:GetDisplayMode() == displayModes.GUILD_INFO
        end

        if communitiesFrame.GuildDetailsFrame and communitiesFrame.GuildDetailsFrame:IsShown() then
            return true
        end
    end

    local guildInfoFrame = rawget(_G, "GuildInfoFrame")
    return guildInfoFrame and guildInfoFrame:IsShown()
end

local function updateGuildLootButtonVisibility(reason)
    local button = rawget(_G, "GuildLootListOpenButton")
    if not button then
        return
    end

    local shouldShow = isGuildInfoDisplayModeActive()
    button:SetShown(shouldShow)

    if state.lastButtonVisible ~= shouldShow then
        state.lastButtonVisible = shouldShow
        debugLog(string.format("Guild loot button visibility=%s (%s)", tostring(shouldShow), tostring(reason or "unknown")))
    end
end

local function ensureGuildInfoButton(reason)
    local parentFrame, parentName = getGuildButtonParent()
    if not parentFrame then
        local guildUiLoaded, communitiesLoaded = getGuildUiLoadState()
        debugLog(string.format(
            "Button not created (%s): parentFrame=nil, Blizzard_GuildUI=%s, Blizzard_Communities=%s",
            tostring(reason or "unknown"),
            tostring(guildUiLoaded),
            tostring(communitiesLoaded)
        ))
        return false
    end

    if parentFrame.GuildLootListButton then
        debugLog(string.format("Guild loot button already exists on %s (%s)", tostring(parentName), tostring(reason or "unknown")))
        return true
    end

    if not parentFrame:IsShown() then
        debugLog(string.format("%s exists but is hidden (%s)", tostring(parentName), tostring(reason or "unknown")))
    end

    local button = CreateFrame("Button", "GuildLootListOpenButton", parentFrame, "UIPanelButtonTemplate")
    button:SetSize(120, 22)
    button:SetPoint("TOPRIGHT", parentFrame, "TOPRIGHT", -32, -32)
    button:SetText("Guild Loot List")
    button:SetScript("OnClick", openDialog)
    parentFrame.GuildLootListButton = button
    debugLog(string.format("Guild loot button created on %s (%s)", tostring(parentName), tostring(reason or "unknown")))
    updateGuildLootButtonVisibility("buttonCreated")
    return true
end

local function scheduleEnsureGuildInfoButton(reason, attempt)
    local currentAttempt = attempt or 1
    local maxAttempts = 10

    if ensureGuildInfoButton(reason) then
        state.buttonRetryPending = false
        return
    end

    if currentAttempt >= maxAttempts then
        local guildUiLoaded, communitiesLoaded = getGuildUiLoadState()
        local hasFrame = rawget(_G, "GuildInfoFrame") ~= nil
        debugLog(string.format(
            "Button setup retries exhausted (%s): attempt=%d, buttonParent=%s, Blizzard_GuildUI=%s, Blizzard_Communities=%s",
            tostring(reason or "unknown"),
            currentAttempt,
            tostring(hasFrame),
            tostring(guildUiLoaded),
            tostring(communitiesLoaded)
        ))
        state.buttonRetryPending = false
        return
    end

    if state.buttonRetryPending and currentAttempt == 1 then
        debugLog(string.format("Button setup retry already pending (%s)", tostring(reason or "unknown")))
        return
    end

    state.buttonRetryPending = true
    debugLog(string.format("Button setup retry scheduled (%s): nextAttempt=%d", tostring(reason or "unknown"), currentAttempt + 1))
    C_Timer.After(0.5, function()
        scheduleEnsureGuildInfoButton(reason, currentAttempt + 1)
    end)
end

local function hookGuildFrameOpen()
    if state.guildUiHooked then
        return
    end

    if type(ToggleGuildFrame) ~= "function" then
        debugLog("ToggleGuildFrame unavailable; cannot hook guild open yet")
        return
    end

    hooksecurefunc("ToggleGuildFrame", function()
        debugLog("ToggleGuildFrame called; ensuring GuildLootList button")
        scheduleEnsureGuildInfoButton("ToggleGuildFrame")
        updateGuildLootButtonVisibility("ToggleGuildFrame")
    end)
    state.guildUiHooked = true
    debugLog("Hooked ToggleGuildFrame for GuildLootList button setup")

    local communitiesFrame = rawget(_G, "CommunitiesFrame")
    if communitiesFrame and not state.communitiesDisplayHooked then
        if type(communitiesFrame.SetDisplayMode) == "function" then
            hooksecurefunc(communitiesFrame, "SetDisplayMode", function()
                updateGuildLootButtonVisibility("SetDisplayMode")
            end)
            state.communitiesDisplayHooked = true
            debugLog("Hooked CommunitiesFrame:SetDisplayMode for button visibility")
        end

        communitiesFrame:HookScript("OnShow", function()
            updateGuildLootButtonVisibility("CommunitiesFrameOnShow")
        end)
    end
end

local function onAddonLoaded(addonName)
    debugLog("ADDON_LOADED: " .. tostring(addonName))
    if addonName == "Blizzard_GuildUI" or addonName == "Blizzard_Communities" then
        local guildUiLoaded, communitiesLoaded = getGuildUiLoadState()
        debugLog(string.format(
            "Guild UI addon loaded (%s): Blizzard_GuildUI=%s, Blizzard_Communities=%s",
            tostring(addonName),
            tostring(guildUiLoaded),
            tostring(communitiesLoaded)
        ))
        hookGuildFrameOpen()
        scheduleEnsureGuildInfoButton("ADDON_LOADED:" .. tostring(addonName))
        updateGuildLootButtonVisibility("ADDON_LOADED")
        rebuildEntriesFromGuildNews()
        refreshTable()
    end
end

addonFrame:SetScript("OnEvent", function(_, event, ...)
    debugLog("Event: " .. tostring(event))
    if event == "PLAYER_LOGIN" then
        setupSlashCommands()
        debugLog("PLAYER_LOGIN: inGuild=" .. tostring(IsInGuild()))
        rebuildEntriesFromGuildNews()
        hookGuildFrameOpen()

        local guildUiLoaded, communitiesLoaded = getGuildUiLoadState()
        debugLog(string.format(
            "PLAYER_LOGIN guild UI state: Blizzard_GuildUI=%s, Blizzard_Communities=%s, GuildInfoFrame=%s",
            tostring(guildUiLoaded),
            tostring(communitiesLoaded),
            tostring(rawget(_G, "GuildInfoFrame") ~= nil)
        ))
        if guildUiLoaded or communitiesLoaded then
            scheduleEnsureGuildInfoButton("PLAYER_LOGIN")
        end
        updateGuildLootButtonVisibility("PLAYER_LOGIN")
    elseif event == "ADDON_LOADED" then
        onAddonLoaded(...)
    elseif event == "GUILD_NEWS_UPDATE" or event == "GUILD_ROSTER_UPDATE" then
        ensureGuildInfoButton(event)
        updateGuildLootButtonVisibility(event)
        rebuildEntriesFromGuildNews()
        refreshTable()
    end
end)

addonFrame:RegisterEvent("PLAYER_LOGIN")
addonFrame:RegisterEvent("ADDON_LOADED")
addonFrame:RegisterEvent("GUILD_NEWS_UPDATE")
addonFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
