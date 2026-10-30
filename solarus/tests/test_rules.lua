-- Rules scenarios. Expected outcomes follow the Comprehensive Rules as implemented in Forge
-- (see docs/solarus/engine-map.md for the Java code each part mirrors).

local Game = require("scripts/mtg/game")
local combat = require("scripts/mtg/combat")

local function attack_with(...)
  local names = { ... }
  return function(game, player, candidates)
    local list = {}
    for _, name in ipairs(names) do
      for _, card in ipairs(candidates) do
        if card:name() == name then
          list[#list + 1] = card
          break
        end
      end
    end
    return list
  end
end

-- blocks given as { blocker_name, attacker_name } pairs
local function block_with(...)
  local pairs_ = { ... }
  return function(game, player, attackers, candidates)
    local blocks, used = {}, {}
    for _, pair in ipairs(pairs_) do
      local blocker, attacker
      for _, card in ipairs(candidates) do
        if card:name() == pair[1] and not used[card] then
          blocker = card
          break
        end
      end
      for _, card in ipairs(attackers) do
        if card:name() == pair[2] then
          attacker = card
          break
        end
      end
      used[blocker] = true
      blocks[#blocks + 1] = { blocker = blocker, attacker = attacker }
    end
    return blocks
  end
end

local function act(kind, name)
  return function(game, player, actions)
    for _, action in ipairs(actions) do
      if action.kind == kind and action.card:name() == name then
        return action
      end
    end
    return nil
  end
end

return function(t)
  t.section("untap and draw")
  do
    local game = t.setup({ { battlefield = { "Savannah Lions" }, hand = {} }, {} })
    local lions = t.find(game.players[1].battlefield, "Savannah Lions")
    lions.tapped = true
    game:run_turn()
    t.eq(lions.tapped, false, "permanents untap in the untap step")
    t.eq(#game.players[1].hand, 1, "active player draws a card")
    t.eq(game:active_player(), game.players[2], "turn passes to the opponent")
  end

  t.section("first player skips the first draw")
  do
    local deck = t.db.make_deck({ Plains = 20 })
    local game = Game.new({ players = { { deck = deck, controller = t.scripted() }, { deck = deck, controller = t.scripted() } },
                            first_player = 1, shuffle = false })
    game:run_turn()
    t.eq(#game.players[1].hand, 7, "no draw on turn 1")
    local drew = 0
    game:on_event(function(e) if e.type == "draw" then drew = drew + 1 end end)
    game:run_turn()
    t.eq(drew, 1, "second player draws on turn 2")
    t.eq(#game.players[2].hand, 7, "and discards back to 7 in cleanup")
  end

  t.section("play a land and cast a creature")
  do
    local game = t.setup({ { hand = { "Plains", "Plains", "Savannah Lions" },
                             controller = t.scripted({ actions = { act("play_land", "Plains"), act("cast", "Savannah Lions") } }) }, {} })
    local p1 = game.players[1]
    game.step = "main1"
    local kinds = {}
    for _, a in ipairs(game:legal_actions(p1)) do
      kinds[a.kind] = (kinds[a.kind] or 0) + 1
    end
    t.eq(kinds.play_land, 2, "both lands are playable before a land is played")
    t.eq(kinds.cast, nil, "can't cast without mana")
    game.step = nil
    game:run_turn()
    local lions = t.find(p1.battlefield, "Savannah Lions")
    t.check(lions ~= nil, "Savannah Lions resolved onto the battlefield")
    t.eq(#p1.battlefield, 2, "only one land played")
    t.eq(lions and lions.sick, true, "creature cast this turn is summoning sick")
    t.eq(#game.stack, 0, "stack is empty after resolving")
  end

  t.section("summoning sickness and haste")
  do
    local game = t.setup({ { battlefield = { "Savannah Lions", "Raging Goblin", "Wall of Vines" } }, {} })
    local p1 = game.players[1]
    t.find(p1.battlefield, "Savannah Lions").sick = true
    t.find(p1.battlefield, "Raging Goblin").sick = true
    local candidates = combat.attack_candidates(game, p1)
    t.eq(#candidates, 1, "only the haste creature can attack (defender can't)")
    t.eq(candidates[1] and candidates[1]:name(), "Raging Goblin", "haste ignores summoning sickness")
  end

  t.section("unblocked attacker and vigilance")
  do
    local game = t.setup({ { battlefield = { "Savannah Lions", "Serra Angel" },
                             controller = t.scripted({ attack = attack_with("Savannah Lions", "Serra Angel") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 14, "2 + 4 combat damage")
    t.eq(t.find(game.players[1].battlefield, "Savannah Lions").tapped, true, "attacking taps")
    t.eq(t.find(game.players[1].battlefield, "Serra Angel").tapped, false, "vigilance doesn't tap")
  end

  t.section("block and trade")
  do
    local game = t.setup({ { battlefield = { "Savannah Lions" }, controller = t.scripted({ attack = attack_with("Savannah Lions") }) },
                           { battlefield = { "Elite Vanguard" }, controller = t.scripted({ block = block_with({ "Elite Vanguard", "Savannah Lions" }) }) } })
    game:run_turn()
    t.eq(#game.players[1].battlefield, 0, "attacker died")
    t.eq(#game.players[2].battlefield, 0, "blocker died")
    t.eq(game.players[2].life, 20, "blocked damage doesn't reach the player")
  end

  t.section("first strike")
  do
    local game = t.setup({ { battlefield = { "Warclamp Mastiff" }, controller = t.scripted({ attack = attack_with("Warclamp Mastiff") }) },
                           { battlefield = { "Elite Vanguard" }, controller = t.scripted({ block = block_with({ "Elite Vanguard", "Warclamp Mastiff" }) }) } })
    local steps = {}
    game:on_event(function(e) if e.type == "step" then steps[#steps + 1] = e.step end end)
    game:run_turn()
    t.check(t.find(game.players[1].battlefield, "Warclamp Mastiff") ~= nil, "first striker survives")
    t.eq(#game.players[2].battlefield, 0, "blocker dies before dealing damage")
    t.check(table.concat(steps, ","):find("combat_first_strike_damage", 1, true) ~= nil, "first strike damage step happened")
  end

  t.section("double strike")
  do
    local game = t.setup({ { battlefield = { "Raging Redcap" }, controller = t.scripted({ attack = attack_with("Raging Redcap") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 18, "double strike deals damage twice")
  end

  t.section("deathtouch and lifelink")
  do
    local game = t.setup({ { battlefield = { "Vampire of the Dire Moon" }, controller = t.scripted({ attack = attack_with("Vampire of the Dire Moon") }) },
                           { battlefield = { "Gigantosaurus" }, controller = t.scripted({ block = block_with({ "Gigantosaurus", "Vampire of the Dire Moon" }) }) } })
    game:run_turn()
    t.eq(#game.players[2].battlefield, 0, "1 deathtouch damage destroys a 10/10")
    t.eq(#game.players[1].battlefield, 0, "the vampire dies too")
    t.eq(game.players[1].life, 21, "lifelink gains life equal to damage dealt")
  end

  t.section("trample")
  do
    local game = t.setup({ { battlefield = { "Tajuru Pathwarden" }, controller = t.scripted({ attack = attack_with("Tajuru Pathwarden") }) },
                           { battlefield = { "Elite Vanguard" }, controller = t.scripted({ block = block_with({ "Elite Vanguard", "Tajuru Pathwarden" }) }) } })
    game:run_turn()
    t.eq(game.players[2].life, 16, "excess damage tramples over (5 power, 1 lethal to the blocker)")
    t.eq(#game.players[2].battlefield, 0, "blocker died")

    local wall = t.setup({ {}, { battlefield = { "Wall of Vines" } } })
    local pathwarden = wall:create_card(t.db.get("Tajuru Pathwarden"), wall.players[1], "battlefield")
    local blocker = wall.players[2].battlefield[1]
    local ok = combat.validate_assignment(pathwarden, { blocker }, 5, true, { amounts = { [blocker] = 2 }, to_player = 3 })
    t.eq(ok, false, "trample must assign lethal (3) to the blocker before the player")
    ok = combat.validate_assignment(pathwarden, { blocker }, 5, true, { amounts = { [blocker] = 3 }, to_player = 2 })
    t.eq(ok, true, "lethal to blocker, rest to player is legal")
  end

  t.section("flying, reach and menace")
  do
    local game = t.setup({ { battlefield = { "Air Elemental", "Savannah Lions" } }, { battlefield = { "Elite Vanguard", "Deadly Recluse" } } })
    local p1, p2 = game.players[1], game.players[2]
    local air = t.find(p1.battlefield, "Air Elemental")
    local lions = t.find(p1.battlefield, "Savannah Lions")
    game.combat = { attackers = { air, lions }, blockers_of = {}, blocking = {}, blocked = {}, dealt_first_strike = {} }
    local vanguard, recluse = t.find(p2.battlefield, "Elite Vanguard"), t.find(p2.battlefield, "Deadly Recluse")
    t.eq((combat.validate_blocks(game, p2, { { blocker = vanguard, attacker = air } })), false, "ground creature can't block a flyer")
    t.eq((combat.validate_blocks(game, p2, { { blocker = recluse, attacker = air } })), true, "reach blocks a flyer")
    t.eq((combat.validate_blocks(game, p2, { { blocker = vanguard, attacker = lions }, { blocker = vanguard, attacker = lions } })), false, "a creature blocks only once")

    local menace_def = setmetatable({ keywords = { Menace = true } }, { __index = t.db.get("Savannah Lions") })
    local menacer = game:create_card(menace_def, p1, "battlefield")
    game.combat.attackers = { menacer }
    t.eq((combat.validate_blocks(game, p2, { { blocker = vanguard, attacker = menacer } })), false, "menace needs two blockers")
    t.eq((combat.validate_blocks(game, p2, { { blocker = vanguard, attacker = menacer }, { blocker = recluse, attacker = menacer } })), true, "two blockers satisfy menace")
  end

  t.section("damage wears off in cleanup")
  do
    local game = t.setup({ { battlefield = { "Serra Angel" }, controller = t.scripted({ attack = attack_with("Serra Angel") }) },
                           { battlefield = { "Leonin Skyhunter" }, controller = t.scripted({ block = block_with({ "Leonin Skyhunter", "Serra Angel" }) }) } })
    game:run_turn()
    local angel = t.find(game.players[1].battlefield, "Serra Angel")
    t.check(angel ~= nil, "4/4 survives 2 damage")
    t.eq(angel and angel.damage, 0, "damage removed at cleanup")
  end

  t.section("legend rule")
  do
    local game = t.setup({ { battlefield = { "Kalakscion, Hunger Tyrant", "Kalakscion, Hunger Tyrant" } }, {} })
    game:check_state_based_actions()
    t.eq(#game.players[1].battlefield, 1, "one copy of a legendary permanent remains")
    t.eq(#game.players[1].graveyard, 1, "the other goes to the graveyard")
  end

  t.section("losing: life and empty library")
  do
    local game = t.setup({ { battlefield = { "Savannah Lions" }, controller = t.scripted({ attack = attack_with("Savannah Lions") }) }, { life = 2 } })
    game:run()
    t.eq(game.over, true, "game ends")
    t.eq(game.winner, game.players[1], "attacker wins at 0 life")
    t.eq(game.players[2].loss_reason, "life", "loss reason")

    local decked = t.setup({ {}, { library = {} } })
    decked:run()
    t.eq(decked.winner, decked.players[1], "player who draws from an empty library loses")
    t.eq(decked.turn, 3, "on their own draw step (player 2's first turn in this setup)")
  end

  t.section("cleanup discards to seven")
  do
    local game = t.setup({ { hand = { "Plains", "Plains", "Plains", "Plains", "Plains", "Plains", "Plains", "Plains", "Plains" } }, {} })
    game:run_turn()
    t.eq(#game.players[1].hand, 7, "hand size 7 after cleanup")
    t.eq(#game.players[1].graveyard, 3, "3 discarded (9 + draw - 7)")
  end

  t.section("mana creatures and summoning sickness")
  do
    local game = t.setup({ { battlefield = { "Llanowar Elves" }, hand = { "Savannah Lions" } }, {} })
    local p1 = game.players[1]
    game.step = "main1"
    t.eq(#game:legal_actions(p1), 0, "Llanowar Elves' G doesn't pay for Savannah Lions' W")
    local elves = t.find(p1.battlefield, "Llanowar Elves")
    game:create_card(t.db.get("Druid of the Cowl"), p1, "hand")
    t.eq(#game:legal_actions(p1), 0, "1G needs two mana sources")
    game:create_card(t.db.get("Forest"), p1, "battlefield")
    t.eq(#game:legal_actions(p1), 1, "Elves + Forest pay for Druid of the Cowl")
    elves.sick = true
    t.eq(#game:legal_actions(p1), 0, "summoning-sick Elves can't tap for mana")
  end

  t.section("flash blocker cast on the opponent's turn")
  do
    local game = t.setup({
      { battlefield = { "Savannah Lions" }, controller = t.scripted({ attack = attack_with("Savannah Lions") }) },
      { battlefield = { "Forest", "Forest" }, hand = { "Ambush Viper" },
        controller = t.scripted({ block = block_with({ "Ambush Viper", "Savannah Lions" }) }) },
    })
    -- Player 2 casts the viper the first time they get priority in beginning of combat.
    local cast = false
    game.players[2].controller.choose_action = function(self, g, player, actions)
      if not cast and g.step == "combat_begin" then
        local action = act("cast", "Ambush Viper")(g, player, actions)
        cast = action ~= nil
        return action
      end
      return nil
    end
    game:run_turn()
    t.eq(cast, true, "flash creature cast during the opponent's beginning of combat")
    t.eq(#game.players[1].battlefield, 0, "deathtouch blocker killed the attacker")
    t.check(t.find(game.players[2].graveyard, "Ambush Viper") ~= nil, "2/1 viper died to 2 damage")
    t.eq(game.players[2].life, 20, "no damage got through")
  end
end
