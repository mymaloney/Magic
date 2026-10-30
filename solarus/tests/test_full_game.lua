-- Whole games between two AI decks built from supported pool cards, plus the coroutine
-- protocol the duel menu uses (controllers/prompt.lua).

local Game = require("scripts/mtg/game")
local ai = require("scripts/mtg/controllers/ai")
local prompt = require("scripts/mtg/controllers/prompt")

local decks = require("scripts/duel/decks")

-- Park-Miller generator: deterministic and exact in double precision.
local function make_rng(seed)
  local state = seed
  return function(n)
    state = (state * 16807) % 2147483647
    return state % n + 1
  end
end

local function new_game(t, seed, controller1, controller2, deck1, deck2)
  deck1, deck2 = deck1 or decks.white, deck2 or decks.green
  return Game.new({
    players = {
      { name = deck1.name, deck = t.db.make_deck(deck1.cards), controller = controller1 or ai.new() },
      { name = deck2.name, deck = t.db.make_deck(deck2.cards), controller = controller2 or ai.new() },
    },
    rng = make_rng(seed),
    max_turns = 200,
  })
end

-- Cards a player owns across all zones, including spells on the stack (triggers aren't cards).
local function count_cards(player, game)
  local n = #player.library + #player.hand + #player.battlefield + #player.graveyard + #player.exile
  for _, item in ipairs(game.stack) do
    if item.kind == "spell" and item.card.owner == player then
      n = n + 1
    end
  end
  return n
end

return function(t)
  t.section("AI vs AI games")
  local wins = { [decks.white.name] = 0, [decks.green.name] = 0 }
  local summaries = {}
  for seed = 1, 20 do
    local game = new_game(t, seed)
    local casts = 0
    game:on_event(function(e)
      if e.type == "cast" then
        casts = casts + 1
      end
    end)
    game:run()
    t.check(game.over, "seed " .. seed .. ": game finished within 200 turns")
    t.check(game.winner ~= nil, "seed " .. seed .. ": there is a winner")
    t.check(casts > 0, "seed " .. seed .. ": spells were cast")
    for _, player in ipairs(game.players) do
      t.eq(count_cards(player, game), 40, "seed " .. seed .. ": " .. player.name .. " still has 40 cards across zones")
      for _, card in ipairs(player.battlefield) do
        t.check(not card:is_creature() or card.damage < card:toughness(), "seed " .. seed .. ": no lethally damaged creature left alive")
      end
    end
    if game.winner then
      wins[game.winner.name] = wins[game.winner.name] + 1
      local loser = game:opponent(game.winner)
      summaries[#summaries + 1] = string.format("%s on turn %d (%s)", game.winner.name, game.turn, tostring(loser.loss_reason))
    end
  end
  print(string.format("  AI vs AI, 20 games: %s %d, %s %d. First games: %s",
                      decks.white.name, wins[decks.white.name], decks.green.name, wins[decks.green.name],
                      table.concat(summaries, "; ", 1, math.min(3, #summaries))))

  t.section("AI vs AI with spells and triggers")
  for _, opponent in ipairs({ decks.white, decks.green }) do
    local rakdos_wins, triggers, spells = 0, 0, 0
    for seed = 1, 10 do
      local game = new_game(t, seed, nil, nil, decks.rakdos, opponent)
      game:on_event(function(e)
        if e.type == "trigger" then
          triggers = triggers + 1
        elseif e.type == "cast" and e.card.def.spell then
          spells = spells + 1
        end
      end)
      game:run()
      t.check(game.over and game.winner ~= nil, "seed " .. seed .. " vs " .. opponent.name .. ": game finished with a winner")
      for _, player in ipairs(game.players) do
        t.eq(count_cards(player, game), 40, "seed " .. seed .. ": " .. player.name .. " still has 40 cards")
      end
      if game.winner and game.winner.name == decks.rakdos.name then
        rakdos_wins = rakdos_wins + 1
      end
    end
    t.check(triggers > 20, "triggers happened vs " .. opponent.name .. " (" .. triggers .. ")")
    t.check(spells > 10, "instants/sorceries were cast vs " .. opponent.name .. " (" .. spells .. ")")
    print(string.format("  %s vs %s, 10 games: %d-%d (%d triggers, %d spells)",
                        decks.rakdos.name, opponent.name, rakdos_wins, 10 - rakdos_wins, triggers, spells))
  end

  t.section("prompt controller (coroutine protocol)")
  do
    -- Player 1 is driven through the prompt protocol, answering with the same AI decisions.
    -- With the same seed the game must play out exactly like the AI-vs-AI game.
    local reference = new_game(t, 7)
    reference:run()

    local game = new_game(t, 7, prompt.new())
    local brain = ai.new()
    local runner = prompt.run(game)
    local request = runner.resume()
    local requests = 0
    while request.kind ~= "game_over" do
      requests = requests + 1
      local p = request.player
      local answer
      if request.kind == "choose_action" then
        answer = brain:choose_action(game, p, request.actions)
      elseif request.kind == "declare_attackers" then
        answer = brain:declare_attackers(game, p, request.candidates)
      elseif request.kind == "declare_blockers" then
        answer = brain:declare_blockers(game, p, request.attackers, request.candidates)
      elseif request.kind == "assign_combat_damage" then
        answer = request.default
      elseif request.kind == "choose_discard" then
        answer = brain:choose_discard(game, p, request.count)
      elseif request.kind == "choose_legend_to_keep" then
        answer = request.cards[1]
      end
      request = runner.resume(answer)
    end
    t.check(requests > 50, "prompt controller was asked many times (" .. requests .. ")")
    t.eq(request.winner and request.winner.name, reference.winner and reference.winner.name, "same winner as the AI-only game")
    t.eq(game.turn, reference.turn, "same number of turns as the AI-only game")
    t.eq(game.players[1].life, reference.players[1].life, "same final life for player 1")
  end
end
