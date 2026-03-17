local addonName, ns = ...

ns.L = ns.L or {}
local L = ns.L

L.CMD_HELP = "Commands: /mahs scan, /mahs status, /mahs debug on|off"
L.SCAN_NEEDS_AH = "Open the Auction House first."
L.SCAN_ALREADY_RUNNING = "A scan is already running."
L.SCAN_STARTED = "AH scan started... waiting for replicate data."
L.SCAN_FINISHED = "AH scan finished. Rows: %d, distinct items: %d"
L.SCAN_FAILED = "AH scan failed: missing replicate data."
L.STATUS_IDLE = "Status: idle"
L.STATUS_RUNNING = "Status: scanning..."
L.STATUS_LAST = "Last scan: %s, rows=%d, items=%d"
L.STATUS_NONE = "Last scan: none"
L.DEBUG_ON = "Debug logging enabled."
L.DEBUG_OFF = "Debug logging disabled."
L.UNKNOWN_COMMAND = "Unknown command."
