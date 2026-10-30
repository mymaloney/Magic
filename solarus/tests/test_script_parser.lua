local script_parser = require("scripts/mtg/script_parser")

return function(t)
  t.section("parse_params")
  local p = script_parser.parse_params("SP$ DealDamage | ValidTgts$ Any | NumDmg$ 3 | SpellDescription$ CARDNAME deals 3 damage to any target.")
  t.check(p.SP == "DealDamage" and p.ValidTgts == "Any" and p.NumDmg == "3", "parse_params basic keys")
  t.eq(p.SpellDescription, "CARDNAME deals 3 damage to any target.", "parse_params keeps value text")

  t.section("every pool card parses")
  t.check(#t.pool > 0, "pool.lua is not empty")
  for _, entry in ipairs(t.pool) do
    local card = script_parser.parse(t.read("solarus/quest/data/cards/" .. entry.file))
    t.eq(card.faces[1].name, entry.name, entry.file .. ": name")
    t.check(card.faces[1].mana_cost ~= nil, entry.file .. ": has ManaCost")
  end

  t.section("spot checks")
  local angel = script_parser.parse(t.read("solarus/quest/data/cards/serra_angel.txt")).faces[1]
  t.check(angel.pt == "4/4" and angel.keywords[1] == "Flying" and angel.keywords[2] == "Vigilance", "Serra Angel P/T and keywords")

  local arbiter = script_parser.parse(t.read("solarus/quest/data/cards/arbiter_of_woe.txt")).faces[1]
  t.check(arbiter.triggers[1].Mode == "ChangesZone" and arbiter.triggers[1].Execute == "TrigDiscard", "Arbiter of Woe trigger")
  local sub = script_parser.parse_params(arbiter.svars.TrigDiscard)
  t.check(sub.DB == "Discard" and sub.SubAbility == "DBLoseLife", "Arbiter of Woe SVar sub-ability chain")
end
