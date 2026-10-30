-- A card in a game: one physical card with its own state (zone, tapped, damage, ...).
-- Characteristics are read through methods: base values from the definition, then continuous
-- effects from static abilities (statics.lua, recomputed lazily by the game), then until-end-of-turn
-- pumps. Reference: forge-game card/Card, staticability/StaticAbilityContinuous (layers).

local Card = {}
Card.__index = Card

function Card.new(def, owner, id, game)
  return setmetatable({
    def = def,
    id = id,
    game = game,
    owner = owner,
    controller = owner,
    base_controller = owner, -- controller without control-changing effects (layer 2)
    zone = nil,           -- "library", "hand", "battlefield", "graveyard", "exile", "stack"
    tapped = false,
    sick = false,         -- summoning sick: hasn't been under its controller's control since their turn began
    damage = 0,
    deathtouch_damage = false,
    pumps = {},           -- until-end-of-turn changes: { { power =, toughness =, keywords = { Flying = true } } }
    chosen_color = nil,   -- "W".."G", chosen as it entered (ChooseColor)
    attached_to = nil,    -- for Auras and Equipment: the permanent (or player) it's attached to
    linked_exiles = nil,  -- cards exiled "until this leaves the battlefield"
    mods = nil,           -- continuous-effect results for this card (statics.lua), or nil
  }, Card)
end

function Card:__tostring()
  return self.def.name .. "#" .. self.id
end

-- Brings static-ability results up to date before a characteristic is read.
local function mods(card)
  local game = card.game
  if game and card.zone == "battlefield" then
    game:ensure_statics()
  end
  return card.mods
end

-- Layer 3 text: SetName (Witness Protection).
function Card:name()
  local m = mods(self)
  return (m and m.name) or self.def.name
end

-- Layer 4: card types after type-changing effects, plus until-end-of-turn ones (Animate, Crew).
local function types_of(card)
  local m = mods(card)
  local types = (m and m.types) or card.def.types
  for _, pump in ipairs(card.pumps) do
    if pump.types then
      local merged = {}
      for t in pairs(types) do
        merged[t] = true
      end
      for t in pairs(pump.types) do
        merged[t] = true
      end
      types = merged
    end
  end
  return types
end

function Card:is_type(card_type)
  return types_of(self)[card_type] == true
end

function Card:is_creature()
  return self:is_type("Creature")
end

function Card:is_land()
  return self:is_type("Land")
end

function Card:is_permanent_card()
  local t = types_of(self)
  return t.Creature or t.Artifact or t.Enchantment or t.Land or t.Planeswalker or t.Battle or false
end

function Card:is_legendary()
  return self.def.supertypes.Legendary == true
end

-- Subtypes (CR 205.3); a Changeling has every creature type (CR 702.73a), Kindred cards too.
function Card:has_subtype(subtype)
  local m = mods(self)
  for _, s in ipairs((m and m.subtypes) or self.def.subtypes) do
    if s == subtype then
      return true
    end
  end
  if (self:is_creature() or self:is_type("Kindred")) and self:has_keyword("Changeling")
      and not (subtype == "Aura" or subtype == "Equipment") then
    return true
  end
  return false
end

function Card:is_aura()
  return self:is_type("Enchantment") and self:has_subtype("Aura")
end

function Card:is_equipment()
  return self:is_type("Artifact") and self:has_subtype("Equipment")
end

local function pump_total(card, field)
  local value = 0
  for _, pump in ipairs(card.pumps) do
    value = value + (pump[field] or 0)
  end
  return value
end

-- Base P/T set by an until-end-of-turn effect (Animate), the newest one.
local function pump_set(card, field)
  local value
  for _, pump in ipairs(card.pumps) do
    value = pump[field] or value
  end
  return value
end

-- Layer 7: characteristic-defining / setting effects, then modifications, then pumps.
function Card:power()
  local m = mods(self)
  local value = pump_set(self, "set_power") or (m and m.set_power) or self.def.power or 0
  return value + (m and m.power or 0) + pump_total(self, "power")
end

function Card:toughness()
  local m = mods(self)
  local value = pump_set(self, "set_toughness") or (m and m.set_toughness) or self.def.toughness or 0
  return value + (m and m.toughness or 0) + pump_total(self, "toughness")
end

-- Layer 6: has it lost all abilities (Eaten by Piranhas, Imprisoned in the Moon)?
function Card:abilities_lost()
  local m = mods(self)
  return (m and m.no_abilities) or false
end

-- Layer 6: keywords from the card, static abilities and pumps, minus removed ones.
function Card:has_keyword(keyword)
  local m = mods(self)
  if m and m.removed[keyword] then
    return false
  end
  if (self.def.keywords[keyword] and not (m and m.no_abilities)) or (m and m.added[keyword]) then
    return true
  end
  for _, pump in ipairs(self.pumps) do
    if pump.keywords and pump.keywords[keyword] then
      return true
    end
  end
  return false
end

local NONE = {}

-- The card's abilities as it is now (none once it has lost all abilities).
function Card:triggers()
  return self:abilities_lost() and NONE or self.def.triggers
end

function Card:activated()
  return self:abilities_lost() and NONE or self.def.activated
end

function Card:statics()
  return self:abilities_lost() and NONE or self.def.statics
end

function Card:mana_abilities()
  local m = mods(self)
  local base = (m and m.no_abilities) and NONE or self.def.mana_abilities
  if m and m.added_mana then
    local list = {}
    for _, a in ipairs(base) do
      list[#list + 1] = a
    end
    for _, a in ipairs(m.added_mana) do
      list[#list + 1] = a
    end
    return list
  end
  return base
end

-- Until-end-of-turn power/toughness/keyword change (PumpEffect); removed in cleanup.
function Card:add_pump(power, toughness, keywords)
  table.insert(self.pumps, { power = power, toughness = toughness, keywords = keywords })
  if self.game then
    self.game.statics_dirty = true
  end
end

-- Until end of turn, becomes `types` too, with base P/T set if given (Animate, Crew).
function Card:add_animation(types, set_power, set_toughness)
  table.insert(self.pumps, { types = types, set_power = set_power, set_toughness = set_toughness })
  if self.game then
    self.game.statics_dirty = true
  end
end

-- Layer 5: colors after color-setting effects.
local function colors_of(card)
  local m = mods(card)
  return (m and m.colors) or card.def.colors
end

function Card:has_color(color)
  return colors_of(self)[color] == true
end

function Card:color_count()
  local n = 0
  for _ in pairs(colors_of(self)) do
    n = n + 1
  end
  return n
end

function Card:mana_value()
  return self.def.mana_value
end

-- CR 400.7: a card that changes zones becomes a new object with no memory of its previous state.
function Card:reset_state()
  self.tapped = false
  self.sick = false
  self.damage = 0
  self.deathtouch_damage = false
  self.pumps = {}
  self.chosen_color = nil
  self.attached_to = nil
  self.mods = nil
  self.controller = self.owner
  self.base_controller = self.owner
  self.kicked = nil                  -- entered from a kicked spell
  self.cast_from_graveyard = nil     -- on the stack after being cast from a graveyard
  self.granted_flashback_turn = nil  -- turn it was given flashback (Flashback, Sphinx of Forgotten Lore)
  self.exile_if_dies_turn = nil      -- turn of an "if it would die this turn, exile it instead" effect
  self.skip_next_untap = nil
end

return Card
