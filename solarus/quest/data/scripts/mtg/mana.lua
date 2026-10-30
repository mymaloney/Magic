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
--   { card = ..., colors = { "W", ... }, extra = n (optional), sacrifice = bool (optional),
--     group = table (optional), pool = entry (optional), late = bool (optional) }
-- and makes one mana of one of its colors. A card may appear in several sources (one per mana
-- ability) but is used at most once. `extra` means the ability itself costs n more generic mana
-- (filters like "{1}, {T}: Add one mana of any color"); `sacrifice` means using it sacrifices the card.
-- Sources sharing a `group` are the units of one ability that makes several mana of one color
-- ("Add three mana of any one color"): any number of them can be used, all paying the same color.
-- `pool` sources (mana already in the pool) are used first, `late` ones (creatures tapped for
-- Heirloom Epic) last.
-- Returns a list of { source, color } or nil.
-- Colored shards are matched first (backtracking; narrow, free sources first); generic is paid with
-- whatever plain sources are left (filters and sacrifice sources are never spent on generic).
function mana.find_payment(cost, sources)
  local function penalty(s)
    return ((s.extra or 0) > 0 or s.sacrifice) and 10 or 0
  end
  local function sort_key(s)
    return penalty(s) + #s.colors + (s.pool and -2 or 0) + (s.late and 5 or 0)
  end
  local ordered = {}
  for i, s in ipairs(sources) do
    ordered[i] = s
  end
  table.sort(ordered, function(a, b)
    local pa, pb = sort_key(a), sort_key(b)
    if pa ~= pb then
      return pa < pb
    end
    if a.card.id ~= b.card.id then
      return a.card.id < b.card.id
    end
    return (a.unit or 0) < (b.unit or 0)
  end)

  local used, unit_used, group_count, group_color = {}, {}, {}, {}
  local assignment = {}
  local extra_needed = 0

  local function available(s)
    if s.group then
      return (used[s.card] == nil or used[s.card] == s.group) and not unit_used[s]
    end
    return used[s.card] == nil
  end
  local function take(s, color)
    if s.group then
      used[s.card] = s.group
      unit_used[s] = true
      group_count[s.group] = (group_count[s.group] or 0) + 1
      group_color[s.group] = group_color[s.group] or color
    else
      used[s.card] = true
    end
  end
  local function release(s)
    if s.group then
      unit_used[s] = nil
      group_count[s.group] = group_count[s.group] - 1
      if group_count[s.group] == 0 then
        used[s.card] = nil
        group_color[s.group] = nil
      end
    else
      used[s.card] = nil
    end
  end
  local function color_for(s, shard)
    local fixed = s.group and group_color[s.group]
    if fixed then
      return pays_with({ colors = { fixed } }, shard)
    end
    return pays_with(s, shard)
  end

  local function plain_left()
    local n = 0
    for _, s in ipairs(ordered) do
      if available(s) and penalty(s) == 0 then
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
      local color = available(source) and color_for(source, shard)
      if color then
        local first_unit = not (source.group and group_count[source.group])
            or group_count[source.group] == 0
        take(source, color)
        local extra = first_unit and (source.extra or 0) or 0
        extra_needed = extra_needed + extra
        assignment[#assignment + 1] = { source = source, color = color }
        if assign(i + 1) then
          return true
        end
        release(source)
        extra_needed = extra_needed - extra
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
    if available(source) and penalty(source) == 0 then
      local color = (source.group and group_color[source.group]) or source.colors[1]
      take(source, color)
      assignment[#assignment + 1] = { source = source, color = color }
      generic = generic - 1
    end
  end
  if generic > 0 then
    return nil
  end
  return assignment
end

return mana
