local ADDON_NAME = ...

local defaults = {
    schemaVersion = 1,
    runCount = 0,
    latestExportID = nil,
    exports = {},
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
    commandHelp = "Commands: /pre scan, /pre finish, /pre status, /pre latest, /pre clear",
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
    finalizePending = false,
    finalizeRetryCount = 0,
    finalizeCheckQueued = false,
}

local FINALIZE_RETRY_INTERVAL_SECONDS = 1
local FINALIZE_MAX_RETRIES = 8
local finalizeScan

local eventFrame = CreateFrame("Frame")

local function log(message, ...)
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    print(string.format("%s %s", L.addonPrefix, message))
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

local function sanitize(value, seen, depth)
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

local function extractEnchantTargetOutputs(recipeID, recipeInfo, defaultCraftingReagents, qualityIDs)
    local outputs = {}
    if type(recipeInfo) ~= "table" then
        return outputs
    end

    local recipeType = recipeInfo.recipeType
    local enchantRecipeType = Enum and Enum.TradeskillRecipeType and Enum.TradeskillRecipeType.Enchant or 3
    if recipeType ~= enchantRecipeType then
        return outputs
    end

    local qualityIDList = getQualityIDList(qualityIDs)
    local enchantTargetGUIDs = safeCallList(C_TradeSkillUI.GetEnchantItems, recipeID, defaultCraftingReagents)
    for _, targetGUID in ipairs(enchantTargetGUIDs) do
        if type(targetGUID) == "string" and targetGUID ~= "" then
            local canStoreEnchant = safeCall(C_TradeSkillUI.CanStoreEnchantInItem, targetGUID)
            if canStoreEnchant == true then
                if #qualityIDList > 0 then
                    for rank, qualityID in ipairs(qualityIDList) do
                        local outputInfo = safeCall(
                            C_TradeSkillUI.GetRecipeOutputItemData,
                            recipeID,
                            defaultCraftingReagents,
                            targetGUID,
                            qualityID
                        )
                        local entry = buildEnchantTargetOutputEntry(targetGUID, qualityID, outputInfo, rank)
                        if entry then
                            outputs[#outputs + 1] = entry
                        end
                    end
                else
                    local outputInfo = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, defaultCraftingReagents, targetGUID)
                    local entry = buildEnchantTargetOutputEntry(targetGUID, nil, outputInfo, nil)
                    if entry then
                        outputs[#outputs + 1] = entry
                    end
                end
            end
        end
    end

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

local function collectRecipeData(recipeID, professionSkillLineID)
    local recipeInfo = safeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    local schematic = safeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    local outputItemData = safeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
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
        qualityIDs
    )

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
    local recipes = {}

    for _, recipeID in ipairs(recipeIDs) do
        recipes[#recipes + 1] = collectRecipeData(recipeID, skillLineID)
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

local function beginScan()
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

local function printStatus()
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

    if command == "finish" then
        finishScan()
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

    log(L.commandHelp)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then
            return
        end

        ensureDatabase()
        SLASH_PROFESSIONRECIPEEXPORTER1 = "/pre"
        SlashCmdList.PROFESSIONRECIPEEXPORTER = handleSlashCommand
        log(L.loaded)
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
    end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_DETAILS_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")