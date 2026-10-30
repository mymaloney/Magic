-- Remembered objects, damage riders, revealed-hand discards, owner's choices, flashback grants and
-- other one-off spell features. Outcomes follow the card text and Forge's implementations.

local function cast(name, opts)
  opts = opts or {}
  return function(game, player, actions)
    if opts.when and not opts.when(game) then
      return nil
    end
    for _, action in ipairs(actions) do
      if action.kind == "cast" and action.card:name() == name and (action.flashback or false) == (opts.flashback or false) then
        return action
      end
    end
    return nil
  end
end

local function activate(name)
  return function(game, player, actions)
    for _, action in ipairs(actions) do
      if action.kind == "activate" and action.card:name() == name then
        return action
      end
    end
    return nil
  end
end

local function label(c)
  return c.life ~= nil and ("player:" .. c.index) or c:name()
end

-- Picks candidates by name, one name per targeting step in order.
local function picks(...)
  local names = { ... }
  local step = 0
  return function(game, player, ability, candidates)
    step = step + 1
    for _, c in ipairs(candidates) do
      if label(c) == names[step] then
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
  t.section("TargetUnique: Boulder Dash")
  do
    local second_candidates
    local step = 0
    local game = t.setup({ { battlefield = lands("Mountain", 2), hand = { "Boulder Dash" },
                             controller = t.scripted({ actions = { cast("Boulder Dash") },
                                                       targets = function(g, p, ability, candidates)
                                                         step = step + 1
                                                         if step == 2 then
                                                           second_candidates = candidates
                                                         end
                                                         for _, c in ipairs(candidates) do
                                                           if label(c) == (step == 1 and "player:2" or "Savannah Lions") then
                                                             return { c }
                                                           end
                                                         end
                                                       end }) },
                           { battlefield = { "Savannah Lions" } } })
    game:run_turn()
    t.eq(game.players[2].life, 18, "2 damage to the first target")
    t.check(t.find(game.players[2].graveyard, "Savannah Lions") ~= nil, "1 damage to the other target")
    local repeated = false
    for _, c in ipairs(second_candidates or {}) do
      repeated = repeated or label(c) == "player:2"
    end
    t.check(second_candidates ~= nil and not repeated, "second target can't be the first one")
  end

  t.section("reveal and choose: Pilfer")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 2), hand = { "Pilfer" },
                             controller = t.scripted({ actions = { cast("Pilfer") } }) },
                           { hand = { "Plains", "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, "chosen nonland card discarded")
    t.check(t.find(game.players[2].hand, "Plains") ~= nil, "land can't be chosen")
  end

  t.section("Remembered$Amount: Syphon Mind")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 4), hand = { "Syphon Mind" },
                             controller = t.scripted({ actions = { cast("Syphon Mind") } }) },
                           { hand = { "Plains", "Serra Angel" } } })
    game:run_turn()
    t.eq(#game.players[2].hand, 1, "opponent discarded one")
    t.eq(#game.players[1].hand, 2, "draw step + 1 per discarded card")
  end

  t.section("RememberedLKI toughness: Tribute to Hunger")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 3), hand = { "Tribute to Hunger" },
                             controller = t.scripted({ actions = { cast("Tribute to Hunger") } }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, "opponent sacrificed")
    t.eq(game.players[1].life, 24, "gained the sacrificed creature's toughness")
  end

  t.section("ConditionDefined + !IsRemembered: Deadly Brew")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 1, "Forest", "Savannah Lions"), hand = { "Deadly Brew" },
                             graveyard = { "Serra Angel" },
                             controller = t.scripted({ actions = { cast("Deadly Brew") } }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, "opponent sacrificed")
    t.check(t.find(p1.graveyard, "Savannah Lions") ~= nil, "sacrificed Lions stays (not another card)")
    t.check(t.find(p1.hand, "Serra Angel") ~= nil, "another permanent card returned")
  end

  t.section("ReplaceDyingDefined: Obliterating Bolt")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 2), hand = { "Obliterating Bolt" },
                             controller = t.scripted({ actions = { cast("Obliterating Bolt") } }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].exile, "Serra Angel") ~= nil, "exiled instead of dying")
  end

  t.section("NumAtt Double: Bulk Up")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 2, "Serra Angel"), hand = { "Bulk Up" },
                             controller = t.scripted({ actions = { cast("Bulk Up") } }) }, {} })
    local angel = game.players[1].battlefield[3]
    local seen
    game.players[1].controller.declare_attackers = function()
      seen = angel:power()
      return {}
    end
    game:run_turn()
    t.eq(seen, 8, "power doubled")
  end

  t.section("DamageSource ParentTarget: Bite Down")
  do
    local game = t.setup({ { battlefield = lands("Forest", 2, "Serra Angel"), hand = { "Bite Down" },
                             controller = t.scripted({ actions = { cast("Bite Down") },
                                                       targets = picks("Serra Angel", "Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, "our Angel dealt 4 to theirs")
    t.check(t.find(game.players[1].battlefield, "Serra Angel") ~= nil, "our Angel took no damage")
  end

  t.section("TargetsWithDifferentControllers: Run Away Together")
  do
    local game = t.setup({ { battlefield = lands("Island", 2, "Savannah Lions"), hand = { "Run Away Together" },
                             controller = t.scripted({ actions = { cast("Run Away Together") },
                                                       targets = function(g, p, ability, candidates)
                                                         return { t.find(candidates, "Savannah Lions"), t.find(candidates, "Serra Angel") }
                                                       end }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[1].hand, "Savannah Lions") ~= nil, "ours returned")
    t.check(t.find(game.players[2].hand, "Serra Angel") ~= nil, "theirs returned")
  end

  t.section("DestinationAlternative: Uncharted Voyage")
  for _, choice in ipairs({ 1, 2 }) do
    local game = t.setup({ { battlefield = lands("Island", 4), hand = { "Uncharted Voyage" },
                             controller = t.scripted({ actions = { cast("Uncharted Voyage") } }) },
                           { battlefield = { "Serra Angel" }, controller = t.scripted({ option = function() return choice end }) } })
    game:run_turn()
    local library = game.players[2].library
    if choice == 1 then
      t.eq(library[#library]:name(), "Serra Angel", "owner chose the top (last = top)")
    else
      t.eq(library[1]:name(), "Serra Angel", "owner chose the bottom")
    end
  end

  t.section("ConditionActivationLimit: Dragon Whelp")
  for _, times in ipairs({ 3, 4 }) do
    local actions = {}
    for i = 1, times do
      actions[i] = activate("Dragon Whelp")
    end
    local game = t.setup({ { battlefield = lands("Mountain", 4, "Dragon Whelp"),
                             controller = t.scripted({ actions = actions }) }, {} })
    game:run_turn()
    local sacrificed = t.find(game.players[1].graveyard, "Dragon Whelp") ~= nil
    t.eq(sacrificed, times >= 4, times .. " activations: sacrificed at end step = " .. tostring(times >= 4))
  end

  t.section("blockedByRemembered: Ride Down")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 1, "Plains", "Savannah Lions"), hand = { "Ride Down" },
                             controller = t.scripted({ actions = { cast("Ride Down", { when = function(g)
                                                         return g.combat ~= nil and next(g.combat.blocking) ~= nil end }) },
                                                       attack = function(g, p, c) return { t.find(c, "Savannah Lions") } end }) },
                           { battlefield = { "Serra Angel" }, controller = t.scripted({ block = function(g, p, attackers, c)
                               return { { blocker = c[1], attacker = attackers[1] } } end }) } })
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, "blocker destroyed")
    t.eq(game.players[2].life, 18, "attacker gained trample and dealt all its damage to the player")
  end

  t.section("Count$ResolvedThisTurn: Venom Connoisseur")
  do
    local game = t.setup({ { battlefield = lands("Plains", 2, "Venom Connoisseur", "Serra Angel"),
                             hand = { "Savannah Lions", "Savannah Lions" },
                             controller = t.scripted({ actions = { cast("Savannah Lions"), cast("Savannah Lions") } }) }, {} })
    local p1 = game.players[1]
    local after_first, after_second
    game.players[1].controller.declare_attackers = function()
      local angel = t.find(p1.battlefield, "Serra Angel")
      after_second = angel:has_keyword("Deathtouch")
      return {}
    end
    game:run_turn()
    t.check(after_second, "second resolution gave all creatures deathtouch")
    local game2 = t.setup({ { battlefield = lands("Plains", 1, "Venom Connoisseur", "Serra Angel"),
                              hand = { "Savannah Lions" },
                              controller = t.scripted({ actions = { cast("Savannah Lions") } }) }, {} })
    local p = game2.players[1]
    game2.players[1].controller.declare_attackers = function()
      after_first = { t.find(p.battlefield, "Venom Connoisseur"):has_keyword("Deathtouch"),
                      t.find(p.battlefield, "Serra Angel"):has_keyword("Deathtouch") }
      return {}
    end
    game2:run_turn()
    t.check(after_first[1] and not after_first[2], "first resolution: only the Connoisseur")
  end

  t.section("discard replacement: Wilt-Leaf Liege")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 3), hand = { "Mind Rot" },
                             controller = t.scripted({ actions = { cast("Mind Rot") }, targets = picks("player:2") }) },
                           { hand = { "Wilt-Leaf Liege", "Plains" } } })
    game:run_turn()
    t.check(t.find(game.players[2].battlefield, "Wilt-Leaf Liege") ~= nil, "opponent's discard put it onto the battlefield")
    t.check(t.find(game.players[2].graveyard, "Plains") ~= nil, "other card discarded normally")
  end

  t.section("Effect: extra land play (Explore)")
  do
    local function land(name)
      return function(game, player, actions)
        for _, action in ipairs(actions) do
          if action.kind == "play_land" and action.card:name() == name then
            return action
          end
        end
      end
    end
    local game = t.setup({ { battlefield = lands("Forest", 2), hand = { "Explore", "Forest", "Forest" },
                             controller = t.scripted({ actions = { land("Forest"), cast("Explore"), land("Forest") } }) }, {} })
    game:run_turn()
    t.eq(#game.players[1].battlefield, 4, "two lands played this turn")
    t.eq(#game.effects, 0, "effect ended at cleanup")
  end

  local statics = require("scripts/mtg/statics")

  t.section("Effect: can't be blocked, ends when it leaves (Goblin Smuggler)")
  do
    local could_block
    local game = t.setup({ { battlefield = { "Goblin Smuggler", "Savannah Lions" },
                             controller = t.scripted({ actions = { activate("Goblin Smuggler") },
                                                       targets = picks("Savannah Lions"),
                                                       attack = function(g, p, c) return { t.find(c, "Savannah Lions") } end }) },
                           { battlefield = { "Serra Angel" }, controller = t.scripted({ block = function(g, p, attackers, c)
                               could_block = statics.can_block_by(g, attackers[1], c[1])
                               return {} end }) } })
    game:run_turn()
    t.eq(could_block, false, "remembered creature can't be blocked")
    t.eq(game.players[2].life, 18, "it dealt damage")
    -- leaving the battlefield ends the effect even within the turn
    local game2 = t.setup({ { battlefield = { "Goblin Smuggler", "Savannah Lions" } }, {} })
    local lions = t.find(game2.players[1].battlefield, "Savannah Lions")
    local smuggler = game2.players[1].battlefield[1]
    local ability = smuggler.def.activated[1].ability
    require("scripts/mtg/effects").Effect.resolve(game2, ability, { game = game2, source = smuggler,
                                                                    controller = game2.players[1], targets = { [ability] = { lions } } })
    t.eq(#game2.effects, 1, "effect created")
    game2:move(lions, "hand")
    t.eq(#game2.effects, 0, "ExileOnMoved: effect ended when its creature left the battlefield")
  end

  t.section("Effect: hidden keyword for a group (Seismic Elemental)")
  do
    local lions_can_block, angel_can_block
    local game = t.setup({ { battlefield = lands("Mountain", 5, "Savannah Lions"), hand = { "Seismic Elemental" },
                             controller = t.scripted({ actions = { cast("Seismic Elemental") } }) },
                           { battlefield = { "Savannah Lions", "Serra Angel" } } })
    game.players[1].controller.declare_attackers = function(_, g)
      local p2 = g.players[2]
      lions_can_block = not t.find(p2.battlefield, "Savannah Lions"):has_keyword("HIDDEN CARDNAME can't block.")
      angel_can_block = not t.find(p2.battlefield, "Serra Angel"):has_keyword("HIDDEN CARDNAME can't block.")
      return {}
    end
    game:run_turn()
    t.eq(lions_can_block, false, "creature without flying can't block")
    t.eq(angel_can_block, true, "flyer can still block")
  end

  t.section("Effect with a trigger cost: Vampire Gourmand")
  do
    local could_block
    local game = t.setup({ { battlefield = { "Vampire Gourmand", "Savannah Lions" },
                             controller = t.scripted({ attack = function(g, p, c) return { t.find(c, "Vampire Gourmand") } end }) },
                           { battlefield = { "Serra Angel" }, controller = t.scripted({ block = function(g, p, attackers, c)
                               could_block = statics.can_block_by(g, attackers[1], c[1])
                               return {} end }) } })
    game:run_turn()
    t.check(t.find(game.players[1].graveyard, "Savannah Lions") ~= nil, "sacrificed another creature")
    t.eq(#game.players[1].hand, 2, "draw step + 1")
    t.eq(could_block, false, "Gourmand can't be blocked")
  end

  t.section("Effect: play from exile (Norin, Swift Survivalist)")
  do
    local game = t.setup({ { battlefield = { "Norin, Swift Survivalist", "Savannah Lions", "Plains" },
                             controller = t.scripted({ actions = { cast("Savannah Lions", { when = function(g)
                                                         return g.step == "main2" end }) },
                                                       attack = function(g, p, c) return { t.find(c, "Savannah Lions") } end }) },
                           { battlefield = { "Serra Angel" }, controller = t.scripted({ block = function(g, p, attackers, c)
                               return { { blocker = c[1], attacker = attackers[1] } } end }) } })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(p1.battlefield, "Savannah Lions") ~= nil, "blocked creature exiled, then cast from exile")
    t.eq(#p1.exile, 0, "nothing left in exile")
    t.check(t.find(game.players[2].battlefield, "Serra Angel").damage == 0, "Angel took no damage")
  end
end
