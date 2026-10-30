-- Ways to cast a card besides paying its mana cost (alternative costs, choices of additional
-- cost, flash for a price, creature spells with additional costs), Fight from an Aura and lure.
-- Outcomes follow the card text and Forge's implementations.

local function cast_variant(name, label)
  return function(game, player, actions)
    for _, action in ipairs(actions) do
      if action.kind == "cast" and action.card:name() == name then
        local v = action.variant and action.card.def.cast_variants[action.variant]
        if (label == nil and v == nil) or (v and v.label == label) then
          return action
        end
      end
    end
  end
end

local function pick(name)
  return function(game, player, ability, candidates)
    for _, c in ipairs(candidates) do
      if c.life == nil and c:name() == name then
        return { c }
      end
    end
  end
end

local function actions_for(game, player, name)
  local list = {}
  for _, action in ipairs(game:legal_actions(player)) do
    if action.kind == "cast" and action.card:name() == name then
      list[#list + 1] = action
    end
  end
  return list
end

return function(t)
  t.section("alternative cost on your turn: Mine Collapse")
  do
    local game = t.setup({ { battlefield = { "Mountain" }, hand = { "Mine Collapse" },
                             controller = t.scripted({ actions = { cast_variant("Mine Collapse", "Alt. cost") },
                                                       targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, "5 damage without paying mana")
    t.check(t.find(game.players[1].graveyard, "Mountain") ~= nil, "Mountain sacrificed")
    -- not on the opponent's turn
    local game2 = t.setup({ { battlefield = { "Mountain" } }, { battlefield = { "Serra Angel" }, hand = { "Mine Collapse" } } })
    t.eq(#actions_for(game2, game2.players[2], "Mine Collapse"), 0, "not castable for the alternative cost on the opponent's turn")
  end

  t.section("choice of additional cost: Eaten Alive")
  for _, label in ipairs({ "Pay Sac<1/Creature>", "Pay 3 B" }) do
    local game = t.setup({ { battlefield = { "Swamp", "Swamp", "Swamp", "Swamp", "Swamp", "Savannah Lions" }, hand = { "Eaten Alive" },
                             controller = t.scripted({ actions = { cast_variant("Eaten Alive", label) },
                                                       targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    t.eq(#actions_for(game, game.players[1], "Eaten Alive"), 0, "nothing castable outside the main phase")
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(game.players[2].exile, "Serra Angel") ~= nil, label .. ": target exiled")
    local sacrificed = t.find(p1.graveyard, "Savannah Lions") ~= nil
    t.eq(sacrificed, label == "Pay Sac<1/Creature>", label .. ": sacrificed only for that choice")
  end
  do
    local game = t.setup({ { battlefield = { "Swamp" }, hand = { "Eaten Alive" } }, { battlefield = { "Serra Angel" } } })
    game.step = "main1"
    t.eq(#actions_for(game, game.players[1], "Eaten Alive"), 0, "can't cast it for just {B}")
  end

  t.section("flash for {2} more: Harbinger of the Tides")
  do
    local game = t.setup({ { battlefield = { "Island", "Island", "Island", "Island" }, hand = { "Harbinger of the Tides" } },
                           { battlefield = { "Serra Angel" } } })
    local p1 = game.players[1]
    game.step = "main1"
    local main = actions_for(game, p1, "Harbinger of the Tides")
    t.check(#main == 1 and main[1].variant == nil, "in the main phase: the normal cast only")
    game.step = "end_of_turn"
    game.active = game.players[2]
    local instant = actions_for(game, p1, "Harbinger of the Tides")
    t.check(#instant == 1 and instant[1].variant ~= nil, "at instant speed: the flash variant")
  end

  t.section("creature spell with an additional cost: Arbiter of Woe")
  do
    local game = t.setup({ { battlefield = { "Swamp", "Swamp", "Swamp", "Swamp", "Swamp", "Swamp", "Savannah Lions" },
                             hand = { "Arbiter of Woe" },
                             controller = t.scripted({ actions = { cast_variant("Arbiter of Woe") } }) },
                           { hand = { "Plains" } } })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(p1.battlefield, "Arbiter of Woe") ~= nil, "cast")
    t.check(t.find(p1.graveyard, "Savannah Lions") ~= nil, "creature sacrificed as a cost")
    t.eq(game.players[2].life, 18, "opponent lost 2")
    t.eq(p1.life, 22, "we gained 2")
  end

  t.section("Fight with the enchanted creature: Meltstrider's Resolve")
  do
    local game = t.setup({ { battlefield = { "Forest", "Serra Angel" }, hand = { "Meltstrider's Resolve" },
                             controller = t.scripted({ actions = { cast_variant("Meltstrider's Resolve") } }) },
                           { battlefield = { "Savannah Lions" } } })
    -- first targeting step: the Aura's creature (ours); second: the fight target (theirs)
    local step = 0
    game.players[1].controller.choose_targets = function(_, g, p, ability, candidates)
      step = step + 1
      return { t.find(candidates, step == 1 and "Serra Angel" or "Savannah Lions") }
    end
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Savannah Lions") ~= nil, "enchanted Angel fought and killed the Lions")
    t.eq(t.find(game.players[1].battlefield, "Serra Angel"):toughness(), 6, "+0/+2")
  end

  t.section("lure: Ochran Assassin")
  do
    local combat = require("scripts/mtg/combat")
    local ai = require("scripts/mtg/controllers/ai")
    local game = t.setup({ { battlefield = { "Ochran Assassin", "Savannah Lions" },
                             controller = t.scripted({ attack = function(g, p, c) return c end }) },
                           { battlefield = { "Serra Angel", "Elite Vanguard" }, controller = ai } })
    local assassin_blockers = 0
    game.players[1].controller.assign_combat_damage = function(_, g, p, attacker, blockers, amount, trample)
      if attacker:name() == "Ochran Assassin" then
        assassin_blockers = #blockers
      end
      return combat.default_assignment(attacker, blockers, amount, trample)
    end
    game:run_turn()
    local p1, p2 = game.players[1], game.players[2]
    t.eq(assassin_blockers, 2, "every creature able to block it did")
    t.check(t.find(p1.graveyard, "Ochran Assassin") ~= nil, "Assassin was blocked")
    t.eq(#p2.battlefield, 1, "1 deathtouch damage killed one of its blockers")
    t.eq(p2.life, 18, "Savannah Lions went unblocked")
    -- validation
    local g2 = t.setup({ { battlefield = { "Ochran Assassin", "Savannah Lions" } }, { battlefield = { "Elite Vanguard" } } })
    local assassin = g2.players[1].battlefield[1]
    g2.combat = { attackers = { assassin, g2.players[1].battlefield[2] }, blockers_of = {}, blocking = {}, blocked = {},
                  dealt_first_strike = {} }
    t.eq(combat.validate_blocks(g2, g2.players[2], {}), false, "not blocking the lure creature is illegal")
    t.eq(combat.validate_blocks(g2, g2.players[2], { { blocker = g2.players[2].battlefield[1], attacker = assassin } }), true,
         "blocking it is legal")
  end
end
