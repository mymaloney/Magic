-- Type, color, name and ability changes (layers 3-6), Animate, Crew and lasting effects from a
-- resolved spell. Outcomes follow the card text and Forge's implementations.

local function cast(name)
  return function(game, player, actions)
    for _, action in ipairs(actions) do
      if action.kind == "cast" and action.card:name() == name then
        return action
      end
    end
  end
end

local function activate(name)
  return function(game, player, actions)
    for _, action in ipairs(actions) do
      if action.kind == "activate" and action.card:name() == name then
        return action
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

local function lands(name, n, ...)
  local list = { ... }
  for _ = 1, n do
    table.insert(list, 1, name)
  end
  return list
end

return function(t)
  t.section("loses all abilities, new type/color/P/T: Eaten by Piranhas")
  do
    local game = t.setup({ { battlefield = lands("Island", 2), hand = { "Eaten by Piranhas" },
                             controller = t.scripted({ actions = { cast("Eaten by Piranhas") }, targets = pick("Aggressive Mammoth") }) },
                           { battlefield = { "Aggressive Mammoth", "Savannah Lions" } } })
    game:run_turn()
    local mammoth = t.find(game.players[2].battlefield, "Aggressive Mammoth")
    local lions = t.find(game.players[2].battlefield, "Savannah Lions")
    t.eq(mammoth:power(), 1, "base power 1")
    t.eq(mammoth:toughness(), 1, "base toughness 1")
    t.check(mammoth:has_subtype("Skeleton") and not mammoth:has_subtype("Elephant"), "Skeleton, not Elephant")
    t.check(mammoth:has_color("B") and not mammoth:has_color("G"), "black, not green")
    t.check(mammoth:is_creature(), "still a creature")
    t.check(not lions:has_keyword("Trample"), "its anthem static stopped")
  end

  t.section("set name and colors: Witness Protection")
  do
    local game = t.setup({ { battlefield = lands("Island", 1), hand = { "Witness Protection" },
                             controller = t.scripted({ actions = { cast("Witness Protection") }, targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    local angel = game.players[2].battlefield[1]
    t.eq(angel:name(), "Legitimate Businessperson", "new name")
    t.check(angel:has_color("G") and angel:has_color("W") and angel:color_count() == 2, "green and white")
    t.check(not angel:has_keyword("Flying"), "lost flying")
    t.check(angel:has_subtype("Citizen") and not angel:has_subtype("Angel"), "Citizen")
  end

  t.section("becomes a land with a mana ability: Imprisoned in the Moon")
  do
    local game = t.setup({ { battlefield = lands("Island", 3), hand = { "Imprisoned in the Moon" },
                             controller = t.scripted({ actions = { cast("Imprisoned in the Moon") }, targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    local p2 = game.players[2]
    local angel = p2.battlefield[1]
    t.check(not angel:is_creature() and angel:is_land(), "a land, not a creature")
    t.eq(angel:color_count(), 0, "colorless")
    local sources = game:mana_sources(p2)
    t.check(#sources == 1 and sources[1].colors[1] == "C", "taps for {C}")
  end

  t.section("Animate until end of turn, Kindred changeling: Firdoch Core")
  do
    local seen
    local game = t.setup({ { battlefield = lands("Plains", 4, "Firdoch Core"),
                             controller = t.scripted({ actions = { activate("Firdoch Core") } }) }, {} })
    local core = game.players[1].battlefield[5]
    t.check(not core:is_creature() and core:has_subtype("Goblin"), "noncreature Kindred changeling has every creature type")
    game.players[1].controller.declare_attackers = function(_, g, p, candidates)
      seen = { creature = core:is_creature(), power = core:power(), attacking = t.find(candidates, "Firdoch Core") ~= nil }
      return {}
    end
    game:run_turn()
    t.check(seen and seen.creature and seen.power == 4, "4/4 artifact creature this turn")
    t.check(seen and seen.attacking, "can attack (was under control since the turn began)")
    t.check(not core:is_creature(), "back to a noncreature artifact after the turn")
  end

  t.section("Crew: Cultivator's Caravan")
  do
    local game = t.setup({ { battlefield = { "Cultivator's Caravan", "Savannah Lions", "Elite Vanguard" },
                             controller = t.scripted({ actions = { activate("Cultivator's Caravan") },
                                                       attack = function(g, p, c) return c end }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.eq(game.players[2].life, 15, "crewed Vehicle attacked for 5")
    t.check(t.find(p1.battlefield, "Savannah Lions").tapped and t.find(p1.battlefield, "Elite Vanguard").tapped,
            "both 2-power creatures tapped to crew 3")
  end

  t.section("AI crews when the Vehicle is bigger than its crew")
  do
    local ai = require("scripts/mtg/controllers/ai")
    local game = t.setup({ { battlefield = { "Cultivator's Caravan", "Savannah Lions", "Elite Vanguard" }, controller = ai }, {} })
    game.step = "main1"
    local choice = ai:choose_action(game, game.players[1], game:legal_actions(game.players[1]))
    t.check(choice ~= nil and choice.kind == "activate", "AI activates crew in main 1")
  end

  t.section("lasting type change from a spell: Rise from the Grave")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 5), hand = { "Rise from the Grave" },
                             controller = t.scripted({ actions = { cast("Rise from the Grave") }, targets = pick("Serra Angel") }) },
                           { graveyard = { "Serra Angel" } } })
    game:run_turn()
    local angel = t.find(game.players[1].battlefield, "Serra Angel")
    t.check(angel ~= nil, "returned under our control")
    t.check(angel and angel:has_subtype("Zombie") and angel:has_subtype("Angel"), "a Zombie in addition")
    t.check(angel and angel:has_color("B") and angel:has_color("W"), "black in addition")
    t.eq(#game.effects, 1, "effect lasts past the turn")
    game:move(angel, "graveyard")
    t.eq(#game.effects, 0, "and ends when the creature leaves")
  end
end
