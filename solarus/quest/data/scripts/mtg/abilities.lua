-- Ability chains: building them from script parameters, targeting, Defined$ lookups, resolution.
-- Reference: forge-game ability/AbilityFactory (building), ability/AbilityUtils (getDefinedCards/
-- Players, resolve), spellability/TargetRestrictions + TargetChoices, zone/MagicStack.hasLegalTargeting.
--
-- An ability:
--   { api = "DealDamage", params = { ... }, sub = ability or nil, parent = ability or nil,
--     target = { filter =, min =, max =, zone = "battlefield"|"graveyard"|"hand"|"stack" } or nil }
-- A resolution/targeting context:
--   ctx = { game =, source = card, controller = player, targets = { [ability] = { obj, ... } },
--           trigger = { card =, controller = } or nil }

local filter = require("scripts/mtg/filter")
local script_parser = require("scripts/mtg/script_parser")
local expr = require("scripts/mtg/expr")

local abilities = {}

-- Parameters every ability may carry: descriptions and AI hints the engine ignores, chaining,
-- and targeting (handled here).
local COMMON_PARAMS = {
  SP = true, AB = true, DB = true, SpellDescription = true, StackDescription = true, TgtPrompt = true,
  AILogic = true, AITgts = true, AIPreference = true, IsCurse = true, SubAbility = true,
  ValidTgts = true, TargetMin = true, TargetMax = true, TgtZone = true, TargetType = true, Defined = true,
  ConditionCheckSVar = true, ConditionSVarCompare = true, ConditionPresent = true, ConditionCompare = true,
  ConditionDescription = true, ValidTgtsDesc = true,
  Cost = true, CostDesc = true, UnlessCost = true, UnlessSwitched = true, UnlessPayer = true, Condition = true,
  RememberObjects = true, ConditionDefined = true, ConditionActivationLimit = true, TargetUnique = true,
  TargetsWithDefinedController = true, TargetsWithDifferentControllers = true,
}

-- Parameters holding amounts; compiled with expr.compile into ability.amounts[key].
local AMOUNT_PARAMS = {
  NumDmg = true, NumCards = true, LifeAmount = true, NumAtt = true, NumDef = true,
  ScryNum = true, SurveilNum = true, DigNum = true, ChangeNum = true, Amount = true,
}

-- Value of an amount parameter at resolution time.
function abilities.value(ability, key, ctx, default)
  local fn = ability.amounts and ability.amounts[key]
  if fn == nil then
    return default
  end
  return fn(ctx.game, ctx)
end

local ZONES = {
  Battlefield = "battlefield", Graveyard = "graveyard", Hand = "hand", Library = "library",
  Exile = "exile", Stack = "stack",
}
abilities.ZONES = ZONES

local DEFINED_CARDS = {
  Self = true, Targeted = true, TargetedCard = true, ParentTarget = true,
  TriggeredCard = true, TriggeredCardLKICopy = true, Enchanted = true, Equipped = true,
  Remembered = true, RememberedCard = true, TriggeredAttackerLKICopy = true, TriggeredAttacker = true,
}
local DEFINED_PLAYERS = {
  You = true, Opponent = true, ["Player.Opponent"] = true, Player = true,
  TargetedPlayer = true, TargetedController = true, TargetedOwner = true, TriggeredCardController = true,
  TriggeredPlayer = true, TriggeredCardOwner = true, TriggeredDefendingPlayer = true, ["Player.Other"] = true,
}
abilities.DEFINED_CARDS = DEFINED_CARDS
abilities.DEFINED_PLAYERS = DEFINED_PLAYERS

-- "3", "+1", "-2" -> number. Anything else (X, SVar math) isn't supported yet.
function abilities.amount(text, default)
  if text == nil then
    return default
  end
  local n = text:match("^[+]?(%-?%d+)$")
  return n and tonumber(n) or nil
end

-- Builds an ability chain from a parameter map; problems are appended to `reasons`.
-- effects = the effect registry (scripts/mtg/effects), passed in to avoid a require cycle.
function abilities.build(params, svars, reasons, effects, parent, depth)
  depth = depth or 0
  local api = params.SP or params.AB or params.DB
  local ability = { api = api, params = params, parent = parent, amounts = {}, svars = svars }
  local spec = effects[api]
  if spec == nil then
    reasons[#reasons + 1] = "effect " .. tostring(api)
    return ability
  end
  for key in pairs(params) do
    if not COMMON_PARAMS[key] and not spec.params[key] then
      reasons[#reasons + 1] = api .. " parameter " .. key
    end
  end

  for key, text in pairs(params) do
    if AMOUNT_PARAMS[key] and not (key == "NumAtt" and text == "Double") then
      local fn, problem = expr.compile(text, svars)
      if fn then
        ability.amounts[key] = fn
      else
        reasons[#reasons + 1] = api .. " " .. key .. "$ " .. text .. " (" .. tostring(problem) .. ")"
      end
    end
  end

  -- "You may pay <cost>. If you do, ..." : Cost$ on a non-root ability, or UnlessCost$ with
  -- UnlessSwitched$ True paid by You. (Cost$ on a spell's or activated ability's root is its real
  -- cost and is taken off by card_db before building.)
  local optional_text = params.Cost
  if params.UnlessCost then
    if params.UnlessSwitched ~= "True" or (params.UnlessPayer or "You") ~= "You" then
      reasons[#reasons + 1] = "UnlessCost without UnlessSwitched"
    end
    optional_text = params.UnlessCost
  end
  if optional_text then
    local parsed, problem = require("scripts/mtg/cost").parse(optional_text)
    if parsed == nil then
      reasons[#reasons + 1] = tostring(problem)
    end
    ability.optional_cost = parsed
  end
  if params.Condition then
    if params.Condition ~= "Kicked" then
      reasons[#reasons + 1] = "Condition$ " .. params.Condition
    end
    ability.condition = function(game, ctx) return ctx.kicked == true end
  end

  -- Conditions (SpellAbilityCondition): when false, this part is skipped; its sub-abilities still run.
  if params.ConditionCheckSVar then
    local check, problem = expr.compile_check(params.ConditionCheckSVar, params.ConditionSVarCompare, svars)
    if check == nil then
      reasons[#reasons + 1] = "condition " .. tostring(problem)
    end
    ability.condition = check
  elseif params.ConditionPresent and params.ConditionDefined then
    -- count of the Defined objects matching ConditionPresent, compared
    local parsed, problem = filter.parse(params.ConditionPresent)
    local compare = expr.compile_compare(params.ConditionCompare or "GE1")
    if parsed == nil or compare == nil then
      reasons[#reasons + 1] = "condition " .. tostring(problem or params.ConditionCompare)
    end
    local defined_text = params.ConditionDefined
    ability.condition = function(game, ctx)
      local n = 0
      for _, obj in ipairs(abilities.defined(game, ability, ctx, defined_text)) do
        if filter.matches(parsed, obj, abilities.filter_ctx(ctx)) then
          n = n + 1
        end
      end
      return compare(n)
    end
    if not DEFINED_CARDS[defined_text] and not DEFINED_PLAYERS[defined_text] then
      reasons[#reasons + 1] = "ConditionDefined " .. defined_text
    end
  elseif params.ConditionPresent then
    local check, problem = expr.compile_present(params.ConditionPresent, params.ConditionCompare)
    if check == nil then
      reasons[#reasons + 1] = "condition " .. tostring(problem)
    end
    ability.condition = check
  elseif params.ConditionActivationLimit then
    -- "if this is the Nth time this ability has resolved/been activated this turn"
    local compare = expr.compile_compare(params.ConditionActivationLimit)
    if compare == nil then
      reasons[#reasons + 1] = "ConditionActivationLimit$ " .. params.ConditionActivationLimit
    end
    ability.condition = function(game, ctx)
      return ctx.activation_index ~= nil and compare(game:activation_count(ctx.source, ctx.activation_index))
    end
  end
  if params.RememberObjects then
    local d = params.RememberObjects
    if not DEFINED_CARDS[d] and not DEFINED_PLAYERS[d] then
      reasons[#reasons + 1] = "RememberObjects " .. d
    end
  end

  if params.ValidTgts then
    local parsed, problem = filter.parse(params.ValidTgts)
    if parsed == nil then
      reasons[#reasons + 1] = problem
    end
    local zone = "battlefield"
    if params.TargetType == "Spell" then
      zone = "stack"
    elseif params.TargetType ~= nil then
      reasons[#reasons + 1] = "TargetType " .. params.TargetType
    elseif params.TgtZone then
      zone = ZONES[params.TgtZone]
    elseif spec.target_zone then
      zone = spec.target_zone(params)
    end
    if zone == nil then
      reasons[#reasons + 1] = "target zone " .. tostring(params.TgtZone or params.Origin)
    end
    local min, max = abilities.amount(params.TargetMin or "1"), abilities.amount(params.TargetMax or "1")
    if min == nil or max == nil then
      reasons[#reasons + 1] = "target count " .. tostring(params.TargetMin) .. ".." .. tostring(params.TargetMax)
    end
    ability.target = { filter = parsed, min = min or 1, max = max or 1, zone = zone }
  end

  if params.Defined then
    local d = params.Defined
    if not DEFINED_CARDS[d] and not DEFINED_PLAYERS[d] then
      reasons[#reasons + 1] = "Defined " .. d
    end
  end

  if spec.validate then
    spec.validate(ability, reasons)
  end

  if params.SubAbility then
    local text = svars[params.SubAbility]
    if text == nil or depth > 20 then
      reasons[#reasons + 1] = "missing SubAbility " .. params.SubAbility
    else
      ability.sub = abilities.build(script_parser.parse_params(text), svars, reasons, effects, ability, depth + 1)
    end
  end
  return ability
end

-- Iterates root, root.sub, ...
-- Iterates root, root.sub, ... For modal abilities (Charm), the chosen modes' chains (recorded in
-- ctx.modes[charm] = { index, ... }) follow the Charm itself; without a ctx no modes are included.
function abilities.chain(root, ctx)
  local list = {}
  local function walk(a)
    while a do
      list[#list + 1] = a
      if a.choices and ctx and ctx.modes and ctx.modes[a] then
        for _, index in ipairs(ctx.modes[a]) do
          walk(a.choices[index])
        end
      end
      a = a.sub
    end
  end
  walk(root)
  return list
end

-- Targeting -------------------------------------------------------------------------------------

local function is_player(obj)
  return obj.life ~= nil
end

local function filter_ctx(ctx)
  return { game = ctx.game, you = ctx.controller, self = ctx.source, remembered = ctx.remembered, x = ctx.x_paid }
end
abilities.filter_ctx = filter_ctx

-- Is obj a legal target for this ability right now? (CR 115, 702.11 hexproof)
function abilities.is_legal_target(ability, obj, ctx)
  local spec = ability.target
  if not filter.matches(spec.filter, obj, filter_ctx(ctx)) then
    return false
  end
  if is_player(obj) then
    return not obj.lost
  end
  if obj.zone ~= spec.zone then
    return false
  end
  if spec.zone == "stack" and obj == ctx.source then
    return false  -- a spell can't target itself
  end
  if spec.zone == "battlefield" and obj:has_keyword("Hexproof") and obj.controller ~= ctx.controller then
    return false
  end
  return true
end

local function owner_or_controller(obj)
  if obj.life ~= nil then
    return obj
  end
  return obj.zone == "battlefield" and obj.controller or obj.owner
end

-- Extra restrictions some abilities put on their targets (TargetUnique, TargetsWithDefinedController).
local function passes_target_restrictions(game, ability, obj, ctx)
  local p = ability.params
  if p.TargetUnique == "True" then
    for other, list in pairs(ctx.targets or {}) do
      if other ~= ability then
        for _, t in ipairs(list) do
          if t == obj then
            return false
          end
        end
      end
    end
  end
  if p.TargetsWithDefinedController then
    local allowed = abilities.defined(game, ability, ctx, p.TargetsWithDefinedController)
    local ok = false
    for _, player in ipairs(allowed) do
      ok = ok or owner_or_controller(obj) == player
    end
    if not ok then
      return false
    end
  end
  return true
end

function abilities.target_candidates(game, ability, ctx)
  local raw = abilities.raw_target_candidates(game, ability, ctx)
  local list = {}
  for _, obj in ipairs(raw) do
    if passes_target_restrictions(game, ability, obj, ctx) then
      list[#list + 1] = obj
    end
  end
  return list
end

function abilities.raw_target_candidates(game, ability, ctx)
  local list = {}
  local spec = ability.target
  if filter.includes_players(spec.filter) then
    for _, player in ipairs(game.players) do
      if abilities.is_legal_target(ability, player, ctx) then
        list[#list + 1] = player
      end
    end
  end
  if spec.zone == "stack" then
    for _, item in ipairs(game.stack) do
      if item.kind == "spell" and abilities.is_legal_target(ability, item.card, ctx) then
        list[#list + 1] = item.card
      end
    end
  else
    for _, player in ipairs(game.players) do
      local cards = spec.zone == "battlefield" and player.battlefield or player[spec.zone]
      for _, card in ipairs(cards) do
        if abilities.is_legal_target(ability, card, ctx) then
          list[#list + 1] = card
        end
      end
    end
  end
  return list
end

-- Can every targeting part of the chain find enough targets? (used to offer spells for casting)
function abilities.can_target(game, root, ctx)
  for _, ability in ipairs(abilities.chain(root)) do
    if ability.target and #abilities.target_candidates(game, ability, ctx) < ability.target.min then
      return false
    end
    if ability.choices then
      local any = false
      for _, choice in ipairs(ability.choices) do
        any = any or abilities.can_target(game, choice, ctx)
      end
      if not any then
        return false
      end
    end
  end
  return true
end

-- Modes of a Charm that could be chosen now (their targets exist).
function abilities.available_modes(game, charm, ctx)
  local list = {}
  for i, choice in ipairs(charm.choices) do
    if abilities.can_target(game, choice, ctx) then
      list[#list + 1] = i
    end
  end
  return list
end

-- Short description of a mode or ability, for menus.
function abilities.describe(ability)
  return ability.params.SpellDescription or ability.params.StackDescription or ability.api
end

-- Asks the controller for every targeting part of the chain. Returns false if some part has too
-- few legal targets (the spell can't be cast / the trigger is removed, CR 601.2c, 603.3d).
function abilities.choose_targets(game, root, ctx)
  ctx.targets = ctx.targets or {}
  ctx.modes = ctx.modes or {}
  -- Walks the chain as choices are made: a Charm's mode is chosen (CR 601.2b) before the targets
  -- of the abilities that follow (601.2c).
  local pending = { root }
  local function next_ability()
    local a = table.remove(pending, 1)
    if a and a.sub then
      table.insert(pending, 1, a.sub)
    end
    return a
  end
  while #pending > 0 do
    local ability = next_ability()
    if ability.choices then
      local options = abilities.available_modes(game, ability, ctx)
      if #options == 0 then
        return false
      end
      local index = ctx.controller.controller:choose_mode(game, ctx.controller, ctx.source, ability, options)
      local ok = false
      for _, o in ipairs(options) do
        ok = ok or o == index
      end
      if not ok then
        error("illegal mode " .. tostring(index))
      end
      ctx.modes[ability] = { index }
      table.insert(pending, 1, ability.choices[index])
    end
    if ability.target then
      local candidates = abilities.target_candidates(game, ability, ctx)
      local spec = ability.target
      if #candidates < spec.min then
        return false
      end
      local chosen = ctx.controller.controller:choose_targets(game, ctx.controller, ability, candidates, spec.min, math.min(spec.max, #candidates), ctx) or {}
      if #chosen < spec.min or #chosen > spec.max then
        error("chose " .. #chosen .. " targets, need " .. spec.min .. ".." .. spec.max)
      end
      if ability.params.TargetsWithDifferentControllers == "True" then
        for i = 1, #chosen do
          for j = i + 1, #chosen do
            if owner_or_controller(chosen[i]) == owner_or_controller(chosen[j]) then
              error("targets must have different controllers")
            end
          end
        end
      end
      local seen = {}
      for _, obj in ipairs(chosen) do
        local found = false
        for _, c in ipairs(candidates) do
          if c == obj then
            found = true
          end
        end
        if not found or seen[obj] then
          error("illegal target " .. tostring(obj.name and obj:name() or obj.name))
        end
        seen[obj] = true
      end
      ctx.targets[ability] = chosen
    end
  end
  return true
end

-- Defined$ -------------------------------------------------------------------------------------

local function targets_up_to(ability, ctx)
  local list = {}
  local chain = {}
  local a = ability
  while a do
    table.insert(chain, 1, a)
    a = a.parent
  end
  for _, part in ipairs(chain) do
    for _, obj in ipairs(ctx.targets[part] or {}) do
      list[#list + 1] = obj
    end
  end
  return list
end

-- Returns the objects (cards or players) a Defined$ value refers to.
function abilities.defined(game, ability, ctx, text)
  if text == nil then
    return {}
  end
  if text == "You" then
    return { ctx.controller }
  elseif text == "Opponent" or text == "Player.Opponent" or text == "Player.Other" then
    return { game:opponent(ctx.controller) }
  elseif text == "Player" then
    return { game.players[1], game.players[2] }
  elseif text == "Self" then
    return { ctx.source }
  elseif text == "TriggeredCard" or text == "TriggeredCardLKICopy" or text == "TriggeredAttackerLKICopy"
      or text == "TriggeredAttacker" then
    return { ctx.trigger and ctx.trigger.card }
  elseif text == "TriggeredDefendingPlayer" then
    return { ctx.trigger and ctx.trigger.defender }
  elseif text == "Remembered" or text == "RememberedCard" then
    local list = {}
    for _, obj in ipairs(ctx.remembered or {}) do
      list[#list + 1] = obj
    end
    return list
  elseif text == "TriggeredCardController" then
    return { ctx.trigger and ctx.trigger.controller }
  elseif text == "TriggeredPlayer" then
    return { ctx.trigger and ctx.trigger.player }
  elseif text == "TriggeredCardOwner" then
    return { ctx.trigger and ctx.trigger.card and ctx.trigger.card.owner }
  elseif text == "Enchanted" or text == "Equipped" then
    local target = ctx.source and ctx.source.attached_to
    return { target }
  end
  local result = {}
  if text == "ParentTarget" then
    local a = ability.parent
    while a and not ctx.targets[a] do
      a = a.parent
    end
    for _, obj in ipairs(a and ctx.targets[a] or {}) do
      result[#result + 1] = obj
    end
    return result
  end
  local targeted = targets_up_to(ability, ctx)
  for _, obj in ipairs(targeted) do
    if text == "Targeted" or text == "TargetedCard" then
      if not is_player(obj) then
        result[#result + 1] = obj
      end
    elseif text == "TargetedPlayer" then
      if is_player(obj) then
        result[#result + 1] = obj
      end
    elseif text == "TargetedController" then
      result[#result + 1] = is_player(obj) and obj or obj.controller
    elseif text == "TargetedOwner" then
      result[#result + 1] = is_player(obj) and obj or obj.owner
    end
  end
  return result
end

-- The objects an effect acts on: its targets if it targets, else Defined$ (or the default).
function abilities.affected(game, ability, ctx, default_defined)
  if ability.target then
    return ctx.targets[ability] or {}
  end
  -- Runs a chain's effects in order without targeting (used by Branch for its chosen path).
function abilities.run_chain(game, root, ctx, effects)
  for _, ability in ipairs(abilities.chain(root, ctx)) do
    if ability.condition == nil or ability.condition(game, ctx) then
      effects[ability.api].resolve(game, ability, ctx)
    end
  end
end

return abilities.defined(game, ability, ctx, ability.params.Defined or default_defined)
end

function abilities.players_of(list)
  local result = {}
  for _, obj in ipairs(list) do
    if is_player(obj) then
      result[#result + 1] = obj
    end
  end
  return result
end

function abilities.cards_of(list)
  local result = {}
  for _, obj in ipairs(list) do
    if not is_player(obj) then
      result[#result + 1] = obj
    end
  end
  return result
end

-- Resolution ------------------------------------------------------------------------------------

-- Resolves a chain (CR 608.2b): if it had targets and all are now illegal, it doesn't resolve
-- (returns false). Otherwise illegal targets are dropped and each part runs in order.
function abilities.resolve(game, root, ctx, effects)
  local had_targets, any_legal = false, false
  for _, ability in ipairs(abilities.chain(root, ctx)) do
    if ability.target then
      local legal = {}
      for _, obj in ipairs(ctx.targets[ability] or {}) do
        had_targets = true
        if abilities.is_legal_target(ability, obj, ctx) then
          legal[#legal + 1] = obj
          any_legal = true
        end
      end
      ctx.targets[ability] = legal
    end
  end
  if had_targets and not any_legal then
    return false
  end
  for _, ability in ipairs(abilities.chain(root, ctx)) do
    local skip = ability.target and #ctx.targets[ability] == 0 and ability.target.min > 0
    ctx.targeted_for_expr = function(kind)
      -- Runs a chain's effects in order without targeting (used by Branch for its chosen path).
function abilities.run_chain(game, root, ctx, effects)
  for _, ability in ipairs(abilities.chain(root, ctx)) do
    if ability.condition == nil or ability.condition(game, ctx) then
      effects[ability.api].resolve(game, ability, ctx)
    end
  end
end

return abilities.defined(game, ability, ctx, kind == "ParentTargeted" and "ParentTarget" or "Targeted")
    end
    if ability.condition and not ability.condition(game, ctx) then
      skip = true
    end
    if not skip and ability.optional_cost then
      -- "You may pay ...; if you do": declining (or being unable to pay) skips the rest.
      local cost_lib = require("scripts/mtg/cost")
      local player = ctx.controller
      if not cost_lib.can_pay(game, player, ctx.source, ability.optional_cost)
          or not player.controller:confirm_optional(game, player, ctx.source, ability) then
        return true
      end
      local paid = cost_lib.pay(game, player, ctx.source, ability.optional_cost)
      ctx.sacrificed = paid.sacrificed
    end
    if not skip then
      effects[ability.api].resolve(game, ability, ctx)
      if ability.params.RememberObjects then
        ctx.remembered = ctx.remembered or {}
        for _, obj in ipairs(abilities.defined(game, ability, ctx, ability.params.RememberObjects)) do
          table.insert(ctx.remembered, obj)
        end
      end
    end
  end
  return true
end

-- Runs a chain's effects in order without targeting (used by Branch for its chosen path).
function abilities.run_chain(game, root, ctx, effects)
  for _, ability in ipairs(abilities.chain(root, ctx)) do
    if ability.condition == nil or ability.condition(game, ctx) then
      effects[ability.api].resolve(game, ability, ctx)
    end
  end
end

return abilities
