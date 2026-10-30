-- Mana costs and automatic payment.
-- Reference: forge-core forge/card/mana/ManaCostParser, ManaCost; forge-ai ComputerUtilMana (auto-pay).

local mana = {}

mana.COLORS = { "W", "U", "B", "R", "G" }
local is_color = { W = true, U = true, B = true, R = true, G = true }

-- "2 W W" -> { generic = 2, shards = { "W", "W" } }; "no cost" -> nil.
-- Hybrid symbols (Forge writes {B/R} as "BR") become shards like "B/R", payable by either color.
-- Returns nil plus a reason for costs the engine can't pay yet (X, phyrexian, 2/W, snow).
function mana.parse_cost(text)
  if text == nil or text == "no cost" then
    return nil
  end
  local cost = { generic = 0, shards = {} }
  for token in text:gmatch("%S+") do
    if token:match("^%d+$") then
      cost.generic = cost.generic + tonumber(token)
    elseif is_color[token] or token == "C" then
      cost.shards[#cost.shards + 1] = token
    elseif #token == 2 and is_color[token:sub(1, 1)] and is_color[token:sub(2, 2)] then
      cost.shards[#cost.shards + 1] = token:sub(1, 1) .. "/" .. token:sub(2, 2)
    else
      return nil, "mana symbol " .. token
    end
  end
  return cost
end

function mana.mana_value(cost)
  if cost == nil then
    return 0
  end
  return cost.generic + #cost.shards
end

-- "W" -> {W}; "Combo W U" -> {W, U}; "Any" -> WUBRG. Returns nil for unsupported Produced$ values.
function mana.parse_produced(text)
  if text == "Any" then
    return { "W", "U", "B", "R", "G" }
  end
  if is_color[text] or text == "C" then
    return { text }
  end
  local rest = text:match("^Combo (.+)$")
  if rest == nil then
    return nil
  end
  local colors = {}
  for token in rest:gmatch("%S+") do
    if token == "Any" then
      return { "W", "U", "B", "R", "G" }
    elseif is_color[token] or token == "C" then
      colors[#colors + 1] = token
    else
      return nil
    end
  end
  return colors
end

-- Which color a source pays a shard with ("W", or "W/U" for hybrid), or nil if it can't.
local function pays_with(source, shard)
  for _, c in ipairs(source.colors) do
    if c == shard or (#shard == 3 and (c == shard:sub(1, 1) or c == shard:sub(3, 3))) then
      return c
    end
  end
  return nil
end

-- Finds a set of sources that pays the cost. Each source is { card = ..., colors = { "W", ... } }
-- and taps for one mana of one of its colors. Returns a list of { source, color } or nil.
-- Colored shards are matched first (backtracking, narrow sources first); generic uses whatever is left,
-- preferring the sources that can make the fewest colors.
function mana.find_payment(cost, sources)
  if #cost.shards + cost.generic > #sources then
    return nil
  end
  local ordered = {}
  for i, s in ipairs(sources) do
    ordered[i] = s
  end
  table.sort(ordered, function(a, b)
    if #a.colors ~= #b.colors then
      return #a.colors < #b.colors
    end
    return a.card.id < b.card.id
  end)

  local used, assignment = {}, {}
  local function assign(i)
    local shard = cost.shards[i]
    if shard == nil then
      return true
    end
    for _, source in ipairs(ordered) do
      local color = not used[source] and pays_with(source, shard)
      if color then
        used[source] = true
        assignment[#assignment + 1] = { source = source, color = color }
        if assign(i + 1) then
          return true
        end
        used[source] = nil
        assignment[#assignment] = nil
      end
    end
    return false
  end
  if not assign(1) then
    return nil
  end

  local generic = cost.generic
  for _, source in ipairs(ordered) do
    if generic == 0 then
      break
    end
    if not used[source] then
      used[source] = true
      assignment[#assignment + 1] = { source = source, color = source.colors[1] }
      generic = generic - 1
    end
  end
  if generic > 0 then
    return nil
  end
  return assignment
end

return mana
