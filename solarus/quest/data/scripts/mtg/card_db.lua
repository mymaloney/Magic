-- Card definitions built from parsed Forge scripts, and the check for what the engine supports.
--
-- A definition is shared by every copy of a card:
--   { name, mana_cost (mana.parse_cost), mana_value, supertypes = {Legendary=true}, types = {Creature=true},
--     subtypes = { "Cat", "Soldier" }, power, toughness, keywords = { Flying = true },
--     mana_abilities = { { colors = { "G" } } }, spell = ability chain (instants/sorceries),
--     triggers = { trigger, ... }, activated = { { ability, cost, limit, zone, sorcery } },
--     etb_replacements = { ability, ... }, supported, unsupported = { "reason", ... }, script }
-- Unsupported cards still load (so the UI can show them) but can't be put into a duel deck.
-- Reference: forge-game card/CardFactory.readCardFace, card/CardFactoryUtil (keywords).

local script_parser = require("scripts/mtg/script_parser")
local mana = require("scripts/mtg/mana")
local keywords = require("scripts/mtg/keywords")
local abilities = require("scripts/mtg/abilities")
local effects = require("scripts/mtg/effects")
local triggers = require("scripts/mtg/triggers")
local replacements = require("scripts/mtg/replacements")
local cost_lib = require("scripts/mtg/cost")
local statics = require("scripts/mtg/statics")
local filter = require("scripts/mtg/filter")

local card_db = {}

local SUPERTYPES = { Basic = true, Legendary = true, Snow = true, World = true, Ongoing = true }
local CARD_TYPES = {
  Artifact = true, Battle = true, Creature = true, Enchantment = true, Instant = true,
  Kindred = true, Land = true, Planeswalker = true, Sorcery = true,
}
-- CR 305.6: basic land types have an intrinsic "{T}: Add <color>" ability.
local BASIC_LAND_MANA = { Plains = "W", Island = "U", Swamp = "B", Mountain = "R", Forest = "G" }

card_db.SUPPORTED_KEYWORDS = keywords.SUPPORTED

-- Card types the engine can cast/play so far.
local PLAYABLE_TYPES = { Creature = true, Artifact = true, Land = true, Instant = true, Sorcery = true, Enchantment = true }

local MANA_ABILITY_PARAMS = {
  AB = true, Cost = true, Produced = true, SpellDescription = true, ActivationLimit = true, AILogic = true,
}

-- { colors, tap, extra, sacrifice, limit } for mana abilities the auto-payer can use, else nil.
local function parse_mana_ability(params)
  if params.AB ~= "Mana" or params.Produced == nil then
    return nil
  end
  for key in pairs(params) do
    if not MANA_ABILITY_PARAMS[key] then
      return nil
    end
  end
  local colors = mana.parse_produced(params.Produced)
  local parsed = cost_lib.parse(params.Cost)
  local spec = parsed and cost_lib.mana_ability_cost(parsed)
  if colors == nil or spec == nil then
    return nil
  end
  spec.colors = colors
  spec.limit = tonumber(params.ActivationLimit or "")
  return spec
end

-- Activated-ability parameters handled here rather than by the effect.
local ACTIVATION_PARAMS = {
  Cost = true, ActivationLimit = true, ActivationZone = true, SorcerySpeed = true,
  PrecostDesc = true, CostDesc = true,
}

local function parse_activated(params, svars, reasons)
  local effect_params = {}
  for k, v in pairs(params) do
    if not ACTIVATION_PARAMS[k] then
      effect_params[k] = v
    end
  end
  local parsed, problem = cost_lib.parse(params.Cost)
  if parsed == nil then
    reasons[#reasons + 1] = tostring(problem)
  end
  local zone = "battlefield"
  if params.ActivationZone then
    zone = abilities.ZONES[params.ActivationZone]
    if zone ~= "graveyard" then
      reasons[#reasons + 1] = "ActivationZone$ " .. params.ActivationZone
    end
  end
  return {
    ability = abilities.build(effect_params, svars, reasons, effects),
    cost = parsed,
    limit = tonumber(params.ActivationLimit or ""),
    zone = zone,
    sorcery = params.SorcerySpeed == "True",
  }
end

function card_db.build_definition(text)
  local script = script_parser.parse(text)
  local face = script.faces[1]
  local def = {
    name = face.name,
    supertypes = {}, types = {}, subtypes = {},
    keywords = {}, mana_abilities = {}, triggers = {}, etb_replacements = {}, activated = {}, statics = {},
    unsupported = {},
    script = script,
  }
  local function unsupported(reason)
    def.unsupported[#def.unsupported + 1] = reason
  end

  if script.layout ~= nil then
    unsupported("layout " .. script.layout)
  end

  for word in (face.types or ""):gmatch("%S+") do
    if SUPERTYPES[word] then
      def.supertypes[word] = true
    elseif CARD_TYPES[word] then
      def.types[word] = true
    else
      def.subtypes[#def.subtypes + 1] = word
    end
  end
  local any_type = false
  for t in pairs(def.types) do
    any_type = true
    if not PLAYABLE_TYPES[t] then
      unsupported("card type " .. t)
    end
  end
  if not any_type then
    unsupported("no card type")
  end

  -- Colors (CR 105.2): the Colors: line (color indicator) or the mana cost's colored symbols.
  def.colors = {}
  local COLOR_WORDS = { white = "W", blue = "U", black = "B", red = "R", green = "G" }
  if face.colors then
    for word in face.colors:gmatch("[^,]+") do
      if COLOR_WORDS[word] then
        def.colors[COLOR_WORDS[word]] = true
      end
    end
  else
    for symbol in (face.mana_cost or ""):gmatch("[WUBRG]") do
      def.colors[symbol] = true
    end
  end

  local cost, cost_problem = mana.parse_cost(face.mana_cost)
  if cost and cost.x > 0 and not (def.types.Instant or def.types.Sorcery) then
    unsupported("X in a permanent's cost")
  end
  def.mana_cost = cost
  def.mana_value = mana.mana_value(cost)
  if cost_problem then
    unsupported(cost_problem)
  elseif cost == nil and not def.types.Land then
    unsupported("no mana cost")
  end

  if face.pt then
    local p, t = face.pt:match("^(%-?%d+%*?)/(%-?%d+%*?)$")
    if p then
      -- "*" is defined by a characteristic-defining static ability (checked below)
      def.power, def.toughness = tonumber(p) or 0, tonumber(t) or 0
      def.cda_power, def.cda_toughness = p == "*", t == "*"
    else
      unsupported("P/T " .. face.pt)
    end
  elseif def.types.Creature then
    unsupported("creature without P/T")
  end

  for _, keyword in ipairs(face.keywords) do
    local name = keyword:match("^([^:]+)")
    if name == "ETBReplacement" then
      replacements.parse_keyword(def, keyword, face.svars, def.unsupported, effects)
    elseif name == "Enchant" then
      -- Aura (CR 303.4): cast targeting what it can enchant; it enters attached to it.
      local what = keyword:match("^Enchant:([^:]+)")
      def.spell = abilities.build({ SP = "Attach", ValidTgts = what }, face.svars, def.unsupported, effects)
      local logic = face.svars.AttachAILogic
      def.spell.harmful_attach = logic == "Curse" or logic == "GainControl"
      local parsed, problem = filter.parse(what or "")
      def.enchant_filter = parsed
      if parsed == nil then
        unsupported(problem)
      end
    elseif name == "Prowess" then
      -- Prowess (CR 702.108): whenever you cast a noncreature spell, +1/+1 until end of turn.
      local svars = { ProwessPump = "DB$ Pump | Defined$ Self | NumAtt$ +1 | NumDef$ +1" }
      def.triggers[#def.triggers + 1] = triggers.parse({
        Mode = "SpellCast", ValidCard = "Card.nonCreature", ValidActivatingPlayer = "You",
        TriggerZones = "Battlefield", Execute = "ProwessPump",
      }, svars, def.unsupported, effects)
    elseif name == "Flashback" or name == "Kicker" then
      local text = keyword:match("^%a+:(.+)$")
      local parsed, problem = mana.parse_cost(text or "")
      if parsed == nil then
        unsupported("keyword " .. keyword .. (problem and (" (" .. problem .. ")") or ""))
      end
      def[name:lower() .. "_cost"] = parsed
      def.keywords[name] = true
    elseif name == "Equip" then
      -- Equip N (CR 702.6): sorcery-speed "attach to target creature you control".
      local n = keyword:match("^Equip:(%d+)$")
      if n == nil then
        unsupported("keyword " .. keyword)
      else
        def.activated[#def.activated + 1] = {
          ability = abilities.build({ AB = "Attach", ValidTgts = "Creature.YouCtrl" }, face.svars, def.unsupported, effects),
          cost = cost_lib.parse(n), zone = "battlefield", sorcery = true, equip = true,
        }
      end
    else
      def.keywords[name] = true
      if not card_db.SUPPORTED_KEYWORDS[keyword] then
        unsupported("keyword " .. keyword)
      end
    end
  end

  local is_spell_card = def.types.Instant or def.types.Sorcery
  for _, params in ipairs(face.abilities) do
    local ability = parse_mana_ability(params)
    if ability then
      def.mana_abilities[#def.mana_abilities + 1] = ability
    elseif params.AB and params.AB ~= "Mana" then
      def.activated[#def.activated + 1] = parse_activated(params, face.svars, def.unsupported)
    elseif params.SP and is_spell_card and def.spell == nil then
      local spell_params = params
      if params.Cost then
        -- Cost$ on a spell = its mana cost plus additional costs (discard, sacrifice, ...).
        local parsed, problem = cost_lib.parse(params.Cost)
        if parsed == nil then
          unsupported(tostring(problem))
        else
          parsed.mana = nil
          def.extra_cost = parsed
        end
        spell_params = {}
        for k, v in pairs(params) do
          if k ~= "Cost" and k ~= "CostDesc" then
            spell_params[k] = v
          end
        end
      end
      def.spell = abilities.build(spell_params, face.svars, def.unsupported, effects)
    else
      unsupported("ability " .. (params.SP and ("SP$ " .. params.SP) or params.AB and ("AB$ " .. params.AB) or "?"))
    end
  end
  if is_spell_card and def.spell == nil then
    unsupported("instant/sorcery without a spell ability")
  end
  for _, subtype in ipairs(def.subtypes) do
    if def.types.Land and BASIC_LAND_MANA[subtype] then
      def.mana_abilities[#def.mana_abilities + 1] = { colors = { BASIC_LAND_MANA[subtype] }, tap = true, extra = 0, sacrifice = false }
    end
  end

  for _, params in ipairs(face.triggers) do
    local trigger = triggers.parse(params, face.svars, def.unsupported, effects)
    if trigger then
      def.triggers[#def.triggers + 1] = trigger
    end
  end
  for _, params in ipairs(face.statics) do
    local st = statics.parse(params, face.svars, def.unsupported, keywords.SUPPORTED)
    if st then
      def.statics[#def.statics + 1] = st
    end
  end
  for _, params in ipairs(face.replacements) do
    replacements.parse(def, params, face.svars, def.unsupported, effects)
  end

  -- "*" power/toughness needs a characteristic-defining static ability that sets it.
  local sets_power, sets_toughness = false, false
  for _, st in ipairs(def.statics) do
    if st.params.CharacteristicDefining == "True" then
      sets_power = sets_power or st.set_power ~= nil
      sets_toughness = sets_toughness or st.set_toughness ~= nil
    end
  end
  if (def.cda_power and not sets_power) or (def.cda_toughness and not sets_toughness) then
    unsupported("P/T " .. tostring(face.pt))
  end

  def.supported = #def.unsupported == 0
  return def
end

-- read_file(path) -> text; paths are relative to the quest data folder ("cards/x.txt").
-- pool is the table returned by cards/pool.lua.
function card_db.new(pool, read_file)
  local db = { by_name = {}, list = {} }
  local texts = {}
  -- First pass: every subtype, so filters like "Creature.Wall" or "Forest.YouCtrl" can be parsed.
  for i, entry in ipairs(pool) do
    texts[i] = read_file("cards/" .. entry.file)
    for types in texts[i]:gmatch("\nTypes:([^\n]*)") do
      for word in types:gmatch("%S+") do
        if not SUPERTYPES[word] and not CARD_TYPES[word] then
          filter.known_subtypes[word] = true
        end
      end
    end
  end
  for i, entry in ipairs(pool) do
    local def = card_db.build_definition(texts[i])
    def.copies = entry.copies
    db.by_name[def.name] = def
    db.list[#db.list + 1] = def
  end

  function db.get(name)
    return db.by_name[name] or error("unknown card: " .. tostring(name))
  end

  -- { "Savannah Lions", "Plains", ... } or { ["Plains"] = 17, ... } -> list of definitions.
  -- Errors on unsupported cards so a duel never starts with cards the engine can't run.
  function db.make_deck(spec)
    local deck = {}
    local function add(name, count)
      local def = db.get(name)
      if not def.supported then
        error(name .. " is not supported yet: " .. table.concat(def.unsupported, ", "))
      end
      for _ = 1, count do
        deck[#deck + 1] = def
      end
    end
    if spec[1] ~= nil then
      for _, name in ipairs(spec) do
        add(name, 1)
      end
    else
      local names = {}
      for name in pairs(spec) do
        names[#names + 1] = name
      end
      table.sort(names)
      for _, name in ipairs(names) do
        add(name, spec[name])
      end
    end
    return deck
  end

  return db
end

return card_db
