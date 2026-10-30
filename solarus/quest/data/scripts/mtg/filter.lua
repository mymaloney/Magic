-- The "Valid" filter mini-language used by ValidTgts$, ValidCard$, ValidCards$ ...
--   "Creature.OppCtrl+nonLand,Player"  =  (creature AND opponent controls AND not a land) OR player
-- "," separates alternatives, "." starts properties, "+" ANDs properties, "!" or "non" negates.
-- Reference: forge-game card/CardProperty.cardHasProperty, player/PlayerProperty, CardType.
--
-- Only the types and properties listed here are understood; filter.parse reports anything else so
-- card_db can mark the card unsupported instead of guessing.

local filter = {}

local CARD_TYPES = {
  Card = true, Permanent = true, Creature = true, Artifact = true, Enchantment = true, Land = true,
  Instant = true, Sorcery = true, Planeswalker = true, Battle = true,
}
local PLAYER_TYPES = { Player = true, Opponent = true, You = true }

-- Each property: function(ctx, obj) -> bool. ctx = { you = player, self = card, controller = function(card) }.
local CARD_PROPS = {
  Self = function(ctx, c) return c == ctx.self end,
  Other = function(ctx, c) return c ~= ctx.self end,
  YouCtrl = function(ctx, c) return ctx.controller(c) == ctx.you end,
  OppCtrl = function(ctx, c) return ctx.controller(c) ~= ctx.you end,
  YouDontCtrl = function(ctx, c) return ctx.controller(c) ~= ctx.you end,
  YouOwn = function(ctx, c) return c.owner == ctx.you end,
  OppOwn = function(ctx, c) return c.owner ~= ctx.you end,
  token = function() return false end,   -- the engine has no tokens yet
  Token = function() return false end,
  tapped = function(_, c) return c.tapped end,
  untapped = function(_, c) return not c.tapped end,
  attacking = function(ctx, c)
    local combat = ctx.game.combat
    if combat then
      for _, a in ipairs(combat.attackers) do
        if a == c then
          return true
        end
      end
    end
    return false
  end,
  blocking = function(ctx, c)
    local combat = ctx.game.combat
    return combat ~= nil and combat.blocking[c] ~= nil
  end,
}
for t in pairs(CARD_TYPES) do
  if t ~= "Card" and t ~= "Permanent" then
    CARD_PROPS[t] = function(_, c) return c:is_type(t) end   -- used negated: nonLand, nonCreature, ...
  end
end
CARD_PROPS.Land = function(_, c) return c:is_land() end

local COMPARISONS = {
  LT = function(a, b) return a < b end, LE = function(a, b) return a <= b end,
  EQ = function(a, b) return a == b end, GE = function(a, b) return a >= b end,
  GT = function(a, b) return a > b end,
}
local NUMERIC = {
  cmc = function(c) return c:mana_value() end,
  power = function(c) return c:power() end,
  toughness = function(c) return c:toughness() end,
}

local PLAYER_PROPS = {
  You = function(ctx, p) return p == ctx.you end,
  Opponent = function(ctx, p) return p ~= ctx.you end,
}

-- Returns a property test function or nil.
local function parse_property(word, is_player)
  local negate = false
  if word:sub(1, 1) == "!" then
    negate, word = true, word:sub(2)
  elseif word:sub(1, 3) == "non" and #word > 3 then
    negate, word = true, word:sub(4):gsub("^%l", string.upper)
  end
  local test
  if is_player then
    test = PLAYER_PROPS[word]
  else
    test = CARD_PROPS[word]
    if test == nil then
      local stat, cmp, n = word:match("^(%a-)(%u%u)(%d+)$")
      if stat and NUMERIC[stat] and COMPARISONS[cmp] then
        local get, compare, value = NUMERIC[stat], COMPARISONS[cmp], tonumber(n)
        test = function(_, c) return compare(get(c), value) end
      end
    end
  end
  if test == nil then
    return nil
  end
  if negate then
    return function(ctx, obj) return not test(ctx, obj) end
  end
  return test
end

-- "Creature.OppCtrl,Player" -> { { kind = "card"|"player", type =, props = { fn, ... } }, ... }
-- Returns nil, reason when something isn't understood.
function filter.parse(text)
  local alternatives = {}
  for alt in text:gmatch("[^,]+") do
    local type_name, rest = alt:match("^([^.]+)%.?(.*)$")
    local entry
    if type_name == "Any" then
      if rest ~= "" then
        return nil, "filter " .. alt
      end
      alternatives[#alternatives + 1] = { kind = "card", type = "Creature", props = {} }
      alternatives[#alternatives + 1] = { kind = "card", type = "Planeswalker", props = {} }
      alternatives[#alternatives + 1] = { kind = "card", type = "Battle", props = {} }
      entry = { kind = "player", type = "Player", props = {} }
    elseif CARD_TYPES[type_name] then
      entry = { kind = "card", type = type_name, props = {} }
    elseif PLAYER_TYPES[type_name] then
      entry = { kind = "player", type = type_name, props = {} }
    else
      return nil, "filter type " .. tostring(type_name)
    end
    if rest ~= "" then
      for word in rest:gmatch("[^+]+") do
        local test = parse_property(word, entry.kind == "player")
        if test == nil then
          return nil, "filter property " .. word
        end
        table.insert(entry.props, test)
      end
    end
    alternatives[#alternatives + 1] = entry
  end
  if #alternatives == 0 then
    return nil, "empty filter"
  end
  return alternatives
end

local function card_has_type(card, type_name)
  if type_name == "Card" then
    return true
  elseif type_name == "Permanent" then
    return card:is_permanent_card()
  end
  return card:is_type(type_name)
end

local function is_player(obj)
  return obj.life ~= nil
end

-- obj: card or player. ctx = { game =, you = player, self = card, controller = function(card) -> player }
-- (controller defaults to card.controller; trigger checks pass the last-known controller instead).
function filter.matches(parsed, obj, ctx)
  local controller = ctx.controller or function(c) return c.controller end
  local full_ctx = { game = ctx.game, you = ctx.you, self = ctx.self, controller = controller }
  for _, alt in ipairs(parsed) do
    local ok
    if alt.kind == "player" then
      ok = is_player(obj)
          and (alt.type ~= "Opponent" or obj ~= ctx.you)
          and (alt.type ~= "You" or obj == ctx.you)
    else
      ok = not is_player(obj) and card_has_type(obj, alt.type)
    end
    if ok then
      for _, test in ipairs(alt.props) do
        if not test(full_ctx, obj) then
          ok = false
          break
        end
      end
    end
    if ok then
      return true
    end
  end
  return false
end

-- True if the filter can match players (so targeting must offer them).
function filter.includes_players(parsed)
  for _, alt in ipairs(parsed) do
    if alt.kind == "player" then
      return true
    end
  end
  return false
end

return filter
