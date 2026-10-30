-- Static abilities (S: lines).
-- Reference: forge-game staticability/StaticAbility, StaticAbilityContinuous (layers),
-- StaticAbilityCantAttackBlock, StaticAbilityMustAttack, StaticAbilityCantBlockBy,
-- StaticAbilityMinMaxBlocker, cost/CostAdjustment (ReduceCost); GameAction.checkStaticAbilities.
--
-- Continuous effects are recomputed whenever the game state changed (game:ensure_statics, called by
-- the Card getters). During the pass every card reads its *base* characteristics, so a filter such as
-- "Creature.powerGE4" can't loop back into the pass. Forge orders effects by layer, timestamp and
-- dependency; here, within each card, set-P/T comes before modifications, and keywords added by
-- one static aren't seen by another static's filter (simplification, see porting-plan.md).
-- Control-changing effects (layer 2) move cards between battlefields, so they're applied separately
-- by statics.update_control, called with the state-based actions.

local filter = require("scripts/mtg/filter")
local expr = require("scripts/mtg/expr")

local statics = {}

local COMMON = { Mode = true, Description = true, Secondary = true, EffectZone = true, Condition = true,
                 IsPresent = true, PresentCompare = true }

local MODE_PARAMS = {
  Continuous = { Affected = true, AffectedDefined = true, AddPower = true, AddToughness = true, AddKeyword = true,
                 RemoveKeyword = true, SetPower = true, SetToughness = true, CharacteristicDefining = true,
                 GainControl = true },
  CantBlock = { ValidCard = true },
  CantAttack = { ValidCard = true },
  ["CantAttack,CantBlock"] = { ValidCard = true },
  MustAttack = { ValidCreature = true },
  CantBlockBy = { ValidAttacker = true, ValidBlocker = true },
  MinMaxBlocker = { ValidCard = true, Max = true },
  CanAttackDefender = { ValidCard = true },
  ReduceCost = { ValidCard = true, Type = true, Activator = true, Amount = true, ValidTarget = true },
}

local CONDITIONS = {
  PlayerTurn = function(game, source) return game:active_player() == source.controller end,
  Threshold = function(game, source) return #source.controller.graveyard >= 7 end,
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

local function parse_amount(params, key, svars, reasons)
  if params[key] == nil then
    return nil
  end
  local fn, problem = expr.compile(params[key], svars)
  if fn == nil then
    reasons[#reasons + 1] = "static " .. key .. "$ " .. params[key] .. " (" .. tostring(problem) .. ")"
  end
  return fn
end

local function parse_keywords(text, reasons, supported)
  local set = {}
  for kw in (text or ""):gmatch("[^&]+") do
    kw = kw:gsub("^%s+", ""):gsub("%s+$", "")
    if not supported[kw] then
      reasons[#reasons + 1] = "static keyword " .. kw
    end
    set[kw] = true
  end
  return set
end

-- Parses an S: line into a static, or records why it isn't supported.
function statics.parse(params, svars, reasons, supported_keywords)
  local allowed = MODE_PARAMS[params.Mode]
  if allowed == nil then
    reasons[#reasons + 1] = "static " .. tostring(params.Mode)
    return nil
  end
  for key in pairs(params) do
    if not COMMON[key] and not allowed[key] then
      reasons[#reasons + 1] = "static " .. params.Mode .. " parameter " .. key
    end
  end
  local st = { mode = params.Mode, params = params }
  if params.Condition then
    st.condition = CONDITIONS[params.Condition]
    if st.condition == nil then
      reasons[#reasons + 1] = "static Condition$ " .. params.Condition
    end
  end
  if params.IsPresent then
    local check, problem = expr.compile_present(params.IsPresent, params.PresentCompare)
    if check == nil then
      reasons[#reasons + 1] = tostring(problem)
    end
    st.present = check
  end
  if params.EffectZone and params.EffectZone ~= "All" and params.EffectZone ~= "Battlefield" then
    reasons[#reasons + 1] = "static EffectZone$ " .. params.EffectZone
  end

  if st.mode == "Continuous" then
    local d = params.AffectedDefined
    if d and d ~= "Self" and d ~= "Enchanted" and d ~= "Equipped" then
      reasons[#reasons + 1] = "static AffectedDefined$ " .. d
    end
    if d == nil and params.Affected == nil then
      if params.CharacteristicDefining == "True" then
        params.AffectedDefined = "Self"   -- a CDA defines the card's own characteristics
      else
        reasons[#reasons + 1] = "static without Affected"
      end
    end
    st.affected = parse_filter(params, "Affected", reasons)
    st.add_power = parse_amount(params, "AddPower", svars, reasons)
    st.add_toughness = parse_amount(params, "AddToughness", svars, reasons)
    st.set_power = parse_amount(params, "SetPower", svars, reasons)
    st.set_toughness = parse_amount(params, "SetToughness", svars, reasons)
    st.add_keywords = parse_keywords(params.AddKeyword, reasons, supported_keywords)
    st.remove_keywords = parse_keywords(params.RemoveKeyword, reasons, supported_keywords)
    if params.GainControl and params.GainControl ~= "You" then
      reasons[#reasons + 1] = "static GainControl$ " .. params.GainControl
    end
    st.gain_control = params.GainControl == "You"
  elseif st.mode == "CantBlockBy" then
    st.valid_attacker = parse_filter(params, "ValidAttacker", reasons, "Creature")
    st.valid_blocker = parse_filter(params, "ValidBlocker", reasons, "Creature")
  elseif st.mode == "MustAttack" then
    st.valid = parse_filter(params, "ValidCreature", reasons, "Creature")
  elseif st.mode == "ReduceCost" then
    if params.Type ~= "Spell" then
      reasons[#reasons + 1] = "ReduceCost Type$ " .. tostring(params.Type)
    end
    st.valid = parse_filter(params, "ValidCard", reasons, "Card")
    st.valid_target = parse_filter(params, "ValidTarget", reasons)
    st.amount = parse_amount(params, "Amount", svars, reasons)
    if params.Activator and params.Activator ~= "You" then
      reasons[#reasons + 1] = "ReduceCost Activator$ " .. params.Activator
    end
  else
    st.valid = parse_filter(params, "ValidCard", reasons, "Card")
    if st.mode == "MinMaxBlocker" then
      st.max = tonumber(params.Max or "")
      if st.max == nil then
        reasons[#reasons + 1] = "MinMaxBlocker Max$ " .. tostring(params.Max)
      end
    end
  end
  return st
end

local function fctx(game, source)
  return { game = game, you = source.controller, self = source }
end

local function active(game, source, st)
  if st.condition and not st.condition(game, source) then
    return false
  end
  if st.present and not st.present(game, { game = game, source = source, controller = source.controller }) then
    return false
  end
  return true
end

-- Every (source, static) currently in effect with the given mode (or all modes if nil).
-- Statics work from the battlefield, except EffectZone$ All ones on a spell's own card (cost
-- reductions), which statics.cost_reduction looks up directly.
local function each_static(game, mode)
  local list = {}
  for _, player in ipairs(game.players) do
    for _, source in ipairs(player.battlefield) do
      for _, st in ipairs(source.def.statics or {}) do
        if (mode == nil or st.mode == mode or (st.mode == "CantAttack,CantBlock" and (mode == "CantAttack" or mode == "CantBlock")))
            and active(game, source, st) then
          list[#list + 1] = { source = source, st = st }
        end
      end
    end
  end
  return list
end

local function affected_cards(game, source, st)
  local candidates
  local d = st.params.AffectedDefined
  if d == "Self" then
    candidates = { source }
  elseif d == "Enchanted" or d == "Equipped" then
    local target = source.attached_to
    candidates = (target and target.life == nil and target.zone == "battlefield") and { target } or {}
  else
    candidates = {}
    for _, player in ipairs(game.players) do
      for _, card in ipairs(player.battlefield) do
        candidates[#candidates + 1] = card
      end
    end
  end
  if st.affected == nil then
    return candidates
  end
  local list = {}
  for _, card in ipairs(candidates) do
    if filter.matches(st.affected, card, fctx(game, source)) then
      list[#list + 1] = card
    end
  end
  return list
end

-- Recomputes card.mods for every card on the battlefield (layers 6-7).
function statics.apply(game)
  local results = {}
  for _, player in ipairs(game.players) do
    for _, card in ipairs(player.battlefield) do
      card.mods = nil
    end
  end
  for _, entry in ipairs(each_static(game, "Continuous")) do
    local source, st = entry.source, entry.st
    local ctx = { game = game, source = source, controller = source.controller }
    for _, card in ipairs(affected_cards(game, source, st)) do
      local m = results[card]
      if m == nil then
        m = { power = 0, toughness = 0, added = {}, removed = {} }
        results[card] = m
      end
      if st.set_power then
        m.set_power = st.set_power(game, ctx)
      end
      if st.set_toughness then
        m.set_toughness = st.set_toughness(game, ctx)
      end
      if st.add_power then
        m.power = m.power + st.add_power(game, ctx)
      end
      if st.add_toughness then
        m.toughness = m.toughness + st.add_toughness(game, ctx)
      end
      for kw in pairs(st.add_keywords) do
        m.added[kw] = true
      end
      for kw in pairs(st.remove_keywords) do
        m.removed[kw] = true
      end
    end
  end
  for card, m in pairs(results) do
    card.mods = m
  end
end

-- Layer 2: who controls each permanent. Returns true if anything changed.
function statics.update_control(game)
  local wanted = {}
  for _, entry in ipairs(each_static(game, "Continuous")) do
    if entry.st.gain_control then
      for _, card in ipairs(affected_cards(game, entry.source, entry.st)) do
        wanted[card] = entry.source.controller
      end
    end
  end
  local moves = {}
  for _, player in ipairs(game.players) do
    for _, card in ipairs(player.battlefield) do
      local controller = wanted[card] or card.base_controller
      if controller ~= card.controller then
        moves[#moves + 1] = { card = card, to = controller }
      end
    end
  end
  for _, mv in ipairs(moves) do
    game:change_control(mv.card, mv.to)
  end
  return #moves > 0
end

-- Does any static of `mode` apply to `card`? (CantBlock, CantAttack, CanAttackDefender)
function statics.applies(game, mode, card)
  for _, entry in ipairs(each_static(game, mode)) do
    if filter.matches(entry.st.valid, card, fctx(game, entry.source)) then
      return true
    end
  end
  return false
end

-- Creatures that must attack if able (MustAttack).
function statics.must_attack(game, card)
  for _, entry in ipairs(each_static(game, "MustAttack")) do
    if filter.matches(entry.st.valid, card, fctx(game, entry.source)) then
      return true
    end
  end
  return false
end

-- Can `blocker` block `attacker` as far as CantBlockBy statics go?
function statics.can_block_by(game, attacker, blocker)
  for _, entry in ipairs(each_static(game, "CantBlockBy")) do
    local c = fctx(game, entry.source)
    if filter.matches(entry.st.valid_attacker, attacker, c) and filter.matches(entry.st.valid_blocker, blocker, c) then
      return false
    end
  end
  return true
end

-- Maximum number of creatures that can block `attacker` (MinMaxBlocker), or nil.
function statics.max_blockers(game, attacker)
  local max
  for _, entry in ipairs(each_static(game, "MinMaxBlocker")) do
    if filter.matches(entry.st.valid, attacker, fctx(game, entry.source)) then
      max = math.min(max or entry.st.max, entry.st.max)
    end
  end
  return max
end

-- Generic mana a spell's cost is reduced by. `targets` (list of objects) is nil when checking
-- whether it could be cast at all: then a ValidTarget reduction counts if some legal target
-- would satisfy it (`candidates`).
function statics.cost_reduction(game, player, card, targets, candidates)
  local total = 0
  local entries = {}
  for _, st in ipairs(card.def.statics or {}) do
    if st.mode == "ReduceCost" and st.params.EffectZone == "All" then
      entries[#entries + 1] = { source = card, st = st }
    end
  end
  for _, entry in ipairs(each_static(game, "ReduceCost")) do
    entries[#entries + 1] = entry
  end
  for _, entry in ipairs(entries) do
    local source, st = entry.source, entry.st
    local you = source == card and player or source.controller
    local c = { game = game, you = you, self = source }
    local ok = active(game, source, st) and filter.matches(st.valid, card, c)
        and (st.params.Activator == nil or player == you)
    if ok and st.valid_target then
      ok = false
      for _, obj in ipairs(targets or candidates or {}) do
        if filter.matches(st.valid_target, obj, c) then
          ok = true
        end
      end
    end
    if ok and st.amount then
      total = total + st.amount(game, { game = game, source = source, controller = you })
    end
  end
  return total
end

return statics
