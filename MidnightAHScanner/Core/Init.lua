local addonName, ns = ...

local frame = CreateFrame("Frame")

local runtime = {
    isAHOpen = false,
    isScanning = false,
    scanStartedAt = nil,
}

local db

local function getText(key)
    return (ns.L and ns.L[key]) or key
end

local function printMsg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99MidnightAHScanner|r: " .. text)
end

local function setDebug(enabled)
    db.settings.debug = enabled and true or false
    if db.settings.debug then
        printMsg(getText("DEBUG_ON"))
    else
        printMsg(getText("DEBUG_OFF"))
    end
end

local function handleSlashCommand(input)
    local command = strlower(strtrim(input or ""))

    if command == "" then
        printMsg(getText("CMD_HELP"))
        return
    end

    if command == "scan" then
        ns.Scanner:StartScan(runtime)
        return
    end

    if command == "status" then
        ns.Scanner:PrintStatus(db, runtime)
        return
    end

    if command == "debug on" then
        setDebug(true)
        return
    end

    if command == "debug off" then
        setDebug(false)
        return
    end

    printMsg(getText("UNKNOWN_COMMAND") .. " " .. getText("CMD_HELP"))
end

local function registerSlashCommands()
    SLASH_MIDNIGHTAHSCANNER1 = "/mahs"
    SlashCmdList.MIDNIGHTAHSCANNER = handleSlashCommand
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then
            return
        end

        db = ns.DB:Init()
        return
    end

    if event == "PLAYER_LOGIN" then
        registerSlashCommands()
        frame:RegisterEvent("AUCTION_HOUSE_SHOW")
        frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
        frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
        frame:UnregisterEvent("PLAYER_LOGIN")
        frame:UnregisterEvent("ADDON_LOADED")
        return
    end

    if event == "AUCTION_HOUSE_SHOW" then
        runtime.isAHOpen = true
        return
    end

    if event == "AUCTION_HOUSE_CLOSED" then
        runtime.isAHOpen = false
        runtime.isScanning = false
        runtime.scanStartedAt = nil
        return
    end

    if event == "REPLICATE_ITEM_LIST_UPDATE" and runtime.isScanning then
        ns.Scanner:FinalizeScan(db, runtime)
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
