-- Costs of activated abilities: "Cost$ 1 B T Sac<1/CARDNAME> Discard<2/Card>".
-- Reference: forge-game cost/Cost (parsing), CostPartMana, CostTap, CostSacrifice, CostDiscard,
-- CostPayLife, cost/CostPayment.
--
-- A parsed cost: { mana = mana cost or nil, tap = bool, sacrifice = { { count, self = bool, filter } },
--                  discard = { { count, filter } }, pay_life = n }

local mana = require("scripts/mtg/mana")
local filter = require("scripts/mtg/filter")

local cost = {}

-- Splits on spaces, keeping "<...>" groups (which may contain spaces) together.
local function tokens(text)
  local list, current, depth = {}, "", 0
  for ch in text:gmatch(".") do
    if ch == "<" then
      depth = depth + 1
    elseif ch == ">" then
      depth = depth - 1
    end
    if ch == " " and depth == 0 then
      if current ~= "" then
        list[#list + 1] = current
      end
      current = ""
    else
      current = current .. ch
    end
  end
  if current ~= "" then
    list[#list + 1] = current
  end
  return list
end

-- "1/Artifact;Creature/artifact or creature" -> count, self, parsed filter
local function parse_card_part(body)
  local count, what = body:match("^(%d+)/([^/]+)")
  if count == nil then
    return nil, "cost part <" .. body .. ">"
  end
  if what == "CARDNAME" then
    return tonumber(count), true, nil
  end
  local parsed, problem = filter.parse((what:gsub(";", ",")))
  if parsed == nil then
    return nil, problem
  end
  return tonumber(count), false, parsed
end

-- Returns a parsed cost, or nil and a reason.
function cost.parse(text)
  local result = { tap = false, sacrifice = {}, discard = {}, pay_life = 0 }
  local mana_tokens = {}
  for _, token in ipairs(tokens(text or "")) do
    local kind, body = token:match("^(%a+)<(.+)>$")
    if token == "T" then
      result.tap = true
    elseif kind == "Sac" then
      local count, self, parsed = parse_card_part(body)
      if count == nil then
        return nil, self
      end
      table.insert(result.sacrifice, { count = count, self = self, filter = parsed })
    elseif kind == "Discard" then
      local count, self, parsed = parse_card_part(body)
      if count == nil or self then
        return nil, "cost Discard<" .. body .. ">"
      end
      table.insert(result.discard, { count = count, filter = parsed })
    elseif kind == "PayLife" and tonumber(body) then
      result.pay_life = result.pay_life + tonumber(body)
    elseif kind then
      return nil, "cost " .. kind
    else
      mana_tokens[#mana_tokens + 1] = token
    end
  end
  if #mana_tokens > 0 then
    local parsed, problem = mana.parse_cost(table.concat(mana_tokens, " "))
    if parsed == nil then
      return nil, problem or "mana cost"
    end
    result.mana = parsed
  end
  return result
end

local function fctx(game, player, source)
  return { game = game, you = player, self = source }
end

-- Permanents `player` could sacrifice for one sacrifice part.
local function sacrifice_candidates(game, player, source, part)
  if part.self then
    return source.zone == "battlefield" and { source } or {}
  end
  local list = {}
  for _, card in ipairs(player.battlefield) do
    if filter.matches(part.filter, card, fctx(game, player, source)) then
      list[#list + 1] = card
    end
  end
  return list
end

local function discard_candidates(game, player, source, part)
  local list = {}
  for _, card in ipairs(player.hand) do
    if card ~= source and filter.matches(part.filter, card, fctx(game, player, source)) then
      list[#list + 1] = card
    end
  end
  return list
end

local TAP_FOR_COST = { tap = true }

-- Mana sources usable for this cost: the source itself can't tap for mana if the cost taps or
-- sacrifices it.
local function usable_sources(game, player, source, c)
  local uses_self = c.tap
  for _, part in ipairs(c.sacrifice) do
    uses_self = uses_self or part.self
  end
  local list = {}
  for _, s in ipairs(game:mana_sources(player)) do
    if not (uses_self and s.card == source) then
      list[#list + 1] = s
    end
  end
  if c.tap_creatures_for_mana then
    -- "For each mana in this ability's activation cost, you may tap an untapped creature you
    -- control rather than pay that mana" (generic only here; used after real mana sources)
    for _, card in ipairs(player.battlefield) do
      if card ~= source and card:is_creature() and not card.tapped then
        list[#list + 1] = { card = card, colors = { "C" }, ability = TAP_FOR_COST, key = "tap_for_cost", late = true }
      end
    end
  end
  return list
end

-- Creatures that could crew `source` (CR 702.122: untapped, summoning sickness doesn't matter).
local function crew_candidates(player, source)
  local list = {}
  for _, card in ipairs(player.battlefield) do
    if card ~= source and card:is_creature() and not card.tapped then
      list[#list + 1] = card
    end
  end
  return list
end

function cost.can_pay(game, player, source, c)
  if c.crew then
    local total = 0
    for _, card in ipairs(crew_candidates(player, source)) do
      total = total + math.max(0, card:power())
    end
    if total < c.crew then
      return false
    end
  end
  if c.tap then
    if source.zone ~= "battlefield" or source.tapped
        or (source:is_creature() and source.sick and not source:has_keyword("Haste")) then
      return false
    end
  end
  for _, part in ipairs(c.sacrifice) do
    if #sacrifice_candidates(game, player, source, part) < part.count then
      return false
    end
  end
  for _, part in ipairs(c.discard) do
    if #discard_candidates(game, player, source, part) < part.count then
      return false
    end
  end
  if c.pay_life > 0 and player.life < c.pay_life then
    return false
  end
  if c.mana and mana.find_payment(c.mana, usable_sources(game, player, source, c)) == nil then
    return false
  end
  return true
end

-- Pays the cost (CR 601.2h). Choices go to the controller via choose_cards.
-- Returns { sacrificed = { { card, power, toughness, mana_value } } } (last-known values).
function cost.pay(game, player, source, c)
  local paid = { sacrificed = {} }
  if c.mana and not game:pay(player, c.mana, usable_sources(game, player, source, c)) then
    error("couldn't pay mana for " .. tostring(source))
  end
  if c.tap then
    game:tap(source)
  end
  if c.crew then
    local chosen = player.controller:choose_cards(game, player, crew_candidates(player, source), 1,
                                                  #crew_candidates(player, source), "crew", c.crew) or {}
    local total = 0
    for _, card in ipairs(chosen) do
      total = total + math.max(0, card:power())
    end
    if total < c.crew then
      error("crew needs total power " .. c.crew)
    end
    for _, card in ipairs(chosen) do
      game:tap(card)
    end
  end
  for _, part in ipairs(c.sacrifice) do
    local candidates = sacrifice_candidates(game, player, source, part)
    local chosen = candidates
    if not part.self then
      chosen = player.controller:choose_cards(game, player, candidates, part.count, part.count, "sacrifice") or {}
    end
    if #chosen ~= part.count then
      error("must sacrifice " .. part.count)
    end
    for _, card in ipairs(chosen) do
      table.insert(paid.sacrificed, { card = card, power = card:power(), toughness = card:toughness(),
                                      mana_value = card:mana_value() })
    end
    game:sacrifice(chosen)
  end
  for _, part in ipairs(c.discard) do
    local candidates = discard_candidates(game, player, source, part)
    local chosen = player.controller:choose_cards(game, player, candidates, part.count, part.count, "discard") or {}
    game:discard(player, chosen, part.count)
  end
  if c.pay_life > 0 then
    game:lose_life(player, c.pay_life)
  end
  return paid
end

-- Mana ability costs the auto-payer understands: {T}, {N} (a filter: "pay N more"), sacrificing
-- the source. Returns { tap, extra, sacrifice } or nil.
function cost.mana_ability_cost(c)
  if c.pay_life > 0 or #c.discard > 0 or #c.sacrifice > 1 then
    return nil
  end
  if #c.sacrifice == 1 and not (c.sacrifice[1].self and c.sacrifice[1].count == 1) then
    return nil
  end
  local extra = 0
  if c.mana then
    if #c.mana.shards > 0 then
      return nil
    end
    extra = c.mana.generic
  end
  return { tap = c.tap, extra = extra, sacrifice = #c.sacrifice == 1 }
end

return cost
