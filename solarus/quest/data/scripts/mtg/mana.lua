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
  local cost = { generic = 0, shards = {}, x = 0 }
  for token in text:gmatch("%S+") do
    if token == "X" then
      cost.x = cost.x + 1   -- the caster chooses X (CR 107.3); its value is added as generic
    elseif token:match("^%d+$") then
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

-- "W" -> {W}; "Combo W U" -> {W, U}; "Any" -> WUBRG; "Chosen" -> {"Chosen"} (the color chosen
-- as the permanent entered, resolved by game:mana_sources). Returns nil for unsupported values.
function mana.parse_produced(text)
  if text == "Any" then
    return { "W", "U", "B", "R", "G" }
  end
  if is_color[text] or text == "C" or text == "Chosen" then
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
    elseif is_color[token] or token == "C" or token == "Chosen" then
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

-- Finds a set of sources that pays the cost. Each source is
--   { card = ..., colors = { "W", ... }, extra = n (optional), sacrifice = bool (optional) }
-- and makes one mana of one of its colors. A card may appear in several sources (one per mana
-- ability) but is used at most once. `extra` means the ability itself costs n more generic mana
-- (filters like "{1}, {T}: Add one mana of any color"); `sacrifice` means using it sacrifices the card.
-- Returns a list of { source, color } or nil.
-- Colored shards are matched first (backtracking; narrow, free sources first); generic is paid with
-- whatever plain sources are left (filters and sacrifice sources are never spent on generic).
function mana.find_payment(cost, sources)
  local function penalty(s)
    return ((s.extra or 0) > 0 or s.sacrifice) and 10 or 0
  end
  local ordered = {}
  for i, s in ipairs(sources) do
    ordered[i] = s
  end
  table.sort(ordered, function(a, b)
    local pa, pb = penalty(a) + #a.colors, penalty(b) + #b.colors
    if pa ~= pb then
      return pa < pb
    end
    return a.card.id < b.card.id
  end)

  local used, assignment = {}, {}
  local extra_needed = 0

  local function plain_left()
    local n = 0
    for _, s in ipairs(ordered) do
      if not used[s.card] and penalty(s) == 0 then
        n = n + 1
      end
    end
    return n
  end

  local function assign(i)
    local shard = cost.shards[i]
    if shard == nil then
      return plain_left() >= cost.generic + extra_needed
    end
    for _, source in ipairs(ordered) do
      local color = not used[source.card] and pays_with(source, shard)
      if color then
        used[source.card] = true
        extra_needed = extra_needed + (source.extra or 0)
        assignment[#assignment + 1] = { source = source, color = color }
        if assign(i + 1) then
          return true
        end
        used[source.card] = nil
        extra_needed = extra_needed - (source.extra or 0)
        assignment[#assignment] = nil
      end
    end
    return false
  end
  if not assign(1) then
    return nil
  end

  local generic = cost.generic + extra_needed
  for _, source in ipairs(ordered) do
    if generic == 0 then
      break
    end
    if not used[source.card] and penalty(source) == 0 then
      used[source.card] = true
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
