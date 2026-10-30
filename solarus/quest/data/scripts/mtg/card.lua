-- A card in a game: one physical card with its own state (zone, tapped, damage, ...).
-- Characteristics are read through methods so continuous effects (layers) can hook in later.
-- Reference: forge-game card/Card.

local Card = {}
Card.__index = Card

function Card.new(def, owner, id)
  return setmetatable({
    def = def,
    id = id,
    owner = owner,
    controller = owner,
    zone = nil,           -- "library", "hand", "battlefield", "graveyard", "exile", "stack"
    tapped = false,
    sick = false,         -- summoning sick: hasn't been under its controller's control since their turn began
    damage = 0,
    deathtouch_damage = false,
  }, Card)
end

function Card:__tostring()
  return self.def.name .. "#" .. self.id
end

function Card:name()
  return self.def.name
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

function Card:power()
  return self.def.power or 0
end

function Card:toughness()
  return self.def.toughness or 0
end

function Card:has_keyword(keyword)
  return self.def.keywords[keyword] == true
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
  self.controller = self.owner
end

return Card
