-- Headless tests for the pure-Lua parts of the quest (no Solarus needed).
-- Run from the repository root:  luajit solarus/tests/run.lua

package.path = "solarus/quest/data/?.lua;" .. package.path

local script_parser = require("scripts/mtg/script_parser")

local failures, checks = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  end
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- Parameter maps
local p = script_parser.parse_params("SP$ DealDamage | ValidTgts$ Any | NumDmg$ 3 | SpellDescription$ CARDNAME deals 3 damage to any target.")
check(p.SP == "DealDamage" and p.ValidTgts == "Any" and p.NumDmg == "3", "parse_params basic keys")
check(p.SpellDescription == "CARDNAME deals 3 damage to any target.", "parse_params keeps value text")

-- Every card in the synced pool parses and its first face name matches the pool entry
local pool = dofile("solarus/quest/data/cards/pool.lua")
check(#pool > 0, "pool.lua is not empty")
for _, entry in ipairs(pool) do
  local card = script_parser.parse(read("solarus/quest/data/cards/" .. entry.file))
  check(card.faces[1].name == entry.name, entry.file .. ": name '" .. tostring(card.faces[1].name) .. "' ~= '" .. entry.name .. "'")
  check(card.faces[1].mana_cost ~= nil, entry.file .. ": has ManaCost")
end

-- Spot checks against known scripts
local angel = script_parser.parse(read("solarus/quest/data/cards/serra_angel.txt")).faces[1]
check(angel.pt == "4/4" and angel.keywords[1] == "Flying" and angel.keywords[2] == "Vigilance", "Serra Angel P/T and keywords")

local arbiter = script_parser.parse(read("solarus/quest/data/cards/arbiter_of_woe.txt")).faces[1]
check(arbiter.triggers[1].Mode == "ChangesZone" and arbiter.triggers[1].Execute == "TrigDiscard", "Arbiter of Woe trigger")
local sub = script_parser.parse_params(arbiter.svars.TrigDiscard)
check(sub.DB == "Discard" and sub.SubAbility == "DBLoseLife", "Arbiter of Woe SVar sub-ability chain")

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
