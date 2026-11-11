-- Shared insertion boundary. Native transactions retain complete stack data;
-- quantity-based helper callers keep their existing freshness/return behavior.
local batches = require("scripts.batches")
local legacy = require("scripts.legacy-transfer")
local this = {}
function this.insert(target, item, count, quality)
    if count <= 0 then return 0 end
    local inserted = batches.insert(target, item, count, quality)
    if inserted ~= nil then return inserted end
    return legacy.insert(target, item, count, quality)
end
this.batchActive = batches.isActive
this.replace = batches.replace
this.removeFromInventory = legacy.removeFromInventory
this.recordStack = legacy.recordStack
this.peek = legacy.peek
this.record = legacy.record
this.setStack = legacy.setStack
this.spill = legacy.spill
return this
