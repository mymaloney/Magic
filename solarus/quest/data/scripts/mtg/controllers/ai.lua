-- Simple heuristic opponent. Reference for better heuristics: forge-ai AiController (what to play),
-- AiAttackController / AiBlockController (combat), ComputerUtilCard.evaluateCreature (card value).

local combat = require("scripts/mtg/combat")
local abilities = require("scripts/mtg/abilities")
local effects = require("scripts/mtg/effects")

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

local function is_player(obj)
  return obj.life ~= nil
end

local function value(obj)
  if is_player(obj) then
    return 5
  end
  local v = obj:mana_value()
  if obj:is_creature() then
    v = v + obj:power() * 2 + obj:toughness()
  end
  return v
end

local function in_combat(game, card)
  local c = game.combat
  if c == nil or is_player(card) then
    return false
  end
  if c.blocking[card] then
    return true
  end
  for _, a in ipairs(c.attackers) do
    if a == card then
      return true
    end
  end
  return false
end

-- Scores a target from `player`'s point of view: >= 1000 means the effect does what we want
-- (hurts an opponent's thing / helps ours), lower means it backfires.
local function target_score(game, player, ability, obj)
  local mine = is_player(obj) and obj == player or (not is_player(obj) and obj.controller == player)
  local harmful = effects.is_harmful(ability)
  if harmful == mine then
    return -value(obj)
  end
  local score = 1000 + value(obj)
  if ability.api == "DealDamage" and harmful then
    local dmg = abilities.amount(ability.params.NumDmg, 0) or 0
    if is_player(obj) then
      score = 1000 + (dmg >= obj.life and 10000 or 20)
    elseif dmg >= obj:toughness() - obj.damage then
      score = 1500 + value(obj)
    else
      score = 1001
    end
  elseif ability.api == "Pump" and not harmful and in_combat(game, obj) then
    score = score + 500
  end
  return score
end

local function best_targets(game, player, ability, candidates, min, max)
  local scored = {}
  for _, obj in ipairs(candidates) do
    scored[#scored + 1] = { obj = obj, score = target_score(game, player, ability, obj) }
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  local chosen = {}
  for _, entry in ipairs(scored) do
    if #chosen >= max then
      break
    end
    if entry.score >= 1000 or #chosen < min then
      chosen[#chosen + 1] = entry.obj
    end
  end
  return chosen, scored[1] and scored[1].score or 0
end

function ai:choose_targets(game, player, ability, candidates, min, max, ctx)
  if ability.params.KW == "Haste" then
    for _, c in ipairs(candidates) do   -- haste goes on a creature that can't attack yet
      if c.life == nil and c.controller == player and c.sick then
        return { c }
      end
    end
  end
  return (best_targets(game, player, ability, candidates, min, max))
end

function ai:confirm_optional(game, player, source, ability)
  local c = ability and ability.optional_cost
  if c then
    for _, part in ipairs(c.sacrifice) do
      if not part.self then
        return false   -- don't feed creatures to optional costs
      end
    end
    if #c.discard > 0 and #player.hand < 2 then
      return false
    end
  end
  return true
end

function ai:choose_number(game, player, min, max, purpose, source)
  return max
end

-- The color that appears most in the mana costs of the cards it owns.
function ai:choose_color(game, player, source, options)
  local count = {}
  for _, zone in ipairs({ "library", "hand", "battlefield", "graveyard" }) do
    for _, card in ipairs(player[zone]) do
      for symbol in (card.def.script.faces[1].mana_cost or ""):gmatch("[WUBRG]") do
        count[symbol] = (count[symbol] or 0) + 1
      end
    end
  end
  local best = options[1]
  for _, c in ipairs(options) do
    if (count[c] or 0) > (count[best] or 0) then
      best = c
    end
  end
  return best
end

-- How good would the targeted parts of a chain be? min over targeted parts of the best target score
-- (>= 1000 means it does what we want); 1000 when nothing is targeted.
local function chain_score(game, player, root, ctx)
  local score = 1000
  for _, ability in ipairs(abilities.chain(root)) do
    if ability.target then
      local candidates = abilities.target_candidates(game, ability, ctx)
      local _, best = best_targets(game, player, ability, candidates, ability.target.min, ability.target.max)
      score = math.min(score, best)
    end
  end
  return score
end

function ai:choose_mode(game, player, source, charm, options)
  local ctx = { game = game, source = source, controller = player, targets = {} }
  local best, best_score = options[1], -math.huge
  for _, index in ipairs(options) do
    local score = chain_score(game, player, charm.choices[index], ctx)
    if score > best_score then
      best, best_score = index, score
    end
  end
  return best
end

-- Is casting this instant/sorcery worth it right now?
local function spell_is_good(game, player, card)
  local ctx = { game = game, source = card, controller = player, targets = {} }
  local opponent = game:opponent(player)
  if card.def.spell.choices then
    local best = -math.huge
    for _, index in ipairs(abilities.available_modes(game, card.def.spell, ctx)) do
      best = math.max(best, chain_score(game, player, card.def.spell.choices[index], ctx))
    end
    return best >= 1000
  end
  for _, ability in ipairs(abilities.chain(card.def.spell)) do
    if ability.target then
      local candidates = abilities.target_candidates(game, ability, ctx)
      local _, best = best_targets(game, player, ability, candidates, ability.target.min, ability.target.max)
      if best < 1000 then
        return false
      end
      if ability.api == "Pump" and not effects.is_harmful(ability) and best < 1500 then
        return false  -- only pump creatures that are in combat
      end
    elseif ability == card.def.spell then
      if ability.api == "DestroyAll" then
        local mine, theirs = 0, 0
        for _, c in ipairs(player.battlefield) do
          mine = mine + (c:is_creature() and 1 or 0)
        end
        for _, c in ipairs(opponent.battlefield) do
          theirs = theirs + (c:is_creature() and 1 or 0)
        end
        if theirs <= mine then
          return false
        end
      elseif ability.api == "Discard" and #opponent.hand == 0 then
        return false
      end
    end
  end
  return true
end

function ai:choose_cards(game, player, cards, min, max, reason)
  local best_first = reason == "dig" or reason == "search"   -- taking cards: the best; paying costs: the worst
  local sorted = {}
  for i, c in ipairs(cards) do
    sorted[i] = c
  end
  table.sort(sorted, function(a, b)
    if value(a) ~= value(b) then
      return (value(a) < value(b)) ~= best_first
    end
    return a.id < b.id
  end)
  local chosen = {}
  for i = 1, best_first and max or min do
    chosen[i] = sorted[i]
  end
  return chosen
end

local function count_lands(player)
  local n = 0
  for _, c in ipairs(player.battlefield) do
    if c:is_land() then
      n = n + 1
    end
  end
  return n
end

-- Scry/surveil: keep lands while short on them, and spells castable soon.
function ai:arrange_top(game, player, cards, away)
  local lands = count_lands(player)
  for _, c in ipairs(player.hand) do
    lands = lands + (c:is_land() and 1 or 0)
  end
  local keep, out = {}, {}
  for _, c in ipairs(cards) do
    local want
    if c:is_land() then
      want = lands < 5
    else
      want = c:mana_value() <= count_lands(player) + 2
    end
    if want then
      keep[#keep + 1] = c
    else
      out[#out + 1] = c
    end
  end
  return { top = keep, away = out }
end

-- Is activating this ability a good idea right now?
local function activation_is_good(game, player, card, act)
  local api = act.ability.api
  local top = game.stack[#game.stack]
  local my_turn = player == game:active_player()
  -- what we'd give up
  for _, part in ipairs(act.cost.sacrifice) do
    if not part.self then
      return false
    end
    if card:is_land() and count_lands(player) <= 5 then
      return false
    end
  end
  if #act.cost.discard > 0 and #player.hand < 3 then
    return false
  end
  local sacrifices_self = #act.cost.sacrifice > 0
  if top ~= nil then
    return false
  end
  if act.equip and card.attached_to ~= nil then
    return false   -- don't keep moving equipment around
  end
  local timing
  if api == "Draw" then
    timing = (not my_turn and game.step == "end_of_turn") or (my_turn and game.step == "main2" and not sacrifices_self)
  elseif (api == "Pump" or api == "PumpAll") and not effects.is_harmful(act.ability) then
    if act.ability.params.KW == "Haste" then
      timing = my_turn and game.step == "main1"
    else
      timing = game.step == "combat_declare_blockers"
    end
  else
    timing = my_turn and game:is_main_phase()
  end
  if not timing then
    return false
  end
  local ctx = { game = game, source = card, controller = player, targets = {} }
  for _, ability in ipairs(abilities.chain(act.ability)) do
    if ability.target then
      local candidates = abilities.target_candidates(game, ability, ctx)
      local _, best = best_targets(game, player, ability, candidates, ability.target.min, ability.target.max)
      if best < 1000 then
        return false
      end
      if ability.params.KW == "Haste" then
        local any_sick = false
        for _, c in ipairs(candidates) do
          any_sick = any_sick or (c.life == nil and c.controller == player and c.sick and c ~= card)
        end
        if not any_sick then
          return false
        end
      elseif ability.api == "Pump" and not effects.is_harmful(ability) and best < 1500 then
        return false
      end
    elseif ability == act.ability and (api == "Pump" or api == "PumpAll") and not in_combat(game, card)
        and api == "Pump" then
      return false  -- self-pumps only matter in combat
    end
  end
  return true
end

function ai:choose_action(game, player, actions)
  for _, action in ipairs(actions) do
    if action.kind == "play_land" then
      return action
    end
  end
  local top = game.stack[#game.stack]
  local my_main = player == game:active_player() and game:is_main_phase() and top == nil
  local best
  for _, action in ipairs(actions) do
    local card = action.card
    if action.kind == "cast" then
      if card.def.spell == nil then
        if my_main and (best == nil or card:mana_value() > best.card:mana_value()) then
          best = action
        end
      else
        local api = card.def.spell.api
        local timing
        if api == "Counter" then
          timing = top ~= nil and top.kind == "spell" and top.controller ~= player
        elseif api == "Pump" then
          timing = game.step == "combat_declare_blockers"
        else
          timing = my_main
        end
        if timing and spell_is_good(game, player, card) and best == nil then
          best = action
        end
      end
    elseif action.kind == "activate" and best == nil then
      if activation_is_good(game, player, card, card.def.activated[action.index]) then
        best = action
      end
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
