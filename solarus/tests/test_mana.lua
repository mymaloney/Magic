local mana = require("scripts/mtg/mana")

return function(t)
  t.section("parse_cost")
  local cost = mana.parse_cost("3 W W")
  t.eq(cost.generic, 3, "generic part")
  t.eq(#cost.shards, 2, "colored shards")
  t.eq(mana.mana_value(cost), 5, "mana value")
  t.eq(mana.parse_cost("no cost"), nil, "no cost")
  local bad, reason = mana.parse_cost("X R")
  t.check(bad == nil and reason == "mana symbol X", "X is reported unsupported")

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
end
