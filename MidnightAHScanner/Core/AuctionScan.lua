local addonName, ns = ...

ns.Scanner = {}

local Scanner = ns.Scanner

local function getText(key)
    return (ns.L and ns.L[key]) or key
end

local function printMsg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99MidnightAHScanner|r: " .. text)
end

local function debugLog(db, text)
    if db and db.settings and db.settings.debug then
        printMsg("[debug] " .. text)
    end
end

local function buildTimestamp()
    return date("%Y-%m-%d %H:%M:%S")
end

local function aggregateReplicateRows(numRows)
    local byItemID = {}

    for index = 1, numRows do
        local _, _, count, _, _, _, _, _, buyoutPrice, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(index)

        if itemID and buyoutPrice and buyoutPrice > 0 and count and count > 0 then
            local unitPrice = math.floor(buyoutPrice / count)
            local itemData = byItemID[itemID]

            if not itemData then
                byItemID[itemID] = {
                    minUnitPrice = unitPrice,
                    minBuyout = buyoutPrice,
                    totalQuantity = count,
                    auctionsSeen = 1,
                }
            else
                if unitPrice < itemData.minUnitPrice then
                    itemData.minUnitPrice = unitPrice
                end
                if buyoutPrice < itemData.minBuyout then
                    itemData.minBuyout = buyoutPrice
                end
                itemData.totalQuantity = itemData.totalQuantity + count
                itemData.auctionsSeen = itemData.auctionsSeen + 1
            end
        end
    end

    return byItemID
end

function Scanner:StartScan(runtime)
    if not runtime.isAHOpen then
        printMsg(getText("SCAN_NEEDS_AH"))
        return
    end

    if runtime.isScanning then
        printMsg(getText("SCAN_ALREADY_RUNNING"))
        return
    end

    runtime.isScanning = true
    runtime.scanStartedAt = GetServerTime()

    printMsg(getText("SCAN_STARTED"))
    C_AuctionHouse.ReplicateItems()
end

function Scanner:FinalizeScan(db, runtime)
    local numRows = C_AuctionHouse.GetNumReplicateItems()
    if not numRows or numRows <= 0 then
        runtime.isScanning = false
        printMsg(getText("SCAN_FAILED"))
        return
    end

    local aggregated = aggregateReplicateRows(numRows)
    local distinctItems = 0
    for _ in pairs(aggregated) do
        distinctItems = distinctItems + 1
    end

    local finishedAt = GetServerTime()
    local scanRecord = {
        startedAt = runtime.scanStartedAt,
        finishedAt = finishedAt,
        timestamp = buildTimestamp(),
        realm = GetRealmName(),
        faction = UnitFactionGroup("player"),
        rows = numRows,
        distinctItems = distinctItems,
        items = aggregated,
    }

    db.latestScan = scanRecord
    db.historyMeta[#db.historyMeta + 1] = {
        startedAt = runtime.scanStartedAt,
        finishedAt = finishedAt,
        rows = numRows,
        distinctItems = distinctItems,
    }

    if #db.historyMeta > 20 then
        table.remove(db.historyMeta, 1)
    end

    runtime.isScanning = false
    runtime.scanStartedAt = nil

    debugLog(db, "Saved latest scan snapshot to MidnightAHScannerDB.latestScan")
    printMsg(string.format(getText("SCAN_FINISHED"), numRows, distinctItems))
end

function Scanner:PrintStatus(db, runtime)
    if runtime.isScanning then
        printMsg(getText("STATUS_RUNNING"))
    else
        printMsg(getText("STATUS_IDLE"))
    end

    local lastScan = db.latestScan
    if not lastScan then
        printMsg(getText("STATUS_NONE"))
        return
    end

    printMsg(string.format(getText("STATUS_LAST"), lastScan.timestamp or "?", lastScan.rows or 0, lastScan.distinctItems or 0))
end
