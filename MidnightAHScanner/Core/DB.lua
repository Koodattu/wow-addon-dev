local addonName, ns = ...

ns.DB = {}

local SCHEMA_VERSION = 1

local function createDefaults()
    return {
        schemaVersion = SCHEMA_VERSION,
        settings = {
            debug = false,
        },
        latestScan = nil,
        historyMeta = {},
    }
end

local function migrate(db)
    if type(db) ~= "table" then
        return createDefaults()
    end

    db.schemaVersion = tonumber(db.schemaVersion) or 0

    if db.schemaVersion < 1 then
        db.settings = db.settings or { debug = false }
        db.latestScan = db.latestScan or nil
        db.historyMeta = db.historyMeta or {}
        db.schemaVersion = 1
    end

    if type(db.settings) ~= "table" then
        db.settings = { debug = false }
    elseif type(db.settings.debug) ~= "boolean" then
        db.settings.debug = false
    end

    if type(db.historyMeta) ~= "table" then
        db.historyMeta = {}
    end

    return db
end

function ns.DB:Init()
    MidnightAHScannerDB = migrate(MidnightAHScannerDB)
    return MidnightAHScannerDB
end
