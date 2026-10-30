-- Trigger modes beyond ChangesZone, intervening-if conditions, SVar amounts, ability conditions
-- and hybrid mana. Outcomes follow the card text (Forge's Trigger<Mode>, AbilityUtils.xCount).

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

local function attack_with(...)
  local names = { ... }
  return function(game, player, candidates)
    local list = {}
    for _, name in ipairs(names) do
      for _, card in ipairs(candidates) do
        local taken = false
        for _, c in ipairs(list) do
          taken = taken or c == card
        end
        if card:name() == name and not taken then
          list[#list + 1] = card
          break
        end
      end
    end
    return list
  end
end

local function in_step(step)
  return function(game) return game.step == step end
end

local function lands(name, n, ...)
  local list = { ... }
  for _ = 1, n do
    table.insert(list, 1, name)
  end
  return list
end

return function(t)
  t.section("Attacks trigger")
  do
    local game = t.setup({ { battlefield = { "Pulse Tracker" }, controller = t.scripted({ attack = attack_with("Pulse Tracker") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 18, "1 combat damage + 1 life lost from the attack trigger")
  end

  t.section("AttackersDeclared with a count")
  for _, flyers in ipairs({ 1, 2 }) do
    local attackers = flyers == 2 and { "Tide Skimmer", "Healer's Hawk" } or { "Tide Skimmer" }
    local game = t.setup({ { battlefield = { "Tide Skimmer", "Healer's Hawk" },
                             controller = t.scripted({ attack = attack_with(unpack(attackers)) }) }, {} })
    game:run_turn()
    t.eq(#game.players[1].hand, flyers == 2 and 2 or 1, "Tide Skimmer draws only when two or more flyers attack (" .. flyers .. ")")
  end

  t.section("Phase trigger with IsPresent")
  for _, extra in ipairs({ 1, 2 }) do
    local bf = { "Leonin Vanguard", "Savannah Lions" }
    if extra == 2 then
      bf[#bf + 1] = "Elite Vanguard"
    end
    local game = t.setup({ { battlefield = bf }, {} })
    game:run_turn()
    t.eq(game.players[1].life, extra == 2 and 21 or 20, "Leonin Vanguard gains life only with three creatures (" .. #bf .. ")")
  end

  t.section("SpellCast: second spell each turn")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 2, "Devoted Duelist"), hand = { "Shock", "Shock" },
                             controller = t.scripted({ actions = { cast("Shock"), cast("Shock") },
                                                       targets = function(g, p, a, candidates)
                                                         for _, c in ipairs(candidates) do
                                                           if c == g.players[2] then
                                                             return { c }
                                                           end
                                                         end
                                                       end }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 15, "two Shocks (4) + Devoted Duelist on the second spell (1)")
  end

  t.section("LifeGained and LifeLost")
  do
    local game = t.setup({ { battlefield = { "Healer's Hawk", "Marauding Blight-Priest" }, controller = t.scripted({ attack = attack_with("Healer's Hawk") }) }, {} })
    game:run_turn()
    t.eq(game.players[2].life, 18, "Hawk's 1 damage + Blight-Priest drain on the lifelink gain")
    t.eq(game.players[1].life, 21, "lifelink")

    local conqueror = t.setup({ { battlefield = { "Mountain", "Bloodthirsty Conqueror" }, hand = { "Shock" },
                                  controller = t.scripted({ actions = { cast("Shock") }, targets = function(g, p, a, c)
                                    for _, x in ipairs(c) do
                                      if x == g.players[2] then
                                        return { x }
                                      end
                                    end
                                  end }) }, {} })
    conqueror:run_turn()
    t.eq(conqueror.players[1].life, 22, "Bloodthirsty Conqueror: gain life equal to the opponent's loss")
  end

  t.section("Raid (CheckSVar on a trigger)")
  for _, attacked in ipairs({ false, true }) do
    local game = t.setup({ { battlefield = lands("Mountain", 5, "Savannah Lions"), hand = { "Gorehorn Raider" },
                             controller = t.scripted({ actions = { cast("Gorehorn Raider", in_step("main2")) },
                                                       attack = attacked and attack_with("Savannah Lions") or nil,
                                                       targets = function(g, p, a, c)
                                                         for _, x in ipairs(c) do
                                                           if x == g.players[2] then
                                                             return { x }
                                                           end
                                                         end
                                                       end }) }, {} })
    game:run_turn()
    local expected = 20 - (attacked and 2 + 2 or 0)
    t.eq(game.players[2].life, expected, "Gorehorn Raider deals 2 only if you attacked (" .. tostring(attacked) .. ")")
  end

  t.section("Condition on a sub-ability")
  for _, attacked in ipairs({ false, true }) do
    local game = t.setup({ { battlefield = { "Island", "Island", "Savannah Lions" }, hand = { "Chart a Course" },
                             controller = t.scripted({ actions = { cast("Chart a Course", in_step("main2")) },
                                                       attack = attacked and attack_with("Savannah Lions") or nil }) }, {} })
    game:run_turn()
    t.eq(#game.players[1].graveyard, attacked and 1 or 2, "Chart a Course discards unless you attacked (" .. tostring(attacked) .. ")")
  end

  t.section("Morbid amount")
  do
    local game = t.setup({ { battlefield = lands("Swamp", 5), hand = { "Murder", "Tragic Banshee" },
                             controller = t.scripted({ actions = { cast("Murder"), cast("Tragic Banshee") } }) },
                           { battlefield = { "Savannah Lions", "Gigantosaurus" } } })
    -- 5 Swamps: Murder (3) leaves 2, not enough for the Banshee; give more mana.
    for _ = 1, 3 do
      game:create_card(t.db.get("Swamp"), game.players[1], "battlefield", { sick = false })
    end
    game.players[1].controller.choose_targets = function(_, g, p, ability, candidates)
      local want = ability.api == "Destroy" and "Savannah Lions" or "Gigantosaurus"
      for _, c in ipairs(candidates) do
        if c.life == nil and c:name() == want then
          return { c }
        end
      end
    end
    game:run_turn()
    t.check(t.find(game.players[2].graveyard, "Gigantosaurus") ~= nil, "after a creature died, Tragic Banshee gives -13/-13")
  end

  t.section("hybrid mana")
  do
    local game = t.setup({ { battlefield = { "Mountain" }, hand = { "Footlight Fiend" } }, {} })
    game.step = "main1"
    t.eq(#game:legal_actions(game.players[1]), 1, "{B/R} paid with a Mountain")
  end

  t.section("enters-tapped replacements")
  do
    local game = t.setup({ { hand = { "Thriving Heath" },
                             controller = t.scripted({ actions = { function(g, p, actions)
                               for _, a in ipairs(actions) do
                                 if a.kind == "play_land" then
                                   return a
                                 end
                               end
                             end }, color = function(g, p, source, options) return "U" end }) }, {} })
    local taps = 0
    game:on_event(function(e) if e.type == "tap" then taps = taps + 1 end end)
    game.step = "main1"
    local land = t.find(game.players[1].hand, "Thriving Heath")
    game:perform(game.players[1], { kind = "play_land", card = land })
    t.eq(land.tapped, true, "Thriving Heath enters tapped")
    t.eq(taps, 0, "entering tapped isn't becoming tapped")
    t.eq(land.chosen_color, "U", "color chosen as it enters")
    land.tapped = false
    local sources = game:mana_sources(game.players[1])
    t.eq(table.concat(sources[1].colors, ","), "W,U", "taps for W or the chosen color")

    local campground = t.setup({ { battlefield = {} }, {} })
    local c1 = campground:create_card(t.db.get("Abandoned Campground"), campground.players[1], "hand")
    campground:move(c1, "battlefield")
    t.eq(c1.tapped, true, "Abandoned Campground enters tapped at 20 life")
    campground.players[2].life = 13
    local c2 = campground:create_card(t.db.get("Abandoned Campground"), campground.players[1], "hand")
    campground:move(c2, "battlefield")
    t.eq(c2.tapped, false, "...but untapped once a player has 13 or less life")
  end

  t.section("ManaExpend")
  do
    local game = t.setup({ { battlefield = lands("Mountain", 6, "Roughshod Duo"), hand = { "Gorehorn Raider" },
                             controller = t.scripted({ actions = { cast("Gorehorn Raider") } }) }, {} })
    local pumped = false
    game:on_event(function(e)
      if e.type == "pump" then
        pumped = true
      end
    end)
    game:run_turn()
    t.check(pumped, "spending a 4th mana this turn triggers Roughshod Duo")
  end
end
