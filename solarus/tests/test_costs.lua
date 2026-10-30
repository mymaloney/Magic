-- Additional and optional costs, X, kicker, flashback, searching/choosing from zones, granted
-- hidden keywords, delayed sacrifices, characteristic-defining P/T, prowess and the remaining
-- replacement effects. Outcomes follow the card text and Forge's implementations.

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

local function pick(name)
  return function(game, player, ability, candidates)
    for _, c in ipairs(candidates) do
      local n = c.life ~= nil and ("player:" .. c.index) or c:name()
      if n == name then
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
  t.section("additional cost: discard")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 2), hand = { "Tormenting Voice", "Plains" },
                             controller = t.scripted({ actions = { cast("Tormenting Voice") } }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(p1.graveyard, "Plains") ~= nil, "discarded a card to cast it")
    t.eq(#p1.hand, 3, "draw step + 2")
  end

  t.section("additional cost: sacrifice, X = its power")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 2, "Serra Angel"), hand = { "Fling" },
                             controller = t.scripted({ actions = { cast("Fling") }, targets = pick("player:2") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 16, "Fling dealt the sacrificed Angel's 4 power")
    t.check(t.find(game.players[1].graveyard, "Serra Angel") ~= nil, "Angel was sacrificed")
  end

  t.section("X spell")
  do
    local game = t.setup({ { battlefield = lands("Island", 5), hand = { "Pull from Tomorrow" },
                             controller = t.scripted({ actions = { cast("Pull from Tomorrow") } }) }, {} })
    game:run_turn()
    t.eq(#game.players[1].hand, 3, "X = 3 (max affordable): draw step 1 + 3 drawn - 1 discarded")
  end

  t.section("kicker")
  for _, kick in ipairs({ true, false }) do
    local game = t.setup({ { battlefield = lands("Island", 4), hand = { "Into the Roil" },
                             controller = t.scripted({ actions = { cast("Into the Roil") }, targets = pick("Serra Angel"),
                                                       optional = function() return kick end }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.check(t.find(game.players[2].hand, "Serra Angel") ~= nil, "bounced (kicked = " .. tostring(kick) .. ")")
    t.eq(#game.players[1].hand, kick and 2 or 1, "draws only if kicked")
  end

  t.section("flashback")
  do
    local game = t.setup({ { battlefield = lands("Island", 5), hand = { "Think Twice" },
                             controller = t.scripted({ actions = { cast("Think Twice"), cast("Think Twice", { flashback = true }) } }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(p1.exile, "Think Twice") ~= nil, "flashed back, then exiled")
    t.eq(#p1.hand, 3, "draw step + two draws")
  end

  t.section("optional costs in abilities")
  for _, pay in ipairs({ true, false }) do
    local game = t.setup({ { battlefield = lands("Mountain", 4), hand = { "Keldon Raider", "Plains" },
                             controller = t.scripted({ actions = { cast("Keldon Raider") }, optional = function() return pay end }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.eq(#p1.graveyard, pay and 1 or 0, "discard only if paying (" .. tostring(pay) .. ")")
    t.eq(#p1.hand, pay and 2 or 2, "hand: Plains + draw step, and when paying, Plains discarded + 1 drawn")
  end

  t.section("search and choose from a zone")
  do
    local game = t.setup({ { battlefield = { "Forest" }, hand = { "Bushwhack" }, library = { "Plains", "Forest", "Savannah Lions" },
                             controller = t.scripted({ actions = { cast("Bushwhack") }, mode = function() return 1 end,
                                                       cards = function(g, p, cards) return { cards[1] } end }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.eq(#p1.hand, 2, "drew Savannah Lions + fetched a basic land")
    local basics = 0
    for _, c in ipairs(p1.hand) do
      basics = basics + (c:is_land() and 1 or 0)
    end
    t.eq(basics, 1, "the fetched card is a basic land")

    local bond = t.setup({ { battlefield = { "Forest", "Forest" }, hand = { "Broken Bond", "Swamp" },
                             controller = t.scripted({ actions = { cast("Broken Bond") },
                                                       cards = function(g, p, cards, min, max) return { cards[1] } end }) },
                           { battlefield = { "Anthem of Champions" } } })
    bond:run_turn()
    t.check(t.find(bond.players[2].graveyard, "Anthem of Champions") ~= nil, "destroyed the enchantment")
    t.check(t.find(bond.players[1].battlefield, "Swamp") ~= nil, "put a land from hand onto the battlefield")
  end

  t.section("return from the graveyard tapped")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 2), graveyard = { "Reassembling Skeleton" },
                             controller = t.scripted({ actions = { function(g, p, actions)
                               for _, a in ipairs(actions) do
                                 if a.kind == "activate" then
                                   return a
                                 end
                               end
                             end } }) }, {} })
    game:run_turn()
    local skeleton = t.find(game.players[1].battlefield, "Reassembling Skeleton")
    t.check(skeleton ~= nil and skeleton.tapped, "returned to the battlefield tapped")
  end

  t.section("doesn't untap / can't block")
  do
    local game = t.setup({ { battlefield = lands("Island", 3), hand = { "Frost Breath" },
                             controller = t.scripted({ actions = { cast("Frost Breath") },
                                                       targets = function(g, p, a, c) return { c[1] } end }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    local angel = t.find(game.players[2].battlefield, "Serra Angel")
    t.eq(angel.tapped, true, "tapped")
    game:run_turn()
    t.eq(angel.tapped, true, "didn't untap in its controller's next untap step")
    game:run_turn()
    game:run_turn()
    t.eq(angel.tapped, false, "untaps the time after")

    local combat = require("scripts/mtg/combat")
    local duel = t.setup({ { battlefield = lands("Mountain", 4), hand = { "Voldaren Duelist" },
                             controller = t.scripted({ actions = { cast("Voldaren Duelist") }, targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    duel:run_turn()
    t.eq(combat.can_block(duel, t.find(duel.players[2].battlefield, "Serra Angel")), true, "the effect ended at end of turn")
  end

  t.section("characteristic-defining P/T")
  do
    local game = t.setup({ { battlefield = { "Crusader of Odric", "Savannah Lions", "Elite Vanguard" } }, {} })
    local crusader = t.find(game.players[1].battlefield, "Crusader of Odric")
    t.eq(crusader:power(), 3, "*/* = number of creatures you control")
    t.eq(crusader:toughness(), 3, "toughness too")
  end

  t.section("prowess")
  do
    local game = t.setup({ { battlefield = lands("Island", 2, "Elementalist Adept"), hand = { "Opt" },
                             controller = t.scripted({ actions = { cast("Opt") } }) }, {} })
    local pumped
    game:on_event(function(e)
      if e.type == "pump" and e.card:name() == "Elementalist Adept" then
        pumped = e.card:power()
      end
    end)
    game:run_turn()
    t.eq(pumped, 3, "noncreature spell: the 2/1 gets +1/+1 until end of turn")
  end

  t.section("damage doubling and can't lose")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 1, "Twinflame Tyrant"), hand = { "Shock" },
                             controller = t.scripted({ actions = { cast("Shock") }, targets = pick("player:2") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 16, "Shock dealt double damage to the opponent")

    local herald = t.setup({ { battlefield = { "Herald of Eternal Dawn" }, life = 0 }, {} })
    herald:check_state_based_actions()
    t.eq(herald.over, false, "a player with Herald of Eternal Dawn doesn't lose at 0 life")
  end

  t.section("untap lock")
  do
    local game = t.setup({ { battlefield = lands("Island", 3), hand = { "Starlight Snare" },
                             controller = t.scripted({ actions = { cast("Starlight Snare") }, targets = pick("Serra Angel") }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    local angel = t.find(game.players[2].battlefield, "Serra Angel")
    t.eq(angel.tapped, true, "tapped as the Aura entered")
    game:run_turn()
    t.eq(angel.tapped, true, "doesn't untap while enchanted")
  end
end
