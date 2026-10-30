-- Static abilities, Auras, Equipment, control change, linked exile and cost reduction.
-- Outcomes follow the card text and the layer rules as Forge applies them (StaticAbilityContinuous,
-- StaticAbilityCantAttackBlock, CostAdjustment, AttachEffect).

local function cast(name, when)
  return function(game, player, actions)
    if when and not when(game) then
      return nil
    end
    for _, action in ipairs(actions) do
      if action.kind == "cast" and action.card:name() == name then
        return action
      end
    end
    return nil
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
  t.section("anthem")
  do
    local game = t.setup({ { battlefield = { "Anthem of Champions", "Savannah Lions" } }, { battlefield = { "Elite Vanguard" } } })
    local lions = t.find(game.players[1].battlefield, "Savannah Lions")
    local opp = t.find(game.players[2].battlefield, "Elite Vanguard")
    t.eq(lions:power(), 3, "your creatures get +1/+1")
    t.eq(lions:toughness(), 2, "toughness too")
    t.eq(opp:power(), 2, "opponents' creatures don't")
    game:move(t.find(game.players[1].battlefield, "Anthem of Champions"), "graveyard")
    t.eq(lions:power(), 2, "bonus ends when the anthem leaves")
  end

  t.section("Aura: cast, bonus, falls off")
  do
    local game = t.setup({ { battlefield = lands("Plains", 2, "Forest", "Savannah Lions"), hand = { "Unflinching Courage" },
                             controller = t.scripted({ actions = { cast("Unflinching Courage") }, targets = pick("Savannah Lions") }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    local lions = t.find(p1.battlefield, "Savannah Lions")
    local aura = t.find(p1.battlefield, "Unflinching Courage")
    t.check(aura ~= nil and aura.attached_to == lions, "Aura entered attached to its target")
    t.eq(lions:power(), 4, "+2/+2")
    t.eq(lions:has_keyword("Lifelink") and lions:has_keyword("Trample"), true, "trample and lifelink")
    game:move(lions, "graveyard")
    game:check_state_based_actions()
    t.check(t.find(p1.graveyard, "Unflinching Courage") ~= nil, "Aura goes to the graveyard when its creature dies")
  end

  t.section("Pacifism")
  do
    local game = t.setup({ { battlefield = { "Savannah Lions", "Pacifism" } }, { battlefield = { "Elite Vanguard" } } })
    local combat = require("scripts/mtg/combat")
    local lions = t.find(game.players[1].battlefield, "Savannah Lions")
    t.find(game.players[1].battlefield, "Pacifism").attached_to = lions
    game.statics_dirty = true
    t.eq(combat.can_attack(game, lions), false, "enchanted creature can't attack")
    t.eq(combat.can_block(game, lions), false, "or block")
    t.eq(combat.can_attack(game, t.find(game.players[2].battlefield, "Elite Vanguard")), true, "other creatures unaffected")
  end

  t.section("Control Magic")
  do
    local game = t.setup({ { battlefield = lands("Island", 4), hand = { "Control Magic" },
                             controller = t.scripted({ actions = { cast("Control Magic") }, targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    local angel = t.find(game.players[1].battlefield, "Serra Angel")
    t.check(angel ~= nil, "you control the enchanted creature")
    t.eq(angel and angel.owner, game.players[2], "its owner doesn't change")
    game:move(t.find(game.players[1].battlefield, "Control Magic"), "graveyard")
    game:check_state_based_actions()
    t.check(t.find(game.players[2].battlefield, "Serra Angel") ~= nil, "control returns when the Aura leaves")
  end

  t.section("Equipment")
  do
    local game = t.setup({ { battlefield = lands("Plains", 4, "Quick-Draw Katana", "Savannah Lions"),
                             controller = t.scripted({ actions = { function(g, p, actions)
                               for _, a in ipairs(actions) do
                                 if a.kind == "activate" and a.card:name() == "Quick-Draw Katana" then
                                   return a
                                 end
                               end
                             end }, attack = function(g, p, c) return c end }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 16, "equipped 4/1 first striker hit on its controller's turn")
    local katana = t.find(game.players[1].battlefield, "Quick-Draw Katana")
    local lions = t.find(game.players[1].battlefield, "Savannah Lions")
    game:move(lions, "graveyard")
    game:check_state_based_actions()
    t.eq(katana.zone, "battlefield", "Equipment stays when the creature dies")
    t.eq(katana.attached_to, nil, "and becomes unattached")
  end

  t.section("exile until this leaves")
  do
    local game = t.setup({ { battlefield = lands("Plains", 3), hand = { "Banishing Light" },
                             controller = t.scripted({ actions = { cast("Banishing Light") }, targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].exile, "Serra Angel") ~= nil, "Banishing Light exiled the creature")
    game:move(t.find(game.players[1].battlefield, "Banishing Light"), "graveyard")
    t.check(t.find(game.players[2].battlefield, "Serra Angel") ~= nil, "it returns when Banishing Light leaves")
  end

  t.section("Juggernaut")
  do
    local game = t.setup({ { battlefield = { "Juggernaut" } }, { battlefield = { "Wall of Vines" } } })
    game:run_turn()
    t.eq(game.players[2].life, 15, "Juggernaut attacked on its own (must attack) and Walls can't block it")
  end

  t.section("cost reduction with a target condition")
  do
    local game = t.setup({ { battlefield = lands("Plains", 2), hand = { "Luminous Rebuke" } },
                           { battlefield = { "Serra Angel" } } })
    local p1 = game.players[1]
    game.step = "main1"
    t.eq(#game:legal_actions(p1), 0, "{4}{W} isn't affordable with two Plains against an untapped creature")
    t.find(game.players[2].battlefield, "Serra Angel").tapped = true
    t.eq(#game:legal_actions(p1), 1, "costs {3} less when it targets a tapped creature")
  end

  t.section("conditional statics")
  do
    local game = t.setup({ { battlefield = { "Fresh-Faced Recruit", "Kitesail Corsair" } }, {} })
    local recruit = t.find(game.players[1].battlefield, "Fresh-Faced Recruit")
    local corsair = t.find(game.players[1].battlefield, "Kitesail Corsair")
    t.eq(recruit:has_keyword("First Strike"), true, "first strike on your turn")
    game.active = game.players[2]
    game.statics_dirty = true
    t.eq(recruit:has_keyword("First Strike"), false, "not on the opponent's turn")
    t.eq(corsair:has_keyword("Flying"), false, "Corsair only flies while attacking")
    game.combat = { attackers = { corsair }, blockers_of = {}, blocking = {}, blocked = {}, dealt_first_strike = {} }
    game.statics_dirty = true
    t.eq(corsair:has_keyword("Flying"), true, "...and flies while attacking")
  end
end
