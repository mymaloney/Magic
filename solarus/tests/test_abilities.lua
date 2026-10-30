-- Triggered abilities, spells, targeting and effects. Expected outcomes follow the card text and the
-- Comprehensive Rules as Forge implements them (TriggerHandler, MagicStack, AbilityUtils, *Effect).

local abilities = require("scripts/mtg/abilities")

-- Action that casts `name` when it's legal (optionally only when `when(game)` holds).
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

local function attack_with(name)
  return function(game, player, candidates)
    for _, card in ipairs(candidates) do
      if card:name() == name then
        return { card }
      end
    end
    return {}
  end
end

-- Target chooser picking one candidate per call, by name, in order ("player:1"/"player:2" for players).
local function target(...)
  local wanted = { ... }
  local next_index = 1
  return function(game, player, ability, candidates)
    local w = wanted[next_index]
    next_index = next_index + 1
    for _, c in ipairs(candidates) do
      local name = c.life ~= nil and ("player:" .. c.index) or c:name()
      if name == w then
        return { c }
      end
    end
    return {}
  end
end

local function events_of(game, kind)
  local list = {}
  game:on_event(function(e)
    if e.type == kind then
      list[#list + 1] = e
    end
  end)
  return list
end

local function stack_top_is(name)
  return function(game)
    local top = game.stack[#game.stack]
    return top ~= nil and top.card:name() == name
  end
end

local function lands(name, n)
  local list = {}
  for i = 1, n do
    list[i] = name
  end
  return list
end

local function with(list, ...)
  local result = {}
  for _, v in ipairs(list) do
    result[#result + 1] = v
  end
  for _, v in ipairs({ ... }) do
    result[#result + 1] = v
  end
  return result
end

return function(t)
  t.section("ETB trigger: draw")
  do
    local game = t.setup({ { battlefield = lands("Island", 3), hand = { "Cloudkin Seer" },
                             controller = t.scripted({ actions = { cast("Cloudkin Seer") } }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.check(t.find(p1.battlefield, "Cloudkin Seer") ~= nil, "Cloudkin Seer resolved")
    t.eq(#p1.hand, 2, "draw step card + ETB draw")
  end

  t.section("ETB trigger with a target, and with no legal target")
  do
    local game = t.setup({ { battlefield = lands("Island", 3), hand = { "Exclusion Mage" },
                             controller = t.scripted({ actions = { cast("Exclusion Mage") } }) },
                           { battlefield = { "Savannah Lions" } } })
    game:run_turn()
    t.check(t.find(game.players[2].hand, "Savannah Lions") ~= nil, "opponent's creature bounced to hand")

    local empty = t.setup({ { battlefield = lands("Island", 3), hand = { "Exclusion Mage" },
                              controller = t.scripted({ actions = { cast("Exclusion Mage") } }) }, {} })
    local removed = events_of(empty, "trigger_removed")
    empty:run_turn()
    t.eq(#removed, 1, "trigger with no legal target is removed from the stack (CR 603.3d)")
  end

  t.section("dies triggers look back at creatures dying together")
  do
    local game = t.setup({ { battlefield = with(lands("Plains", 4), "Cruel Celebrant", "Savannah Lions"), hand = { "Day of Judgment" },
                             controller = t.scripted({ actions = { cast("Day of Judgment") } }) },
                           { battlefield = { "Elite Vanguard" } } })
    game:run_turn()
    t.eq(#game.players[1].battlefield, 4, "only lands left")
    t.eq(#game.players[2].battlefield, 0, "opponent's creature destroyed too")
    t.eq(game.players[2].life, 18, "Celebrant saw itself and Savannah Lions die (2 triggers)")
    t.eq(game.players[1].life, 22, "and drained 2")
  end

  t.section("another creature entering")
  do
    local game = t.setup({ { battlefield = { "Plains", "Dazzling Angel" }, hand = { "Savannah Lions" },
                             controller = t.scripted({ actions = { cast("Savannah Lions") } }) }, {} })
    game:run_turn()
    t.eq(game.players[1].life, 21, "Dazzling Angel: gain 1 when another creature you control enters")
  end

  t.section("burn spells and targets")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 2), hand = { "Shock", "Shock" },
                             controller = t.scripted({ actions = { cast("Shock"), cast("Shock") },
                                                       targets = target("player:2", "Elite Vanguard") }) },
                           { battlefield = { "Elite Vanguard", "Serra Angel" } } })
    game:run_turn()
    t.eq(game.players[2].life, 18, "Shock to the face")
    t.check(t.find(game.players[2].graveyard, "Elite Vanguard") ~= nil, "Shock kills a 2/1")
    t.eq(#game.players[1].graveyard, 2, "both Shocks went to the graveyard")
  end

  t.section("responding: the original spell fizzles")
  do
    local game = t.setup({
      { battlefield = lands("Swamp", 3), hand = { "Murder" }, controller = t.scripted({ actions = { cast("Murder") } }) },
      { battlefield = { "Savannah Lions", "Island" }, hand = { "Unsummon" },
        controller = t.scripted({ actions = { cast("Unsummon", stack_top_is("Murder")) } }) },
    })
    local fizzles = events_of(game, "fizzle")
    game:run_turn()
    t.check(t.find(game.players[2].hand, "Savannah Lions") ~= nil, "Unsummon resolved first (stack is last in, first out)")
    t.eq(#fizzles, 1, "Murder had no legal target left and didn't resolve")
    t.check(t.find(game.players[1].graveyard, "Murder") ~= nil, "fizzled spell goes to the graveyard")
  end

  t.section("counterspell")
  do
    local game = t.setup({
      { battlefield = { "Plains" }, hand = { "Savannah Lions" }, controller = t.scripted({ actions = { cast("Savannah Lions") } }) },
      { battlefield = lands("Island", 2), hand = { "Essence Scatter" },
        controller = t.scripted({ actions = { cast("Essence Scatter", stack_top_is("Savannah Lions")) } }) },
    })
    game:run_turn()
    t.check(t.find(game.players[1].graveyard, "Savannah Lions") ~= nil, "countered creature spell is in the graveyard")
    t.eq(#game.players[1].battlefield, 1, "it never entered")
  end

  t.section("until end of turn pump")
  do
    local game = t.setup({ { battlefield = { "Forest", "Savannah Lions" }, hand = { "Giant Growth" },
                             controller = t.scripted({ actions = { cast("Giant Growth") }, attack = attack_with("Savannah Lions") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 15, "pumped 5/4 attacker")
    t.eq(t.find(game.players[1].battlefield, "Savannah Lions"):power(), 2, "pump ends at cleanup")
  end

  t.section("optional trigger")
  for _, accept in ipairs({ true, false }) do
    local game = t.setup({ { battlefield = lands("Swamp", 4), hand = { "Gravedigger" }, graveyard = { "Serra Angel" },
                             controller = t.scripted({ actions = { cast("Gravedigger") }, optional = function() return accept end }) }, {} })
    game:run_turn()
    local in_hand = t.find(game.players[1].hand, "Serra Angel") ~= nil
    t.eq(in_hand, accept, "Gravedigger returns the creature only if its controller says yes (" .. tostring(accept) .. ")")
  end

  t.section("hexproof")
  do
    local game = t.setup({ { battlefield = { "Mountain" }, hand = { "Shock" } }, { battlefield = { "Sylvan Caryatid" } } })
    local shock = t.find(game.players[1].hand, "Shock")
    local p1, p2 = game.players[1], game.players[2]
    local caryatid = t.find(p2.battlefield, "Sylvan Caryatid")
    local function can_target(controller)
      for _, c in ipairs(abilities.target_candidates(game, shock.def.spell, { game = game, source = shock, controller = controller })) do
        if c == caryatid then
          return true
        end
      end
      return false
    end
    t.eq(can_target(p1), false, "opponent can't target a hexproof creature")
    t.eq(can_target(p2), true, "its controller can")
  end

  t.section("discard, death triggers with targets, reanimation")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 3), hand = { "Mind Rot" },
                             controller = t.scripted({ actions = { cast("Mind Rot") }, targets = target("player:2") }) },
                           { hand = { "Plains", "Island", "Swamp" } } })
    game:run_turn()
    t.eq(#game.players[2].hand, 1, "Mind Rot: target player discards two")

    local goblin = t.setup({
      { battlefield = { "Festering Goblin" }, controller = t.scripted({ attack = attack_with("Festering Goblin"), targets = target("Llanowar Elves") }) },
      { battlefield = { "Elite Vanguard", "Llanowar Elves" },
        controller = t.scripted({ block = function(game, player, attackers, candidates)
          return { { blocker = t.find(candidates, "Elite Vanguard"), attacker = attackers[1] } }
        end }) },
    })
    goblin:run_turn()
    t.check(t.find(goblin.players[2].graveyard, "Llanowar Elves") ~= nil, "Festering Goblin's death trigger gave -1/-1 to the Elves")
    t.check(t.find(goblin.players[2].graveyard, "Elite Vanguard") ~= nil, "blocker died in combat")

    local zombify = t.setup({ { battlefield = lands("Swamp", 4), hand = { "Zombify" }, graveyard = { "Serra Angel" },
                                controller = t.scripted({ actions = { cast("Zombify") } }) }, {} })
    zombify:run_turn()
    local angel = t.find(zombify.players[1].battlefield, "Serra Angel")
    t.check(angel ~= nil, "Zombify returned the creature to the battlefield")
    t.eq(angel and angel.controller, zombify.players[1], "under its owner's control")
  end
end
