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

function Card:name()
  return self.def.name
end

-- Brings static-ability results up to date before a characteristic is read.
local function mods(card)
  local game = card.game
  if game and card.zone == "battlefield" then
    game:ensure_statics()
  end
  return card.mods
end

function Card:is_type(card_type)
  return self.def.types[card_type] == true
end

function Card:is_creature()
  return self.def.types.Creature == true
end

function Card:is_land()
  return self.def.types.Land == true
end

function Card:is_permanent_card()
  local t = self.def.types
  return t.Creature or t.Artifact or t.Enchantment or t.Land or t.Planeswalker or t.Battle or false
end

function Card:is_legendary()
  return self.def.supertypes.Legendary == true
end

-- Subtypes (CR 205.3); a Changeling has every creature type.
function Card:has_subtype(subtype)
  for _, s in ipairs(self.def.subtypes) do
    if s == subtype then
      return true
    end
  end
  if self.def.keywords.Changeling and self:is_creature() and not (subtype == "Aura" or subtype == "Equipment") then
    return true
  end
  return false
end

function Card:is_aura()
  return self.def.types.Enchantment == true and self:has_subtype("Aura")
end

function Card:is_equipment()
  return self.def.types.Artifact == true and self:has_subtype("Equipment")
end

local function pump_total(card, field)
  local value = 0
  for _, pump in ipairs(card.pumps) do
    value = value + (pump[field] or 0)
  end
  return value
end

-- Layer 7: characteristic-defining / setting effects, then modifications, then pumps.
function Card:power()
  local m = mods(self)
  local value = (m and m.set_power) or self.def.power or 0
  return value + (m and m.power or 0) + pump_total(self, "power")
end

function Card:toughness()
  local m = mods(self)
  local value = (m and m.set_toughness) or self.def.toughness or 0
  return value + (m and m.toughness or 0) + pump_total(self, "toughness")
end

-- Layer 6: keywords from the card, static abilities and pumps, minus removed ones.
function Card:has_keyword(keyword)
  local m = mods(self)
  if m and m.removed[keyword] then
    return false
  end
  if self.def.keywords[keyword] or (m and m.added[keyword]) then
    return true
  end
  for _, pump in ipairs(self.pumps) do
    if pump.keywords and pump.keywords[keyword] then
      return true
    end
  end
  return false
end

-- Until-end-of-turn power/toughness/keyword change (PumpEffect); removed in cleanup.
function Card:add_pump(power, toughness, keywords)
  table.insert(self.pumps, { power = power, toughness = toughness, keywords = keywords })
  if self.game then
    self.game.statics_dirty = true
  end
end

function Card:has_color(color)
  return self.def.colors[color] == true
end

function Card:color_count()
  local n = 0
  for _ in pairs(self.def.colors) do
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
