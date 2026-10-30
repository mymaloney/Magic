-- A two-player game: zones, turn structure, priority, casting, state-based actions.
-- Reference: forge-game Game, GameAction (moveTo, checkStateEffects), phase/PhaseHandler
-- (mainLoopStep, onPhaseBegin, isSkippingPhase), zone/MagicStack, player/PlaySpellAbility.
--
-- Every decision is delegated to the player's controller (implementations in controllers/):
--   choose_action(game, player, actions)                           -> action or nil (pass priority)
--   declare_attackers(game, player, candidates)                    -> { card, ... }
--   declare_blockers(game, player, attackers, candidates)          -> { { blocker =, attacker = }, ... }
--   assign_combat_damage(game, player, attacker, blockers, amount, trample) -> { amounts = {[blocker]=n}, to_player = n }
--   choose_discard(game, player, count)                            -> { card, ... } (exactly count cards from hand)
--   choose_legend_to_keep(game, player, cards)                     -> card
--   choose_targets(game, player, ability, candidates, min, max, ctx) -> { card or player, ... }
--   confirm_optional(game, player, source, ability)                -> true to use a "may" trigger
--   choose_color(game, player, source, options)                    -> one of options ("W".."G")
--   choose_cards(game, player, cards, min, max, reason)            -> { card, ... } (reason: "sacrifice", "discard")
-- Invalid answers raise errors: controllers must only pick legal options (combat.validate_* help).
--
-- Libraries keep the top card at the END of the list.

local Card = require("scripts/mtg/card")
local filter = require("scripts/mtg/filter")
local mana = require("scripts/mtg/mana")
local combat = require("scripts/mtg/combat")
local abilities = require("scripts/mtg/abilities")
local effects = require("scripts/mtg/effects")
local triggers = require("scripts/mtg/triggers")
local replacements = require("scripts/mtg/replacements")
local cost_lib = require("scripts/mtg/cost")
local statics = require("scripts/mtg/statics")

local Game = {}
Game.__index = Game

-- What happened this turn, for "this turn" conditions (raid, morbid, ...). Reset each turn.
local function new_history()
  return {
    attackers = {},       -- [player] = number of creatures they attacked with
    life_lost = {},       -- [player] = total life lost
    life_gained = {},     -- [player] = number of times they gained life
    creatures_died = 0,
    entered = {},         -- { { card, controller } } permanents that entered the battlefield
    cast = {},            -- { { card, player } } spells cast
    mana_spent = {},      -- [player] = mana spent on spells
    activations = {},     -- [card] = { [ability key] = times activated }
  }
end

Game.STEPS = {
  "untap", "upkeep", "draw", "main1",
  "combat_begin", "combat_declare_attackers", "combat_declare_blockers",
  "combat_first_strike_damage", "combat_damage", "combat_end",
  "main2", "end_of_turn", "cleanup",
}
local NO_PRIORITY = { untap = true, cleanup = true }
local MAX_HAND_SIZE = 7

-- opts = {
--   players = { { name =, deck = { def, ... }, controller = }, { ... } },
--   first_player = 1 | 2 (default: random), rng = function(n) -> 1..n (default math.random),
--   shuffle = true, opening_hand = 7, starting_life = 20, max_turns = 200,
-- }
function Game.new(opts)
  local game = setmetatable({
    players = {},
    stack = {},
    rng = opts.rng or math.random,
    turn = 0,
    active = nil,
    step = nil,
    over = false,
    winner = nil,
    max_turns = opts.max_turns or 200,
    listeners = {},
    next_id = 1,
    lands_played = 0,
    combat = nil,
    pending_triggers = {},  -- triggered abilities waiting to be put on the stack
    history = new_history(),
    lookback = nil,         -- battlefield snapshot while a batch of simultaneous moves happens
    statics_dirty = true,   -- continuous effects need recomputing (statics.apply)
    computing_statics = false,
  }, Game)

  for i, spec in ipairs(opts.players) do
    local player = {
      index = i, id = -i, name = spec.name or ("Player " .. i),
      controller = spec.controller, life = opts.starting_life or 20,
      library = {}, hand = {}, battlefield = {}, graveyard = {}, exile = {},
      lost = false, drew_from_empty = false,
    }
    game.players[i] = player
    local deck = spec.deck or {}
    for j = #deck, 1, -1 do   -- deck[1] ends up on top
      game:create_card(deck[j], player, "library")
    end
    if opts.shuffle ~= false then
      game:shuffle(player)
    end
  end

  game.active = game.players[opts.first_player or game.rng(2)]
  for _, player in ipairs(game.players) do
    game:draw(player, opts.opening_hand or 7)
  end
  return game
end

-- Events -------------------------------------------------------------------------------------

function Game:on_event(listener)
  self.listeners[#self.listeners + 1] = listener
end

local remove_from   -- defined with the zone helpers below

function Game:emit(event)
  self.statics_dirty = true   -- every event is a state change that can affect continuous effects
  for _, listener in ipairs(self.listeners) do
    listener(event)
  end
end

-- Recomputes continuous effects if anything changed (called by Card getters).
function Game:ensure_statics()
  if self.statics_dirty and not self.computing_statics then
    self.computing_statics = true
    self.statics_dirty = false
    statics.apply(self)
    self.computing_statics = false
  end
end

-- Moves a permanent to another player's battlefield (layer 2 control change, CR 613.1b).
function Game:change_control(card, player)
  remove_from(card.controller.battlefield, card)
  card.controller = player
  card.sick = true   -- hasn't been under the new controller's control since their turn began
  table.insert(player.battlefield, card)
  self:emit({ type = "control", card = card, player = player })
end

-- Attaches an Aura or Equipment to a permanent (CR 301.5c, 303.4).
function Game:attach(attachment, target)
  attachment.attached_to = target
  self:emit({ type = "attach", card = attachment, target = target })
end

-- Players and cards ----------------------------------------------------------------------------

function Game:active_player()
  return self.active
end

function Game:opponent(player)
  return self.players[3 - player.index]
end

function Game:create_card(def, owner, zone, opts)
  local card = Card.new(def, owner, self.next_id, self)
  self.next_id = self.next_id + 1
  card.zone = zone
  local list = self:zone_list(owner, zone)
  list[#list + 1] = card
  if opts then
    for k, v in pairs(opts) do
      card[k] = v
    end
  end
  return card
end

function Game:zone_list(player, zone)
  if zone == "stack" then
    return nil
  end
  return player[zone] or error("unknown zone " .. tostring(zone))
end

function remove_from(list, card)
  for i, c in ipairs(list) do
    if c == card then
      table.remove(list, i)
      return true
    end
  end
  return false
end

-- Moves a card to a zone (GameAction.moveTo). Permanents go to their controller's battlefield
-- (opts.controller, default owner); everything else goes to its owner's zone.
function Game:battlefield_snapshot()
  local snapshot = {}
  for _, player in ipairs(self.players) do
    for _, card in ipairs(player.battlefield) do
      snapshot[#snapshot + 1] = { card = card, controller = card.controller }
    end
  end
  return snapshot
end

-- Runs fn with one battlefield snapshot shared by every move inside it, so cards leaving the
-- battlefield at the same time see each other leave (e.g. creatures dying together in combat).
function Game:with_lookback(fn)
  if self.lookback then
    return fn()
  end
  self.lookback = self:battlefield_snapshot()
  fn()
  self.lookback = nil
end

function Game:move(card, zone, opts)
  opts = opts or {}
  local from = card.zone
  local lki_controller, lookback
  if from == "battlefield" then
    lki_controller = card.controller
    lookback = self.lookback or self:battlefield_snapshot()
    remove_from(card.controller.battlefield, card)
  elseif from == "stack" then
    for i, item in ipairs(self.stack) do
      if item.kind == "spell" and item.card == card then
        table.remove(self.stack, i)
        break
      end
    end
  elseif from ~= nil then
    remove_from(card.owner[from], card)
  end
  card:reset_state()
  card.zone = zone
  if zone == "battlefield" then
    card.controller = opts.controller or card.owner
    card.base_controller = card.controller
    card.sick = true
    card.tapped = opts.tapped or false
    if opts.attach_to then
      card.attached_to = opts.attach_to
    end
    table.insert(card.controller.battlefield, card)
    replacements.apply_etb(self, card, effects)
    table.insert(self.history.entered, { card = card, controller = card.controller })
  elseif zone == "library" and opts.position == "bottom" then
    table.insert(card.owner.library, 1, card)
  elseif zone ~= "stack" then
    table.insert(card.owner[zone], card)
  end
  if from == "battlefield" and zone == "graveyard" and card:is_creature() then
    self.history.creatures_died = self.history.creatures_died + 1
  end
  self:emit({ type = "zone_change", card = card, from = from, to = zone })
  triggers.collect(self, card, from, zone, lki_controller, lookback)
  -- "Exile ... until this leaves the battlefield" ends: the cards return (CR 610.3a).
  if from == "battlefield" and card.linked_exiles then
    local exiled = card.linked_exiles
    card.linked_exiles = nil
    for _, other in ipairs(exiled) do
      if other.zone == "exile" then
        self:move(other, "battlefield")
      end
    end
  end
end

-- Discards exactly `count` cards chosen from the player's hand.
function Game:discard(player, cards, count)
  if #cards ~= count then
    error("must discard exactly " .. count .. " cards")
  end
  for _, card in ipairs(cards) do
    if card.zone ~= "hand" or card.owner ~= player then
      error(tostring(card) .. " isn't in hand")
    end
  end
  for _, card in ipairs(cards) do
    self:move(card, "graveyard")
    self:emit({ type = "discard", player = player, card = card })
  end
end

function Game:shuffle(player)
  local lib = player.library
  for i = #lib, 2, -1 do
    local j = self.rng(i)
    lib[i], lib[j] = lib[j], lib[i]
  end
end

function Game:draw(player, count)
  for _ = 1, count or 1 do
    local card = player.library[#player.library]
    if card == nil then
      player.drew_from_empty = true  -- CR 704.5b, checked as a state-based action
      return
    end
    self:move(card, "hand")
    self:emit({ type = "draw", player = player, card = card })
    triggers.fire(self, "Drawn", { card = card, player = player })
  end
end

function Game:tap(card)
  if not card.tapped then
    card.tapped = true
    self:emit({ type = "tap", card = card })
    triggers.fire(self, "Taps", { card = card })
  end
end

function Game:untap(card)
  if card.tapped then
    card.tapped = false
    self:emit({ type = "untap", card = card })
  end
end

function Game:gain_life(player, amount)
  if amount > 0 then
    player.life = player.life + amount
    local times = (self.history.life_gained[player] or 0) + 1
    self.history.life_gained[player] = times
    self:emit({ type = "life", player = player, amount = amount, life = player.life })
    triggers.fire(self, "LifeGained", { player = player, amount = amount, first = times == 1 })
  end
end

function Game:lose_life(player, amount)
  if amount > 0 then
    player.life = player.life - amount
    self.history.life_lost[player] = (self.history.life_lost[player] or 0) + amount
    self:emit({ type = "life", player = player, amount = -amount, life = player.life })
    triggers.fire(self, "LifeLost", { player = player, amount = amount })
  end
end

-- Deals a batch of simultaneous damage: hits = { { source =, target = card or player, amount = } }.
-- Applies deathtouch marking and lifelink (CR 120.3, 702.2b, 702.15b).
function Game:deal_damage_batch(hits, is_combat)
  local lifelink = {}
  for _, hit in ipairs(hits) do
    local source, target, amount = hit.source, hit.target, hit.amount
    if amount > 0 then
      if target.life ~= nil then
        self:lose_life(target, amount)
      else
        target.damage = target.damage + amount
        if source:has_keyword("Deathtouch") then
          target.deathtouch_damage = true
        end
      end
      self:emit({ type = "damage", source = source, target = target, amount = amount, combat = is_combat })
      if source:has_keyword("Lifelink") then
        local who = source.controller
        lifelink[who] = (lifelink[who] or 0) + amount
      end
    end
  end
  for _, player in ipairs(self.players) do
    if lifelink[player] then
      self:gain_life(player, lifelink[player])
    end
  end
end

-- State-based actions (GameAction.checkStateEffects, CR 704) -----------------------------------

function Game:lose(player, reason)
  if not player.lost then
    player.lost = true
    player.loss_reason = reason
    self:emit({ type = "player_lost", player = player, reason = reason })
  end
end

-- Returns true if the game is over.
function Game:check_state_based_actions()
  repeat
    local changed = statics.update_control(self)
    for _, player in ipairs(self.players) do
      if not player.lost then
        if player.life <= 0 then
          self:lose(player, "life")
          changed = true
        elseif player.drew_from_empty then
          self:lose(player, "drew from empty library")
          changed = true
        end
      end
    end

    local to_graveyard, destroyed = {}, {}
    for _, player in ipairs(self.players) do
      for _, card in ipairs(player.battlefield) do
        if card:is_creature() then
          if card:toughness() <= 0 then
            to_graveyard[#to_graveyard + 1] = card
          elseif (card.damage >= card:toughness() or card.deathtouch_damage)
              and not card:has_keyword("Indestructible") then
            destroyed[#destroyed + 1] = card
          end
        end
      end
      -- Auras attached illegally go to the graveyard; Equipment just falls off (CR 704.5m-n).
      for _, card in ipairs(player.battlefield) do
        local target = card.attached_to
        if card:is_aura() then
          local legal = target ~= nil and target.life == nil and target.zone == "battlefield" and target ~= card
              and (card.def.enchant_filter == nil
                   or filter.matches(card.def.enchant_filter, target, { game = self, you = card.controller, self = card }))
          if not legal then
            to_graveyard[#to_graveyard + 1] = card
          end
        elseif card:is_equipment() and target ~= nil then
          if target.life ~= nil or target.zone ~= "battlefield" or not target:is_creature() then
            card.attached_to = nil
            changed = true
          end
        end
      end
      -- Legend rule (CR 704.5j)
      local by_name = {}
      for _, card in ipairs(player.battlefield) do
        if card:is_legendary() then
          by_name[card:name()] = by_name[card:name()] or {}
          table.insert(by_name[card:name()], card)
        end
      end
      for _, cards in pairs(by_name) do
        if #cards > 1 then
          local keep = player.controller:choose_legend_to_keep(self, player, cards)
          for _, card in ipairs(cards) do
            if card ~= keep then
              to_graveyard[#to_graveyard + 1] = card
            end
          end
        end
      end
    end
    self:with_lookback(function()
      for _, card in ipairs(to_graveyard) do
        if card.zone == "battlefield" then
          self:move(card, "graveyard")
          changed = true
        end
      end
      for _, card in ipairs(destroyed) do
        if card.zone == "battlefield" then
          self:emit({ type = "destroy", card = card })
          self:move(card, "graveyard")
          changed = true
        end
      end
    end)
  until not changed

  local alive = {}
  for _, player in ipairs(self.players) do
    if not player.lost then
      alive[#alive + 1] = player
    end
  end
  if #alive <= 1 and not self.over then
    self.over = true
    self.winner = alive[1]
    self:emit({ type = "game_over", winner = self.winner })
  end
  return self.over
end

-- Mana --------------------------------------------------------------------------------------------

function Game:activation_count(card, key)
  local per_card = self.history.activations[card]
  return per_card and per_card[key] or 0
end

function Game:count_activation(card, key)
  self.history.activations[card] = self.history.activations[card] or {}
  self.history.activations[card][key] = self:activation_count(card, key) + 1
end

-- One source per usable mana ability: { card, colors, ability, extra, sacrifice }.
function Game:mana_sources(player)
  local sources = {}
  for _, card in ipairs(player.battlefield) do
    local sick = card:is_creature() and card.sick and not card:has_keyword("Haste")
    for i, ability in ipairs(card.def.mana_abilities) do
      local usable = not (ability.tap and (card.tapped or sick))
          and (ability.limit == nil or self:activation_count(card, "mana" .. i) < ability.limit)
      if usable then
        local colors, seen = {}, {}
        for _, c in ipairs(ability.colors) do
          if c == "Chosen" then
            c = card.chosen_color
          end
          if c and not seen[c] then
            seen[c] = true
            colors[#colors + 1] = c
          end
        end
        if #colors > 0 then
          sources[#sources + 1] = { card = card, colors = colors, ability = ability, key = "mana" .. i,
                                    extra = ability.extra, sacrifice = ability.sacrifice }
        end
      end
    end
  end
  return sources
end

-- Sacrifices permanents (CR 701.17), together.
function Game:sacrifice(cards)
  self:with_lookback(function()
    for _, card in ipairs(cards) do
      if card.zone == "battlefield" then
        self:emit({ type = "sacrifice", card = card })
        self:move(card, "graveyard")
      end
    end
  end)
end

function Game:can_pay(player, cost)
  if cost == nil then
    return false
  end
  return mana.find_payment(cost, self:mana_sources(player)) ~= nil
end

-- A spell's mana cost after cost reductions (generic part only, CR 601.2f). `targets` is the
-- chosen target list, or nil while checking castability (then `candidates` are the possible targets).
function Game:spell_cost(player, card, targets, candidates)
  local cost = card.def.mana_cost
  local reduction = statics.cost_reduction(self, player, card, targets, candidates)
  if cost == nil or reduction <= 0 then
    return cost
  end
  return { generic = math.max(0, cost.generic - reduction), shards = cost.shards }
end

-- Activates mana abilities to pay the cost (they don't use the stack). Returns true if paid.
-- `sources` defaults to all of the player's mana sources.
function Game:pay(player, cost, sources)
  local payment = mana.find_payment(cost, sources or self:mana_sources(player))
  if payment == nil then
    return false
  end
  local sacrificed = {}
  for _, p in ipairs(payment) do
    local source = p.source
    if source.ability.tap then
      self:tap(source.card)
    end
    self:count_activation(source.card, source.key)
    if source.sacrifice then
      sacrificed[#sacrificed + 1] = source.card
    end
    self:emit({ type = "mana", player = player, source = source.card, color = p.color })
  end
  if #sacrificed > 0 then
    self:sacrifice(sacrificed)
  end
  return true
end

-- Actions and priority ----------------------------------------------------------------------------

function Game:is_main_phase()
  return self.step == "main1" or self.step == "main2"
end

function Game:can_act_at_sorcery_speed(player)
  return player == self.active and self:is_main_phase() and #self.stack == 0
end

-- Legal actions for a player with priority: { kind = "play_land" | "cast", card = card }.
function Game:legal_actions(player)
  local actions = {}
  local sorcery_speed = self:can_act_at_sorcery_speed(player)
  for _, card in ipairs(player.battlefield) do
    self:add_activations(actions, player, card, "battlefield")
  end
  for _, card in ipairs(player.graveyard) do
    self:add_activations(actions, player, card, "graveyard")
  end
  for _, card in ipairs(player.hand) do
    if not card.def.supported then
      -- Unsupported cards can sit in hand (e.g. created by tests) but can never be played.
    elseif card:is_land() then
      if sorcery_speed and self.lands_played < 1 then
        actions[#actions + 1] = { kind = "play_land", card = card }
      end
    elseif card.def.mana_cost ~= nil then
      local timing_ok = sorcery_speed or card:has_keyword("Flash") or card:is_type("Instant")
      if timing_ok then
        local ctx = { game = self, source = card, controller = player }
        local candidates = {}
        if card.def.spell and card.def.spell.target then
          candidates = abilities.target_candidates(self, card.def.spell, ctx)
        end
        if self:can_pay(player, self:spell_cost(player, card, nil, candidates))
            and (card.def.spell == nil or abilities.can_target(self, card.def.spell, ctx)) then
          actions[#actions + 1] = { kind = "cast", card = card }
        end
      end
    end
  end
  return actions
end

-- Activated abilities of `card` (in `zone`) that `player` can activate now.
function Game:add_activations(actions, player, card, zone)
  if not card.def.supported or card.controller ~= player then
    return
  end
  for i, act in ipairs(card.def.activated) do
    if act.zone == zone
        and (not act.sorcery or self:can_act_at_sorcery_speed(player))
        and (act.limit == nil or self:activation_count(card, i) < act.limit)
        and cost_lib.can_pay(self, player, card, act.cost)
        and abilities.can_target(self, act.ability, { game = self, source = card, controller = player }) then
      actions[#actions + 1] = { kind = "activate", card = card, index = i }
    end
  end
end

local function is_legal(actions, action)
  for _, a in ipairs(actions) do
    if a.kind == action.kind and a.card == action.card and a.index == action.index then
      return true
    end
  end
  return false
end

function Game:perform(player, action)
  if not is_legal(self:legal_actions(player), action) then
    error("illegal action " .. tostring(action.kind) .. " " .. tostring(action.card))
  end
  local card = action.card
  if action.kind == "play_land" then
    self.lands_played = self.lands_played + 1
    self:move(card, "battlefield")
    self:emit({ type = "play_land", player = player, card = card })
  elseif action.kind == "activate" then
    -- CR 602.2: put on the stack, choose targets, pay costs.
    local act = card.def.activated[action.index]
    local item = { kind = "ability", card = card, controller = player, ability = act.ability,
                   ctx = { game = self, source = card, controller = player, targets = {} } }
    self.stack[#self.stack + 1] = item
    if not abilities.choose_targets(self, item.ability, item.ctx) then
      error("no legal targets for " .. tostring(card))
    end
    self:count_activation(card, action.index)
    cost_lib.pay(self, player, card, act.cost)
    self:emit({ type = "activate", player = player, card = card, targets = item.ctx.targets })
  elseif action.kind == "cast" then
    -- CR 601.2: move to the stack, choose targets, pay costs.
    self:move(card, "stack")
    local item = { kind = "spell", card = card, controller = player, ability = card.def.spell,
                   ctx = { game = self, source = card, controller = player, targets = {} } }
    self.stack[#self.stack + 1] = item
    if item.ability and not abilities.choose_targets(self, item.ability, item.ctx) then
      error("no legal targets for " .. tostring(card))
    end
    local all_targets = {}
    for _, list in pairs(item.ctx.targets) do
      for _, obj in ipairs(list) do
        all_targets[#all_targets + 1] = obj
      end
    end
    if not self:pay(player, self:spell_cost(player, card, all_targets)) then
      error("couldn't pay for " .. tostring(card))
    end
    local spent_before = self.history.mana_spent[player] or 0
    local spent_after = spent_before + card:mana_value()
    self.history.mana_spent[player] = spent_after
    table.insert(self.history.cast, { card = card, player = player })
    self:emit({ type = "cast", player = player, card = card, targets = item.ctx.targets })
    triggers.fire(self, "SpellCast", { card = card, player = player, targets = item.ctx.targets })
    triggers.fire(self, "ManaExpend", { player = player, before = spent_before, after = spent_after })
  end
end

-- Puts waiting triggered abilities on the stack: active player's first, so they resolve last
-- (CR 603.3b, APNAP). A trigger that needs targets and has none is removed (CR 603.3d).
function Game:put_triggers_on_stack()
  local pending = self.pending_triggers
  self.pending_triggers = {}
  local order = { self.active, self:opponent(self.active) }
  for _, player in ipairs(order) do
    for _, pt in ipairs(pending) do
      if pt.controller == player then
        local ctx = { game = self, source = pt.source, controller = player, targets = {}, trigger = pt.event }
        if abilities.choose_targets(self, pt.trigger.ability, ctx) then
          table.insert(self.stack, { kind = "trigger", card = pt.source, controller = player,
                                     ability = pt.trigger.ability, trigger = pt.trigger, ctx = ctx })
          self:emit({ type = "trigger", card = pt.source, player = player, targets = ctx.targets })
        else
          self:emit({ type = "trigger_removed", card = pt.source, player = player })
        end
      end
    end
  end
end

function Game:resolve_top()
  local item = self.stack[#self.stack]
  local card = item.card
  self:emit({ type = "resolve", card = card, kind = item.kind })
  if item.kind == "ability" then
    table.remove(self.stack)
    if not abilities.resolve(self, item.ability, item.ctx, effects) then
      self:emit({ type = "fizzle", card = card })
    end
  elseif item.kind == "trigger" then
    table.remove(self.stack)
    local player = item.controller
    if item.trigger.recheck and not item.trigger.condition(self, item.ctx) then
      return  -- intervening "if" no longer true (CR 603.4)
    end
    if item.trigger.optional and not player.controller:confirm_optional(self, player, card, item.ability) then
      return
    end
    if not abilities.resolve(self, item.ability, item.ctx, effects) then
      self:emit({ type = "fizzle", card = card })
    end
  elseif card:is_permanent_card() then
    if item.ability then
      -- An Aura spell: if its target is gone it doesn't resolve (CR 608.3b) and goes to the graveyard.
      if not abilities.resolve(self, item.ability, item.ctx, effects) then
        self:emit({ type = "fizzle", card = card })
      end
      if card.zone == "stack" then
        self:move(card, "graveyard")
      end
    else
      self:move(card, "battlefield", { controller = item.controller })
    end
  else
    if item.ability and not abilities.resolve(self, item.ability, item.ctx, effects) then
      self:emit({ type = "fizzle", card = card })
    end
    if card.zone == "stack" then
      self:move(card, "graveyard")
    end
  end
end

-- Priority round for the current step (PhaseHandler.mainLoopStep). Returns when all players pass
-- in succession with an empty stack, or when the game ends.
function Game:priority_round()
  local first = self.active      -- player who must pass last before the stack resolves / step ends
  local player = self.active
  local actions_taken = 0
  while true do
    if self:check_state_based_actions() then
      return
    end
    if #self.pending_triggers > 0 then
      -- CR 117.5: state-based actions, then triggers, repeated before anyone gets priority.
      self:put_triggers_on_stack()
    else
      local action = player.controller:choose_action(self, player, self:legal_actions(player))
      if action then
        self:perform(player, action)
        first = player
        actions_taken = actions_taken + 1
        if actions_taken > 1000 then
          error("more than 1000 actions in one step")
        end
      else
        local next_player = self:opponent(player)
        if next_player == first then
          if #self.stack == 0 then
            return
          end
          self:resolve_top()
          player, first = self.active, self.active
        else
          player = next_player
        end
      end
    end
  end
end

-- Turn structure -----------------------------------------------------------------------------------

local turn_based = {}

function turn_based.untap(game, player)
  for _, card in ipairs(player.battlefield) do
    card.sick = false   -- controlled continuously since this turn began (CR 302.6)
  end
  for _, card in ipairs(player.battlefield) do
    game:untap(card)
  end
end

function turn_based.draw(game, player)
  game:draw(player, 1)
end

function turn_based.combat_begin(game, player)
  game.combat = { attackers = {}, blockers_of = {}, blocking = {}, blocked = {}, dealt_first_strike = {} }
end

function turn_based.combat_declare_attackers(game, player)
  local candidates = combat.attack_candidates(game, player)
  local attackers = {}
  if #candidates > 0 then
    attackers = player.controller:declare_attackers(game, player, candidates) or {}
  end
  -- Creatures that must attack if able are added (StaticAbilityMustAttack, CR 508.1d).
  for _, card in ipairs(candidates) do
    local declared = false
    for _, a in ipairs(attackers) do
      declared = declared or a == card
    end
    if not declared and statics.must_attack(game, card) then
      attackers[#attackers + 1] = card
    end
  end
  local ok, reason = combat.validate_attackers(game, player, attackers)
  if not ok then
    error("invalid attack: " .. reason)
  end
  game.combat.attackers = attackers
  game.history.attackers[player] = #attackers
  for _, card in ipairs(attackers) do
    if not card:has_keyword("Vigilance") then
      game:tap(card)
    end
  end
  game:emit({ type = "attackers", player = player, attackers = attackers })
  for _, card in ipairs(attackers) do
    triggers.fire(game, "Attacks", { card = card, player = player })
  end
  if #attackers > 0 then
    triggers.fire(game, "AttackersDeclared", { player = player, attackers = attackers })
  end
end

function turn_based.combat_declare_blockers(game, player)
  local defender = game:opponent(player)
  local candidates = combat.block_candidates(game, defender)
  local blocks = {}
  if #candidates > 0 then
    blocks = defender.controller:declare_blockers(game, defender, game.combat.attackers, candidates) or {}
  end
  local ok, reason = combat.validate_blocks(game, defender, blocks)
  if not ok then
    error("invalid blocks: " .. reason)
  end
  local c = game.combat
  for _, block in ipairs(blocks) do
    c.blocking[block.blocker] = block.attacker
    c.blockers_of[block.attacker] = c.blockers_of[block.attacker] or {}
    table.insert(c.blockers_of[block.attacker], block.blocker)
    c.blocked[block.attacker] = true
  end
  game:emit({ type = "blockers", player = defender, blocks = blocks })
  for _, block in ipairs(blocks) do
    triggers.fire(game, "Blocks", { card = block.blocker, player = defender })
  end
  for _, attacker in ipairs(c.attackers) do
    if c.blocked[attacker] then
      triggers.fire(game, "AttackerBlocked", { card = attacker, blockers = c.blockers_of[attacker] })
    end
  end
end

function turn_based.combat_first_strike_damage(game, player)
  combat.deal_damage_step(game, true)
end

function turn_based.combat_damage(game, player)
  combat.deal_damage_step(game, false)
end

function turn_based.combat_end(game, player)
  game.combat = nil
end

function turn_based.cleanup(game, player)
  local excess = #player.hand - MAX_HAND_SIZE
  if excess > 0 then
    game:discard(player, player.controller:choose_discard(game, player, excess), excess)
  end
  -- CR 514.2: damage wears off and "until end of turn" effects end.
  for _, p in ipairs(game.players) do
    for _, card in ipairs(p.battlefield) do
      card.damage = 0
      card.deathtouch_damage = false
      card.pumps = {}
    end
  end
end

-- CR 103.8a, 508.8, 510.4 (PhaseHandler.isSkippingPhase).
function Game:skips_step(step)
  if step == "draw" then
    return self.turn == 1
  elseif step == "combat_declare_blockers" or step == "combat_damage" then
    return self.combat == nil or #self.combat.attackers == 0
  elseif step == "combat_first_strike_damage" then
    return self.combat == nil or #self.combat.attackers == 0 or not combat.has_first_strikers(self)
  end
  return false
end

function Game:run_step(step)
  self.step = step
  if self:skips_step(step) then
    return
  end
  self:emit({ type = "step", step = step, player = self.active, turn = self.turn })
  if turn_based[step] then
    turn_based[step](self, self.active)
  end
  if not NO_PRIORITY[step] then
    triggers.fire(self, "Phase", { step = step, player = self.active })
  end
  if NO_PRIORITY[step] then
    -- CR 514.3a: players only get priority in cleanup if state-based actions or triggers happen.
    self:check_state_based_actions()
    if #self.pending_triggers > 0 and not self.over then
      self:priority_round()
    end
  else
    self:priority_round()
  end
end

-- Plays one full turn for the active player, then passes the turn.
function Game:run_turn()
  self.turn = self.turn + 1
  self.lands_played = 0
  self.history = new_history()
  self:emit({ type = "turn", player = self.active, turn = self.turn })
  for _, step in ipairs(Game.STEPS) do
    if self.over then
      return
    end
    self:run_step(step)
  end
  self.step = nil
  self.active = self:opponent(self.active)
end

-- Plays until the game ends or max_turns is reached. Returns the winner (nil for a draw or unfinished).
function Game:run()
  while not self.over and self.turn < self.max_turns do
    self:run_turn()
  end
  return self.winner
end

return Game
