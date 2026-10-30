-- Activated abilities: costs (mana, tap, sacrifice, discard), activation limits, and mana
-- abilities with costs (filters, sacrifice). Outcomes follow the card text (Forge's Cost*, CostPayment).

local function activate(name, index)
  return function(game, player, actions)
    for _, action in ipairs(actions) do
      if action.kind == "activate" and action.card:name() == name and (index == nil or action.index == index) then
        return action
      end
    end
    return nil
  end
end

local function cast(name)
  return function(game, player, actions)
    for _, action in ipairs(actions) do
      if action.kind == "cast" and action.card:name() == name then
        return action
      end
    end
    return nil
  end
end

local function count_kind(actions, kind)
  local n = 0
  for _, a in ipairs(actions) do
    if a.kind == kind then
      n = n + 1
    end
  end
  return n
end

local function opponent_target(game, player, ability, candidates)
  for _, c in ipairs(candidates) do
    if c == game.players[2] then
      return { c }
    end
  end
end

return function(t)
  t.section("tap + sacrifice cost")
  do
    local game = t.setup({ { battlefield = { "Fanatical Firebrand" },
                             controller = t.scripted({ actions = { activate("Fanatical Firebrand") }, targets = opponent_target }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 19, "Fanatical Firebrand dealt 1")
    t.check(t.find(game.players[1].graveyard, "Fanatical Firebrand") ~= nil, "and was sacrificed as a cost")
  end

  t.section("mana cost on an activated ability")
  do
    local game = t.setup({ { battlefield = { "Island", "Island", "Island", "Island", "Island", "Mystic Archaeologist" },
                             controller = t.scripted({ actions = { activate("Mystic Archaeologist") } }) }, {} })
    game:run_turn()
    t.eq(#game.players[1].hand, 3, "draw step + 2 from the ability")
    local tapped = 0
    for _, c in ipairs(game.players[1].battlefield) do
      tapped = tapped + (c.tapped and 1 or 0)
    end
    t.eq(tapped, 5, "{3}{U}{U} paid with five Islands")
  end

  t.section("discard + sacrifice cost")
  do
    local game = t.setup({ { battlefield = { "Insolent Neonate" }, hand = { "Plains", "Plains" },
                             controller = t.scripted({ actions = { activate("Insolent Neonate") } }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.eq(#p1.graveyard, 2, "discarded a card and sacrificed the Neonate")
    t.eq(#p1.hand, 3, "2 - 1 discarded + draw step + 1 drawn")
  end

  t.section("filter mana with an activation limit")
  do
    local game = t.setup({ { battlefield = { "Island", "Island", "Scarecrow Guide" }, hand = { "Savannah Lions", "Elite Vanguard" } }, {} })
    local p1 = game.players[1]
    game.step = "main1"
    t.eq(count_kind(game:legal_actions(p1), "cast"), 2, "{1}: add one mana of any color makes W")
    game:perform(p1, cast("Savannah Lions")(game, p1, game:legal_actions(p1)))
    t.eq(count_kind(game:legal_actions(p1), "cast"), 0, "only once each turn")
  end

  t.section("sacrifice and tap-filter mana sources")
  do
    local game = t.setup({ { battlefield = { "Wild Cantor" }, hand = { "Savannah Lions" } }, {} })
    local p1 = game.players[1]
    game.step = "main1"
    game:perform(p1, cast("Savannah Lions")(game, p1, game:legal_actions(p1)))
    t.check(t.find(p1.graveyard, "Wild Cantor") ~= nil, "Wild Cantor sacrificed for W")

    local lens = t.setup({ { battlefield = { "Forest", "Prismatic Lens" }, hand = { "Savannah Lions", "Llanowar Elves" } }, {} })
    local q1 = lens.players[1]
    lens.step = "main1"
    lens:perform(q1, cast("Savannah Lions")(lens, q1, lens:legal_actions(q1)))
    t.eq(t.find(q1.battlefield, "Prismatic Lens").tapped, true, "Lens filtered the Forest's mana into W")
    t.eq(t.find(q1.battlefield, "Forest").tapped, true, "the Forest paid the filter's {1}")
  end

  t.section("AI uses activated abilities")
  do
    local ai = require("scripts/mtg/controllers/ai")
    local game = t.setup({ { battlefield = { "Plains", "Gideon's Lawkeeper" }, controller = ai.new() },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    t.eq(t.find(game.players[2].battlefield, "Serra Angel").tapped, true, "AI tapped the opponent's best creature")
  end
end
