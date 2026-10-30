-- Controller for a human player behind an event-driven UI (the Solarus duel menu).
--
-- The engine runs inside a coroutine. Each decision yields a request table to the UI; the UI
-- answers by resuming the coroutine with the result:
--   local runner = prompt.run(game)
--   local request = runner.resume()          -- start; returns the first request
--   request = runner.resume(answer)          -- answer it; returns the next request
--   -- request.kind == "game_over" (with .winner) when the game has ended
--
-- Requests: { kind = "choose_action", player, actions }          answer: action or nil (pass)
--           { kind = "declare_attackers", player, candidates }    answer: { card, ... }
--           { kind = "declare_blockers", player, attackers, candidates } answer: { { blocker, attacker }, ... }
--           { kind = "assign_combat_damage", player, attacker, blockers, amount, trample, default }
--           { kind = "choose_discard", player, count }            answer: { card, ... }
--           { kind = "choose_legend_to_keep", player, cards }     answer: card
--           { kind = "choose_targets", player, ability, source, candidates, min, max }
--                                                                 answer: { card or player, ... }
--           { kind = "confirm_optional", player, source, ability } answer: true / false
--           { kind = "choose_color", player, source, options }     answer: one of options ("W".."G")
--           { kind = "choose_cards", player, candidates, min, max, reason } answer: { card, ... }
--             (paying a cost: reason "sacrifice" or "discard")
-- The UI must only send legal answers (offer only the listed options; check blocks with
-- combat.validate_blocks and damage with combat.validate_assignment before answering).

local combat = require("scripts/mtg/combat")

local prompt = {}
prompt.__index = prompt

function prompt.new()
  return setmetatable({}, prompt)
end

local function ask(request)
  return coroutine.yield(request)
end

function prompt:choose_action(game, player, actions)
  return ask({ kind = "choose_action", player = player, actions = actions })
end

function prompt:declare_attackers(game, player, candidates)
  return ask({ kind = "declare_attackers", player = player, candidates = candidates })
end

function prompt:declare_blockers(game, player, attackers, candidates)
  return ask({ kind = "declare_blockers", player = player, attackers = attackers, candidates = candidates })
end

function prompt:assign_combat_damage(game, player, attacker, blockers, amount, trample)
  return ask({
    kind = "assign_combat_damage", player = player, attacker = attacker, blockers = blockers,
    amount = amount, trample = trample,
    default = combat.default_assignment(attacker, blockers, amount, trample),
  })
end

function prompt:choose_discard(game, player, count)
  return ask({ kind = "choose_discard", player = player, count = count })
end

function prompt:choose_legend_to_keep(game, player, cards)
  return ask({ kind = "choose_legend_to_keep", player = player, cards = cards })
end

function prompt:choose_targets(game, player, ability, candidates, min, max, ctx)
  return ask({ kind = "choose_targets", player = player, ability = ability, source = ctx.source,
               candidates = candidates, min = min, max = max })
end

function prompt:confirm_optional(game, player, source, ability)
  return ask({ kind = "confirm_optional", player = player, source = source, ability = ability })
end

function prompt:choose_cards(game, player, cards, min, max, reason)
  return ask({ kind = "choose_cards", player = player, candidates = cards, min = min, max = max, reason = reason })
end

function prompt:choose_color(game, player, source, options)
  return ask({ kind = "choose_color", player = player, source = source, options = options })
end

-- Runs game:run() in a coroutine; see the header for the protocol.
function prompt.run(game)
  local co = coroutine.create(function()
    game:run()
  end)
  local runner = {}
  function runner.resume(answer)
    local ok, request = coroutine.resume(co, answer)
    if not ok then
      error(debug.traceback(co, request), 0)
    end
    if coroutine.status(co) == "dead" then
      return { kind = "game_over", winner = game.winner }
    end
    return request
  end
  return runner
end

return prompt
