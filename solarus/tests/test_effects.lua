-- Library effects (Scry, Surveil, Dig), Sacrifice, Fight, Charm, Branch and mass effects.
-- Outcomes follow the card text (Forge's ScryEffect, SurveilEffect, DigEffect, FightEffect, CharmEffect, ...).

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

local function named(list, name)
  for _, c in ipairs(list) do
    if c.life == nil and c:name() == name then
      return c
    end
  end
end

return function(t)
  t.section("Scry")
  do
    -- library (top first): Savannah Lions, Island, ...
    local game = t.setup({ { battlefield = { "Island" }, hand = { "Opt" },
                             library = { "Plains", "Plains", "Island", "Savannah Lions" },
                             controller = t.scripted({ actions = { cast("Opt", function(g) return g.step == "main1" end) },
                                                       arrange = function(g, p, cards) return { top = {}, away = cards } end }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    -- draw step drew Savannah Lions; Opt scried Island to the bottom, then drew the next Plains
    t.check(t.find(p1.hand, "Savannah Lions") ~= nil, "drew the top card in the draw step")
    t.eq(p1.library[1]:name(), "Island", "scried card went to the bottom")
    t.eq(#p1.library, 2, "Opt drew one card")
  end

  t.section("Surveil")
  do
    local game = t.setup({ { battlefield = { "Swamp", "Swamp", "Swamp" }, hand = { "Diresight" },
                             library = { "Plains", "Plains", "Plains", "Plains", "Island", "Savannah Lions" },
                             controller = t.scripted({ actions = { cast("Diresight") },
                                                       arrange = function(g, p, cards) return { top = { cards[2] }, away = { cards[1] } } end }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.eq(#p1.graveyard, 2, "one surveilled card + Diresight in the graveyard")
    t.eq(p1.life, 18, "lost 2 life")
  end

  t.section("Dig")
  do
    local game = t.setup({ { battlefield = { "Forest", "Swamp" }, hand = { "Grisly Salvage" },
                             library = { "Plains", "Island", "Savannah Lions", "Swamp", "Shock", "Plains" },
                             controller = t.scripted({ actions = { cast("Grisly Salvage") },
                                                       cards = function(g, p, cards) return { named(cards, "Savannah Lions") } end }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(p1.hand, "Savannah Lions") ~= nil, "took a creature into hand")
    t.eq(#p1.graveyard, 5, "the other four + Grisly Salvage in the graveyard")
  end

  t.section("Sacrifice at end of turn")
  do
    local game = t.setup({ { battlefield = { "Ball Lightning" } }, {} })
    game:run_turn()
    t.check(t.find(game.players[1].graveyard, "Ball Lightning") ~= nil, "Ball Lightning sacrificed at the end step")
  end

  t.section("Fight")
  do
    local game = t.setup({ { battlefield = { "Forest", "Mountain", "Forest", "Savannah Lions" }, hand = { "Savage Smash" },
                             controller = t.scripted({ actions = { cast("Savage Smash") },
                                                       targets = function(g, p, ability, cands)
                                                         return { named(cands, ability.api == "Fight" and "Serra Angel" or "Savannah Lions") }
                                                       end }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, "4/3 pumped Lions fought and killed the 4/4 Angel")
    t.check(t.find(game.players[1].graveyard, "Savannah Lions") ~= nil, "and died to its 4 damage")
  end

  t.section("Charm")
  do
    local game = t.setup({ { battlefield = { "Mountain", "Mountain", "Mountain" }, hand = { "Slagstorm" },
                             controller = t.scripted({ actions = { cast("Slagstorm") }, mode = function(g, p, s, charm, options) return 2 end }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.eq(game.players[1].life, 17, "mode 2: 3 damage to each player")
    t.eq(game.players[2].life, 17, "...both of them")
    t.check(t.find(game.players[2].battlefield, "Serra Angel") ~= nil, "mode 1 (creatures) wasn't chosen")
  end

  t.section("Branch")
  do
    local game = t.setup({ { battlefield = { "Garna, Bloodfist of Keld", "Savannah Lions" },
                             controller = t.scripted({ attack = function(g, p, c) return { t.find(c, "Savannah Lions") } end }) },
                           { battlefield = { "Serra Angel" }, controller = t.scripted({ block = function(g, p, attackers, c)
                               return { { blocker = c[1], attacker = attackers[1] } } end }) } })
    game:run_turn()
    t.eq(#game.players[1].hand, 2, "attacking creature died: Garna draws (draw step + 1)")
  end

  t.section("ChangeZoneAll at instant speed")
  do
    local game = t.setup({
      { battlefield = { "Savannah Lions", "Elite Vanguard" },
        controller = t.scripted({ attack = function(g, p, c) return { t.find(c, "Savannah Lions") } end }) },
      { battlefield = { "Island", "Island", "Island", "Island" }, hand = { "Aetherize" },
        controller = t.scripted({ actions = { cast("Aetherize", function(g) return g.step == "combat_declare_blockers" end) } }) },
    })
    game:run_turn()
    t.check(t.find(game.players[1].hand, "Savannah Lions") ~= nil, "attacking creature returned to hand")
    t.check(t.find(game.players[1].battlefield, "Elite Vanguard") ~= nil, "non-attacker stayed")
    t.eq(game.players[2].life, 20, "no damage got through")
  end
end
