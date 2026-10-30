-- Amounts and conditions written in Forge's SVar language.
--   NumDmg$ 3        NumAtt$ +X        SVar:X:Count$Valid Creature.YouCtrl
--   SVar:X:Count$Morbid.1.0           SVar:X:ReplaceCount$DamageAmount/Twice
--   CheckSVar$ RaidTest | SVarCompare$ GE1
-- Reference: forge-game ability/AbilityUtils.calculateAmount, xCount, doXMath; card/CardFactoryUtil
-- (Count$ handlers); util/Expressions.compare.
--
-- expr.compile(text, svars) turns an amount into function(game, ctx) -> number, or returns
-- nil, reason when it uses something not implemented yet (the card is then unsupported).
-- ctx is an ability context (abilities.lua): game, source, controller, targets, trigger, ...

local filter = require("scripts/mtg/filter")

local expr = {}

local COMPARE = {
  LT = function(a, b) return a < b end, LE = function(a, b) return a <= b end,
  EQ = function(a, b) return a == b end, NE = function(a, b) return a ~= b end,
  GE = function(a, b) return a >= b end, GT = function(a, b) return a > b end,
}

-- "GE3" -> function(value) -> bool, or nil.
function expr.compile_compare(text)
  local op, n = (text or "GE1"):match("^(%u%u)(%-?%d+)$")
  if op == nil or COMPARE[op] == nil then
    return nil
  end
  local compare, value = COMPARE[op], tonumber(n)
  return function(x) return compare(x, value) end
end

local function filter_ctx(ctx)
  return { game = ctx.game, you = ctx.controller, self = ctx.source }
end

local ZONE_NAMES = { Graveyard = "graveyard", Hand = "hand", Exile = "exile", Library = "library", Battlefield = "battlefield" }

-- Cards of a zone list matching a filter, for every player.
local function count_valid(game, ctx, zones, parsed, sum_power)
  local n = 0
  for _, player in ipairs(game.players) do
    for _, zone in ipairs(zones) do
      for _, card in ipairs(player[zone]) do
        if filter.matches(parsed, card, filter_ctx(ctx)) then
          n = n + (sum_power and card:power() or 1)
        end
      end
    end
  end
  return n
end

local function card_stat(card, stat)
  if card == nil or card.life ~= nil then
    return 0
  end
  if stat == "CardPower" then
    return card:power()
  elseif stat == "CardToughness" then
    return card:toughness()
  elseif stat == "CardManaCost" then
    return card:mana_value()
  end
end

local CARD_STATS = { CardPower = true, CardToughness = true, CardManaCost = true }

-- Compiles the part before any "/math" suffix. Returns fn or nil, reason.
local function compile_base(text, svars, depth)
  local n = tonumber(text)
  if n then
    return function() return n end
  end
  local kind, rest = text:match("^([%a]+)%$(.*)$")
  if kind == nil then
    -- a bare SVar name (e.g. NumDmg$ X)
    local svar = svars[text]
    if svar and depth < 10 then
      return expr.compile(svar, svars, depth + 1)
    end
    return nil, "amount " .. text
  end

  if kind == "Count" then
    local valid_zone, filter_text = rest:match("^Valid([%a,]*) (.+)$")
    if filter_text then
      local zones = {}
      if valid_zone == "" then
        zones = { "battlefield" }
      else
        for z in valid_zone:gmatch("[^,]+") do
          if ZONE_NAMES[z] == nil then
            return nil, "Count$Valid" .. valid_zone
          end
          zones[#zones + 1] = ZONE_NAMES[z]
        end
      end
      local sum_power = false
      local f, suffix = filter_text:match("^(.-)%$(%a+)$")
      if f then
        if suffix ~= "CardPower" then
          return nil, "Count$Valid ...$" .. suffix
        end
        filter_text, sum_power = f, true
      end
      local parsed, problem = filter.parse(filter_text)
      if parsed == nil then
        return nil, problem
      end
      return function(game, ctx) return count_valid(game, ctx, zones, parsed, sum_power) end
    end
    if CARD_STATS[rest] then
      return function(game, ctx) return card_stat(ctx.source, rest) end
    end
    if rest == "AttackersDeclared" then
      return function(game, ctx) return game.history.attackers[ctx.controller] or 0 end
    elseif rest == "LifeOppsLostThisTurn" then
      return function(game, ctx) return game.history.life_lost[game:opponent(ctx.controller)] or 0 end
    elseif rest == "xPaid" then
      return function(game, ctx) return ctx.x_paid or 0 end
    end
    local a, b = rest:match("^Morbid%.(%-?%d+)%.(%-?%d+)$")
    if a then
      a, b = tonumber(a), tonumber(b)
      return function(game) return game.history.creatures_died > 0 and a or b end
    end
    local entered_filter = rest:match("^ThisTurnEntered_Battlefield_(.+)$")
    if entered_filter then
      local strict_other = false
      if entered_filter:find("+StrictlyOther", 1, true) then
        entered_filter = entered_filter:gsub("%+StrictlyOther", "+Other")
        strict_other = true
      end
      local parsed, problem = filter.parse(entered_filter)
      if parsed == nil then
        return nil, problem
      end
      return function(game, ctx)
        local count = 0
        for _, entry in ipairs(game.history.entered) do
          -- counts creatures that have left again too; "YouCtrl" means controlled as it entered
          if filter.matches(parsed, entry.card, { game = game, you = ctx.controller, self = ctx.source,
                                                  controller = function() return entry.controller end }) then
            count = count + 1
          end
        end
        return count
      end
    end
    local cast_filter = rest:match("^ThisTurnCast_(.+)$")
    if cast_filter then
      local parsed, problem = filter.parse(cast_filter)
      if parsed == nil then
        return nil, problem
      end
      return function(game, ctx)
        local count = 0
        for _, entry in ipairs(game.history.cast) do
          if filter.matches(parsed, entry.card, { game = game, you = ctx.controller, self = ctx.source,
                                                  controller = function() return entry.player end }) then
            count = count + 1
          end
        end
        return count
      end
    end
    return nil, "Count$" .. rest
  elseif kind == "PlayerCountPlayers" then
    if rest == "LowestLifeTotal" or rest == "HighestLifeTotal" then
      local lowest = rest == "LowestLifeTotal"
      return function(game)
        local value
        for _, player in ipairs(game.players) do
          if not player.lost and (value == nil or (lowest and player.life < value) or (not lowest and player.life > value)) then
            value = player.life
          end
        end
        return value or 0
      end
    end
  elseif kind == "TriggerCount" or kind == "ReplaceCount" then
    local key = ({ LifeAmount = "amount", DamageAmount = "amount", Amount = "amount" })[rest]
    if key then
      local field = kind == "TriggerCount" and "trigger" or "replace"
      return function(game, ctx) return ctx[field] and ctx[field][key] or 0 end
    end
  elseif kind == "TriggeredCard" then
    local f = rest:match("^Valid (.+)$")
    if f then
      local parsed, problem = filter.parse(f)
      if parsed == nil then
        return nil, problem
      end
      return function(game, ctx)
        local card = ctx.trigger and ctx.trigger.card
        return (card and filter.matches(parsed, card, filter_ctx(ctx))) and 1 or 0
      end
    end
    if CARD_STATS[rest] then
      return function(game, ctx) return card_stat(ctx.trigger and ctx.trigger.card, rest) end
    end
  elseif kind == "SVar" then
    local svar = svars[rest]
    if svar and depth < 10 then
      return expr.compile(svar, svars, depth + 1)
    end
  elseif kind == "Sacrificed" then
    -- last-known characteristics of what was sacrificed to pay the cost (ctx.sacrificed)
    if CARD_STATS[rest] then
      local key = rest == "CardPower" and "power" or rest == "CardToughness" and "toughness" or "mana_value"
      return function(game, ctx)
        local first = ctx.sacrificed and ctx.sacrificed[1]
        return first and first[key] or 0
      end
    end
  elseif kind == "Targeted" or kind == "ParentTargeted" then
    if CARD_STATS[rest] then
      return function(game, ctx)
        local list = ctx.targeted_for_expr and ctx.targeted_for_expr(kind) or {}
        return card_stat(list[1], rest)
      end
    end
  end
  return nil, kind .. "$" .. rest
end

local MATH = {
  Plus = function(x, n) return x + n end,
  Minus = function(x, n) return x - n end,
  Times = function(x, n) return x * n end,
}

-- Compiles an amount or SVar text. Returns function(game, ctx) -> number, or nil, reason.
function expr.compile(text, svars, depth)
  depth = depth or 0
  if text == nil then
    return nil, "missing amount"
  end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  -- "+3" / "-X": sign applied to the rest
  local sign, unsigned = text:match("^([+-])(.+)$")
  if sign and not tonumber(text) then
    local fn, problem = expr.compile(unsigned, svars, depth + 1)
    if fn == nil then
      return nil, problem
    end
    if sign == "-" then
      return function(game, ctx) return -fn(game, ctx) end
    end
    return fn
  end
  local base_text, math_text = text:match("^([^/]+)/(.+)$")
  if base_text == nil then
    base_text = text
  end
  local base, problem = compile_base(base_text, svars, depth)
  if base == nil then
    return nil, problem
  end
  if math_text == nil then
    return base
  end
  local op, n = math_text:match("^(%a+)%.(%-?%d+)$")
  local svar_op, svar_name = math_text:match("^(%a+)%.(%a[%w]*)$")
  if op and MATH[op] then
    local f, value = MATH[op], tonumber(n)
    return function(game, ctx) return f(base(game, ctx), value) end
  elseif svar_op and MATH[svar_op] and svars[svar_name] then
    local operand, problem2 = expr.compile(svars[svar_name], svars, depth + 1)
    if operand == nil then
      return nil, problem2
    end
    local f = MATH[svar_op]
    return function(game, ctx) return f(base(game, ctx), operand(game, ctx)) end
  elseif math_text == "Twice" then
    return function(game, ctx) return base(game, ctx) * 2 end
  elseif math_text == "HalfDown" then
    return function(game, ctx) return math.floor(base(game, ctx) / 2) end
  elseif math_text == "HalfUp" then
    return function(game, ctx) return math.ceil(base(game, ctx) / 2) end
  elseif math_text == "Negative" then
    return function(game, ctx) return -base(game, ctx) end
  end
  return nil, "amount math /" .. math_text
end

-- A condition: CheckSVar-style (svar_name + compare text) compiled to function(game, ctx) -> bool.
function expr.compile_check(svar_name, compare_text, svars)
  local value, problem = expr.compile(svar_name, svars)
  if value == nil then
    return nil, problem
  end
  local compare = expr.compile_compare(compare_text)
  if compare == nil then
    return nil, "compare " .. tostring(compare_text)
  end
  return function(game, ctx) return compare(value(game, ctx)) end
end

-- IsPresent-style condition: number of battlefield cards matching `filter_text` compared.
function expr.compile_present(filter_text, compare_text)
  local parsed, problem = filter.parse(filter_text)
  if parsed == nil then
    return nil, problem
  end
  local compare = expr.compile_compare(compare_text or "GE1")
  if compare == nil then
    return nil, "compare " .. tostring(compare_text)
  end
  return function(game, ctx) return compare(count_valid(game, ctx, { "battlefield" }, parsed, false)) end
end

return expr
