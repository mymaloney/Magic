-- Reflexive and delayed triggers, Ward, extra combats, Cascade and copying spells.
-- Outcomes follow the card text and Forge's implementations.

local function cast(name, when)
  return function(game, player, actions)
    if when and not when(game, player) then
      return nil
    end
    for _, action in ipairs(actions) do
      if action.kind == "cast" and action.card:name() == name then
        return action
      end
    end
  end
end

local function target_named(name)
  return function(game, player, ability, candidates)
    for _, c in ipairs(candidates) do
      local label = c.life ~= nil and ("player:" .. c.index) or c:name()
      if label == name then
        return { c }
      end
    end
  end
end

return function(t)
  t.section("ImmediateTrigger: Ruthless Lawbringer")
  for _, pay in ipairs({ true, false }) do
    local game = t.setup({ { battlefield = { "Plains", "Swamp", "Plains", "Savannah Lions" }, hand = { "Ruthless Lawbringer" },
                             controller = t.scripted({ actions = { cast("Ruthless Lawbringer") }, targets = target_named("Serra Angel"),
                                                       optional = function() return pay end }) },
                           { battlefield = { "Serra Angel" } } })
    game:run_turn()
    local p1 = game.players[1]
    t.eq(t.find(p1.graveyard, "Savannah Lions") ~= nil, pay, "sacrificed only if chosen (" .. tostring(pay) .. ")")
    t.eq(t.find(game.players[2].graveyard, "Serra Angel") ~= nil, pay, "when you do: destroyed (" .. tostring(pay) .. ")")
  end

  t.section("Ward: Tolarian Terror")
  for _, mountains in ipairs({ 1, 3 }) do
    local lands = {}
    for i = 1, mountains do
      lands[i] = "Mountain"
    end
    local countered = false
    local game = t.setup({ { battlefield = lands, hand = { "Shock" },
                             controller = t.scripted({ actions = { cast("Shock") }, targets = target_named("Tolarian Terror") }) },
                           { battlefield = { "Tolarian Terror" } } })
    game:on_event(function(e)
      if e.type == "countered" then
        countered = true
      end
    end)
    game:run_turn()
    t.eq(countered, mountains == 1, mountains .. " Mountains: countered unless {2} paid")
    t.check(t.find(game.players[1].graveyard, "Shock") ~= nil, "Shock ends in the graveyard either way")
  end

  t.section("extra combat: Aurelia, the Warleader")
  do
    local combats = 0
    local game = t.setup({ { battlefield = { "Aurelia, the Warleader", "Savannah Lions" },
                             controller = t.scripted({ attack = function(g, p, c) return c end }) }, {} })
    game:on_event(function(e)
      if e.type == "attackers" then
        combats = combats + 1
      end
    end)
    game:run_turn()
    t.eq(combats, 2, "two combat phases (no third: Aurelia's trigger is for the first attack only)")
    t.eq(game.players[2].life, 10, "Lions untapped and attacked again: (3 + 2) x 2")
  end

  t.section("Cascade: Maelstrom Colossus")
  do
    local plains = {}
    for i = 1, 8 do
      plains[i] = "Plains"
    end
    -- top of library is the last entry: the draw step takes a Plains, then Cascade exiles a Plains
    -- and hits Savannah Lions
    local game = t.setup({ { battlefield = plains, hand = { "Maelstrom Colossus" },
                             library = { "Shivan Dragon", "Savannah Lions", "Plains", "Plains" },
                             controller = t.scripted({ actions = { cast("Maelstrom Colossus") } }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(p1.battlefield, "Maelstrom Colossus") ~= nil, "Colossus resolved")
    t.check(t.find(p1.battlefield, "Savannah Lions") ~= nil, "cascaded into Savannah Lions for free")
    t.eq(#p1.library, 2, "Shivan Dragon (too expensive, never reached) + the exiled Plains")
    t.eq(p1.library[1]:name(), "Plains", "exiled Plains went to the bottom")
    t.eq(#p1.exile, 0, "nothing left in exile")
  end

  t.section("DelayedTrigger + CopySpellAbility: Teach by Example")
  do
    local function teach_resolved(g, p)
      return #g.stack == 0 and t.find(p.graveyard, "Teach by Example") ~= nil
    end
    local game = t.setup({ { battlefield = { "Mountain", "Mountain", "Mountain" }, hand = { "Teach by Example", "Shock" },
                             controller = t.scripted({ actions = { cast("Teach by Example"), cast("Shock", teach_resolved) },
                                                       targets = target_named("player:2") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 16, "Shock and its copy each dealt 2")
    t.check(t.find(game.players[1].graveyard, "Shock") ~= nil, "the original Shock went to the graveyard once")
    t.eq(#game.delayed_triggers, 0, "the delayed trigger is used up")
  end
end
