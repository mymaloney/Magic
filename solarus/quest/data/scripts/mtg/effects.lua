-- Effect implementations, keyed by API name (the SP$/AB$/DB$ value).
-- Reference: forge-game ability/ApiType.java maps each name to ability/effects/<Name>Effect.java.
--
-- Each entry: { params = { allowed parameter = true }, resolve = function(game, ability, ctx),
--               validate = function(ability, reasons) (optional),
--               target_zone = function(params) -> zone (optional, for targets outside the battlefield),
--               harmful = true|false|function(ability) (for the AI: does this hurt what it affects?) }
-- Parameters not listed (beyond the common ones in abilities.lua) make the card unsupported.

local abilities = require("scripts/mtg/abilities")
local filter = require("scripts/mtg/filter")
local keywords = require("scripts/mtg/keywords")

local effects = {}

local function number_param(ability, reasons, key, default)
  local n = abilities.amount(ability.params[key], default)
  if n == nil then
    reasons[#reasons + 1] = ability.api .. " " .. key .. "$ " .. tostring(ability.params[key])
  end
  return n
end

local function require_targets_or_defined(ability, reasons, allowed_default)
  if ability.target == nil and ability.params.Defined == nil and not allowed_default then
    reasons[#reasons + 1] = ability.api .. " without targets or Defined"
  end
end

local function amount(ability, key, default)
  return abilities.amount(ability.params[key], default) or default
end

local function move_all(game, cards, zone, opts)
  game:with_lookback(function()
    for _, card in ipairs(cards) do
      game:move(card, zone, opts)
    end
  end)
end

effects.Draw = {
  params = { NumCards = true },
  validate = function(a, r) number_param(a, r, "NumCards", 1) end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      game:draw(player, amount(a, "NumCards", 1))
    end
  end,
  harmful = false,
}

effects.GainLife = {
  params = { LifeAmount = true },
  validate = function(a, r) number_param(a, r, "LifeAmount", nil) end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      game:gain_life(player, amount(a, "LifeAmount", 0))
    end
  end,
  harmful = false,
}

effects.LoseLife = {
  params = { LifeAmount = true },
  validate = function(a, r)
    number_param(a, r, "LifeAmount", nil)
    require_targets_or_defined(a, r, true)
  end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      game:lose_life(player, amount(a, "LifeAmount", 0))
    end
  end,
  harmful = true,
}

effects.DealDamage = {
  params = { NumDmg = true },
  validate = function(a, r)
    number_param(a, r, "NumDmg", nil)
    require_targets_or_defined(a, r)
  end,
  resolve = function(game, a, ctx)
    local hits = {}
    for _, obj in ipairs(abilities.affected(game, a, ctx)) do
      hits[#hits + 1] = { source = ctx.source, target = obj, amount = amount(a, "NumDmg", 0) }
    end
    game:deal_damage_batch(hits, false)
  end,
  harmful = true,
}

effects.Discard = {
  params = { NumCards = true, Mode = true },
  validate = function(a, r)
    number_param(a, r, "NumCards", 1)
    if a.params.Mode ~= "TgtChoose" and a.params.Mode ~= "Random" then
      r[#r + 1] = "Discard Mode$ " .. tostring(a.params.Mode)
    end
  end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      local count = math.min(amount(a, "NumCards", 1), #player.hand)
      if count > 0 then
        local cards
        if a.params.Mode == "Random" then
          cards = {}
          local pool = {}
          for i, c in ipairs(player.hand) do
            pool[i] = c
          end
          for i = 1, count do
            cards[i] = table.remove(pool, game.rng(#pool))
          end
        else
          cards = player.controller:choose_discard(game, player, count)
        end
        game:discard(player, cards, count)
      end
    end
  end,
  harmful = true,
}

local function destroy(game, cards)
  local doomed = {}
  for _, card in ipairs(cards) do
    if card.zone == "battlefield" and not card:has_keyword("Indestructible") then
      doomed[#doomed + 1] = card
    end
  end
  for _, card in ipairs(doomed) do
    game:emit({ type = "destroy", card = card })
  end
  move_all(game, doomed, "graveyard")
end

effects.Destroy = {
  params = { NoRegen = true },
  validate = function(a, r) require_targets_or_defined(a, r) end,
  resolve = function(game, a, ctx)
    destroy(game, abilities.cards_of(abilities.affected(game, a, ctx)))
  end,
  harmful = true,
}

effects.DestroyAll = {
  params = { ValidCards = true, NoRegen = true },
  validate = function(a, r)
    local parsed, problem = filter.parse(a.params.ValidCards or "")
    a.valid_cards = parsed
    if parsed == nil then
      r[#r + 1] = problem
    end
  end,
  resolve = function(game, a, ctx)
    local cards = {}
    for _, player in ipairs(game.players) do
      for _, card in ipairs(player.battlefield) do
        if filter.matches(a.valid_cards, card, { game = game, you = ctx.controller, self = ctx.source }) then
          cards[#cards + 1] = card
        end
      end
    end
    destroy(game, cards)
  end,
  harmful = true,
}

effects.ChangeZone = {
  params = { Origin = true, Destination = true, LibraryPosition = true },
  target_zone = function(params) return abilities.ZONES[params.Origin] end,
  validate = function(a, r)
    local p = a.params
    if abilities.ZONES[p.Origin or ""] == nil or abilities.ZONES[p.Destination or ""] == nil then
      r[#r + 1] = "ChangeZone " .. tostring(p.Origin) .. " -> " .. tostring(p.Destination)
    end
    if p.Destination == "Library" and p.LibraryPosition ~= "0" and p.LibraryPosition ~= "-1" then
      r[#r + 1] = "ChangeZone LibraryPosition$ " .. tostring(p.LibraryPosition)
    end
    require_targets_or_defined(a, r)
  end,
  resolve = function(game, a, ctx)
    local origin = abilities.ZONES[a.params.Origin]
    local destination = abilities.ZONES[a.params.Destination]
    local cards = {}
    for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx))) do
      if card.zone == origin then
        cards[#cards + 1] = card
      end
    end
    local opts = { controller = ctx.controller }
    if a.params.LibraryPosition == "-1" then
      opts.position = "bottom"
    end
    if destination ~= "battlefield" then
      opts.controller = nil
    end
    move_all(game, cards, destination, opts)
  end,
  harmful = function(a)
    return a.params.Origin == "Battlefield"
  end,
}

local function parse_keywords(a, r)
  local list = {}
  if a.params.KW then
    local supported = keywords.SUPPORTED
    for kw in a.params.KW:gmatch("[^&]+") do
      kw = kw:gsub("^%s+", ""):gsub("%s+$", "")
      if not supported[kw] then
        r[#r + 1] = "granted keyword " .. kw
      end
      list[kw] = true
    end
  end
  a.keywords = list
end

local function pump(card, a)
  card:add_pump(amount(a, "NumAtt", 0), amount(a, "NumDef", 0), a.keywords)
end

local function pump_harmful(a)
  return a.params.IsCurse == "True" or amount(a, "NumAtt", 0) < 0 or amount(a, "NumDef", 0) < 0
end

effects.Pump = {
  params = { NumAtt = true, NumDef = true, KW = true },
  validate = function(a, r)
    number_param(a, r, "NumAtt", 0)
    number_param(a, r, "NumDef", 0)
    parse_keywords(a, r)
  end,
  resolve = function(game, a, ctx)
    for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx, "Self"))) do
      if card.zone == "battlefield" then
        pump(card, a)
        game:emit({ type = "pump", card = card })
      end
    end
  end,
  harmful = pump_harmful,
}

effects.PumpAll = {
  params = { ValidCards = true, NumAtt = true, NumDef = true, KW = true },
  validate = function(a, r)
    number_param(a, r, "NumAtt", 0)
    number_param(a, r, "NumDef", 0)
    parse_keywords(a, r)
    local parsed, problem = filter.parse(a.params.ValidCards or "")
    a.valid_cards = parsed
    if parsed == nil then
      r[#r + 1] = problem
    end
  end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(game.players) do
      for _, card in ipairs(player.battlefield) do
        if filter.matches(a.valid_cards, card, { game = game, you = ctx.controller, self = ctx.source }) then
          pump(card, a)
        end
      end
    end
    game:emit({ type = "pump_all" })
  end,
  harmful = pump_harmful,
}

effects.Tap = {
  params = {},
  validate = function(a, r) require_targets_or_defined(a, r) end,
  resolve = function(game, a, ctx)
    for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx))) do
      game:tap(card)
    end
  end,
  harmful = true,
}

effects.Untap = {
  params = {},
  validate = function(a, r) require_targets_or_defined(a, r) end,
  resolve = function(game, a, ctx)
    for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx))) do
      game:untap(card)
    end
  end,
  harmful = false,
}

effects.Mill = {
  params = { NumCards = true },
  validate = function(a, r) number_param(a, r, "NumCards", 1) end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      local cards = {}
      for i = 1, math.min(amount(a, "NumCards", 1), #player.library) do
        cards[i] = player.library[#player.library - i + 1]
      end
      move_all(game, cards, "graveyard")
    end
  end,
  harmful = true,
}

effects.Counter = {
  params = {},
  validate = function(a, r)
    if a.target == nil or a.target.zone ~= "stack" then
      r[#r + 1] = "Counter without a target spell"
    end
  end,
  resolve = function(game, a, ctx)
    for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx))) do
      if card.zone == "stack" then
        game:emit({ type = "countered", card = card })
        game:move(card, "graveyard")
      end
    end
  end,
  harmful = true,
}

function effects.is_harmful(ability)
  local h = effects[ability.api] and effects[ability.api].harmful
  if type(h) == "function" then
    return h(ability)
  end
  return h == true
end

return effects
