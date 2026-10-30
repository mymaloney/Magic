-- Mana costs and automatic payment.
-- Reference: forge-core forge/card/mana/ManaCostParser, ManaCost; forge-ai ComputerUtilMana (auto-pay).

local mana = {}

mana.COLORS = { "W", "U", "B", "R", "G" }
local is_color = { W = true, U = true, B = true, R = true, G = true }

-- "2 W W" -> { generic = 2, shards = { "W", "W" } }; "no cost" -> nil.
-- Returns nil plus a reason for costs the engine can't pay yet (X, hybrid, phyrexian, snow).
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

local function produces(source, color)
  for _, c in ipairs(source.colors) do
    if c == color then
      return true
    end
  end
  return false
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
      if not used[source] and produces(source, shard) then
        used[source] = true
        assignment[#assignment + 1] = { source = source, color = shard }
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
