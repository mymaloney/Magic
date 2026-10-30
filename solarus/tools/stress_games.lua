-- Stress test: AI-vs-AI games with random 40-card decks from every synced nonland card, to catch
-- engine errors the scenario tests miss. Run from the repository root:
--   luajit solarus/tools/stress_games.lua [seed] [games]

package.path = "solarus/quest/data/?.lua;" .. package.path
local card_db = require("scripts/mtg/card_db")
local Game = require("scripts/mtg/game")
local ai = require("scripts/mtg/controllers/ai")
local function read(p) local f = io.open("solarus/quest/data/" .. p, "rb") local s = f:read("*a") f:close() return s end
local db = card_db.new(dofile("solarus/quest/data/cards/pool.lua"), read)
local spells = {}
for _, d in ipairs(db.list) do
  if not d.types.Land then spells[#spells + 1] = d.name end
end
local basics = { "Plains", "Island", "Swamp", "Mountain", "Forest" }
local seed = tonumber(arg[1]) or 1
local games = tonumber(arg[2]) or 50
local used = {}
local function rng_factory(s)
  local state = s
  return function(n) state = (state * 16807) % 2147483647 return state % n + 1 end
end
local errors, turns = 0, 0
for g = 1, games do
  local r = rng_factory(seed * 1000 + g)
  local function deck()
    local names = {}
    for i = 1, 23 do local n = spells[r(#spells)]; names[#names + 1] = n; used[n] = true end
    local c1, c2 = basics[r(5)], basics[r(5)]
    for i = 1, 17 do names[#names + 1] = (i % 2 == 0) and c1 or c2 end
    return names
  end
  local d1, d2 = deck(), deck()
  local game = Game.new({ players = { { name = "A", deck = db.make_deck(d1), controller = ai.new() },
                                      { name = "B", deck = db.make_deck(d2), controller = ai.new() } },
                          rng = r, max_turns = 60 })
  local ok, err = xpcall(function() game:run() end, debug.traceback)
  turns = turns + game.turn
  if not ok then
    errors = errors + 1
    print("GAME " .. g .. " ERROR: " .. err:sub(1, 1500))
  end
end
local n = 0 for _ in pairs(used) do n = n + 1 end
print(("games %d, errors %d, avg turns %.1f, distinct spells used %d/%d"):format(games, errors, turns / games, n, #spells))
