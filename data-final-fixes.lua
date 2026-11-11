-- Modlist UI can retain thumbnail dimensions from an older portal snapshot.
-- Repair only references to our own, unchanged 144x144 thumbnail. Nothing runs
-- during gameplay; the optional dependency puts this after Modlist UI's data.
if not mods["modlist-ui"] then return end

local filename = "__even-distribution-fork__/thumbnail.png"
local size = 144

local function repair(sprite)
  if sprite.filename == filename then
    local dimensions = sprite.size
    local width = sprite.width or (type(dimensions) == "table" and dimensions[1] or dimensions) or size
    local height = sprite.height or (type(dimensions) == "table" and dimensions[2] or dimensions) or size
    local x, y = sprite.x or 0, sprite.y or 0
    if x == 0 and y == 0 and sprite.position then x, y = sprite.position[1], sprite.position[2] end
    if x + width > size or y + height > size then
      -- Preserve the intended display size while using the whole actual image.
      sprite.scale = (sprite.scale or 1) * math.max(width, height) / size
      sprite.size = nil
      sprite.width, sprite.height = size, size
      sprite.x, sprite.y = 0, 0
      sprite.position = nil
    end
  end
  for _, layer in pairs(sprite.layers or {}) do repair(layer) end
end

for _, sprite in pairs(data.raw.sprite or {}) do repair(sprite) end
