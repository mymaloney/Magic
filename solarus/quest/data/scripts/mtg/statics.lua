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
                 GainControl = true, AddHiddenKeyword = true, AdjustLandPlays = true, AffectedZone = true,
                 MayPlay = true, AddType = true, RemoveCardTypes = true, RemoveCreatureTypes = true,
                 RemoveAllAbilities = true, SetColor = true, AddColor = true, SetName = true, AddAbility = true },
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

local CARD_TYPES = { Artifact = true, Creature = true, Enchantment = true, Land = true, Planeswalker = true,
                     Instant = true, Sorcery = true, Battle = true, Kindred = true }
local COLOR_WORDS = { White = "W", Blue = "U", Black = "B", Red = "R", Green = "G" }

-- "Green & White" -> { G = true, W = true }; "Colorless" -> {}.
local function parse_colors(text, reasons)
  local set = {}
  for word in text:gmatch("[^&]+") do
    word = word:gsub("^%s+", ""):gsub("%s+$", "")
    if COLOR_WORDS[word] then
      set[COLOR_WORDS[word]] = true
    elseif word ~= "Colorless" then
      reasons[#reasons + 1] = "static color " .. word
    end
  end
  return set
end

-- AddAbility$ for a mana ability "{T}: Add <one color>" (Imprisoned in the Moon).
local function parse_added_mana(text, reasons)
  local params = {}
  for part in (text or ""):gmatch("[^|]+") do
    local k, v = part:match("^%s*([^$]+)%$%s*(.-)%s*$")
    if k then
      params[k] = v
    end
  end
  local produced = params.Produced
  if params.AB ~= "Mana" or params.Cost ~= "T" or produced == nil or not produced:match("^[WUBRGC]$") then
    reasons[#reasons + 1] = "static AddAbility"
    return nil
  end
  return { colors = { produced }, tap = true, extra = 0, sacrifice = false }
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
    if params.Affected == "You" then
      -- affects the player, not cards: "You may play an additional land this turn."
      st.affects_you = true
      if params.AdjustLandPlays == nil then
        reasons[#reasons + 1] = "static Affected$ You"
      end
    else
      st.affected = parse_filter(params, "Affected", reasons)
    end
    if params.AdjustLandPlays then
      st.land_plays = tonumber(params.AdjustLandPlays)
      if st.land_plays == nil or not st.affects_you then
        reasons[#reasons + 1] = "static AdjustLandPlays$ " .. params.AdjustLandPlays
      end
    end
    local zone = params.AffectedZone or "Battlefield"
    if zone ~= "Battlefield" and not (zone == "Exile" and params.MayPlay == "True") then
      reasons[#reasons + 1] = "static AffectedZone$ " .. zone
    end
    if params.MayPlay and (params.MayPlay ~= "True" or zone ~= "Exile") then
      reasons[#reasons + 1] = "static MayPlay outside exile"
    end
    st.may_play = params.MayPlay == "True"
    -- layers 3-6: name, types, colors, abilities
    if params.AddType then
      st.add_types, st.add_subtypes = {}, {}
      for word in params.AddType:gmatch("[^&]+") do
        word = word:gsub("^%s+", ""):gsub("%s+$", "")
        if CARD_TYPES[word] then
          st.add_types[word] = true
        else
          st.add_subtypes[#st.add_subtypes + 1] = word
        end
      end
    end
    st.remove_card_types = params.RemoveCardTypes == "True"
    st.remove_creature_types = params.RemoveCreatureTypes == "True"
    st.remove_all_abilities = params.RemoveAllAbilities == "True"
    st.set_colors = params.SetColor and parse_colors(params.SetColor, reasons)
    st.add_colors = params.AddColor and parse_colors(params.AddColor, reasons)
    st.set_name = params.SetName
    if params.AddAbility then
      local text = svars[params.AddAbility]
      st.added_mana = parse_added_mana(text, reasons)
    end
    st.changes_object = st.add_types or st.remove_card_types or st.remove_creature_types or st.remove_all_abilities
        or st.set_colors or st.add_colors or st.set_name or st.added_mana
    st.add_power = parse_amount(params, "AddPower", svars, reasons)
    st.add_toughness = parse_amount(params, "AddToughness", svars, reasons)
    st.set_power = parse_amount(params, "SetPower", svars, reasons)
    st.set_toughness = parse_amount(params, "SetToughness", svars, reasons)
    st.add_keywords = parse_keywords(params.AddKeyword, reasons, supported_keywords)
    st.remove_keywords = parse_keywords(params.RemoveKeyword, reasons, supported_keywords)
    if params.AddHiddenKeyword then
      st.add_keywords = st.add_keywords or {}
      for kw in pairs(parse_keywords("HIDDEN " .. params.AddHiddenKeyword:gsub("&", "& HIDDEN "), reasons, supported_keywords)) do
        st.add_keywords[kw] = true
      end
    end
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
  return { game = game, you = source.controller, self = source, remembered = source.remembered }
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
-- Statics work from the battlefield and from temporary effects (game.effects), except
-- EffectZone$ All ones on a spell's own card (cost reductions), which statics.cost_reduction
-- looks up directly.
local function each_static(game, mode)
  local list = {}
  local function add(source)
    if source.mods and source.mods.no_abilities then
      return   -- lost all abilities (layer 6)
    end
    for _, st in ipairs(source.def.statics or {}) do
      if (mode == nil or st.mode == mode or (st.mode == "CantAttack,CantBlock" and (mode == "CantAttack" or mode == "CantBlock")))
          and active(game, source, st) then
        list[#list + 1] = { source = source, st = st }
      end
    end
  end
  for _, player in ipairs(game.players) do
    for _, source in ipairs(player.battlefield) do
      add(source)
    end
  end
  for _, effect in ipairs(game.effects or {}) do
    add(effect)
  end
  return list
end

local function affected_cards(game, source, st)
  if st.affects_you or st.may_play then
    return {}   -- see statics.extra_land_plays and statics.may_play_cards
  end
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

local function new_mods()
  return { power = 0, toughness = 0, added = {}, removed = {} }
end

local function copy_set(set)
  local copy = {}
  for k in pairs(set) do
    copy[k] = true
  end
  return copy
end

-- Creature types are the subtypes a creature can have; others (Aura, Equipment, Vehicle, land
-- types) stay when an effect removes creature types. The pool's cards only need this split.
local NON_CREATURE_SUBTYPES = { Aura = true, Equipment = true, Vehicle = true, Book = true, Plains = true,
                                Island = true, Swamp = true, Mountain = true, Forest = true }

-- Layers 3-6 for one card: name, types, colors, losing abilities, added mana abilities.
local function apply_object_change(card, m, st)
  local def = card.def
  if st.set_name then
    m.name = st.set_name
  end
  if st.remove_card_types or st.add_types then
    m.types = st.remove_card_types and {} or copy_set(m.types or def.types)
    for t in pairs(st.add_types or {}) do
      m.types[t] = true
    end
  end
  if st.remove_creature_types or st.add_subtypes then
    local subtypes = {}
    for _, sub in ipairs(m.subtypes or def.subtypes) do
      if not st.remove_creature_types or NON_CREATURE_SUBTYPES[sub] then
        subtypes[#subtypes + 1] = sub
      end
    end
    for _, sub in ipairs(st.add_subtypes or {}) do
      subtypes[#subtypes + 1] = sub
    end
    m.subtypes = subtypes
  end
  if st.set_colors then
    m.colors = copy_set(st.set_colors)
  end
  if st.add_colors then
    m.colors = copy_set(m.colors or def.colors)
    for c in pairs(st.add_colors) do
      m.colors[c] = true
    end
  end
  if st.remove_all_abilities then
    m.no_abilities = true
    m.added_mana = nil
  end
  if st.added_mana then
    m.added_mana = m.added_mana or {}
    m.added_mana[#m.added_mana + 1] = st.added_mana
  end
end

-- Recomputes card.mods for every card on the battlefield. Pass 1 applies layers 3-6 object
-- changes (types, colors, name, losing abilities); their results are visible to pass 2, which
-- skips statics of sources that lost their abilities and applies keywords and P/T (layers 6-7).
function statics.apply(game)
  for _, player in ipairs(game.players) do
    for _, card in ipairs(player.battlefield) do
      card.mods = nil
    end
  end
  local objects = {}
  for _, entry in ipairs(each_static(game, "Continuous")) do
    if entry.st.changes_object then
      for _, card in ipairs(affected_cards(game, entry.source, entry.st)) do
        objects[card] = objects[card] or new_mods()
        apply_object_change(card, objects[card], entry.st)
      end
    end
  end
  for card, m in pairs(objects) do
    card.mods = m
  end

  local results = {}
  for _, entry in ipairs(each_static(game, "Continuous")) do
    local source, st = entry.source, entry.st
    local ctx = { game = game, source = source, controller = source.controller }
    for _, card in ipairs(affected_cards(game, source, st)) do
      local m = results[card]
      if m == nil then
        m = new_mods()
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
    local o = objects[card]
    if o then
      for _, key in ipairs({ "name", "types", "subtypes", "colors", "no_abilities", "added_mana" }) do
        m[key] = o[key]
      end
    end
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

-- Additional lands `player` may play this turn (AdjustLandPlays).
function statics.extra_land_plays(game, player)
  local n = 0
  for _, entry in ipairs(each_static(game, "Continuous")) do
    if entry.st.land_plays and entry.source.controller == player then
      n = n + entry.st.land_plays
    end
  end
  return n
end

-- Cards in exile that `player` may play (MayPlay statics they control).
function statics.may_play_cards(game, player)
  local list, seen = {}, {}
  for _, entry in ipairs(each_static(game, "Continuous")) do
    if entry.st.may_play and entry.source.controller == player then
      for _, p in ipairs(game.players) do
        for _, card in ipairs(p.exile) do
          if not seen[card] and filter.matches(entry.st.affected, card, fctx(game, entry.source)) then
            seen[card] = true
            list[#list + 1] = card
          end
        end
      end
    end
  end
  return list
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
