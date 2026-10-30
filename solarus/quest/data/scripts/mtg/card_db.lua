-- Card definitions built from parsed Forge scripts, and the check for what the engine supports.
--
-- A definition is shared by every copy of a card:
--   { name, mana_cost (mana.parse_cost), mana_value, supertypes = {Legendary=true}, types = {Creature=true},
--     subtypes = { "Cat", "Soldier" }, power, toughness, keywords = { Flying = true },
--     mana_abilities = { { colors = { "G" } } }, supported, unsupported = { "reason", ... }, script }
-- Unsupported cards still load (so the UI can show them) but can't be put into a duel deck.
-- Reference: forge-game card/CardFactory.readCardFace, card/CardFactoryUtil (keywords).

local script_parser = require("scripts/mtg/script_parser")
local mana = require("scripts/mtg/mana")

local card_db = {}

local SUPERTYPES = { Basic = true, Legendary = true, Snow = true, World = true, Ongoing = true }
local CARD_TYPES = {
  Artifact = true, Battle = true, Creature = true, Enchantment = true, Instant = true,
  Kindred = true, Land = true, Planeswalker = true, Sorcery = true,
}
-- CR 305.6: basic land types have an intrinsic "{T}: Add <color>" ability.
local BASIC_LAND_MANA = { Plains = "W", Island = "U", Swamp = "B", Mountain = "R", Forest = "G" }

-- Keywords the rules engine implements. Add a keyword here only once it really works.
card_db.SUPPORTED_KEYWORDS = {
  ["Flying"] = true, ["Reach"] = true, ["Vigilance"] = true, ["Haste"] = true, ["Defender"] = true,
  ["First Strike"] = true, ["Double Strike"] = true, ["Trample"] = true, ["Deathtouch"] = true,
  ["Lifelink"] = true, ["Menace"] = true, ["Flash"] = true, ["Indestructible"] = true,
}

-- Card types the engine can cast/play so far (permanent spells with no spell abilities, and lands).
local PLAYABLE_TYPES = { Creature = true, Artifact = true, Land = true }

local MANA_ABILITY_PARAMS = { AB = true, Cost = true, Produced = true, SpellDescription = true }

local function parse_mana_ability(params)
  if params.AB ~= "Mana" or params.Cost ~= "T" or params.Produced == nil then
    return nil
  end
  for key in pairs(params) do
    if not MANA_ABILITY_PARAMS[key] then
      return nil
    end
  end
  local colors = mana.parse_produced(params.Produced)
  if colors == nil then
    return nil
  end
  return { colors = colors }
end

function card_db.build_definition(text)
  local script = script_parser.parse(text)
  local face = script.faces[1]
  local def = {
    name = face.name,
    supertypes = {}, types = {}, subtypes = {},
    keywords = {}, mana_abilities = {},
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

  local cost, cost_problem = mana.parse_cost(face.mana_cost)
  def.mana_cost = cost
  def.mana_value = mana.mana_value(cost)
  if cost_problem then
    unsupported(cost_problem)
  elseif cost == nil and not def.types.Land then
    unsupported("no mana cost")
  end

  if face.pt then
    local p, t = face.pt:match("^(%-?%d+)/(%-?%d+)$")
    if p then
      def.power, def.toughness = tonumber(p), tonumber(t)
    else
      unsupported("P/T " .. face.pt)
    end
  elseif def.types.Creature then
    unsupported("creature without P/T")
  end

  for _, keyword in ipairs(face.keywords) do
    local name = keyword:match("^([^:]+)")
    def.keywords[name] = true
    if not card_db.SUPPORTED_KEYWORDS[keyword] then
      unsupported("keyword " .. keyword)
    end
  end

  for _, params in ipairs(face.abilities) do
    local ability = parse_mana_ability(params)
    if ability then
      def.mana_abilities[#def.mana_abilities + 1] = ability
    else
      unsupported("ability " .. (params.SP and ("SP$ " .. params.SP) or params.AB and ("AB$ " .. params.AB) or "?"))
    end
  end
  for _, subtype in ipairs(def.subtypes) do
    if def.types.Land and BASIC_LAND_MANA[subtype] then
      def.mana_abilities[#def.mana_abilities + 1] = { colors = { BASIC_LAND_MANA[subtype] } }
    end
  end

  for _, params in ipairs(face.triggers) do
    unsupported("trigger " .. tostring(params.Mode))
  end
  for _, params in ipairs(face.statics) do
    unsupported("static " .. tostring(params.Mode))
  end
  for _, params in ipairs(face.replacements) do
    unsupported("replacement " .. tostring(params.Event))
  end

  def.supported = #def.unsupported == 0
  return def
end

-- read_file(path) -> text; paths are relative to the quest data folder ("cards/x.txt").
-- pool is the table returned by cards/pool.lua.
function card_db.new(pool, read_file)
  local db = { by_name = {}, list = {} }
  for _, entry in ipairs(pool) do
    local def = card_db.build_definition(read_file("cards/" .. entry.file))
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
