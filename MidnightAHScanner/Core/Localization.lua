local addonName, ns = ...

ns.L = ns.L or {}
local L = ns.L

L.CMD_HELP = "Commands: /mahs scan, /mahs status, /mahs debug on|off"
L.SCAN_NEEDS_AH = "Open the Auction House first."
L.SCAN_ALREADY_RUNNING = "A scan is already running."
L.SCAN_STARTED = "AH scan started... waiting for replicate data."
L.SCAN_WAITING = "Scan is waiting for server response (%ds elapsed)."
L.SCAN_TIMEOUT = "Scan timed out waiting for replicate data. If you scanned recently, ReplicateItems may be on ~15 min account-wide cooldown."
L.SCAN_THROTTLED = "Auction House request queue is throttled. If this was a replicate scan, wait and retry later."
L.SCAN_FINISHED = "AH scan finished. Rows: %d, distinct items: %d"
L.SCAN_FAILED = "AH scan failed: missing replicate data."
L.STATUS_IDLE = "Status: idle"
L.STATUS_RUNNING = "Status: scanning... (%ds elapsed)"
L.STATUS_LAST = "Last scan: %s, rows=%d, items=%d"
L.STATUS_NONE = "Last scan: none"
L.DEBUG_ON = "Debug logging enabled."
L.DEBUG_OFF = "Debug logging disabled."
L.UNKNOWN_COMMAND = "Unknown command."
