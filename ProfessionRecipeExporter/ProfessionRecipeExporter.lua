local ADDON_NAME = ...

local defaults = {
    schemaVersion = 1,
    runCount = 0,
    latestExportID = nil,
    exports = {},
    salvageRunCount = 0,
    latestSalvageExportID = nil,
    salvageExports = {},
    salvageTrackingEnabled = true,
    salvageTrackingSessionCounter = 0,
    latestSalvageTrackingSessionID = nil,
    salvageTrackingSessions = {},
}

local L = {
    addonPrefix = "|cff33ff99ProfessionRecipeExporter|r",
    loaded = "Loaded. Use /pre scan to export profession recipe data.",
    scanStarted = "Scan started.",
    scanInstruction = "Open each profession window manually to capture data. Use /pre finish when done.",
    scanAlreadyRunning = "Scan is already running.",
    scanNotRunning = "No active scan. Use /pre scan to start.",
    professionCaptured = "Captured profession skillLineID=%d.",
    professionUpdated = "Updated capture for profession skillLineID=%d.",
    scanFinished = "Scan finished. Export #%d saved (%d professions, %d recipes).",
    noExportData = "No export data available yet.",
    statusIdle = "Status: idle.",
    statusRunning = "Status: scanning (%d professions captured).",
    statusLatest = "Latest export #%d: %d professions, %d recipes, %s.",
    salvageScanStarted = "Salvage scan started.",
    salvageScanInstruction = "Open a profession window to capture salvage recipes. Use /pre salvagedone when done.",
    salvageScanFinished = "Salvage scan finished. Export #%d saved (%d professions, %d salvage recipes).",
    salvageScanAlreadyRunning = "Salvage scan is already running.",
    salvageScanNotRunning = "No active salvage scan. Use /pre salvagescan to start.",
    salvageProfessionCaptured = "Captured salvage recipes for profession skillLineID=%d.",
    salvageProfessionUpdated = "Updated salvage recipes for profession skillLineID=%d.",
    salvageTrackingSessionStarted = "Salvage tracking session started (#%d).",
    salvageTrackingEnabled = "Salvage auto-tracking enabled.",
    salvageTrackingDisabled = "Salvage auto-tracking disabled.",
    salvageTrackingStatus = "Salvage tracking: %s. Sessions=%d, LatestSessionID=%s, CurrentSessionID=%s.",
    salvageTrackingCleared = "Salvage tracking history cleared.",
    salvageTrackingLatest = "Latest salvage tracking session: ProfessionRecipeExporterDB.salvageTrackingSessions[%d]",
    commandHelp = "Commands: /pre scan, /pre finish, /pre salvagescan, /pre salvagedone, /pre salvagelogstatus, /pre salvagelogon, /pre salvagelogoff, /pre salvagelogclear, /pre salvageloglatest, /pre status, /pre latest, /pre clear",
    dataCleared = "All saved export data cleared.",
    captureSkippedNotReady = "Trade skill UI is not ready yet; waiting for next update.",
    captureSkippedNoSkillLine = "Could not determine current profession skillLineID; waiting for next update.",
    captureUsedRecipeFallback = "Resolved profession via recipe fallback skillLineID=%d.",
    finalizeWaitingForItemData = "Finalizing export: waiting for %d item names to load.",
    finalizeForcedWithMissingNames = "Finalizing with %d reagent names still unresolved after retries.",
    finalizeUnresolvedIDs = "Unresolved reagent itemIDs: %s",
    finalizeAlreadyPending = "Finalize is already in progress; waiting for item data.",
}

local state = {
    isScanning = false,
    currentExport = nil,
    isSalvageScanning = false,
    currentSalvageExport = nil,
    finalizePending = false,
    finalizeRetryCount = 0,
    finalizeCheckQueued = false,
    salvageTrackingHooked = false,
    currentSalvageTrackingSession = nil,
    pendingSalvageCalls = {},
}

local FINALIZE_RETRY_INTERVAL_SECONDS = 1
local FINALIZE_MAX_RETRIES = 8
local DEBUG_ENCHANT_OUTPUTS = false
local DEBUG_MIDNIGHT_RECIPES = false
local finalizeScan
local sanitize

local eventFrame = CreateFrame("Frame")

local function log(message, ...)
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    print(string.format("%s %s", L.addonPrefix, message))
end

local function debugEnchantLog(message, ...)
    if not DEBUG_ENCHANT_OUTPUTS then
        return
    end
    log("[enchant-debug] " .. message, ...)
end

local function debugMidnightLog(message, ...)
    if not DEBUG_MIDNIGHT_RECIPES then
        return
    end
    log("[midnight-debug] " .. message, ...)
end

local function summarizeTable(tableValue)
    local function asString(value)
        local ok, result = pcall(tostring, value)
        if ok then
            return result
        end
        return "<unstringable>"
    end

    if type(tableValue) ~= "table" then
        return asString(tableValue)
    end

    local keys = {}
    for key in pairs(tableValue) do
        keys[#keys + 1] = asString(key)
    end
    table.sort(keys)

    local keyParts = {}
    local maxKeys = 24
    local keyLimit = math.min(#keys, maxKeys)
    for index = 1, keyLimit do
        keyParts[#keyParts + 1] = keys[index]
    end
    if #keys > maxKeys then
        keyParts[#keyParts + 1] = string.format("...(+%d)", #keys - maxKeys)
    end

    local fieldParts = {}
    local preferredFields = {
        "itemID",
        "itemLink",
        "hyperlink",
        "name",
        "qualityID",
        "quality",
        "quantity",
        "numAvailable",
        "craftableCount",
    }

    for _, fieldName in ipairs(preferredFields) do
        local value = tableValue[fieldName]
        if value ~= nil then
            fieldParts[#fieldParts + 1] = string.format("%s=%s", fieldName, asString(value))
        end
    end

    if #fieldParts == 0 then
        fieldParts[#fieldParts + 1] = "no-preferred-fields"
    end

    local scalarParts = {}
    local maxScalarParts = 20
    local scalarCount = 0
    for _, key in ipairs(keys) do
        if scalarCount >= maxScalarParts then
            break
        end

        local value = tableValue[key]
        local valueType = type(value)
        if valueType == "string" or valueType == "number" or valueType == "boolean" or valueType == "nil" then
            scalarCount = scalarCount + 1
            scalarParts[#scalarParts + 1] = string.format("%s=%s", key, asString(value))
        end
    end
    if #scalarParts == 0 then
        scalarParts[#scalarParts + 1] = "no-scalar-fields"
    end

    return string.format(
        "keys=[%s] fields=[%s] scalars=[%s]",
        table.concat(keyParts, ", "),
        table.concat(fieldParts, ", "),
        table.concat(scalarParts, ", ")
    )
end

local function copyDefaults(target, source)
    for key, value in pairs(source) do
        if target[key] == nil then
            if type(value) == "table" then
                target[key] = {}
                copyDefaults(target[key], value)
            else
                target[key] = value
            end
        elseif type(target[key]) == "table" and type(value) == "table" then
            copyDefaults(target[key], value)
        end
    end
end

local function ensureDatabase()
    ProfessionRecipeExporterDB = ProfessionRecipeExporterDB or {}
    copyDefaults(ProfessionRecipeExporterDB, defaults)
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end

    local ok, result1, result2, result3, result4 = pcall(fn, ...)
    if not ok then
        return nil
    end

    return result1, result2, result3, result4
end

local function safeCallList(fn, ...)
    if type(fn) ~= "function" then
        return {}
    end

    local function pack(...)
        return {
            n = select("#", ...),
            ...,
        }
    end

    local results = pack(pcall(fn, ...))
    local ok = results[1]
    if not ok then
        return {}
    end

    local firstResult = results[2]
    if firstResult == nil then
        return {}
    end

    if type(firstResult) == "table" then
        return firstResult
    end

    local list = {}
    for i = 2, results.n do
        local value = results[i]
        local valueType = type(value)
        if value ~= nil and (
            valueType == "number"
            or valueType == "string"
            or valueType == "table"
            or valueType == "boolean"
        ) then
            list[#list + 1] = value
        end
    end

    return list
end

local function safeToString(value)
    local ok, result = pcall(tostring, value)
    if ok then
        return result
    end
    return "<unstringable>"
end

local function isSalvageTrackingEnabled()
    return ProfessionRecipeExporterDB and ProfessionRecipeExporterDB.salvageTrackingEnabled == true
end

local function getCurrentISOTime()
    return date("!%Y-%m-%dT%H:%M:%SZ")
end

local function getOrCreateSalvageTrackingSession()
    if not ProfessionRecipeExporterDB then
        return nil
    end

    if type(state.currentSalvageTrackingSession) == "table" then
        return state.currentSalvageTrackingSession
    end

    local db = ProfessionRecipeExporterDB
    db.salvageTrackingSessionCounter = (db.salvageTrackingSessionCounter or 0) + 1
    local sessionID = db.salvageTrackingSessionCounter

    local classLocalized, classFile = UnitClass("player")
    local raceLocalized, raceFile = UnitRace("player")

    local session = {
        sessionID = sessionID,
        startedAtEpoch = time(),
        startedAtISO8601 = getCurrentISOTime(),
        player = {
            name = UnitName("player"),
            realm = GetRealmName(),
            classLocalized = classLocalized,
            classFile = classFile,
            raceLocalized = raceLocalized,
            raceFile = raceFile,
            faction = UnitFactionGroup("player"),
            level = UnitLevel("player"),
        },
        craftCalls = {},
        craftBeginEvents = {},
        spellcastSucceededEvents = {},
        craftResultEvents = {},
        counters = {
            craftCallID = 0,
            craftBeginEventID = 0,
            spellcastEventID = 0,
            craftResultEventID = 0,
        },
    }

    db.salvageTrackingSessions[sessionID] = session
    db.latestSalvageTrackingSessionID = sessionID
    state.currentSalvageTrackingSession = session
    state.pendingSalvageCalls = {}

    log(L.salvageTrackingSessionStarted, sessionID)
    return session
end

local function getRecipeNameByID(recipeID)
    if type(recipeID) ~= "number" then
        return nil
    end

    local recipeInfo = safeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if type(recipeInfo) == "table" and type(recipeInfo.name) == "string" and recipeInfo.name ~= "" then
        return recipeInfo.name
    end

    return nil
end

local function buildItemLocationSnapshot(itemLocation)
    if type(itemLocation) ~= "table" then
        return nil
    end

    local snapshot = {
        itemID = safeCall(C_Item.GetItemID, itemLocation),
        itemGUID = safeCall(C_Item.GetItemGUID, itemLocation),
    }

    if type(itemLocation.GetBagAndSlot) == "function" then
        local bagIndex, slotIndex = safeCall(itemLocation.GetBagAndSlot, itemLocation)
        if type(bagIndex) == "number" then
            snapshot.bagIndex = bagIndex
        end
        if type(slotIndex) == "number" then
            snapshot.slotIndex = slotIndex
        end
    end

    return snapshot
end

local function getMostRecentPendingSalvageCall()
    for index = #state.pendingSalvageCalls, 1, -1 do
        local pending = state.pendingSalvageCalls[index]
        if type(pending) == "table" and (pending.remainingCrafts or 0) > 0 then
            return pending
        end
    end
    return nil
end

local function getPendingSalvageCallByRecipe(recipeSpellID)
    if type(recipeSpellID) ~= "number" then
        return nil
    end
    for _, pending in ipairs(state.pendingSalvageCalls) do
        if type(pending) == "table"
            and pending.recipeSpellID == recipeSpellID
            and (pending.remainingCrafts or 0) > 0
        then
            return pending
        end
    end
    return nil
end

local function recordCraftSalvageCall(recipeSpellID, numCasts, itemTargetLocation, craftingReagentInfo, applyConcentration)
    if not isSalvageTrackingEnabled() then
        return
    end

    local session = getOrCreateSalvageTrackingSession()
    if not session then
        return
    end

    local casts = (type(numCasts) == "number" and numCasts > 0) and numCasts or 1
    session.counters.craftCallID = (session.counters.craftCallID or 0) + 1
    local craftCallID = session.counters.craftCallID

    local callRecord = {
        craftCallID = craftCallID,
        timestampEpoch = time(),
        timestampISO8601 = getCurrentISOTime(),
        recipeSpellID = recipeSpellID,
        recipeName = getRecipeNameByID(recipeSpellID),
        numCasts = casts,
        applyConcentration = applyConcentration == true,
        itemTarget = sanitize(buildItemLocationSnapshot(itemTargetLocation)),
        craftingReagentInfo = sanitize(craftingReagentInfo),
    }

    table.insert(session.craftCalls, callRecord)
    table.insert(state.pendingSalvageCalls, {
        craftCallID = craftCallID,
        recipeSpellID = recipeSpellID,
        remainingCrafts = casts,
        lastUpdateEpoch = time(),
    })
end

local function recordCraftBegin(recipeSpellID)
    if not isSalvageTrackingEnabled() then
        return
    end

    local session = getOrCreateSalvageTrackingSession()
    if not session then
        return
    end

    local pending = getPendingSalvageCallByRecipe(recipeSpellID) or getMostRecentPendingSalvageCall()

    session.counters.craftBeginEventID = (session.counters.craftBeginEventID or 0) + 1
    table.insert(session.craftBeginEvents, {
        craftBeginEventID = session.counters.craftBeginEventID,
        timestampEpoch = time(),
        timestampISO8601 = getCurrentISOTime(),
        recipeSpellID = recipeSpellID,
        recipeName = getRecipeNameByID(recipeSpellID),
        linkedCraftCallID = pending and pending.craftCallID or nil,
    })
end

local function recordSpellcastSucceeded(unitTarget, castGUID, spellID, castBarID)
    if not isSalvageTrackingEnabled() then
        return
    end

    if unitTarget ~= "player" then
        return
    end

    local session = getOrCreateSalvageTrackingSession()
    if not session then
        return
    end

    local pending = getPendingSalvageCallByRecipe(spellID)
    if pending then
        pending.remainingCrafts = math.max(0, (pending.remainingCrafts or 0) - 1)
        pending.lastUpdateEpoch = time()
    end

    session.counters.spellcastEventID = (session.counters.spellcastEventID or 0) + 1
    table.insert(session.spellcastSucceededEvents, {
        spellcastEventID = session.counters.spellcastEventID,
        timestampEpoch = time(),
        timestampISO8601 = getCurrentISOTime(),
        unitTarget = unitTarget,
        castGUID = castGUID,
        spellID = spellID,
        castBarID = castBarID,
        linkedCraftCallID = pending and pending.craftCallID or nil,
    })
end

local function inferRecipeSpellIDFromResultData(craftingItemResultData)
    if type(craftingItemResultData) ~= "table" then
        return nil
    end

    local candidateKeys = {
        "recipeSpellID",
        "recipeID",
        "spellID",
    }

    for _, key in ipairs(candidateKeys) do
        local value = craftingItemResultData[key]
        if type(value) == "number" and value > 0 then
            return value
        end
    end

    return nil
end

local function summarizeCraftResultData(craftingItemResultData)
    if type(craftingItemResultData) ~= "table" then
        return nil
    end

    local summary = {
        operationID = craftingItemResultData.operationID,
        quantity = craftingItemResultData.quantity,
        multicraft = craftingItemResultData.multicraft,
        craftingQuality = craftingItemResultData.craftingQuality,
        itemID = craftingItemResultData.itemID,
        hyperlink = craftingItemResultData.hyperlink,
        concentrationSpent = craftingItemResultData.concentrationSpent,
        ingenuityRefund = craftingItemResultData.ingenuityRefund,
        hasIngenuityProc = craftingItemResultData.hasIngenuityProc,
        hasResourcesReturned = type(craftingItemResultData.resourcesReturned) == "table" and #craftingItemResultData.resourcesReturned > 0 or false,
    }

    if summary.itemID == nil and type(summary.hyperlink) == "string" then
        local parsedItemID = summary.hyperlink:match("Hitem:(%d+):")
        if parsedItemID then
            summary.itemID = tonumber(parsedItemID)
        end
    end

    return summary
end

local function recordCraftResultEvent(craftingItemResultData)
    if not isSalvageTrackingEnabled() then
        return
    end

    local session = getOrCreateSalvageTrackingSession()
    if not session then
        return
    end

    local inferredRecipeSpellID = inferRecipeSpellIDFromResultData(craftingItemResultData)
    local pending = getPendingSalvageCallByRecipe(inferredRecipeSpellID) or getMostRecentPendingSalvageCall()

    session.counters.craftResultEventID = (session.counters.craftResultEventID or 0) + 1
    table.insert(session.craftResultEvents, {
        craftResultEventID = session.counters.craftResultEventID,
        timestampEpoch = time(),
        timestampISO8601 = getCurrentISOTime(),
        inferredRecipeSpellID = inferredRecipeSpellID,
        inferredRecipeName = getRecipeNameByID(inferredRecipeSpellID),
        linkedCraftCallID = pending and pending.craftCallID or nil,
        resultSummary = sanitize(summarizeCraftResultData(craftingItemResultData)),
        rawData = sanitize(craftingItemResultData),
    })
end

local function hookSalvageCraftCallIfNeeded()
    if state.salvageTrackingHooked then
        return
    end

    if type(C_TradeSkillUI) ~= "table" or type(C_TradeSkillUI.CraftSalvage) ~= "function" then
        return
    end

    hooksecurefunc(C_TradeSkillUI, "CraftSalvage", function(recipeSpellID, numCasts, itemTargetLocation, craftingReagentInfo, applyConcentration)
        recordCraftSalvageCall(recipeSpellID, numCasts, itemTargetLocation, craftingReagentInfo, applyConcentration)
    end)

    state.salvageTrackingHooked = true
end

local function resolveItemNameByID(itemID)
    if type(itemID) ~= "number" then
        return nil
    end

    local itemName = safeCall(C_Item.GetItemNameByID, itemID)
    if type(itemName) == "string" and itemName ~= "" then
        return itemName
    end

    local itemNameFromInfo = safeCall(C_Item.GetItemInfo, itemID)
    if type(itemNameFromInfo) == "string" and itemNameFromInfo ~= "" then
        return itemNameFromInfo
    end

    safeCall(C_Item.RequestLoadItemDataByID, itemID)
    return nil
end

local function countKeys(input)
    local count = 0
    for _ in pairs(input) do
        count = count + 1
    end
    return count
end

local function formatItemIDSet(itemIDSet)
    local ids = {}
    for itemID in pairs(itemIDSet) do
        ids[#ids + 1] = itemID
    end

    table.sort(ids)

    local maxToPrint = 50
    local display = {}
    local limit = math.min(#ids, maxToPrint)
    for index = 1, limit do
        display[#display + 1] = tostring(ids[index])
    end

    if #ids > maxToPrint then
        display[#display + 1] = string.format("...(+%d more)", #ids - maxToPrint)
    end

    return table.concat(display, ", ")
end

local function forEachExportReagent(exportData, callback)
    if type(exportData) ~= "table" then
        return
    end

    local professions = exportData.professions
    if type(professions) ~= "table" then
        return
    end

    for _, professionData in pairs(professions) do
        if type(professionData) == "table" and type(professionData.recipes) == "table" then
            for _, recipeData in ipairs(professionData.recipes) do
                if type(recipeData) == "table" and type(recipeData.recipeReagentSlots) == "table" then
                    for _, slotData in ipairs(recipeData.recipeReagentSlots) do
                        if type(slotData) == "table" and type(slotData.reagents) == "table" then
                            for _, reagentData in ipairs(slotData.reagents) do
                                if type(reagentData) == "table" then
                                    callback(reagentData)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function enrichCurrentExportReagentItemNames(exportData)
    forEachExportReagent(exportData, function(reagentData)
        local itemID = reagentData.itemID
        if type(itemID) ~= "number" then
            return
        end

        if type(reagentData.itemName) == "string" and reagentData.itemName ~= "" then
            return
        end

        local itemName = resolveItemNameByID(itemID)
        if type(itemName) == "string" and itemName ~= "" then
            reagentData.itemName = itemName
        end
    end)
end

local function collectUnresolvedReagentItemIDs(exportData)
    local unresolved = {}
    forEachExportReagent(exportData, function(reagentData)
        local itemID = reagentData.itemID
        local itemName = reagentData.itemName
        if type(itemID) == "number" and (type(itemName) ~= "string" or itemName == "") then
            unresolved[itemID] = true
        end
    end)
    return unresolved
end

local function requestItemDataForSet(itemIDSet)
    for itemID in pairs(itemIDSet) do
        safeCall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local function continueFinalizeAfterItemWarmup()
    if not state.finalizePending then
        return
    end

    local exportData = state.currentExport
    if type(exportData) ~= "table" then
        state.finalizePending = false
        state.finalizeRetryCount = 0
        state.finalizeCheckQueued = false
        return
    end

    enrichCurrentExportReagentItemNames(exportData)
    local unresolved = collectUnresolvedReagentItemIDs(exportData)
    local unresolvedCount = countKeys(unresolved)
    if unresolvedCount == 0 then
        state.finalizePending = false
        state.finalizeRetryCount = 0
        finalizeScan()
        return
    end

    state.finalizeRetryCount = state.finalizeRetryCount + 1
    if state.finalizeRetryCount >= FINALIZE_MAX_RETRIES then
        state.finalizePending = false
        state.finalizeRetryCount = 0
        log(L.finalizeForcedWithMissingNames, unresolvedCount)
        log(L.finalizeUnresolvedIDs, formatItemIDSet(unresolved))
        finalizeScan()
        return
    end

    requestItemDataForSet(unresolved)
    state.finalizeCheckQueued = true
    C_Timer.After(FINALIZE_RETRY_INTERVAL_SECONDS, function()
        state.finalizeCheckQueued = false
        continueFinalizeAfterItemWarmup()
    end)
end

local function startFinalizeSequence()
    local exportData = state.currentExport
    if type(exportData) ~= "table" then
        finalizeScan()
        return
    end

    enrichCurrentExportReagentItemNames(exportData)
    local unresolved = collectUnresolvedReagentItemIDs(exportData)
    local unresolvedCount = countKeys(unresolved)
    if unresolvedCount == 0 then
        finalizeScan()
        return
    end

    state.finalizePending = true
    state.finalizeRetryCount = 0
    log(L.finalizeWaitingForItemData, unresolvedCount)
    log(L.finalizeUnresolvedIDs, formatItemIDSet(unresolved))
    requestItemDataForSet(unresolved)
    if not state.finalizeCheckQueued then
        state.finalizeCheckQueued = true
        C_Timer.After(FINALIZE_RETRY_INTERVAL_SECONDS, function()
            state.finalizeCheckQueued = false
            continueFinalizeAfterItemWarmup()
        end)
    end
end

sanitize = function(value, seen, depth)
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return value
    end

    if valueType ~= "table" then
        return {
            __type = valueType,
            __value = safeToString(value),
        }
    end

    seen = seen or {}
    depth = depth or 0
    if depth > 10 then
        return {
            __type = "table",
            __truncated = true,
        }
    end

    if seen[value] then
        return {
            __type = "table",
            __circular = true,
        }
    end

    seen[value] = true
    local result = {}
    for key, tableValue in pairs(value) do
        local resultKeyType = type(key)
        local resultKey = key
        if resultKeyType ~= "string" and resultKeyType ~= "number" then
            resultKey = "__key_" .. safeToString(key)
        end
        result[resultKey] = sanitize(tableValue, seen, depth + 1)
    end
    seen[value] = nil
    return result
end

local function extractRecipeSchematicReagents(schematic)
    local reagentSlots = {}
    if type(schematic) ~= "table" then
        return reagentSlots
    end

    local slotSchematics = schematic.reagentSlotSchematics
    if type(slotSchematics) ~= "table" then
        return reagentSlots
    end

    for slotIndex, slot in ipairs(slotSchematics) do
        local slotEntry = {
            slotIndex = slotIndex,
            raw = sanitize(slot),
            reagents = {},
        }

        if type(slot) == "table" and type(slot.reagents) == "table" then
            for reagentIndex, reagent in ipairs(slot.reagents) do
                local sanitizedReagent = sanitize(reagent)
                if type(reagent) == "table" then
                    local itemID = reagent.itemID
                    local itemName = resolveItemNameByID(itemID)
                    if type(itemName) == "string" and itemName ~= "" then
                        sanitizedReagent.itemName = itemName
                    end
                    if type(itemID) == "number" then
                        local reagentQuality = safeCall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemID)
                        if type(reagentQuality) ~= "number" then
                            local reagentQualityInfo = safeCall(C_TradeSkillUI.GetItemReagentQualityInfo, itemID)
                            if type(reagentQualityInfo) == "table" then
                                sanitizedReagent.reagentQualityInfo = sanitize(reagentQualityInfo)
                                if type(reagentQualityInfo.currentQuality) == "number" then
                                    reagentQuality = reagentQualityInfo.currentQuality
                                elseif type(reagentQualityInfo.quality) == "number" then
                                    reagentQuality = reagentQualityInfo.quality
                                end
                            end
                        end
                        if type(reagentQuality) == "number" then
                            sanitizedReagent.reagentQuality = reagentQuality
                        end

                        local itemQuality = safeCall(C_Item.GetItemQualityByID, itemID)
                        if type(itemQuality) == "number" then
                            sanitizedReagent.itemQuality = itemQuality
                        end
                    end
                end
                slotEntry.reagents[reagentIndex] = sanitizedReagent
            end
        end

        reagentSlots[#reagentSlots + 1] = slotEntry
    end

    return reagentSlots
end

local function buildDefaultCraftingReagents(schematic)
    local craftingReagents = {}
    if type(schematic) ~= "table" then
        return craftingReagents
    end

    local slotSchematics = schematic.reagentSlotSchematics
    if type(slotSchematics) ~= "table" then
        return craftingReagents
    end

    for _, slot in ipairs(slotSchematics) do
        if type(slot) == "table" and slot.required == true then
            local dataSlotIndex = slot.dataSlotIndex
            if type(dataSlotIndex) == "number" then
                local selectedReagent = nil
                if type(slot.reagents) == "table" then
                    for _, slotReagent in ipairs(slot.reagents) do
                        if type(slotReagent) == "table" then
                            if type(slotReagent.itemID) == "number" then
                                selectedReagent = {
                                    itemID = slotReagent.itemID,
                                }
                                break
                            elseif type(slotReagent.currencyID) == "number" then
                                selectedReagent = {
                                    currencyID = slotReagent.currencyID,
                                }
                                break
                            end
                        end
                    end
                end

                if selectedReagent then
                    local quantity = slot.quantityRequired
                    if type(quantity) ~= "number" or quantity <= 0 then
                        quantity = 1
                    end

                    craftingReagents[#craftingReagents + 1] = {
                        reagent = selectedReagent,
                        dataSlotIndex = dataSlotIndex,
                        quantity = quantity,
                    }
                end
            end
        end
    end

    return craftingReagents
end

local function extractCraftingStatFlags(operationInfo)
    local stats = {
        affectedByMulticraft = false,
        affectedByResourcefulness = false,
        affectedByIngenuity = false,
        bonusStats = {},
    }

    if type(operationInfo) ~= "table" then
        return stats
    end

    local bonusStats = operationInfo.bonusStats
    if type(bonusStats) ~= "table" then
        return stats
    end

    for _, bonusStat in ipairs(bonusStats) do
        if type(bonusStat) == "table" then
            local bonusStatName = bonusStat.bonusStatName
            if type(bonusStatName) == "string" and bonusStatName ~= "" then
                stats.bonusStats[#stats.bonusStats + 1] = bonusStatName

                local lowerName = string.lower(bonusStatName)
                if string.find(lowerName, "multicraft", 1, true) then
                    stats.affectedByMulticraft = true
                end
                if string.find(lowerName, "resourcefulness", 1, true) then
                    stats.affectedByResourcefulness = true
                end
                if string.find(lowerName, "ingenuity", 1, true) then
                    stats.affectedByIngenuity = true
                end
            end
        end
    end

    return stats
end

local function extractSalvageTargets(recipeID)
    local targets = {}
    local salvageableItemIDs = safeCallList(C_TradeSkillUI.GetSalvagableItemIDs, recipeID)
    for _, itemID in ipairs(salvageableItemIDs) do
        if type(itemID) == "number" then
            local itemName = resolveItemNameByID(itemID)
            targets[#targets + 1] = {
                itemID = itemID,
                itemName = itemName,
            }
        end
    end
    return targets
end

local function buildOutputQualityEntries(qualityItemIDs, qualityIDs)
    local entries = {}
    local qualityItemIDList = safeCallList(function()
        return qualityItemIDs
    end)
    local qualityIDList = safeCallList(function()
        return qualityIDs
    end)

    for index, itemID in ipairs(qualityItemIDList) do
        if type(itemID) == "number" then
            local itemName = resolveItemNameByID(itemID)
            local itemQuality = safeCall(C_Item.GetItemQualityByID, itemID)
            entries[#entries + 1] = {
                rank = index,
                qualityID = qualityIDList[index],
                itemID = itemID,
                itemName = itemName,
                itemQuality = itemQuality,
            }
        end
    end

    return entries
end

local function getQualityIDList(qualityIDs)
    local qualityIDList = safeCallList(function()
        return qualityIDs
    end)
    local result = {}
    for _, qualityID in ipairs(qualityIDList) do
        if type(qualityID) == "number" then
            result[#result + 1] = qualityID
        end
    end
    return result
end

local function extractItemIDFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    local itemID = link:match("Hitem:(%d+):")
    if itemID then
        return tonumber(itemID)
    end
    return nil
end

local function collectVellumTargetGUIDs()
    local targetGUIDs = {}
    local seen = {}
    local vellumItemIDs = {
        [38682] = true,
    }

    local bagStart = Enum and Enum.BagIndex and Enum.BagIndex.Backpack or 0
    local bagEnd = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 5

    for bagIndex = bagStart, bagEnd do
        local numSlots = safeCall(C_Container.GetContainerNumSlots, bagIndex)
        if type(numSlots) == "number" and numSlots > 0 then
            for slotIndex = 1, numSlots do
                local containerInfo = safeCall(C_Container.GetContainerItemInfo, bagIndex, slotIndex)
                if type(containerInfo) == "table" and vellumItemIDs[containerInfo.itemID] == true then
                    local itemGUID = containerInfo.itemGUID
                    if type(itemGUID) ~= "string" or itemGUID == "" then
                        if type(ItemLocation) == "table" and type(ItemLocation.CreateFromBagAndSlot) == "function" then
                            local itemLocation = ItemLocation:CreateFromBagAndSlot(bagIndex, slotIndex)
                            itemGUID = safeCall(C_Item.GetItemGUID, itemLocation)
                        end
                    end

                    if type(itemGUID) == "string" and itemGUID ~= "" and not seen[itemGUID] then
                        seen[itemGUID] = true
                        targetGUIDs[#targetGUIDs + 1] = itemGUID
                        debugEnchantLog("Found vellum GUID bag=%d slot=%d guid=%s", bagIndex, slotIndex, itemGUID)
                    end
                end
            end
        end
    end

    debugEnchantLog("Collected %d vellum GUID(s)", #targetGUIDs)
    return targetGUIDs
end

local function buildEnchantTargetOutputEntry(targetGUID, qualityID, outputInfo, rank)
    if type(outputInfo) ~= "table" then
        return nil
    end

    local itemID = outputInfo.itemID
    if type(itemID) ~= "number" then
        itemID = extractItemIDFromLink(outputInfo.hyperlink)
    end
    if type(itemID) ~= "number" then
        itemID = extractItemIDFromLink(outputInfo.itemLink)
    end

    if type(itemID) ~= "number" then
        return nil
    end

    local itemName = resolveItemNameByID(itemID)
    local itemQuality = safeCall(C_Item.GetItemQualityByID, itemID)

    return {
        targetGUID = targetGUID,
        qualityID = qualityID,
        rank = rank,
        itemID = itemID,
        itemName = itemName,
        itemQuality = itemQuality,
        outputInfo = sanitize(outputInfo),
    }
end

local function extractEnchantTargetOutputs(recipeID, recipeInfo, defaultCraftingReagents, qualityIDs, fallbackTargetGUIDs)
    local outputs = {}
    if type(recipeInfo) ~= "table" then
        return outputs
    end

    local recipeType = recipeInfo.recipeType
    local enchantRecipeType = Enum and Enum.TradeskillRecipeType and Enum.TradeskillRecipeType.Enchant or 3
    local recipeName = recipeInfo.name
    local isEnchantRecipe = false

    if recipeType == enchantRecipeType then
        isEnchantRecipe = true
    elseif recipeInfo.isEnchantingRecipe == true then
        isEnchantRecipe = true
    elseif type(recipeName) == "string" and string.find(string.lower(recipeName), "^enchant ") then
        isEnchantRecipe = true
    end

    if not isEnchantRecipe then
        debugEnchantLog(
            "Recipe %d skipped for enchant-target extraction (recipeType=%s, isEnchantingRecipe=%s, name=%s)",
            recipeID,
            tostring(recipeType),
            tostring(recipeInfo.isEnchantingRecipe),
            tostring(recipeName)
        )
        return outputs
    end

    local qualityIDList = getQualityIDList(qualityIDs)

    local seenTargetGUIDs = {}
    local targetGUIDs = {}
    local function addTargetGUIDs(guidList)
        for _, guid in ipairs(guidList) do
            if type(guid) == "string" and guid ~= "" and not seenTargetGUIDs[guid] then
                seenTargetGUIDs[guid] = true
                targetGUIDs[#targetGUIDs + 1] = guid
            end
        end
    end

    addTargetGUIDs(safeCallList(C_TradeSkillUI.GetEnchantItems, recipeID, defaultCraftingReagents))
    addTargetGUIDs(safeCallList(C_TradeSkillUI.GetEnchantItems, recipeID))
    addTargetGUIDs(fallbackTargetGUIDs or {})
    debugEnchantLog("Recipe %d (%s): target GUID candidates=%d", recipeID, tostring(recipeInfo.name), #targetGUIDs)

    local seenOutputKey = {}
    for _, targetGUID in ipairs(targetGUIDs) do
        if type(targetGUID) == "string" and targetGUID ~= "" then
            local canStoreEnchant = safeCall(C_TradeSkillUI.CanStoreEnchantInItem, targetGUID)
            debugEnchantLog("Recipe %d target=%s canStore=%s", recipeID, targetGUID, tostring(canStoreEnchant))
            if canStoreEnchant == true then
                local function tryAddEntry(qualityID, rank)
                    local outputInfo = safeCall(
                        C_TradeSkillUI.GetRecipeOutputItemData,
                        recipeID,
                        defaultCraftingReagents,
                        targetGUID,
                        qualityID
                    )
                    debugEnchantLog(
                        "Recipe %d target=%s qualityID=%s attempt=withReagents+quality output=%s",
                        recipeID,
                        targetGUID,
                        tostring(qualityID),
                        outputInfo and "table" or "nil"
                    )
                    local entry = buildEnchantTargetOutputEntry(targetGUID, qualityID, outputInfo, rank)
                    if not entry then
                        outputInfo = safeCall(
                            C_TradeSkillUI.GetRecipeOutputItemData,
                            recipeID,
                            nil,
                            targetGUID,
                            qualityID
                        )
                        debugEnchantLog(
                            "Recipe %d target=%s qualityID=%s attempt=noReagents+quality output=%s",
                            recipeID,
                            targetGUID,
                            tostring(qualityID),
                            outputInfo and "table" or "nil"
                        )
                        entry = buildEnchantTargetOutputEntry(targetGUID, qualityID, outputInfo, rank)
                    end
                    if not entry then
                        outputInfo = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, defaultCraftingReagents, targetGUID)
                        debugEnchantLog(
                            "Recipe %d target=%s qualityID=%s attempt=withReagents output=%s",
                            recipeID,
                            targetGUID,
                            tostring(qualityID),
                            outputInfo and "table" or "nil"
                        )
                        entry = buildEnchantTargetOutputEntry(targetGUID, qualityID, outputInfo, rank)
                    end
                    if not entry then
                        outputInfo = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, nil, targetGUID)
                        debugEnchantLog(
                            "Recipe %d target=%s qualityID=%s attempt=noReagents output=%s",
                            recipeID,
                            targetGUID,
                            tostring(qualityID),
                            outputInfo and "table" or "nil"
                        )
                        entry = buildEnchantTargetOutputEntry(targetGUID, qualityID, outputInfo, rank)
                    end

                    if entry then
                        local itemID = entry.itemID
                        local qualityKey = qualityID or 0
                        local key = string.format("%s:%d:%d", targetGUID, itemID, qualityKey)
                        if not seenOutputKey[key] then
                            seenOutputKey[key] = true
                            outputs[#outputs + 1] = entry
                            debugEnchantLog(
                                "Recipe %d resolved target output: qualityID=%s rank=%s itemID=%d itemName=%s",
                                recipeID,
                                tostring(qualityID),
                                tostring(rank),
                                entry.itemID,
                                tostring(entry.itemName)
                            )
                            return true
                        end
                    end
                    debugEnchantLog(
                        "Recipe %d target=%s qualityID=%s no item resolved",
                        recipeID,
                        targetGUID,
                        tostring(qualityID)
                    )
                    return false
                end

                if #qualityIDList > 0 then
                    for rank, qualityID in ipairs(qualityIDList) do
                        tryAddEntry(qualityID, rank)
                    end
                else
                    tryAddEntry(nil, nil)
                end
            end
        end
    end

    debugEnchantLog("Recipe %d (%s): resolved enchant target outputs=%d", recipeID, tostring(recipeInfo.name), #outputs)

    return outputs
end

local function collectCategoryData()
    local categories = {}
    local categoryIDs = safeCallList(C_TradeSkillUI.GetCategories)

    for _, categoryID in ipairs(categoryIDs) do
        local categoryInfo = safeCall(C_TradeSkillUI.GetCategoryInfo, categoryID)
        local subcategories = safeCallList(C_TradeSkillUI.GetSubCategories, categoryID)
        local subcategoryData = {}

        for _, subCategoryID in ipairs(subcategories) do
            subcategoryData[#subcategoryData + 1] = {
                subCategoryID = subCategoryID,
                info = sanitize(safeCall(C_TradeSkillUI.GetCategoryInfo, subCategoryID)),
            }
        end

        categories[#categories + 1] = {
            categoryID = categoryID,
            info = sanitize(categoryInfo),
            subcategories = subcategoryData,
        }
    end

    return categories
end

local function collectRecipeData(recipeID, professionSkillLineID, vellumTargetGUIDs)
    local recipeInfo = safeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    local schematic = safeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    local outputItemData = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
    local recipeName = type(recipeInfo) == "table" and recipeInfo.name or nil
    local recipeType = type(recipeInfo) == "table" and recipeInfo.recipeType or nil
    local isEnchantingRecipe = type(recipeInfo) == "table" and recipeInfo.isEnchantingRecipe or nil
    local enchantRecipeType = Enum and Enum.TradeskillRecipeType and Enum.TradeskillRecipeType.Enchant or 3
    local looksEnchantByName = type(recipeName) == "string" and string.find(string.lower(recipeName), "^enchant ") ~= nil
    local isEnchantRecipe = recipeType == enchantRecipeType or isEnchantingRecipe == true or looksEnchantByName

    local isDebugTargetRecipeName = type(recipeName) == "string"
        and (string.match(recipeName, "^Enchant Chest %- ") ~= nil or string.match(recipeName, "^Enchant Helm %- ") ~= nil)

    if isEnchantRecipe and isDebugTargetRecipeName then
        debugMidnightLog(
            "GetRecipeOutputItemData recipeID=%d recipeName=%s output=%s",
            recipeID,
            safeToString(recipeName),
            summarizeTable(outputItemData)
        )
        debugMidnightLog("RecipeInfo recipeID=%d recipeType=%s isEnchantingRecipe=%s", recipeID, safeToString(recipeType), safeToString(isEnchantingRecipe))
    end
    local qualityItemIDs = safeCall(C_TradeSkillUI.GetRecipeQualityItemIDs, recipeID)
    local qualityIDs = safeCall(C_TradeSkillUI.GetQualitiesForRecipe, recipeID)
    local outputQualityEntries = buildOutputQualityEntries(qualityItemIDs, qualityIDs)
    local requirements = safeCall(C_TradeSkillUI.GetRecipeRequirements, recipeID)
    local sourceText = safeCall(C_TradeSkillUI.GetRecipeSourceText, recipeID)
    local recipeItemLink = safeCall(C_TradeSkillUI.GetRecipeItemLink, recipeID)
    local recipeLink = safeCall(C_TradeSkillUI.GetRecipeLink, recipeID)
    local tradeSkillLineID, tradeSkillLineName, parentTradeSkillID = safeCall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
    local isSalvageRecipe = type(recipeInfo) == "table" and recipeInfo.isSalvageRecipe == true
    local defaultCraftingReagents = buildDefaultCraftingReagents(schematic)
    local craftingOperationInfo = nil
    if type(schematic) == "table" and schematic.hasCraftingOperationInfo then
        craftingOperationInfo = safeCall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, defaultCraftingReagents, nil, false)
        if type(craftingOperationInfo) ~= "table" then
            craftingOperationInfo = safeCall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, false)
        end
    end
    local craftingStatFlags = extractCraftingStatFlags(craftingOperationInfo)
    local recipeSalvageTargets = {}
    if isSalvageRecipe then
        recipeSalvageTargets = extractSalvageTargets(recipeID)
    end
    local recipeEnchantTargetOutputs = extractEnchantTargetOutputs(
        recipeID,
        recipeInfo,
        defaultCraftingReagents,
        qualityIDs,
        vellumTargetGUIDs
    )

    if isEnchantRecipe and isDebugTargetRecipeName then
        debugMidnightLog("RecipeProbe recipeID=%d professionSkillLineID=%s", recipeID, safeToString(professionSkillLineID))
        debugMidnightLog("RecipeInfo summary=%s", summarizeTable(recipeInfo))
        debugMidnightLog("RecipeSchematic summary=%s", summarizeTable(schematic))
        debugMidnightLog("RecipeOutput(base) summary=%s", summarizeTable(outputItemData))
        debugMidnightLog("QualityIDs summary=%s", summarizeTable(qualityIDs))
        debugMidnightLog("QualityItemIDs summary=%s", summarizeTable(qualityItemIDs))
        debugMidnightLog("OutputQualities summary=%s", summarizeTable(outputQualityEntries))
        debugMidnightLog("DefaultCraftingReagents summary=%s", summarizeTable(defaultCraftingReagents))
        debugMidnightLog("RecipeLinks itemLink=%s recipeLink=%s sourceText=%s", safeToString(recipeItemLink), safeToString(recipeLink), safeToString(sourceText))
        debugMidnightLog("TradeSkillLine tradeSkillLineID=%s tradeSkillLineName=%s parentTradeSkillID=%s", safeToString(tradeSkillLineID), safeToString(tradeSkillLineName), safeToString(parentTradeSkillID))

        local qualityIDList = getQualityIDList(qualityIDs)
        if #qualityIDList == 0 then
            qualityIDList = { nil }
        end

        local probeTargetGUIDs = {}
        local seenProbeTargetGUIDs = {}
        local function addProbeTargetGUIDs(guidList)
            for _, guid in ipairs(guidList or {}) do
                if type(guid) == "string" and guid ~= "" and not seenProbeTargetGUIDs[guid] then
                    seenProbeTargetGUIDs[guid] = true
                    probeTargetGUIDs[#probeTargetGUIDs + 1] = guid
                end
            end
        end

        addProbeTargetGUIDs(safeCallList(C_TradeSkillUI.GetEnchantItems, recipeID, defaultCraftingReagents))
        addProbeTargetGUIDs(safeCallList(C_TradeSkillUI.GetEnchantItems, recipeID))
        addProbeTargetGUIDs(vellumTargetGUIDs)
        debugMidnightLog("Probe targetGUID count=%d", #probeTargetGUIDs)

        local probeBase = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        debugMidnightLog("Probe GetRecipeOutputItemData(recipeID) => %s", summarizeTable(probeBase))

        for _, qualityID in ipairs(qualityIDList) do
            local probeQualityOnly = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, nil, nil, qualityID)
            debugMidnightLog(
                "Probe GetRecipeOutputItemData(recipeID,nil,nil,qualityID=%s) => %s",
                safeToString(qualityID),
                summarizeTable(probeQualityOnly)
            )

            local probeReagentsQuality = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, defaultCraftingReagents, nil, qualityID)
            debugMidnightLog(
                "Probe GetRecipeOutputItemData(recipeID,defaultReagents,nil,qualityID=%s) => %s",
                safeToString(qualityID),
                summarizeTable(probeReagentsQuality)
            )
        end

        local maxTargetProbes = math.min(#probeTargetGUIDs, 3)
        if #probeTargetGUIDs > maxTargetProbes then
            debugMidnightLog("Probe targetGUID list truncated to first %d of %d", maxTargetProbes, #probeTargetGUIDs)
        end

        for targetIndex = 1, maxTargetProbes do
            local targetGUID = probeTargetGUIDs[targetIndex]
            local canStoreEnchant = safeCall(C_TradeSkillUI.CanStoreEnchantInItem, targetGUID)
            debugMidnightLog("Probe targetGUID[%d]=%s canStore=%s", targetIndex, safeToString(targetGUID), safeToString(canStoreEnchant))

            local probeTargetNoQuality = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, defaultCraftingReagents, targetGUID)
            debugMidnightLog(
                "Probe GetRecipeOutputItemData(recipeID,defaultReagents,targetGUID=%s) => %s",
                safeToString(targetGUID),
                summarizeTable(probeTargetNoQuality)
            )

            for _, qualityID in ipairs(qualityIDList) do
                local probeTargetQuality = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, defaultCraftingReagents, targetGUID, qualityID)
                debugMidnightLog(
                    "Probe GetRecipeOutputItemData(recipeID,defaultReagents,targetGUID=%s,qualityID=%s) => %s",
                    safeToString(targetGUID),
                    safeToString(qualityID),
                    summarizeTable(probeTargetQuality)
                )

                local probeTargetNoReagentsQuality = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, nil, targetGUID, qualityID)
                debugMidnightLog(
                    "Probe GetRecipeOutputItemData(recipeID,nil,targetGUID=%s,qualityID=%s) => %s",
                    safeToString(targetGUID),
                    safeToString(qualityID),
                    summarizeTable(probeTargetNoReagentsQuality)
                )
            end
        end
    end

    return {
        recipeID = recipeID,
        professionSkillLineID = professionSkillLineID,
        recipeInfo = sanitize(recipeInfo),
        recipeSchematic = sanitize(schematic),
        recipeReagentSlots = extractRecipeSchematicReagents(schematic),
        recipeOutput = sanitize(outputItemData),
        qualityItemIDs = sanitize(qualityItemIDs),
        qualityIDs = sanitize(qualityIDs),
        recipeOutputQualities = sanitize(outputQualityEntries),
        recipeEnchantTargetOutputs = sanitize(recipeEnchantTargetOutputs),
        defaultCraftingReagents = sanitize(defaultCraftingReagents),
        recipeOperationInfo = sanitize(craftingOperationInfo),
        recipeCraftingStats = sanitize(craftingStatFlags),
        recipeSalvageTargets = sanitize(recipeSalvageTargets),
        recipeRequirements = sanitize(requirements),
        recipeSourceText = sourceText,
        recipeItemLink = recipeItemLink,
        recipeLink = recipeLink,
        recipeTradeSkillLine = {
            tradeSkillLineID = tradeSkillLineID,
            tradeSkillLineName = tradeSkillLineName,
            parentTradeSkillID = parentTradeSkillID,
        },
    }
end

local function collectProfessionData(skillLineID)
    local professionInfoBySkillLine = safeCall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
    local baseProfessionInfo = safeCall(C_TradeSkillUI.GetBaseProfessionInfo)
    local childProfessionInfos = safeCall(C_TradeSkillUI.GetChildProfessionInfos) or {}
    local categoryData = collectCategoryData()
    local recipeIDs = safeCallList(C_TradeSkillUI.GetAllRecipeIDs)
    local vellumTargetGUIDs = collectVellumTargetGUIDs()
    local recipes = {}

    for _, recipeID in ipairs(recipeIDs) do
        recipes[#recipes + 1] = collectRecipeData(recipeID, skillLineID, vellumTargetGUIDs)
    end

    return {
        skillLineID = skillLineID,
        collectedAtEpoch = time(),
        professionInfo = sanitize(professionInfoBySkillLine),
        baseProfessionInfo = sanitize(baseProfessionInfo),
        childProfessionInfos = sanitize(childProfessionInfos),
        categories = categoryData,
        recipes = recipes,
        recipeCount = #recipes,
    }
end

local function findFirstBagItemGUID(itemID)
    if type(itemID) ~= "number" then
        return nil, nil, nil
    end

    local bagStart = Enum and Enum.BagIndex and Enum.BagIndex.Backpack or 0
    local bagEnd = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 5

    for bagIndex = bagStart, bagEnd do
        local numSlots = safeCall(C_Container.GetContainerNumSlots, bagIndex)
        if type(numSlots) == "number" and numSlots > 0 then
            for slotIndex = 1, numSlots do
                local containerInfo = safeCall(C_Container.GetContainerItemInfo, bagIndex, slotIndex)
                if type(containerInfo) == "table" and containerInfo.itemID == itemID then
                    local itemGUID = containerInfo.itemGUID
                    if (type(itemGUID) ~= "string" or itemGUID == "")
                        and type(ItemLocation) == "table"
                        and type(ItemLocation.CreateFromBagAndSlot) == "function"
                    then
                        local itemLocation = ItemLocation:CreateFromBagAndSlot(bagIndex, slotIndex)
                        itemGUID = safeCall(C_Item.GetItemGUID, itemLocation)
                    end

                    if type(itemGUID) == "string" and itemGUID ~= "" then
                        return itemGUID, bagIndex, slotIndex
                    end
                end
            end
        end
    end

    return nil, nil, nil
end

local function collectSalvageRecipeData(recipeID, professionSkillLineID)
    local recipeInfo = safeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if type(recipeInfo) ~= "table" or recipeInfo.isSalvageRecipe ~= true then
        return nil
    end

    local schematic = safeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    local defaultCraftingReagents = buildDefaultCraftingReagents(schematic)
    local recipeSalvageTargets = extractSalvageTargets(recipeID)
    local recipeOutputBase = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
    local tradeSkillLineID, tradeSkillLineName, parentTradeSkillID = safeCall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)

    local inputProbes = {}
    for _, target in ipairs(recipeSalvageTargets) do
        local targetItemID = target.itemID
        local ownedCount = safeCall(C_Item.GetItemCount, targetItemID) or 0
        local itemGUID, bagIndex, slotIndex = findFirstBagItemGUID(targetItemID)

        local outputNoAllocation = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, defaultCraftingReagents, nil)
        if type(outputNoAllocation) ~= "table" then
            outputNoAllocation = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        end

        local outputWithAllocation = nil
        local outputWithAllocationNoReagents = nil
        if type(itemGUID) == "string" and itemGUID ~= "" then
            outputWithAllocation = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, defaultCraftingReagents, itemGUID)
            outputWithAllocationNoReagents = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, nil, itemGUID)
        end

        inputProbes[#inputProbes + 1] = {
            itemID = targetItemID,
            itemName = target.itemName,
            ownedCount = ownedCount,
            hasAllocationItem = type(itemGUID) == "string" and itemGUID ~= "",
            allocationItemGUID = itemGUID,
            bagIndex = bagIndex,
            slotIndex = slotIndex,
            outputNoAllocation = sanitize(outputNoAllocation),
            outputWithAllocation = sanitize(outputWithAllocation),
            outputWithAllocationNoReagents = sanitize(outputWithAllocationNoReagents),
        }
    end

    return {
        recipeID = recipeID,
        professionSkillLineID = professionSkillLineID,
        recipeInfo = sanitize(recipeInfo),
        recipeSchematic = sanitize(schematic),
        recipeOutputBase = sanitize(recipeOutputBase),
        defaultCraftingReagents = sanitize(defaultCraftingReagents),
        recipeSalvageTargets = sanitize(recipeSalvageTargets),
        inputProbes = sanitize(inputProbes),
        recipeTradeSkillLine = {
            tradeSkillLineID = tradeSkillLineID,
            tradeSkillLineName = tradeSkillLineName,
            parentTradeSkillID = parentTradeSkillID,
        },
    }
end

local function collectProfessionSalvageData(skillLineID)
    local professionInfoBySkillLine = safeCall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
    local recipeIDs = safeCallList(C_TradeSkillUI.GetAllRecipeIDs)
    local salvageRecipes = {}

    for _, recipeID in ipairs(recipeIDs) do
        local recipeData = collectSalvageRecipeData(recipeID, skillLineID)
        if recipeData then
            salvageRecipes[#salvageRecipes + 1] = recipeData
        end
    end

    return {
        skillLineID = skillLineID,
        collectedAtEpoch = time(),
        professionInfo = sanitize(professionInfoBySkillLine),
        salvageRecipes = salvageRecipes,
        salvageRecipeCount = #salvageRecipes,
    }
end

local function finalizeSalvageScan()
    state.isSalvageScanning = false

    local exportData = state.currentSalvageExport
    if not exportData then
        return
    end

    local db = ProfessionRecipeExporterDB
    db.salvageRunCount = (db.salvageRunCount or 0) + 1
    local exportID = db.salvageRunCount

    exportData.exportID = exportID
    exportData.completedAtEpoch = time()
    exportData.completedAtISO8601 = date("!%Y-%m-%dT%H:%M:%SZ")
    exportData.totalProfessionsScanned = 0
    exportData.totalSalvageRecipesScanned = 0

    for _, professionData in pairs(exportData.professions) do
        exportData.totalProfessionsScanned = exportData.totalProfessionsScanned + 1
        exportData.totalSalvageRecipesScanned = exportData.totalSalvageRecipesScanned + (professionData.salvageRecipeCount or 0)
    end

    db.salvageExports[exportID] = exportData
    db.latestSalvageExportID = exportID
    state.currentSalvageExport = nil

    log(L.salvageScanFinished, exportID, exportData.totalProfessionsScanned, exportData.totalSalvageRecipesScanned)
end

finalizeScan = function()
    state.isScanning = false

    local exportData = state.currentExport
    if not exportData then
        return
    end

    local db = ProfessionRecipeExporterDB
    db.runCount = db.runCount + 1
    local exportID = db.runCount

    exportData.exportID = exportID
    exportData.completedAtEpoch = time()
    exportData.completedAtISO8601 = date("!%Y-%m-%dT%H:%M:%SZ")
    exportData.totalProfessionsScanned = 0
    exportData.totalRecipesScanned = 0

    for _, professionData in pairs(exportData.professions) do
        exportData.totalProfessionsScanned = exportData.totalProfessionsScanned + 1
        exportData.totalRecipesScanned = exportData.totalRecipesScanned + (professionData.recipeCount or 0)
    end

    db.exports[exportID] = exportData
    db.latestExportID = exportID
    state.currentExport = nil

    log(L.scanFinished, exportID, exportData.totalProfessionsScanned, exportData.totalRecipesScanned)
end

local function resolveCurrentSkillLineID()
    local childSkillLineID = safeCall(C_TradeSkillUI.GetProfessionChildSkillLineID)
    if type(childSkillLineID) == "number" and childSkillLineID > 0 then
        return childSkillLineID
    end

    local childInfo = safeCall(C_TradeSkillUI.GetChildProfessionInfo)
    if type(childInfo) == "table" and type(childInfo.skillLineID) == "number" and childInfo.skillLineID > 0 then
        return childInfo.skillLineID
    end

    local baseInfo = safeCall(C_TradeSkillUI.GetBaseProfessionInfo)
    if type(baseInfo) == "table" and type(baseInfo.skillLineID) == "number" and baseInfo.skillLineID > 0 then
        return baseInfo.skillLineID
    end

    local recipeIDs = safeCallList(C_TradeSkillUI.GetAllRecipeIDs)
    local firstRecipeID = recipeIDs[1]
    if firstRecipeID ~= nil then
        local tradeSkillID = safeCall(C_TradeSkillUI.GetTradeSkillLineForRecipe, firstRecipeID)
        if type(tradeSkillID) == "number" and tradeSkillID > 0 then
            log(L.captureUsedRecipeFallback, tradeSkillID)
            return tradeSkillID
        end
    end

    return nil
end

local function captureCurrentProfession()
    if not state.isScanning then
        return
    end

    local isReady = safeCall(C_TradeSkillUI.IsTradeSkillReady)
    if not isReady then
        log(L.captureSkippedNotReady)
        return
    end

    local currentExport = state.currentExport
    if not currentExport then
        state.isScanning = false
        return
    end

    local skillLineID = resolveCurrentSkillLineID()
    if type(skillLineID) ~= "number" then
        log(L.captureSkippedNoSkillLine)
        return
    end

    currentExport.professions = currentExport.professions or {}
    local hadPrevious = currentExport.professions[skillLineID] ~= nil
    currentExport.professions[skillLineID] = collectProfessionData(skillLineID)

    if hadPrevious then
        log(L.professionUpdated, skillLineID)
    else
        log(L.professionCaptured, skillLineID)
    end
end

local function captureCurrentSalvageProfession()
    if not state.isSalvageScanning then
        return
    end

    local isReady = safeCall(C_TradeSkillUI.IsTradeSkillReady)
    if not isReady then
        log(L.captureSkippedNotReady)
        return
    end

    local currentExport = state.currentSalvageExport
    if not currentExport then
        state.isSalvageScanning = false
        return
    end

    local skillLineID = resolveCurrentSkillLineID()
    if type(skillLineID) ~= "number" then
        log(L.captureSkippedNoSkillLine)
        return
    end

    currentExport.professions = currentExport.professions or {}
    local hadPrevious = currentExport.professions[skillLineID] ~= nil
    currentExport.professions[skillLineID] = collectProfessionSalvageData(skillLineID)

    if hadPrevious then
        log(L.salvageProfessionUpdated, skillLineID)
    else
        log(L.salvageProfessionCaptured, skillLineID)
    end
end

local function beginScan()
    if state.isSalvageScanning then
        log(L.salvageScanAlreadyRunning)
        return
    end

    if state.isScanning then
        log(L.scanAlreadyRunning)
        return
    end

    state.isScanning = true
    local classLocalized, classFile = UnitClass("player")
    local raceLocalized, raceFile = UnitRace("player")
    state.currentExport = {
        schemaVersion = 1,
        addonName = ADDON_NAME,
        gameVersion = select(1, GetBuildInfo()),
        interfaceVersion = select(4, GetBuildInfo()),
        startedAtEpoch = time(),
        startedAtISO8601 = date("!%Y-%m-%dT%H:%M:%SZ"),
        player = {
            name = UnitName("player"),
            realm = GetRealmName(),
            classLocalized = classLocalized,
            classFile = classFile,
            raceLocalized = raceLocalized,
            raceFile = raceFile,
            faction = UnitFactionGroup("player"),
            level = UnitLevel("player"),
        },
        professions = {},
    }

    log(L.scanStarted)
    log(L.scanInstruction)
end

local function beginSalvageScan()
    if state.isScanning then
        log(L.scanAlreadyRunning)
        return
    end

    if state.isSalvageScanning then
        log(L.salvageScanAlreadyRunning)
        return
    end

    state.isSalvageScanning = true
    local classLocalized, classFile = UnitClass("player")
    local raceLocalized, raceFile = UnitRace("player")
    state.currentSalvageExport = {
        schemaVersion = 1,
        exportType = "salvage",
        addonName = ADDON_NAME,
        gameVersion = select(1, GetBuildInfo()),
        interfaceVersion = select(4, GetBuildInfo()),
        startedAtEpoch = time(),
        startedAtISO8601 = date("!%Y-%m-%dT%H:%M:%SZ"),
        player = {
            name = UnitName("player"),
            realm = GetRealmName(),
            classLocalized = classLocalized,
            classFile = classFile,
            raceLocalized = raceLocalized,
            raceFile = raceFile,
            faction = UnitFactionGroup("player"),
            level = UnitLevel("player"),
        },
        professions = {},
    }

    log(L.salvageScanStarted)
    log(L.salvageScanInstruction)
end

local function finishScan()
    if not state.isScanning then
        log(L.scanNotRunning)
        return
    end

    if state.finalizePending then
        log(L.finalizeAlreadyPending)
        return
    end

    startFinalizeSequence()
end

local function finishSalvageScan()
    if not state.isSalvageScanning then
        log(L.salvageScanNotRunning)
        return
    end

    finalizeSalvageScan()
end

local function printStatus()
    if state.isSalvageScanning then
        local currentExport = state.currentSalvageExport
        local capturedCount = 0
        if currentExport and currentExport.professions then
            for _ in pairs(currentExport.professions) do
                capturedCount = capturedCount + 1
            end
        end

        log("Status: salvage scanning (%d professions captured).", capturedCount)
        return
    end

    if state.isScanning then
        local currentExport = state.currentExport
        local capturedCount = 0
        if currentExport and currentExport.professions then
            for _ in pairs(currentExport.professions) do
                capturedCount = capturedCount + 1
            end
        end

        log(L.statusRunning, capturedCount)
        return
    end

    log(L.statusIdle)
    local db = ProfessionRecipeExporterDB
    if not db.latestExportID then
        log(L.noExportData)
        return
    end

    local latest = db.exports[db.latestExportID]
    if not latest then
        log(L.noExportData)
        return
    end

    log(L.statusLatest, latest.exportID, latest.totalProfessionsScanned or 0, latest.totalRecipesScanned or 0, latest.completedAtISO8601 or "unknown")
end

local function printLatestExportPathHint()
    local db = ProfessionRecipeExporterDB
    if not db.latestExportID or not db.exports[db.latestExportID] then
        log(L.noExportData)
        return
    end

    local latest = db.exports[db.latestExportID]
    log("Latest export ID: %d", latest.exportID)
    log("SavedVariables table: ProfessionRecipeExporterDB.exports[%d]", latest.exportID)
end

local function clearData()
    ProfessionRecipeExporterDB = {}
    copyDefaults(ProfessionRecipeExporterDB, defaults)
    log(L.dataCleared)
end

local function printSalvageLogStatus()
    local db = ProfessionRecipeExporterDB
    local enabledText = db.salvageTrackingEnabled and "enabled" or "disabled"
    local sessionCount = 0
    for _ in pairs(db.salvageTrackingSessions or {}) do
        sessionCount = sessionCount + 1
    end

    local latestSessionID = db.latestSalvageTrackingSessionID
    local currentSessionID = state.currentSalvageTrackingSession and state.currentSalvageTrackingSession.sessionID or nil
    log(
        L.salvageTrackingStatus,
        enabledText,
        sessionCount,
        tostring(latestSessionID),
        tostring(currentSessionID)
    )
end

local function setSalvageTrackingEnabled(enabled)
    ProfessionRecipeExporterDB.salvageTrackingEnabled = enabled == true
    if ProfessionRecipeExporterDB.salvageTrackingEnabled then
        getOrCreateSalvageTrackingSession()
        log(L.salvageTrackingEnabled)
    else
        log(L.salvageTrackingDisabled)
    end
end

local function clearSalvageTrackingHistory()
    local db = ProfessionRecipeExporterDB
    db.salvageTrackingSessions = {}
    db.salvageTrackingSessionCounter = 0
    db.latestSalvageTrackingSessionID = nil
    state.currentSalvageTrackingSession = nil
    state.pendingSalvageCalls = {}
    log(L.salvageTrackingCleared)

    if db.salvageTrackingEnabled then
        getOrCreateSalvageTrackingSession()
    end
end

local function printLatestSalvageTrackingPathHint()
    local db = ProfessionRecipeExporterDB
    local latestSessionID = db.latestSalvageTrackingSessionID
    if type(latestSessionID) ~= "number" then
        log("No salvage tracking session available yet.")
        return
    end

    if type(db.salvageTrackingSessions[latestSessionID]) ~= "table" then
        log("Latest salvage tracking session ID exists but no data found.")
        return
    end

    log(L.salvageTrackingLatest, latestSessionID)
end

local function handleSlashCommand(input)
    local command = input and input:match("^%s*(%S+)")
    if not command then
        log(L.commandHelp)
        return
    end

    command = string.lower(command)
    if command == "scan" then
        beginScan()
        return
    end

    if command == "salvagescan" then
        beginSalvageScan()
        return
    end

    if command == "finish" then
        finishScan()
        return
    end

    if command == "salvagedone" then
        finishSalvageScan()
        return
    end

    if command == "salvagelogstatus" then
        printSalvageLogStatus()
        return
    end

    if command == "salvagelogon" then
        setSalvageTrackingEnabled(true)
        return
    end

    if command == "salvagelogoff" then
        setSalvageTrackingEnabled(false)
        return
    end

    if command == "salvagelogclear" then
        clearSalvageTrackingHistory()
        return
    end

    if command == "salvageloglatest" then
        printLatestSalvageTrackingPathHint()
        return
    end

    if command == "status" then
        printStatus()
        return
    end

    if command == "latest" then
        printLatestExportPathHint()
        return
    end

    if command == "clear" then
        clearData()
        return
    end

    if command == "debugenchant" then
        local arg = input and input:match("^%s*%S+%s+(%S+)")
        if type(arg) == "string" then
            arg = string.lower(arg)
        end

        if arg == "on" then
            DEBUG_ENCHANT_OUTPUTS = true
            log("Enchant debug logging enabled.")
            return
        elseif arg == "off" then
            DEBUG_ENCHANT_OUTPUTS = false
            log("Enchant debug logging disabled.")
            return
        end

        log("Usage: /pre debugenchant on|off")
        return
    end

    if command == "debugmidnight" then
        local arg = input and input:match("^%s*%S+%s+(%S+)")
        if type(arg) == "string" then
            arg = string.lower(arg)
        end

        if arg == "on" then
            DEBUG_MIDNIGHT_RECIPES = true
            log("Midnight recipe debug logging enabled.")
            return
        elseif arg == "off" then
            DEBUG_MIDNIGHT_RECIPES = false
            log("Midnight recipe debug logging disabled.")
            return
        end

        log("Usage: /pre debugmidnight on|off")
        return
    end

    log(L.commandHelp)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then
            return
        end

        ensureDatabase()
        hookSalvageCraftCallIfNeeded()
        if ProfessionRecipeExporterDB.salvageTrackingEnabled then
            getOrCreateSalvageTrackingSession()
        end
        SLASH_PROFESSIONRECIPEEXPORTER1 = "/pre"
        SlashCmdList.PROFESSIONRECIPEEXPORTER = handleSlashCommand
        log(L.loaded)
        return
    end

    if event == "TRADE_SKILL_CRAFT_BEGIN" then
        local recipeSpellID = ...
        recordCraftBegin(recipeSpellID)
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unitTarget, castGUID, spellID, castBarID = ...
        recordSpellcastSucceeded(unitTarget, castGUID, spellID, castBarID)
        return
    end

    if event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        local craftingItemResultData = ...
        recordCraftResultEvent(craftingItemResultData)
        return
    end

    if event == "GET_ITEM_INFO_RECEIVED" then
        if state.finalizePending and not state.finalizeCheckQueued then
            state.finalizeCheckQueued = true
            C_Timer.After(0.1, function()
                state.finalizeCheckQueued = false
                continueFinalizeAfterItemWarmup()
            end)
        end
        return
    end

    if event == "TRADE_SKILL_SHOW"
        or event == "TRADE_SKILL_LIST_UPDATE"
        or event == "TRADE_SKILL_DETAILS_UPDATE"
        or event == "TRADE_SKILL_DATA_SOURCE_CHANGED"
    then
        if state.isScanning then
            captureCurrentProfession()
        end
        if state.isSalvageScanning then
            captureCurrentSalvageProfession()
        end
    end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_DETAILS_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
eventFrame:RegisterEvent("TRADE_SKILL_CRAFT_BEGIN")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")