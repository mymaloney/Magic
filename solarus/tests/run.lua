-- Headless tests for the pure-Lua parts of the quest (no Solarus needed).
-- Run from the repository root:  luajit solarus/tests/run.lua
-- Each test_*.lua file returns function(t); t provides assertions and game-building helpers.

package.path = "solarus/quest/data/?.lua;" .. package.path

local card_db = require("scripts/mtg/card_db")
local Game = require("scripts/mtg/game")
local combat = require("scripts/mtg/combat")

local TEST_FILES = { "test_script_parser", "test_mana", "test_rules", "test_abilities", "test_triggers", "test_activated", "test_effects", "test_full_game", "test_duel_ui" }

local t = { checks = 0, failures = 0, section_name = "" }

function t.section(name)
  t.section_name = name
end

function t.check(cond, msg)
  t.checks = t.checks + 1
  if not cond then
    t.failures = t.failures + 1
    print("FAIL [" .. t.section_name .. "] " .. msg)
  end
end

function t.eq(actual, expected, msg)
  t.check(actual == expected, msg .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

function t.read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

t.pool = dofile("solarus/quest/data/cards/pool.lua")
t.db = card_db.new(t.pool, function(path) return t.read("solarus/quest/data/" .. path) end)

-- A controller that passes priority and answers from `script` (all fields optional):
--   actions = { function(game, player, actions) -> action or nil, ... }  tried in order: the first
--             function is removed once it returns an action; until then the player passes
--   attack = function(game, player, candidates) -> cards     (default: no attack)
--   block = function(game, player, attackers, candidates) -> blocks (default: no blocks)
--   assign = function(game, player, attacker, blockers, amount, trample) -> assignment (default: combat.default_assignment)
--   legend = function(game, player, cards) -> card            (default: first)
--   targets = function(game, player, ability, candidates, min, max) -> list (default: the first
--             max(min, 1) candidates, capped at max)
--   optional = function(game, player, source, ability) -> bool  (default: true)
function t.scripted(script)
  script = script or {}
  local queue = script.actions or {}
  return {
    choose_action = function(_, game, player, actions)
      if #queue > 0 then
        local action = queue[1](game, player, actions)
        if action then
          table.remove(queue, 1)
          return action
        end
      end
      return nil
    end,
    declare_attackers = function(_, game, player, candidates)
      return script.attack and script.attack(game, player, candidates) or {}
    end,
    declare_blockers = function(_, game, player, attackers, candidates)
      return script.block and script.block(game, player, attackers, candidates) or {}
    end,
    assign_combat_damage = function(_, game, player, attacker, blockers, amount, trample)
      if script.assign then
        return script.assign(game, player, attacker, blockers, amount, trample)
      end
      return combat.default_assignment(attacker, blockers, amount, trample)
    end,
    choose_discard = function(_, game, player, count)
      local cards = {}
      for i = 1, count do
        cards[i] = player.hand[i]
      end
      return cards
    end,
    choose_legend_to_keep = function(_, game, player, cards)
      return script.legend and script.legend(game, player, cards) or cards[1]
    end,
    choose_targets = function(_, game, player, ability, candidates, min, max)
      if script.targets then
        return script.targets(game, player, ability, candidates, min, max)
      end
      local chosen = {}
      for i = 1, math.min(math.max(min, 1), max) do
        chosen[i] = candidates[i]
      end
      return chosen
    end,
    choose_cards = function(_, game, player, cards, min, max, reason)
      if script.cards then
        return script.cards(game, player, cards, min, max, reason)
      end
      local chosen = {}
      for i = 1, min do
        chosen[i] = cards[i]
      end
      return chosen
    end,
    arrange_top = function(_, game, player, cards, away)
      if script.arrange then
        return script.arrange(game, player, cards, away)
      end
      return { top = cards, away = {} }
    end,
    choose_mode = function(_, game, player, source, charm, options)
      return script.mode and script.mode(game, player, source, charm, options) or options[1]
    end,
    choose_color = function(_, game, player, source, options)
      return script.color and script.color(game, player, source, options) or options[1]
    end,
    confirm_optional = function(_, game, player, source, ability)
      if script.optional then
        return script.optional(game, player, source, ability)
      end
      return true
    end,
  }
end

-- Builds a game for a rules scenario (like Forge's SimulationTest + addCard + devModeSet):
--   t.setup({ { controller =, battlefield = { "Savannah Lions" }, hand = {}, graveyard = {}, library = {}, life = 20 },
--             { ... } })
-- Battlefield creatures start without summoning sickness. Libraries default to 10 Plains so
-- nobody decks out. Player 1 is active; the next run_turn() is turn 2 (no first-turn draw skip).
function t.setup(specs)
  local game = Game.new({
    players = { { name = "P1", controller = specs[1].controller or t.scripted() },
                { name = "P2", controller = specs[2].controller or t.scripted() } },
    first_player = 1, shuffle = false, opening_hand = 0,
  })
  game.turn = 1
  for i, spec in ipairs(specs) do
    local player = game.players[i]
    player.life = spec.life or 20
    for _, name in ipairs(spec.library or { "Plains", "Plains", "Plains", "Plains", "Plains",
                                             "Plains", "Plains", "Plains", "Plains", "Plains" }) do
      game:create_card(t.db.get(name), player, "library")
    end
    for _, name in ipairs(spec.hand or {}) do
      game:create_card(t.db.get(name), player, "hand")
    end
    for _, name in ipairs(spec.battlefield or {}) do
      game:create_card(t.db.get(name), player, "battlefield", { sick = false })
    end
    for _, name in ipairs(spec.graveyard or {}) do
      game:create_card(t.db.get(name), player, "graveyard")
    end
  end
  return game
end

function t.find(list, name, nth)
  nth = nth or 1
  for _, card in ipairs(list) do
    if card:name() == name then
      nth = nth - 1
      if nth == 0 then
        return card
      end
    end
  end
  return nil
end

for _, file in ipairs(TEST_FILES) do
  t.section(file)
  local ok, err = xpcall(function() dofile("solarus/tests/" .. file .. ".lua")(t) end, debug.traceback)
  if not ok then
    t.failures = t.failures + 1
    print("ERROR [" .. t.section_name .. "] " .. tostring(err))
  end
end

print(string.format("%d checks, %d failures", t.checks, t.failures))
os.exit(t.failures == 0 and 0 or 1)
