-- Combat: legal attackers/blockers, block validation, damage assignment and dealing.
-- Reference: forge-game combat/CombatUtil (canAttack, canBlock, validateBlocks), combat/Combat
-- (assignCombatDamage, dealAssignedDamage). Follows current rules: no damage assignment order;
-- a blocked attacker divides its damage among its blockers as its controller chooses, and with
-- trample may assign the rest to the player once every blocker has been assigned lethal damage.

local statics = require("scripts/mtg/statics")

local combat = {}

-- combat state on the game: game.combat = { attackers = { card, ... },
--   blockers_of = { [attacker] = { blocker, ... } }, blocking = { [blocker] = attacker },
--   blocked = { [attacker] = true } }  -- stays blocked even if its blockers leave (CR 509.1h)

function combat.can_attack(game, card)
  return card.zone == "battlefield" and card:is_creature() and not card.tapped
      and (not card.sick or card:has_keyword("Haste"))
      and (not card:has_keyword("Defender") or statics.applies(game, "CanAttackDefender", card))
      and not statics.applies(game, "CantAttack", card)
end

function combat.attack_candidates(game, player)
  local list = {}
  for _, card in ipairs(player.battlefield) do
    if combat.can_attack(game, card) then
      list[#list + 1] = card
    end
  end
  return list
end

function combat.can_block(game, blocker)
  return blocker.zone == "battlefield" and blocker:is_creature() and not blocker.tapped
      and not statics.applies(game, "CantBlock", blocker)
end

function combat.can_block_attacker(blocker, attacker)
  if attacker:has_keyword("Flying") and not (blocker:has_keyword("Flying") or blocker:has_keyword("Reach")) then
    return false
  end
  if attacker.game and not statics.can_block_by(attacker.game, attacker, blocker) then
    return false
  end
  return true
end

function combat.block_candidates(game, player)
  local list = {}
  for _, card in ipairs(player.battlefield) do
    if combat.can_block(game, card) then
      list[#list + 1] = card
    end
  end
  return list
end

local function contains(list, item)
  for _, x in ipairs(list) do
    if x == item then
      return true
    end
  end
  return false
end

-- attackers: list of cards. Returns true or false, reason.
function combat.validate_attackers(game, player, attackers)
  local seen = {}
  for _, card in ipairs(attackers) do
    if seen[card] then
      return false, tostring(card) .. " declared twice"
    end
    seen[card] = true
    if card.controller ~= player or not combat.can_attack(game, card) then
      return false, tostring(card) .. " can't attack"
    end
  end
  return true
end

-- blocks: list of { blocker = card, attacker = card }. Returns true or false, reason.
function combat.validate_blocks(game, player, blocks)
  local attackers = game.combat.attackers
  local used, count = {}, {}
  for _, block in ipairs(blocks) do
    local blocker, attacker = block.blocker, block.attacker
    if used[blocker] then
      return false, tostring(blocker) .. " blocks more than one creature"
    end
    used[blocker] = true
    if blocker.controller ~= player or not combat.can_block(game, blocker) then
      return false, tostring(blocker) .. " can't block"
    end
    if not contains(attackers, attacker) then
      return false, tostring(attacker) .. " isn't attacking"
    end
    if not combat.can_block_attacker(blocker, attacker) then
      return false, tostring(blocker) .. " can't block " .. tostring(attacker)
    end
    count[attacker] = (count[attacker] or 0) + 1
  end
  for attacker, n in pairs(count) do
    if attacker:has_keyword("Menace") and n < 2 then
      return false, tostring(attacker) .. " has menace and needs two or more blockers"
    end
    local max = statics.max_blockers(game, attacker)
    if max and n > max then
      return false, tostring(attacker) .. " can't be blocked by more than " .. max
    end
  end
  return true
end

-- Lethal damage for assignment purposes (CR 702.2c deathtouch, 510.1c-d).
function combat.lethal_damage(source, creature)
  local remaining = math.max(0, creature:toughness() - creature.damage)
  if source:has_keyword("Deathtouch") and remaining > 0 then
    return 1
  end
  return remaining
end

-- Default division of a blocked attacker's damage: lethal to each blocker in turn, the rest to the
-- player if trample, otherwise piled on the last blocker.
-- Returns { amounts = { [blocker] = n }, to_player = n }.
function combat.default_assignment(attacker, blockers, amount, trample)
  local result = { amounts = {}, to_player = 0 }
  local left = amount
  for _, blocker in ipairs(blockers) do
    local n = math.min(left, combat.lethal_damage(attacker, blocker))
    result.amounts[blocker] = n
    left = left - n
  end
  if left > 0 then
    if trample then
      result.to_player = left
    else
      local last = blockers[#blockers]
      result.amounts[last] = result.amounts[last] + left
    end
  end
  return result
end

function combat.validate_assignment(attacker, blockers, amount, trample, assignment)
  local total = assignment.to_player or 0
  if total < 0 then
    return false, "negative damage"
  end
  if total > 0 and not trample then
    return false, tostring(attacker) .. " is blocked and has no trample"
  end
  for blocker, n in pairs(assignment.amounts) do
    if not contains(blockers, blocker) then
      return false, tostring(blocker) .. " isn't blocking " .. tostring(attacker)
    end
    if n < 0 then
      return false, "negative damage"
    end
    total = total + n
  end
  if total ~= amount then
    return false, "assigned " .. total .. " damage, must assign " .. amount
  end
  if (assignment.to_player or 0) > 0 then
    for _, blocker in ipairs(blockers) do
      if (assignment.amounts[blocker] or 0) < combat.lethal_damage(attacker, blocker) then
        return false, "trample needs lethal damage assigned to " .. tostring(blocker) .. " first"
      end
    end
  end
  return true
end

function combat.has_first_strikers(game)
  local c = game.combat
  for _, attacker in ipairs(c.attackers) do
    if attacker:has_keyword("First Strike") or attacker:has_keyword("Double Strike") then
      return true
    end
  end
  for blocker in pairs(c.blocking) do
    if blocker:has_keyword("First Strike") or blocker:has_keyword("Double Strike") then
      return true
    end
  end
  return false
end

local function deals_damage_this_step(game, card, first_strike_step)
  local fs, ds = card:has_keyword("First Strike"), card:has_keyword("Double Strike")
  if first_strike_step then
    return fs or ds
  end
  -- CR 510.4: in the second step, creatures that didn't deal first-strike damage, plus double strikers.
  return ds or not game.combat.dealt_first_strike[card]
end

local function in_combat(card)
  return card.zone == "battlefield"
end

-- Computes and deals one combat damage step. All damage is dealt simultaneously.
function combat.deal_damage_step(game, first_strike_step)
  local c = game.combat
  local attacking_player = game:active_player()
  local defending_player = game:opponent(attacking_player)
  local hits = {}  -- { source = card, target = card or player, amount = n }

  for _, attacker in ipairs(c.attackers) do
    if in_combat(attacker) and deals_damage_this_step(game, attacker, first_strike_step) then
      local amount = attacker:power()
      if first_strike_step then
        c.dealt_first_strike[attacker] = true
      end
      if amount > 0 then
        local trample = attacker:has_keyword("Trample")
        if not c.blocked[attacker] then
          hits[#hits + 1] = { source = attacker, target = defending_player, amount = amount }
        else
          local blockers = {}
          for _, blocker in ipairs(c.blockers_of[attacker] or {}) do
            if in_combat(blocker) then
              blockers[#blockers + 1] = blocker
            end
          end
          if #blockers == 0 then
            if trample then  -- CR 702.19e
              hits[#hits + 1] = { source = attacker, target = defending_player, amount = amount }
            end
          else
            local assignment
            if #blockers == 1 and not trample then
              assignment = { amounts = { [blockers[1]] = amount }, to_player = 0 }
            else
              assignment = attacking_player.controller:assign_combat_damage(game, attacking_player, attacker, blockers, amount, trample)
              local ok, reason = combat.validate_assignment(attacker, blockers, amount, trample, assignment)
              if not ok then
                error("invalid damage assignment: " .. reason)
              end
            end
            for _, blocker in ipairs(blockers) do
              local n = assignment.amounts[blocker] or 0
              if n > 0 then
                hits[#hits + 1] = { source = attacker, target = blocker, amount = n }
              end
            end
            if (assignment.to_player or 0) > 0 then
              hits[#hits + 1] = { source = attacker, target = defending_player, amount = assignment.to_player }
            end
          end
        end
      end
    end
  end

  for blocker, attacker in pairs(c.blocking) do
    if in_combat(blocker) and deals_damage_this_step(game, blocker, first_strike_step) then
      if first_strike_step then
        c.dealt_first_strike[blocker] = true
      end
      local amount = blocker:power()
      if amount > 0 and in_combat(attacker) then
        hits[#hits + 1] = { source = blocker, target = attacker, amount = amount }
      end
    end
  end

  -- Sort for deterministic event order (pairs() order isn't stable).
  table.sort(hits, function(a, b)
    if a.source.id ~= b.source.id then
      return a.source.id < b.source.id
    end
    local ta = a.target.id or 0
    local tb = b.target.id or 0
    return ta < tb
  end)
  game:deal_damage_batch(hits, true)
end

return combat
