local mana = require("scripts/mtg/mana")

return function(t)
  t.section("parse_cost")
  local cost = mana.parse_cost("3 W W")
  t.eq(cost.generic, 3, "generic part")
  t.eq(#cost.shards, 2, "colored shards")
  t.eq(mana.mana_value(cost), 5, "mana value")
  t.eq(mana.parse_cost("no cost"), nil, "no cost")
  local xr = mana.parse_cost("X R")
  t.check(xr ~= nil and xr.x == 1 and xr.generic == 0, "X is counted separately (chosen on casting)")
  local bad, reason = mana.parse_cost("2/W")
  t.check(bad == nil and reason == "mana symbol 2/W", "unknown symbols are reported unsupported")

  t.section("parse_produced")
  t.eq(table.concat(mana.parse_produced("G")), "G", "single color")
  t.eq(table.concat(mana.parse_produced("Combo W U")), "WU", "combo")
  t.eq(#mana.parse_produced("Any"), 5, "any color")
  t.eq(table.concat(mana.parse_produced("Combo W Chosen"), ","), "W,Chosen", "chosen color is resolved later")
  t.eq(mana.parse_produced("Combo W Remembered"), nil, "unknown Produced$ parts are unsupported")

  t.section("find_payment")
  local id = 0
  local function src(...)
    id = id + 1
    return { card = { id = id }, colors = { ... } }
  end
  -- The any-color source must be saved for U; the narrow sources pay W and generic.
  local sources = { src("W", "U", "B", "R", "G"), src("W"), src("W") }
  local payment = mana.find_payment(mana.parse_cost("1 W U"), sources)
  t.check(payment ~= nil, "1WU payable with Plains, Plains, any-color")
  local paid_u
  for _, p in ipairs(payment or {}) do
    if p.color == "U" then
      paid_u = p.source
    end
  end
  t.check(paid_u == sources[1], "U paid by the any-color source")
  t.eq(mana.find_payment(mana.parse_cost("U U"), { src("U"), src("W") }), nil, "UU not payable with one blue source")
  t.eq(mana.find_payment(mana.parse_cost("3"), { src("G"), src("G") }), nil, "not enough sources")

  -- An ability making three mana of one color: its units pay with a single color.
  local group = { amount = 3 }
  local card = { id = 100 }
  local units = {}
  for u = 1, 3 do
    units[u] = { card = card, colors = { "W", "U", "B", "R", "G" }, group = group, unit = u }
  end
  local p = mana.find_payment(mana.parse_cost("G G"), units)
  t.check(p ~= nil and #p == 2 and p[1].color == "G" and p[2].color == "G", "two units pay GG")
  t.eq(mana.find_payment(mana.parse_cost("G U"), units), nil, "units can't pay two different colors")
  t.check(mana.find_payment(mana.parse_cost("1 U"), { units[1], units[2], units[3], src("G") }) ~= nil,
          "units mix with other sources")

  local function lands(name, n, ...)
    local list = { ... }
    for _ = 1, n do
      table.insert(list, 1, name)
    end
    return list
  end
  local function cast(name)
    return function(game, player, actions)
      for _, action in ipairs(actions) do
        if action.kind == "cast" and action.card:name() == name then
          return action
        end
      end
    end
  end

  local function can_cast(game, player, name)
    for _, action in ipairs(game:legal_actions(player)) do
      if action.kind == "cast" and action.card:name() == name then
        return true
      end
    end
    return false
  end

  t.section("restricted multi-mana: Somberwald Sage")
  do
    local game = t.setup({ { battlefield = { "Somberwald Sage" }, hand = { "Shock", "Savannah Lions", "Savannah Lions" },
                             controller = t.scripted({ actions = { cast("Savannah Lions"), cast("Savannah Lions") } }) }, {} })
    local p1 = game.players[1]
    game.step = "main1"
    t.eq(can_cast(game, p1, "Shock"), false, "can't spend it on a noncreature spell")
    t.eq(can_cast(game, p1, "Savannah Lions"), true, "can spend it on a creature spell")
    game:run_turn()
    local lions = 0
    for _, c in ipairs(p1.battlefield) do
      lions = lions + (c:name() == "Savannah Lions" and 1 or 0)
    end
    t.eq(lions, 2, "second creature paid from the leftover mana in the pool")
    t.eq(#p1.mana_pool, 0, "pool empties")

    local game2 = t.setup({ { battlefield = { "Somberwald Sage", "Plains", "Plains" }, hand = { "Serra Angel" },
                              controller = t.scripted({ actions = { cast("Serra Angel") } }) }, {} })
    game2:run_turn()
    t.check(t.find(game2.players[1].battlefield, "Serra Angel") ~= nil, "3 Sage mana + 2 Plains pay 3WW")
  end

  t.section("persistent mana: Brazen Collector")
  do
    local shock_in_main2 = function(g, p, actions)
      return g.step == "main2" and cast("Shock")(g, p, actions) or nil
    end
    local game = t.setup({ { battlefield = { "Brazen Collector" }, hand = { "Shock" },
                             controller = t.scripted({ actions = { shock_in_main2 },
                                                       targets = function(g, p, a, c) return { g.players[2] } end,
                                                       attack = function(g, p, c) return c end }) }, {} })
    local p1 = game.players[1]
    local pool_in_main2
    game:on_event(function(e)
      if e.type == "step" and e.step == "main2" and pool_in_main2 == nil then
        pool_in_main2 = #p1.mana_pool
      end
    end)
    game:run_turn()
    t.check(pool_in_main2 ~= nil, "reached main 2")
    t.check(t.find(p1.graveyard, "Shock") ~= nil, "Shock cast in main 2 with the Collector's mana")
    t.eq(game.players[2].life, 16, "2 combat + 2 Shock")
  end

  t.section("tap creatures for mana: Heirloom Epic")
  do
    local game = t.setup({ { battlefield = { "Heirloom Epic", "Plains", "Savannah Lions", "Savannah Lions", "Elite Vanguard" },
                             controller = t.scripted({ actions = { function(g, p, actions)
                               for _, a in ipairs(actions) do
                                 if a.kind == "activate" and a.card:name() == "Heirloom Epic" then
                                   return a
                                 end
                               end
                             end } }) }, {} })
    game:run_turn()
    local p1 = game.players[1]
    t.eq(#p1.hand, 2, "draw step + 1")
    local tapped = 0
    for _, c in ipairs(p1.battlefield) do
      tapped = tapped + (c:is_creature() and c.tapped and 1 or 0)
    end
    t.eq(tapped, 3, "three creatures tapped for the rest of {4}")
  end
end
