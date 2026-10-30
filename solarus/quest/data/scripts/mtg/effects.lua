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

-- Required amount parameters must be present (their syntax is checked by abilities.build).
local function number_param(ability, reasons, key, default)
  if default == nil and ability.params[key] == nil then
    reasons[#reasons + 1] = ability.api .. " without " .. key
  end
end

local function require_targets_or_defined(ability, reasons, allowed_default)
  if ability.target == nil and ability.params.Defined == nil and not allowed_default then
    reasons[#reasons + 1] = ability.api .. " without targets or Defined"
  end
end

local CTX  -- context of the effect being resolved (set by resolve wrappers below)

local function amount(ability, key, default)
  return abilities.value(ability, key, CTX, default)
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
  params = { NumDmg = true, DamageSource = true, DamageMap = true, ReplaceDyingDefined = true },
  validate = function(a, r)
    number_param(a, r, "NumDmg", nil)
    require_targets_or_defined(a, r)
    local d = a.params.DamageSource
    if d and not abilities.DEFINED_CARDS[d] then
      r[#r + 1] = "DamageSource$ " .. d
    end
    if a.params.ReplaceDyingDefined and a.params.ReplaceDyingDefined ~= "Targeted" then
      r[#r + 1] = "ReplaceDyingDefined$ " .. a.params.ReplaceDyingDefined
    end
  end,
  resolve = function(game, a, ctx)
    local source = ctx.source
    if a.params.DamageSource then
      source = abilities.cards_of(abilities.defined(game, a, ctx, a.params.DamageSource))[1]
      if source == nil or source.zone ~= "battlefield" then
        return
      end
    end
    local hits = {}
    for _, obj in ipairs(abilities.affected(game, a, ctx)) do
      hits[#hits + 1] = { source = source, target = obj, amount = amount(a, "NumDmg", 0) }
      if a.params.ReplaceDyingDefined and obj.life == nil then
        obj.exile_if_dies_turn = game.turn   -- "if it would die this turn, exile it instead"
      end
    end
    game:deal_damage_batch(hits, false)
  end,
  harmful = true,
}

effects.DamageResolve = {   -- Forge batches damage with DamageMap; ours is dealt as each part resolves
  params = {},
  resolve = function() end,
  harmful = false,
}

effects.Discard = {
  params = { NumCards = true, Mode = true, DiscardValid = true, DiscardValidDesc = true, RememberDiscarded = true },
  validate = function(a, r)
    number_param(a, r, "NumCards", 1)
    local mode = a.params.Mode
    if mode ~= "TgtChoose" and mode ~= "Random" and mode ~= "RevealYouChoose" then
      r[#r + 1] = "Discard Mode$ " .. tostring(mode)
    end
    if a.params.DiscardValid then
      local parsed, problem = filter.parse(a.params.DiscardValid)
      a.discard_valid = parsed
      if parsed == nil then
        r[#r + 1] = problem
      end
    end
  end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      local count = math.min(amount(a, "NumCards", 1), #player.hand)
      if count > 0 then
        local cards
        if a.params.Mode == "RevealYouChoose" then
          -- the player reveals their hand and the ability's controller chooses (Pilfer)
          local valid = {}
          for _, c in ipairs(player.hand) do
            if a.discard_valid == nil or filter.matches(a.discard_valid, c, abilities.filter_ctx(ctx)) then
              valid[#valid + 1] = c
            end
          end
          count = math.min(count, #valid)
          cards = count > 0 and ctx.controller.controller:choose_cards(game, ctx.controller, valid, count, count, "discard_other") or {}
          game:emit({ type = "reveal_hand", player = player })
        elseif a.params.Mode == "Random" then
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
        game:discard(player, cards, count, ctx.controller)
        if a.params.RememberDiscarded == "True" then
          ctx.remembered = ctx.remembered or {}
          for _, c in ipairs(cards) do
            table.insert(ctx.remembered, c)
          end
        end
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
        if filter.matches(a.valid_cards, card, abilities.filter_ctx(ctx)) then
          cards[#cards + 1] = card
        end
      end
    end
    destroy(game, cards)
  end,
  harmful = true,
}

effects.ChangeZone = {
  params = { Origin = true, Destination = true, LibraryPosition = true, Duration = true, ChangeType = true,
             ChangeNum = true, Optional = true, Hidden = true, Mandatory = true, Tapped = true,
             ChangeTypeDesc = true, SelectPrompt = true, GainControl = true, RememberChanged = true,
             Chooser = true, DefinedPlayer = true, DestinationAlternative = true,
             LibraryPositionAlternative = true, AlternativeDecider = true, StaticEffect = true },
  target_zone = function(params) return abilities.ZONES[params.Origin] end,
  validate = function(a, r)
    local p = a.params
    if abilities.ZONES[p.Origin or ""] == nil or abilities.ZONES[p.Destination or ""] == nil then
      r[#r + 1] = "ChangeZone " .. tostring(p.Origin) .. " -> " .. tostring(p.Destination)
    end
    if p.Duration and (p.Duration ~= "UntilHostLeavesPlay" or p.Destination ~= "Exile") then
      r[#r + 1] = "ChangeZone Duration$ " .. p.Duration
    end
    if p.DestinationAlternative then
      -- "its owner puts it on the top or bottom of their library" (Uncharted Voyage)
      if p.Destination ~= "Library" or p.DestinationAlternative ~= "Library" or p.LibraryPositionAlternative ~= "-1"
          or p.AlternativeDecider ~= "TargetedOwner" then
        r[#r + 1] = "ChangeZone DestinationAlternative"
      end
    elseif p.Destination == "Library" and p.LibraryPosition ~= "0" and p.LibraryPosition ~= "-1" then
      r[#r + 1] = "ChangeZone LibraryPosition$ " .. tostring(p.LibraryPosition)
    end
    if p.GainControl and p.GainControl ~= "True" then
      r[#r + 1] = "ChangeZone GainControl$ " .. p.GainControl
    end
    if p.StaticEffect then
      -- a lasting effect on the moved card, e.g. "That creature is a black Zombie" (Rise from the Grave)
      local text = a.svars[p.StaticEffect]
      if text == nil or p.Destination ~= "Battlefield" then
        r[#r + 1] = "ChangeZone StaticEffect$ " .. p.StaticEffect
      else
        local st = require("scripts/mtg/statics").parse(require("scripts/mtg/script_parser").parse_params(text),
                                                         a.svars, r, keywords.SUPPORTED)
        a.static_effect = st
      end
    end
    if (p.Chooser or p.DefinedPlayer) and (p.Chooser ~= "Targeted" or p.DefinedPlayer ~= "Targeted") then
      r[#r + 1] = "ChangeZone Chooser$ " .. tostring(p.Chooser)
    end
    if p.ChangeType then
      -- choose (or search for) cards in the origin zone rather than targeting them
      local parsed, problem = filter.parse(p.ChangeType)
      a.change_type = parsed
      if parsed == nil then
        r[#r + 1] = problem
      end
      if (a.target and not p.DefinedPlayer) or p.Defined then
        r[#r + 1] = "ChangeZone with ChangeType and targets"
      end
      if p.Optional and p.Optional ~= "You" and p.Optional ~= "True" then
        r[#r + 1] = "ChangeZone Optional$ " .. p.Optional
      end
    end
  end,
  resolve = function(game, a, ctx)
    local origin = abilities.ZONES[a.params.Origin]
    local destination = abilities.ZONES[a.params.Destination]
    local cards = {}
    if a.change_type then
      -- CR 701.19: choosing from a hidden zone may fail to find; from the hand only if optional.
      local player = ctx.controller
      local zones_of = { player }
      if a.params.DefinedPlayer == "Targeted" then
        -- the targeted player chooses from their own zone (Ruthless Negotiation)
        player = abilities.players_of(ctx.targets[a] or {})[1]
        if player == nil then
          return
        end
        zones_of = { player }
      elseif a.params.GainControl == "True" and origin == "graveyard" then
        zones_of = game.players   -- "a creature card from a graveyard"
      end
      local candidates = {}
      for _, owner in ipairs(zones_of) do
        for _, card in ipairs(owner[origin]) do
          if filter.matches(a.change_type, card, { game = game, you = ctx.controller, self = ctx.source,
                                                   remembered = ctx.remembered }) then
            candidates[#candidates + 1] = card
          end
        end
      end
      local n = math.min(amount(a, "ChangeNum", 1), #candidates)
      local optional = a.params.Optional ~= nil or (origin == "library" and a.params.Mandatory ~= "True")
      if n > 0 then
        -- a player choosing what they lose (Ruthless Negotiation) picks differently from one searching
        local reason = a.params.DefinedPlayer and "lose" or "search"
        cards = player.controller:choose_cards(game, player, candidates, optional and 0 or n, n, reason) or {}
      end
      if origin == "library" then
        game:shuffle(player)
      end
    elseif a.target == nil and a.params.Defined == nil then
      cards = { ctx.source }   -- e.g. "Return this card from your graveyard to the battlefield"
    else
      cards = abilities.cards_of(abilities.affected(game, a, ctx))
    end
    local in_origin = {}
    for _, card in ipairs(cards) do
      if card.zone == origin then
        in_origin[#in_origin + 1] = card
      end
    end
    cards = in_origin
    local opts = { controller = ctx.controller, tapped = a.params.Tapped == "True" }
    if a.params.LibraryPosition == "-1" then
      opts.position = "bottom"
    end
    if a.params.DestinationAlternative and cards[1] then
      local owner = cards[1].owner
      local choice = owner.controller:choose_option(game, owner, ctx.source, { "Top of library", "Bottom of library" })
      if choice == 2 then
        opts.position = "bottom"
      end
    end
    if a.params.RememberChanged == "True" then
      ctx.remembered = ctx.remembered or {}
      for _, card in ipairs(cards) do
        table.insert(ctx.remembered, card)
      end
    end
    if destination ~= "battlefield" then
      opts.controller = nil
    end
    if a.params.Duration == "UntilHostLeavesPlay" then
      -- CR 610.3: exiled until the source leaves; if it already left, nothing is exiled.
      local host = ctx.source
      if host.zone ~= "battlefield" then
        return
      end
      host.linked_exiles = host.linked_exiles or {}
      for _, card in ipairs(cards) do
        table.insert(host.linked_exiles, card)
      end
    end
    move_all(game, cards, destination, opts)
    if a.static_effect then
      local moved = {}
      for _, card in ipairs(cards) do
        if card.zone == "battlefield" then
          moved[#moved + 1] = card
        end
      end
      if #moved > 0 then
        game:add_effect({ name = ctx.source:name() .. "'s Effect", source = ctx.source, controller = ctx.controller,
                          def = { statics = { a.static_effect } }, remembered = moved,
                          exile_on_moved = "battlefield", permanent = true })
      end
    end
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
  local power = a.params.NumAtt == "Double" and card:power() or amount(a, "NumAtt", 0)  -- "double its power"
  card:add_pump(power, amount(a, "NumDef", 0), a.keywords)
end

local function pump_harmful(a)
  local att, def = a.params.NumAtt or "", a.params.NumDef or ""
  return a.params.IsCurse == "True" or att:sub(1, 1) == "-" or def:sub(1, 1) == "-"
end

local DOESNT_UNTAP = "HIDDEN This card doesn't untap during your next untap step."

local function validate_duration(a, r)
  if a.params.Duration and not (a.params.Duration == "Permanent" and a.keywords[DOESNT_UNTAP]) then
    r[#r + 1] = a.api .. " Duration$ " .. a.params.Duration
  end
  if a.params.AtEOT and a.params.AtEOT ~= "Sacrifice" then
    r[#r + 1] = a.api .. " AtEOT$ " .. a.params.AtEOT
  end
end

local SAC_SELF   -- "sacrifice it" for AtEOT$ Sacrifice, built on first use
local function sacrifice_at_end_step(game, card, controller)
  if SAC_SELF == nil then
    SAC_SELF = abilities.build({ DB = "Sacrifice", SacValid = "Self" }, {}, {}, effects)
  end
  table.insert(game.at_end_step, { source = card, controller = controller,
                                   trigger = { ability = SAC_SELF }, event = {} })
end

-- Applies a pump to one card; the "doesn't untap" keyword becomes a flag instead (Duration$ Permanent).
local function apply_pump(game, card, a, ctx)
  if a.keywords[DOESNT_UNTAP] then
    card.skip_next_untap = true
  end
  pump(card, a)
  if a.params.AtEOT == "Sacrifice" then
    sacrifice_at_end_step(game, card, ctx.controller)
  end
end

effects.Pump = {
  params = { NumAtt = true, NumDef = true, KW = true, Duration = true, AtEOT = true, PumpZone = true },
  validate = function(a, r)
    number_param(a, r, "NumAtt", 0)
    number_param(a, r, "NumDef", 0)
    if a.params.PumpZone then
      -- "target card in your graveyard gains flashback until end of turn"
      if a.params.PumpZone ~= "Graveyard" or a.params.KW ~= "Flashback" or a.params.NumAtt or a.params.NumDef then
        r[#r + 1] = "Pump PumpZone$ " .. a.params.PumpZone
      end
      a.keywords = {}
    else
      parse_keywords(a, r)
    end
    validate_duration(a, r)
  end,
  resolve = function(game, a, ctx)
    if a.params.PumpZone == "Graveyard" then
      for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx))) do
        if card.zone == "graveyard" then
          card.granted_flashback_turn = game.turn
          game:emit({ type = "grant_flashback", card = card })
        end
      end
      return
    end
    for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx, "Self"))) do
      if card.zone == "battlefield" then
        apply_pump(game, card, a, ctx)
        game:emit({ type = "pump", card = card })
      end
    end
  end,
  harmful = pump_harmful,
}

effects.PumpAll = {
  params = { ValidCards = true, NumAtt = true, NumDef = true, KW = true, Duration = true },
  validate = function(a, r)
    number_param(a, r, "NumAtt", 0)
    number_param(a, r, "NumDef", 0)
    parse_keywords(a, r)
    validate_duration(a, r)
    local parsed, problem = filter.parse(a.params.ValidCards or "")
    a.valid_cards = parsed
    if parsed == nil then
      r[#r + 1] = problem
    end
  end,
  resolve = function(game, a, ctx)
    -- Defined$ Targeted on a PumpAll limits it to the targeted player's permanents (Sleep).
    local players = a.params.Defined and abilities.players_of(abilities.defined(game, a, ctx, a.params.Defined)) or game.players
    for _, player in ipairs(players) do
      for _, card in ipairs(player.battlefield) do
        if filter.matches(a.valid_cards, card, abilities.filter_ctx(ctx)) then
          apply_pump(game, card, a, ctx)
        end
      end
    end
    game:emit({ type = "pump_all" })
  end,
  harmful = pump_harmful,
}

effects.Tap = {
  params = { ETB = true },
  validate = function(a, r) require_targets_or_defined(a, r) end,
  resolve = function(game, a, ctx)
    for _, card in ipairs(abilities.cards_of(abilities.affected(game, a, ctx))) do
      if a.params.ETB == "True" and ctx.etb then
        card.tapped = true   -- enters tapped: not "becoming tapped", so no Taps trigger
      else
        game:tap(card)
      end
    end
  end,
  harmful = true,
}

-- Attach: an Aura spell resolving (it enters attached to its target) or Equip.
effects.Attach = {
  params = {},
  validate = function(a, r)
    if a.target == nil then
      r[#r + 1] = "Attach without a target"
    end
  end,
  resolve = function(game, a, ctx)
    local target = (ctx.targets[a] or {})[1]
    local attachment = ctx.source
    if target == nil then
      return
    end
    if attachment.zone == "stack" then
      game:move(attachment, "battlefield", { controller = ctx.controller, attach_to = target })
    elseif attachment.zone == "battlefield" then
      game:attach(attachment, target)
    end
  end,
  harmful = function(a) return a.harmful_attach == true end,
}

local COLOR_WORDS = { white = "W", blue = "U", black = "B", red = "R", green = "G" }

effects.ChooseColor = {
  params = { Exclude = true },
  validate = function(a, r)
    if a.params.Exclude and COLOR_WORDS[a.params.Exclude] == nil then
      r[#r + 1] = "ChooseColor Exclude$ " .. a.params.Exclude
    end
  end,
  resolve = function(game, a, ctx)
    local options = {}
    for _, c in ipairs({ "W", "U", "B", "R", "G" }) do
      if COLOR_WORDS[a.params.Exclude or ""] ~= c then
        options[#options + 1] = c
      end
    end
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      local color = player.controller:choose_color(game, player, ctx.source, options)
      if not color then
        error("no color chosen")
      end
      ctx.source.chosen_color = color
      game:emit({ type = "color_chosen", card = ctx.source, player = player, color = color })
    end
  end,
  harmful = false,
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

local script_parser = require("scripts/mtg/script_parser")
local expr = require("scripts/mtg/expr")

local function sub_chain(a, r, name)
  local text = name and a.svars[name]
  if text == nil then
    r[#r + 1] = a.api .. " sub-ability " .. tostring(name)
    return nil
  end
  return abilities.build(script_parser.parse_params(text), a.svars, r, effects, a)
end

local function chain_has_targets(root)
  for _, x in ipairs(abilities.chain(root)) do
    if x.target or x.choices then
      return true
    end
  end
  return false
end

-- Look at the top `n` cards of a library and split them between the top and `away`
-- ("bottom" for scry, "graveyard" for surveil); the controller chooses (arrange_top).
local function look_and_arrange(game, player, n, away)
  local cards = {}
  for i = 1, math.min(n, #player.library) do
    cards[i] = player.library[#player.library - i + 1]   -- cards[1] is the top card
  end
  if #cards == 0 then
    return
  end
  local answer = player.controller:arrange_top(game, player, cards, away) or { top = cards, away = {} }
  local seen = {}
  for _, list in ipairs({ answer.top or {}, answer.away or {} }) do
    for _, c in ipairs(list) do
      if seen[c] then
        error("card arranged twice")
      end
      seen[c] = true
    end
  end
  for _, c in ipairs(cards) do
    if not seen[c] then
      error("every looked-at card must be placed")
    end
  end
  -- remove the looked-at cards, then put them back: top list in order (first = new top card)
  for _ = 1, #cards do
    table.remove(player.library)
  end
  for i = #(answer.top or {}), 1, -1 do
    table.insert(player.library, answer.top[i])
  end
  for _, c in ipairs(answer.away or {}) do
    if away == "bottom" then
      table.insert(player.library, 1, c)
    else
      c.zone = "library"
      table.insert(player.library, c)       -- move() takes it from the top
      game:move(c, "graveyard")
    end
  end
  game:emit({ type = away == "bottom" and "scry" or "surveil", player = player, count = #cards,
              away = #(answer.away or {}) })
end

effects.Scry = {
  params = { ScryNum = true },
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      look_and_arrange(game, player, amount(a, "ScryNum", 1), "bottom")
    end
  end,
  harmful = false,
}

effects.Surveil = {
  params = { Amount = true },
  resolve = function(game, a, ctx)
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      look_and_arrange(game, player, amount(a, "Amount", 1), "graveyard")
    end
  end,
  harmful = false,
}

-- Dig: look at the top DigNum cards, put up to ChangeNum matching ChangeValid into DestinationZone
-- (default hand), the rest into DestinationZone2 (default the bottom of the library).
effects.Dig = {
  params = { DigNum = true, ChangeNum = true, ChangeValid = true, DestinationZone = true,
             DestinationZone2 = true, LibraryPosition = true, Optional = true, Reveal = true },
  validate = function(a, r)
    local parsed, problem = filter.parse(a.params.ChangeValid or "Card")
    a.change_valid = parsed
    if parsed == nil then
      r[#r + 1] = problem
    end
    local z1, z2 = a.params.DestinationZone or "Hand", a.params.DestinationZone2 or "Library"
    if not (z1 == "Hand" or (z1 == "Library" and a.params.LibraryPosition == "0")) then
      r[#r + 1] = "Dig DestinationZone$ " .. z1
    end
    if z2 ~= "Graveyard" and z2 ~= "Library" then
      r[#r + 1] = "Dig DestinationZone2$ " .. z2
    end
  end,
  resolve = function(game, a, ctx)
    local player = ctx.controller
    local n = amount(a, "DigNum", 1)
    local cards = {}
    for i = 1, math.min(n, #player.library) do
      cards[i] = player.library[#player.library - i + 1]
    end
    local valid = {}
    for _, c in ipairs(cards) do
      if filter.matches(a.change_valid, c, { game = game, you = player, self = ctx.source }) then
        valid[#valid + 1] = c
      end
    end
    local count = math.min(amount(a, "ChangeNum", 1), #valid)
    local min = a.params.Optional == "True" and 0 or count
    local chosen = count > 0 and player.controller:choose_cards(game, player, valid, min, count, "dig") or {}
    local picked = {}
    for _, c in ipairs(chosen) do
      picked[c] = true
    end
    local to_top = (a.params.DestinationZone == "Library")
    local rest_zone = (a.params.DestinationZone2 or "Library") == "Graveyard" and "graveyard" or "bottom"
    for _ = 1, #cards do
      table.remove(player.library)
    end
    local kept_on_top = {}
    for _, c in ipairs(cards) do
      if picked[c] then
        if to_top then
          kept_on_top[#kept_on_top + 1] = c
        else
          c.zone = "library"
          table.insert(player.library, c)
          game:move(c, "hand")
        end
      elseif rest_zone == "bottom" then
        table.insert(player.library, 1, c)
      else
        c.zone = "library"
        table.insert(player.library, c)
        game:move(c, "graveyard")
      end
    end
    for i = #kept_on_top, 1, -1 do
      table.insert(player.library, kept_on_top[i])
    end
    game:emit({ type = "dig", player = player, count = #cards })
  end,
  harmful = false,
}

effects.Sacrifice = {
  params = { SacValid = true, Amount = true, RememberSacrificed = true },
  validate = function(a, r)
    if a.params.SacValid ~= "Self" then
      local parsed, problem = filter.parse(a.params.SacValid or "")
      a.sac_valid = parsed
      if parsed == nil then
        r[#r + 1] = problem
      end
    end
  end,
  resolve = function(game, a, ctx)
    if a.params.SacValid == "Self" then
      game:sacrifice({ ctx.source })
      return
    end
    for _, player in ipairs(abilities.players_of(abilities.affected(game, a, ctx, "You"))) do
      local candidates = {}
      for _, c in ipairs(player.battlefield) do
        if filter.matches(a.sac_valid, c, { game = game, you = player, self = ctx.source }) then
          candidates[#candidates + 1] = c
        end
      end
      local n = math.min(amount(a, "Amount", 1), #candidates)
      if n > 0 then
        local chosen = player.controller:choose_cards(game, player, candidates, n, n, "sacrifice")
        if a.params.RememberSacrificed == "True" then
          ctx.remembered = ctx.remembered or {}
          ctx.remembered_lki = ctx.remembered_lki or {}
          for _, c in ipairs(chosen) do
            table.insert(ctx.remembered, c)
            ctx.remembered_lki[c] = { power = c:power(), toughness = c:toughness(), mana_value = c:mana_value() }
          end
        end
        game:sacrifice(chosen)
      end
    end
  end,
  harmful = function(a) return a.params.SacValid ~= "Self" end,
}

-- Fight (CR 701.12): the Defined creature and the target each deal damage equal to their power to
-- the other; nothing happens if either has left the battlefield.
effects.Fight = {
  params = {},
  validate = function(a, r)
    local d = a.params.Defined
    if d ~= "ParentTarget" and d ~= "TriggeredCardLKICopy" and d ~= "TriggeredCard" and d ~= "Self" and d ~= "Enchanted" then
      r[#r + 1] = "Fight Defined$ " .. tostring(d)
    end
    if a.target == nil then
      r[#r + 1] = "Fight without a target"
    end
  end,
  resolve = function(game, a, ctx)
    local fighter = abilities.cards_of(abilities.defined(game, a, ctx, a.params.Defined))[1]
    local other = abilities.cards_of(ctx.targets[a] or {})[1]
    if fighter and other and fighter.zone == "battlefield" and other.zone == "battlefield" and fighter ~= other then
      game:deal_damage_batch({
        { source = fighter, target = other, amount = fighter:power() },
        { source = other, target = fighter, amount = other:power() },
      }, false)
    end
  end,
  harmful = true,
}

effects.Charm = {
  params = { Choices = true, CharmNum = true },
  validate = function(a, r)
    if a.params.CharmNum and a.params.CharmNum ~= "1" then
      r[#r + 1] = "Charm CharmNum$ " .. a.params.CharmNum
    end
    a.choices = {}
    for name in (a.params.Choices or ""):gmatch("[^,]+") do
      a.choices[#a.choices + 1] = sub_chain(a, r, name)
    end
    if #a.choices == 0 then
      r[#r + 1] = "Charm without choices"
    end
  end,
  resolve = function() end,   -- the chosen mode's chain follows it (abilities.chain with ctx.modes)
  harmful = false,
}

effects.Branch = {
  params = { BranchConditionSVar = true, BranchConditionSVarCompare = true, TrueSubAbility = true, FalseSubAbility = true },
  validate = function(a, r)
    local check, problem = expr.compile_check(a.params.BranchConditionSVar or "", a.params.BranchConditionSVarCompare, a.svars)
    if check == nil then
      r[#r + 1] = "Branch condition " .. tostring(problem)
    end
    a.branch_check = check
    a.branch_true = a.params.TrueSubAbility and sub_chain(a, r, a.params.TrueSubAbility)
    a.branch_false = a.params.FalseSubAbility and sub_chain(a, r, a.params.FalseSubAbility)
    for _, b in ipairs({ a.branch_true or false, a.branch_false or false }) do
      if b and chain_has_targets(b) then
        r[#r + 1] = "Branch with targets"
      end
    end
  end,
  resolve = function(game, a, ctx)
    local path = a.branch_check(game, ctx) and a.branch_true or a.branch_false
    if path then
      abilities.run_chain(game, path, ctx, effects)
    end
  end,
  harmful = false,
}

effects.Cleanup = {   -- forgets the objects remembered so far (ctx.remembered)
  params = { ClearRemembered = true },
  resolve = function(game, a, ctx)
    ctx.remembered = {}
    ctx.remembered_lki = {}
  end,
  harmful = false,
}

effects.UntapAll = {
  params = { ValidCards = true },
  validate = function(a, r)
    local parsed, problem = filter.parse(a.params.ValidCards or "Card")
    a.valid_cards = parsed
    if parsed == nil then
      r[#r + 1] = problem
    end
  end,
  resolve = function(game, a, ctx)
    for _, player in ipairs(game.players) do
      for _, card in ipairs(player.battlefield) do
        if filter.matches(a.valid_cards, card, abilities.filter_ctx(ctx)) then
          game:untap(card)
        end
      end
    end
  end,
  harmful = false,
}

local function all_matching(game, ctx, parsed, players)
  local list = {}
  for _, player in ipairs(players or game.players) do
    for _, card in ipairs(player.battlefield) do
      if filter.matches(parsed, card, abilities.filter_ctx(ctx)) then
        list[#list + 1] = card
      end
    end
  end
  return list
end

local function parse_valid(a, r, key, default)
  if a.params[key] == nil and default == nil then
    return nil
  end
  local parsed, problem = filter.parse(a.params[key] or default)
  if parsed == nil then
    r[#r + 1] = problem
  end
  return parsed
end

effects.ChangeZoneAll = {
  params = { ChangeType = true, Origin = true, Destination = true },
  validate = function(a, r)
    a.change_type = parse_valid(a, r, "ChangeType", "Card")
    local ok = (a.params.Origin == "Battlefield" and a.params.Destination == "Hand")
        or (a.params.Origin == "Graveyard" and a.params.Destination == "Battlefield")
    if not ok then
      r[#r + 1] = "ChangeZoneAll " .. tostring(a.params.Origin) .. " -> " .. tostring(a.params.Destination)
    end
  end,
  resolve = function(game, a, ctx)
    if a.params.Origin == "Graveyard" then
      local cards = {}
      for _, player in ipairs(game.players) do
        for _, card in ipairs(player.graveyard) do
          if filter.matches(a.change_type, card, abilities.filter_ctx(ctx)) then
            cards[#cards + 1] = card
          end
        end
      end
      move_all(game, cards, "battlefield", { controller = ctx.controller })
      return
    end
    move_all(game, all_matching(game, ctx, a.change_type), "hand")
  end,
  harmful = true,
}

effects.DamageAll = {
  params = { NumDmg = true, ValidCards = true, ValidPlayers = true, ValidDescription = true },
  validate = function(a, r)
    number_param(a, r, "NumDmg", nil)
    a.valid_cards = parse_valid(a, r, "ValidCards")
    a.valid_players = parse_valid(a, r, "ValidPlayers")
  end,
  resolve = function(game, a, ctx)
    local n = amount(a, "NumDmg", 0)
    local hits = {}
    if a.valid_cards then
      for _, card in ipairs(all_matching(game, ctx, a.valid_cards)) do
        hits[#hits + 1] = { source = ctx.source, target = card, amount = n }
      end
    end
    if a.valid_players then
      for _, player in ipairs(game.players) do
        if filter.matches(a.valid_players, player, abilities.filter_ctx(ctx)) then
          hits[#hits + 1] = { source = ctx.source, target = player, amount = n }
        end
      end
    end
    game:deal_damage_batch(hits, false)
  end,
  harmful = true,
}

effects.TapAll = {
  params = { ValidCards = true },
  validate = function(a, r)
    a.valid_cards = parse_valid(a, r, "ValidCards", "Card")
  end,
  resolve = function(game, a, ctx)
    local players = a.target and abilities.players_of(ctx.targets[a] or {}) or nil
    for _, card in ipairs(all_matching(game, ctx, a.valid_cards, players)) do
      game:tap(card)
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

-- Creates a temporary effect (Forge's effect "card" in the command zone): static abilities that
-- apply until end of turn, with their own remembered objects. Reference: effects/EffectEffect.
-- ExileOnMoved$ ends it when a remembered object leaves that zone; ForgetOnMoved$ just forgets it.
local statics_lib = require("scripts/mtg/statics")

effects.Effect = {
  params = { StaticAbilities = true, ExileOnMoved = true, ForgetOnMoved = true, Name = true },
  validate = function(a, r)
    a.effect_statics = {}
    for name in (a.params.StaticAbilities or ""):gmatch("[^,]+") do
      local text = a.svars[name]
      if text == nil then
        r[#r + 1] = "Effect static " .. name
      else
        local st = statics_lib.parse(script_parser.parse_params(text), a.svars, r, keywords.SUPPORTED)
        a.effect_statics[#a.effect_statics + 1] = st
      end
    end
    if #a.effect_statics == 0 then
      r[#r + 1] = "Effect without StaticAbilities"
    end
    for _, key in ipairs({ "ExileOnMoved", "ForgetOnMoved" }) do
      if a.params[key] and abilities.ZONES[a.params[key]] == nil then
        r[#r + 1] = "Effect " .. key .. "$ " .. a.params[key]
      end
    end
  end,
  resolve = function(game, a, ctx)
    local remembered = {}
    if a.params.RememberObjects then
      for _, obj in ipairs(abilities.defined(game, a, ctx, a.params.RememberObjects)) do
        remembered[#remembered + 1] = obj
      end
    end
    game:add_effect({
      name = a.params.Name or (ctx.source:name() .. "'s Effect"),
      source = ctx.source, controller = ctx.controller,
      def = { statics = a.effect_statics },
      remembered = remembered,
      exile_on_moved = a.params.ExileOnMoved and abilities.ZONES[a.params.ExileOnMoved],
      forget_on_moved = a.params.ForgetOnMoved and abilities.ZONES[a.params.ForgetOnMoved],
    })
  end,
  harmful = false,
}

-- Adds mana to the controller's pool (a triggered or spell Mana effect; mana *abilities* are
-- handled by the auto-payer). PersistentMana$ keeps it until end of turn. Reference: effects/ManaEffect.
effects.Mana = {
  params = { Produced = true, PersistentMana = true, Amount = true },
  validate = function(a, r)
    local colors = require("scripts/mtg/mana").parse_produced(a.params.Produced or "")
    if colors == nil or #colors ~= 1 then
      r[#r + 1] = "Mana Produced$ " .. tostring(a.params.Produced)
    end
    a.mana_color = colors and colors[1]
    number_param(a, r, "Amount", 1)
  end,
  resolve = function(game, a, ctx)
    for _ = 1, amount(a, "Amount", 1) do
      game:add_mana(ctx.controller, a.mana_color, { persistent = a.params.PersistentMana == "True" })
    end
  end,
  harmful = false,
}

-- Becomes a creature (or other types) until end of turn, with base P/T if given (Animate; Crew).
-- Reference: effects/AnimateEffect.
effects.Animate = {
  params = { Power = true, Toughness = true, Types = true },
  validate = function(a, r)
    require_targets_or_defined(a, r)
    a.animate_types = {}
    for t in (a.params.Types or ""):gmatch("[^,]+") do
      a.animate_types[t] = true
    end
    for _, key in ipairs({ "Power", "Toughness" }) do
      if a.params[key] and tonumber(a.params[key]) == nil then
        r[#r + 1] = "Animate " .. key .. "$ " .. a.params[key]
      end
    end
  end,
  resolve = function(game, a, ctx)
    for _, card in ipairs(abilities.defined(game, a, ctx, a.params.Defined or "Targeted")) do
      if card.zone == "battlefield" then
        card:add_animation(a.animate_types, tonumber(a.params.Power or ""), tonumber(a.params.Toughness or ""))
        game:emit({ type = "animate", card = card })
      end
    end
  end,
  harmful = false,
}

-- Every resolve function sees the current context through CTX (used by amount()).
for _, spec in pairs(effects) do
  if type(spec) == "table" and spec.resolve then
    local resolve = spec.resolve
    spec.resolve = function(game, a, ctx)
      local previous = CTX
      CTX = ctx
      resolve(game, a, ctx)
      CTX = previous
    end
  end
end

return effects
