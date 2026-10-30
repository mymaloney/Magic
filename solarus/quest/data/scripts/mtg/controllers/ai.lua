-- Simple heuristic opponent. Reference for better heuristics: forge-ai AiController (what to play),
-- AiAttackController / AiBlockController (combat), ComputerUtilCard.evaluateCreature (card value).

local combat = require("scripts/mtg/combat")

local ai = {}
ai.__index = ai

function ai.new()
  return setmetatable({}, ai)
end

-- Would `source` deal lethal damage to `target` in a fight? (ignores first strike ordering)
local function kills(source, target)
  if source:power() <= 0 then
    return false
  end
  return source:has_keyword("Deathtouch") or source:power() >= target:toughness() - target.damage
end

function ai:choose_action(game, player, actions)
  for _, action in ipairs(actions) do
    if action.kind == "play_land" then
      return action
    end
  end
  if player ~= game:active_player() or not game:is_main_phase() then
    return nil
  end
  local best
  for _, action in ipairs(actions) do
    if action.kind == "cast" and (best == nil or action.card:mana_value() > best.card:mana_value()) then
      best = action
    end
  end
  return best
end

function ai:declare_attackers(game, player, candidates)
  local opponent = game:opponent(player)
  local blockers = combat.block_candidates(game, opponent)

  local total = 0
  for _, card in ipairs(candidates) do
    total = total + card:power()
  end
  if #blockers == 0 and total >= opponent.life then
    return candidates
  end

  local attackers = {}
  for _, attacker in ipairs(candidates) do
    if attacker:power() > 0 then
      local safe = true
      for _, blocker in ipairs(blockers) do
        if combat.can_block_attacker(blocker, attacker) and kills(blocker, attacker) and not kills(attacker, blocker) then
          safe = false
          break
        end
      end
      if safe then
        attackers[#attackers + 1] = attacker
      end
    end
  end
  return attackers
end

function ai:declare_blockers(game, player, attackers, candidates)
  local sorted = {}
  for i, a in ipairs(attackers) do
    sorted[i] = a
  end
  table.sort(sorted, function(a, b) return a:power() > b:power() end)

  local blocks, used, blocked = {}, {}, {}
  local function pick(attacker, accept)
    for _, blocker in ipairs(candidates) do
      if not used[blocker] and combat.can_block_attacker(blocker, attacker) and accept(blocker, attacker) then
        used[blocker] = true
        blocked[attacker] = true
        blocks[#blocks + 1] = { blocker = blocker, attacker = attacker }
        return true
      end
    end
    return false
  end

  for _, attacker in ipairs(sorted) do
    if not attacker:has_keyword("Menace") then
      local _ = pick(attacker, function(b, a) return kills(b, a) and not kills(a, b) end)  -- good block
          or pick(attacker, function(b, a) return not kills(a, b) end)                      -- safe block
          or pick(attacker, function(b, a) return kills(b, a) and b:mana_value() <= a:mana_value() end) -- trade
    end
  end

  -- Chump block the biggest unblocked attackers if the rest would be lethal.
  local function incoming()
    local n = 0
    for _, attacker in ipairs(sorted) do
      if not blocked[attacker] or attacker:has_keyword("Trample") then
        n = n + attacker:power()
      end
    end
    return n
  end
  for _, attacker in ipairs(sorted) do
    if incoming() < player.life then
      break
    end
    if not blocked[attacker] and not attacker:has_keyword("Menace") then
      pick(attacker, function() return true end)
    end
  end
  return blocks
end

function ai:assign_combat_damage(game, player, attacker, blockers, amount, trample)
  return combat.default_assignment(attacker, blockers, amount, trample)
end

function ai:choose_discard(game, player, count)
  local hand = {}
  for i, card in ipairs(player.hand) do
    hand[i] = card
  end
  table.sort(hand, function(a, b)
    if a:mana_value() ~= b:mana_value() then
      return a:mana_value() > b:mana_value()
    end
    return a.id < b.id
  end)
  local discard = {}
  for i = 1, count do
    discard[i] = hand[i]
  end
  return discard
end

function ai:choose_legend_to_keep(game, player, cards)
  return cards[1]
end

return ai
