-- Triggered abilities.
-- Reference: forge-game trigger/TriggerHandler (runTrigger, look-back for leaves-the-battlefield),
-- trigger/Trigger<Mode>.performTest for each mode, zone/MagicStack.addAllTriggeredAbilitiesToStack,
-- trigger/WrappedAbility (optional "may" triggers are asked on resolution; intervening "if"
-- conditions are checked again on resolution, CR 603.4).
--
-- Flow: the engine calls triggers.fire(game, mode, event) when something happens (game:move does
-- it for ChangesZone). Matching triggers wait in game.pending_triggers and go on the stack the
-- next time a player would get priority (game:put_triggers_on_stack, APNAP order).
--
-- Events per mode (fields of `event`):
--   ChangesZone      card, from, to, controller (last known)       AttackersDeclared  player, attackers
--   Attacks          card (attacker), player                       Blocks             card (blocker)
--   AttackerBlocked  card (attacker), blockers                     Phase              step, player (active)
--   SpellCast        card, player                                  Drawn              card, player
--   LifeGained       player, amount (+ first = first gain this turn)  LifeLost        player, amount
--   Taps             card                                          ManaExpend         player, before, after

local abilities = require("scripts/mtg/abilities")
local filter = require("scripts/mtg/filter")
local script_parser = require("scripts/mtg/script_parser")
local expr = require("scripts/mtg/expr")

local triggers = {}

local COMMON = {
  Mode = true, TriggerZones = true, Execute = true, TriggerDescription = true, OptionalDecider = true,
  Secondary = true, CheckSVar = true, SVarCompare = true, IsPresent = true, PresentCompare = true,
  NoResolvingCheck = true,
}

-- Phase$ names -> engine steps
local PHASES = {
  Upkeep = "upkeep", Draw = "draw", Main1 = "main1", BeginCombat = "combat_begin",
  ["Declare Attackers"] = "combat_declare_attackers", ["Declare Blockers"] = "combat_declare_blockers",
  EndCombat = "combat_end", Main2 = "main2", ["End of Turn"] = "end_of_turn",
}

local function parse_filter(params, key, reasons, default)
  local text = params[key] or default
  if text == nil then
    return nil
  end
  local parsed, problem = filter.parse(text)
  if parsed == nil then
    reasons[#reasons + 1] = problem
  end
  return parsed
end

-- How a mode reads its parameters (parse) and tests an event (test).
-- test(trigger, event, ctx) where ctx = { game, you = source controller, self = source card,
-- controller = function(card) -> player (last-known controller for cards leaving play) }.
local MODES = {}

MODES.ChangesZone = {
  params = { Origin = true, Destination = true, ValidCard = true },
  parse = function(trigger, params, reasons)
    for _, key in ipairs({ "Origin", "Destination" }) do
      local value = params[key]
      if value ~= nil and value ~= "Any" and abilities.ZONES[value] == nil then
        reasons[#reasons + 1] = "trigger " .. key .. "$ " .. value
      end
      trigger[key:lower()] = (value and value ~= "Any") and abilities.ZONES[value] or nil
    end
    if params.ValidCard == nil then
      reasons[#reasons + 1] = "trigger without ValidCard"
    end
    trigger.valid_card = parse_filter(params, "ValidCard", reasons, "Card")
  end,
  test = function(trigger, event, ctx)
    return (trigger.origin == nil or trigger.origin == event.from)
        and (trigger.destination == nil or trigger.destination == event.to)
        and filter.matches(trigger.valid_card, event.card, ctx)
  end,
}

local function card_mode(extra_params)
  local params = { ValidCard = true }
  for k in pairs(extra_params or {}) do
    params[k] = true
  end
  return {
    params = params,
    parse = function(trigger, p, reasons)
      trigger.valid_card = parse_filter(p, "ValidCard", reasons, "Card")
    end,
    test = function(trigger, event, ctx)
      return filter.matches(trigger.valid_card, event.card, ctx)
    end,
  }
end

MODES.Attacks = card_mode({ FirstAttack = true })   -- one combat per turn, so every attack is the first
MODES.Blocks = card_mode()
MODES.AttackerBlocked = card_mode()
MODES.Taps = card_mode()
MODES.Drawn = card_mode()

local function player_mode(key, extra)
  local params = { [key] = true }
  for k in pairs(extra or {}) do
    params[k] = true
  end
  return params
end

MODES.Phase = {
  params = player_mode("ValidPlayer", { Phase = true }),
  parse = function(trigger, p, reasons)
    trigger.step = PHASES[p.Phase or ""]
    if trigger.step == nil then
      reasons[#reasons + 1] = "trigger Phase$ " .. tostring(p.Phase)
    end
    trigger.valid_player = parse_filter(p, "ValidPlayer", reasons, "Player")
  end,
  test = function(trigger, event, ctx)
    return trigger.step == event.step and filter.matches(trigger.valid_player, event.player, ctx)
  end,
}

MODES.SpellCast = {
  params = player_mode("ValidActivatingPlayer", { ValidCard = true, ActivatorThisTurnCast = true, TargetsValid = true }),
  parse = function(trigger, p, reasons)
    trigger.valid_card = parse_filter(p, "ValidCard", reasons, "Card")
    trigger.valid_player = parse_filter(p, "ValidActivatingPlayer", reasons, "Player")
    trigger.targets_valid = parse_filter(p, "TargetsValid", reasons)
    if p.ActivatorThisTurnCast then
      trigger.cast_count = expr.compile_compare(p.ActivatorThisTurnCast)
      if trigger.cast_count == nil then
        reasons[#reasons + 1] = "ActivatorThisTurnCast$ " .. p.ActivatorThisTurnCast
      end
    end
  end,
  test = function(trigger, event, ctx)
    if not (filter.matches(trigger.valid_card, event.card, ctx) and filter.matches(trigger.valid_player, event.player, ctx)) then
      return false
    end
    if trigger.cast_count then
      local n = 0
      for _, entry in ipairs(ctx.game.history.cast) do
        if entry.player == event.player then
          n = n + 1
        end
      end
      if not trigger.cast_count(n) then
        return false
      end
    end
    if trigger.targets_valid then
      local hit = false
      for _, list in pairs(event.targets or {}) do
        for _, obj in ipairs(list) do
          if filter.matches(trigger.targets_valid, obj, ctx) then
            hit = true
          end
        end
      end
      return hit
    end
    return true
  end,
}

MODES.AttackersDeclared = {
  params = player_mode("AttackingPlayer", { ValidAttackers = true, ValidAttackersAmount = true }),
  parse = function(trigger, p, reasons)
    trigger.valid_player = parse_filter(p, "AttackingPlayer", reasons, "Player")
    trigger.valid_attackers = parse_filter(p, "ValidAttackers", reasons, "Creature")
    trigger.attackers_amount = expr.compile_compare(p.ValidAttackersAmount or "GE1")
    if trigger.attackers_amount == nil then
      reasons[#reasons + 1] = "ValidAttackersAmount$ " .. tostring(p.ValidAttackersAmount)
    end
  end,
  test = function(trigger, event, ctx)
    local n = 0
    for _, card in ipairs(event.attackers) do
      if filter.matches(trigger.valid_attackers, card, ctx) then
        n = n + 1
      end
    end
    return filter.matches(trigger.valid_player, event.player, ctx) and trigger.attackers_amount(n)
  end,
}

local function life_mode()
  return {
    params = player_mode("ValidPlayer", { FirstTime = true }),
    parse = function(trigger, p, reasons)
      trigger.valid_player = parse_filter(p, "ValidPlayer", reasons, "Player")
      trigger.first_time = p.FirstTime == "True"
    end,
    test = function(trigger, event, ctx)
      return filter.matches(trigger.valid_player, event.player, ctx) and (not trigger.first_time or event.first)
    end,
  }
end
MODES.LifeGained = life_mode()
MODES.LifeLost = life_mode()

MODES.ManaExpend = {
  params = { Amount = true, Player = true },
  parse = function(trigger, p, reasons)
    trigger.amount = tonumber(p.Amount or "")
    if trigger.amount == nil then
      reasons[#reasons + 1] = "ManaExpend Amount$ " .. tostring(p.Amount)
    end
    trigger.valid_player = parse_filter(p, "Player", reasons, "Player")
  end,
  test = function(trigger, event, ctx)
    return filter.matches(trigger.valid_player, event.player, ctx)
        and event.before < trigger.amount and event.after >= trigger.amount
  end,
}

-- Parses a T: line. Returns a trigger table; problems are appended to `reasons`.
function triggers.parse(params, svars, reasons, effects)
  local mode = MODES[params.Mode]
  if mode == nil then
    reasons[#reasons + 1] = "trigger " .. tostring(params.Mode)
    return nil
  end
  for key in pairs(params) do
    if not COMMON[key] and not mode.params[key] then
      reasons[#reasons + 1] = "trigger parameter " .. key
    end
  end
  local trigger = { mode = params.Mode, params = params }
  mode.parse(trigger, params, reasons)
  if params.TriggerZones ~= nil and params.TriggerZones ~= "Battlefield" then
    reasons[#reasons + 1] = "TriggerZones$ " .. params.TriggerZones
  end
  if params.OptionalDecider ~= nil and params.OptionalDecider ~= "You" then
    reasons[#reasons + 1] = "OptionalDecider$ " .. params.OptionalDecider
  end
  trigger.optional = params.OptionalDecider == "You"

  -- Intervening "if" conditions (CR 603.4).
  if params.CheckSVar then
    local check, problem = expr.compile_check(params.CheckSVar, params.SVarCompare, svars)
    if check == nil then
      reasons[#reasons + 1] = "trigger condition " .. tostring(problem)
    end
    trigger.condition = check
  elseif params.IsPresent then
    local check, problem = expr.compile_present(params.IsPresent, params.PresentCompare)
    if check == nil then
      reasons[#reasons + 1] = "trigger condition " .. tostring(problem)
    end
    trigger.condition = check
  end
  trigger.recheck = trigger.condition ~= nil and params.NoResolvingCheck ~= "True"

  local execute = params.Execute and svars[params.Execute]
  if execute == nil then
    reasons[#reasons + 1] = "trigger without Execute"
  else
    trigger.ability = abilities.build(script_parser.parse_params(execute), svars, reasons, effects)
  end
  return trigger
end

local function battlefield_sources(game)
  local sources = {}
  for _, player in ipairs(game.players) do
    for _, c in ipairs(player.battlefield) do
      sources[#sources + 1] = { card = c, controller = c.controller }
    end
  end
  return sources
end

-- Something happened: queue every matching trigger.
-- For ChangesZone out of the battlefield, event.lookback lists the battlefield as it was just
-- before (CR 603.10: leaves-the-battlefield triggers "look back in time").
function triggers.fire(game, mode, event)
  local sources
  if mode == "ChangesZone" and event.from == "battlefield" and event.to ~= "battlefield" then
    sources = event.lookback
  else
    sources = battlefield_sources(game)
  end
  local spec = MODES[mode]
  for _, source in ipairs(sources) do
    for _, trigger in ipairs(source.card.def.triggers or {}) do
      if trigger.mode == mode then
        local ctx = {
          game = game, you = source.controller, self = source.card,
          controller = function(c)
            if c == event.card and event.controller then
              return event.controller
            end
            return c.controller
          end,
        }
        local cond_ctx = { game = game, source = source.card, controller = source.controller, trigger = event }
        if spec.test(trigger, event, ctx) and (trigger.condition == nil or trigger.condition(game, cond_ctx)) then
          table.insert(game.pending_triggers, {
            source = source.card,
            controller = source.controller,
            trigger = trigger,
            event = event,
          })
        end
      end
    end
  end
end

-- Kept for game:move (ChangesZone).
function triggers.collect(game, card, from, to, lki_controller, lookback)
  triggers.fire(game, "ChangesZone", {
    card = card, from = from, to = to,
    controller = (from == "battlefield") and lki_controller or card.controller,
    lookback = lookback,
  })
end

return triggers
