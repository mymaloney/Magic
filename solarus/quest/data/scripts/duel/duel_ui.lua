-- Duel screen logic, independent of Solarus (no sol.* calls) so it can be tested headlessly.
-- scripts/menus/duel.lua draws this state and forwards input to it.
--
-- The engine runs in a coroutine (controllers/prompt.lua). This model holds the human player's
-- current request, a cursor over three rows of cards, and per-request selections, and turns
-- abstract inputs into answers:
--   ui:press("left" | "right" | "up" | "down")   move the cursor
--   ui:press("select")    play/cast the focused card, toggle an attacker/discard/target, set up a
--                         block, say yes to a "may" ability
--   ui:press("confirm")   pass priority / submit attackers, blocks, discards, targets / say yes /
--                         leave a finished game
--   ui:press("cancel")    drop a half-made block / say no to a "may" ability
-- While choosing targets, row 3 shows the candidates (cards from any zone, and players) instead of
-- the hand.
-- Requests the human has no real choice in (no legal actions, combat damage division) are
-- answered automatically, and priority with only instant-speed options passes automatically
-- outside the stop points in duel_ui:wants_stop.

local combat = require("scripts/mtg/combat")
local prompt = require("scripts/mtg/controllers/prompt")

local duel_ui = {}
duel_ui.__index = duel_ui

duel_ui.ROWS = { "opponent", "battlefield", "hand" }
local LOG_SIZE = 6
local COLOR_NAMES = { W = "White", U = "Blue", B = "Black", R = "Red", G = "Green" }

local STEP_NAMES = {
  untap = "untap", upkeep = "upkeep", draw = "draw step", main1 = "main phase",
  combat_begin = "beginning of combat", combat_declare_attackers = "declare attackers",
  combat_declare_blockers = "declare blockers", combat_first_strike_damage = "first strike damage",
  combat_damage = "combat damage", combat_end = "end of combat", main2 = "second main phase",
  end_of_turn = "end step", cleanup = "cleanup",
}

-- game: an mtg Game whose human player uses controllers/prompt; human: that player.
function duel_ui.new(game, human)
  local ui = setmetatable({
    game = game,
    human = human,
    opponent = game:opponent(human),
    runner = prompt.run(game),
    request = nil,
    row = 3,
    col = 1,
    selected = {},        -- attackers / discards being chosen: [card] = true
    blocks = {},          -- [blocker] = attacker
    pending_blocker = nil,
    log = {},
    error_message = nil,
    finished = false,     -- true once the player has acknowledged the end of the game
  }, duel_ui)
  game:on_event(function(event) ui:on_game_event(event) end)
  return ui
end

-- Player-facing name
function duel_ui:who(player)
  if player == self.human then
    return "You"
  end
  return player.name
end

function duel_ui:add_log(text)
  table.insert(self.log, text)
  if #self.log > LOG_SIZE then
    table.remove(self.log, 1)
  end
end

function duel_ui:on_game_event(e)
  local t = e.type
  if t == "turn" then
    self:add_log("Turn " .. e.turn .. ": " .. (e.player == self.human and "your turn" or e.player.name .. "'s turn"))
  elseif t == "play_land" then
    self:add_log(self:who(e.player) .. " played " .. e.card:name())
  elseif t == "cast" then
    self:add_log(self:who(e.player) .. " cast " .. e.card:name() .. self:targets_text(e.targets))
  elseif t == "trigger" then
    self:add_log(e.card:name() .. " triggered" .. self:targets_text(e.targets))
  elseif t == "activate" then
    self:add_log(self:who(e.player) .. " used " .. e.card:name() .. self:targets_text(e.targets))
  elseif t == "sacrifice" then
    self:add_log(e.card:name() .. " was sacrificed")
  elseif t == "countered" then
    self:add_log(e.card:name() .. " was countered")
  elseif t == "fizzle" then
    self:add_log(e.card:name() .. " fizzled (no legal target)")
  elseif t == "attackers" and #e.attackers > 0 then
    self:add_log(self:who(e.player) .. " attacked with " .. #e.attackers .. (#e.attackers == 1 and " creature" or " creatures"))
  elseif t == "blockers" and #e.blocks > 0 then
    self:add_log(self:who(e.player) .. " blocked with " .. #e.blocks)
  elseif t == "damage" and e.target.life ~= nil then
    self:add_log(e.source:name() .. " dealt " .. e.amount .. " to " .. (e.target == self.human and "you" or e.target.name))
  elseif t == "destroy" then
    self:add_log(e.card:name() .. " died")
  elseif t == "discard" then
    self:add_log(self:who(e.player) .. " discarded " .. e.card:name())
  elseif t == "player_lost" then
    self:add_log(self:who(e.player) .. " lost (" .. e.reason .. ")")
  end
end

-- " -> Green" / " -> Savannah Lions" for a log line, from an engine targets table.
function duel_ui:targets_text(targets)
  local names = {}
  for _, list in pairs(targets or {}) do
    for _, obj in ipairs(list) do
      names[#names + 1] = obj.life ~= nil and self:who(obj) or obj:name()
    end
  end
  if #names == 0 then
    return ""
  end
  table.sort(names)
  return " -> " .. table.concat(names, ", ")
end

-- Short label for a card or player
function duel_ui:label(obj)
  if obj.life ~= nil then
    return self:who(obj)
  end
  return obj:name()
end

-- Rows ----------------------------------------------------------------------------------------

-- Nonland permanents, plus lands with activated abilities other than mana (so they can be used).
local function shown_permanents(player)
  local list = {}
  for _, card in ipairs(player.battlefield) do
    if not card:is_land() or #card:activated() > 0 then
      list[#list + 1] = card
    end
  end
  return list
end

-- Requests that pick some of request.candidates (shown in row 3).
local PICK_KINDS = { choose_targets = true, choose_cards = true }
local abilities = require("scripts/mtg/abilities")

-- Cards shown in a row (1 = opponent's permanents, 2 = yours, 3 = your hand, followed by cards
-- in other zones you can do something with: flashback, graveyard abilities, playable from exile).
function duel_ui:row_cards(row)
  if row == 1 then
    return shown_permanents(self.opponent)
  elseif row == 2 then
    return shown_permanents(self.human)
  end
  if self.option_entries then
    return self.option_entries
  end
  if self.request and PICK_KINDS[self.request.kind] then
    return self.request.candidates
  end
  if self.request and self.request.kind == "arrange_top" then
    return self.request.cards
  end
  if self.request and self.request.kind == "choose_action" then
    local cards, seen = {}, {}
    for _, card in ipairs(self.human.hand) do
      cards[#cards + 1] = card
    end
    for _, action in ipairs(self.request.actions) do
      local card = action.card
      if card.zone ~= "hand" and card.zone ~= "battlefield" and not seen[card] then
        seen[card] = true
        cards[#cards + 1] = card
      end
    end
    return cards
  end
  return self.human.hand
end

-- { { name = "Forest", untapped = 3, total = 5 }, ... } in first-seen order.
function duel_ui:land_summary(player)
  local groups, order = {}, {}
  for _, card in ipairs(player.battlefield) do
    if card:is_land() then
      local g = groups[card:name()]
      if g == nil then
        g = { name = card:name(), untapped = 0, total = 0 }
        groups[card:name()] = g
        order[#order + 1] = g
      end
      g.total = g.total + 1
      if not card.tapped then
        g.untapped = g.untapped + 1
      end
    end
  end
  return order
end

function duel_ui:clamp_focus()
  local n = #self:row_cards(self.row)
  if self.col > n then
    self.col = n
  end
  if self.col < 1 then
    self.col = 1
  end
end

function duel_ui:focused_card()
  return self:row_cards(self.row)[self.col]
end

-- Highlights for drawing a card.
function duel_ui:card_marks(card)
  local r = self.request
  local marks = {
    focused = card == self:focused_card(),
    tapped = card.tapped == true,
    option = card.is_option == true,
    selected = self.selected[card] == true,
    blocking = self.blocks[card] ~= nil,
    pending = card == self.pending_blocker,
  }
  local c = self.game.combat
  if c then
    for _, attacker in ipairs(c.attackers) do
      if attacker == card then
        marks.attacking = true
      end
    end
    if c.blocking[card] then
      marks.blocking = true
    end
  end
  if r and r.kind == "choose_action" then
    for _, action in ipairs(r.actions) do
      if action.card == card then
        marks.playable = true
      end
    end
  end
  return marks
end

-- Requests ------------------------------------------------------------------------------------

local function contains(list, item)
  for _, x in ipairs(list) do
    if x == item then
      return true
    end
  end
  return false
end

-- Should a priority request with only instant-speed options stop for the player? Like Forge's
-- default phase stops: your main phases, anything on the stack, after blockers are declared,
-- and the opponent's end step. Otherwise priority passes automatically.
function duel_ui:wants_stop(request)
  local game = self.game
  local step = game.step
  if #game.stack > 0 or step == "combat_declare_blockers" then
    return true
  end
  if game:active_player() == self.human then
    return step == "main1" or step == "main2"
  end
  return step == "end_of_turn"
end

-- Resumes the engine with an answer and runs until the human has a real decision to make.
function duel_ui:advance(answer)
  self.selected, self.blocks, self.pending_blocker, self.error_message = {}, {}, nil, nil
  local request = self.runner.resume(answer)
  while true do
    if request.kind == "choose_action" and (#request.actions == 0 or not self:wants_stop(request)) then
      request = self.runner.resume(nil)
    elseif request.kind == "assign_combat_damage" then
      request = self.runner.resume(request.default)
    else
      break
    end
  end
  self.request = request
  self.option_entries = nil
  if request.kind == "declare_blockers" then
    -- blocks a lure attacker forces (Ochran Assassin) start out declared
    for _, block in ipairs(combat.apply_lure(self.game, self.human, {})) do
      self.blocks[block.blocker] = block.attacker
    end
  end
  if request.kind == "choose_color" then
    self.option_entries = {}
    for _, c in ipairs(request.options) do
      self.option_entries[#self.option_entries + 1] = { is_option = true, value = c, label = COLOR_NAMES[c] }
    end
    self.row, self.col = 3, 1
  elseif request.kind == "choose_mode" then
    self.option_entries = {}
    for _, index in ipairs(request.options) do
      local text = abilities.describe(request.charm.choices[index])
      self.option_entries[#self.option_entries + 1] = {
        is_option = true, value = index, label = "Mode" .. index, detail = text,
      }
    end
    self.row, self.col = 3, 1
  elseif request.kind == "arrange_top" then
    self.row, self.col = 3, 1
  elseif request.kind == "choose_option" then
    self.option_entries = {}
    for i, label in ipairs(request.labels) do
      self.option_entries[#self.option_entries + 1] = { is_option = true, value = i, label = label, detail = label }
    end
    self.row, self.col = 3, 1
  elseif request.kind == "choose_number" then
    self.option_entries = {}
    for n = request.min, request.max do
      self.option_entries[#self.option_entries + 1] = { is_option = true, value = n, label = tostring(n),
                                                        detail = request.purpose .. " = " .. n }
    end
    self.row, self.col = 3, 1
  end
  if request.kind == "declare_attackers" or request.kind == "declare_blockers" then
    self.row = 2
  elseif request.kind == "choose_discard" or request.kind == "choose_action" or PICK_KINDS[request.kind] then
    self.row = 3
    if PICK_KINDS[request.kind] then
      self.col = 1
    end
  end
  self:clamp_focus()
end

function duel_ui:start()
  self:advance(nil)
end

-- prefix .. name .. suffix, shortening the name so the whole line fits LINE_CHARS.
local LINE_CHARS = 35
local function fit(prefix, name, suffix)
  local room = LINE_CHARS - #prefix - #suffix
  if #name > room then
    name = name:sub(1, room - 1) .. "."
  end
  return prefix .. name .. suffix
end

-- Two short lines for the current request: what is happening, and which keys to press.
-- Both fit the duel screen's 35-character lines (error messages may be clipped).
function duel_ui:prompt_text()
  local r = self.request
  if r == nil then
    return "", ""
  end
  local kind = r.kind
  local title, help
  if kind == "game_over" then
    if r.winner == self.human then
      title = "You won!"
    elseif r.winner == nil then
      title = "Draw."
    else
      title = "You lost."
    end
    help = "Enter: continue"
  elseif kind == "choose_action" and self.option_entries then
    title, help = "Which ability?", "Space: use  Bksp: back"
  elseif kind == "choose_action" then
    local top = self.game.stack[#self.game.stack]
    if top then
      title = fit("Respond to ", top.card:name(), top.kind == "trigger" and " (ability)?" or "?")
    else
      local whose = self.game:active_player() == self.human and "Your " or "Their "
      title = whose .. (STEP_NAMES[self.game.step] or "")
    end
    help = "Space: play  Enter: pass"
  elseif PICK_KINDS[kind] then
    local n = 0
    for _ in pairs(self.selected) do
      n = n + 1
    end
    if kind == "choose_targets" then
      title = fit("Target for ", r.source:name(), "")
    else
      local verbs = { sacrifice = "Sacrifice ", discard = "Discard ", discard_other = "They discard ",
                      dig = "Take up to ", search = "Find up to " }
      title = (verbs[r.reason] or "Choose ") .. ((r.reason == "dig" or r.reason == "search") and r.max or r.min)
      if r.reason == "crew" then
        title = "Crew: tap power " .. r.power_needed .. "+"
      end
    end
    if r.max == 1 then
      help = "Space: choose" .. (r.min == 0 and "  Enter: none" or "")
    else
      help = "Space: pick (" .. n .. "/" .. r.max .. ")  Enter: done"
    end
  elseif kind == "choose_color" then
    title = fit("Color for ", r.source:name(), "")
    help = "Space: choose"
  elseif kind == "choose_option" then
    title = fit("Choose for ", r.source:name(), "")
    help = "Space: choose"
  elseif kind == "choose_number" then
    title = fit(r.purpose .. " for ", r.source:name(), "")
    help = "Space: choose"
  elseif kind == "choose_mode" then
    title = fit("Mode for ", r.source:name(), "")
    help = "Space: choose (see details)"
  elseif kind == "arrange_top" then
    local scry = r.away == "bottom"
    title = (scry and "Scry " or "Surveil ") .. #r.cards .. " (first = top)"
    help = scry and "Space: to bottom  Enter: done" or "Space: to graveyard  Enter: done"
  elseif kind == "confirm_optional" then
    if r.ability and r.ability.api == "Kicker" then
      title = fit("Kick ", r.source:name(), "?")
    elseif r.ability and r.ability.optional_cost then
      title = fit("Pay the cost for ", r.source:name(), "?")
    else
      title = fit("Use ", r.source:name(), "?")
    end
    help = "Space: yes  Bksp: no"
  elseif kind == "declare_attackers" then
    title, help = "Declare attackers", "Space: pick  Enter: attack"
  elseif kind == "declare_blockers" then
    if self.pending_blocker then
      title, help = "Block which attacker?", "Space: block  Bksp: cancel"
    else
      title, help = "Declare blockers", "Space: pick  Enter: done"
    end
  elseif kind == "choose_discard" then
    local n = 0
    for _ in pairs(self.selected) do
      n = n + 1
    end
    title, help = "Discard " .. r.count .. " (" .. n .. " picked)", "Space: pick  Enter: done"
  elseif kind == "choose_legend_to_keep" then
    title, help = "Legend rule: keep one", "Space: keep"
  else
    title, help = kind, ""
  end
  return self.error_message or title, help
end

function duel_ui:select()
  local r, card = self.request, self:focused_card()
  if r == nil or card == nil then
    return
  end
  self.error_message = nil
  if r.kind == "choose_action" then
    if card.is_option then
      self:advance(card.action)
      return
    end
    local matching = {}
    for _, action in ipairs(r.actions) do
      if action.card == card then
        matching[#matching + 1] = action
      end
    end
    if #matching == 1 then
      self:advance(matching[1])
    elseif #matching > 1 then
      -- several things to do with this card: list them in row 3
      self.option_entries = {}
      for _, action in ipairs(matching) do
        self.option_entries[#self.option_entries + 1] = duel_ui.action_option(action)
      end
      self.row, self.col = 3, 1
    end
  elseif r.kind == "declare_attackers" then
    if contains(r.candidates, card) then
      self.selected[card] = not self.selected[card] or nil
    end
  elseif r.kind == "declare_blockers" then
    if self.row == 2 and contains(r.candidates, card) then
      if self.blocks[card] then
        self.blocks[card] = nil
      else
        self.pending_blocker = card
        self.row = 1
        self.col = 1
        for i, c in ipairs(self:row_cards(1)) do   -- jump to the first attacker
          if contains(r.attackers, c) then
            self.col = i
            break
          end
        end
      end
    elseif self.row == 1 and self.pending_blocker and contains(r.attackers, card) then
      if combat.can_block_attacker(self.pending_blocker, card) then
        self.blocks[self.pending_blocker] = card
        self.pending_blocker = nil
        self.row = 2
        self:clamp_focus()
      else
        self.error_message = self.pending_blocker:name() .. " can't block that"
      end
    end
  elseif r.kind == "choose_discard" then
    if self.row == 3 then
      self.selected[card] = not self.selected[card] or nil
    end
  elseif r.kind == "choose_legend_to_keep" then
    if contains(r.cards, card) then
      self:advance(card)
    end
  elseif PICK_KINDS[r.kind] then
    if self.row == 3 and contains(r.candidates, card) then
      if r.max == 1 and r.min == 1 then
        self:advance({ card })
      else
        local n = 0
        for _ in pairs(self.selected) do
          n = n + 1
        end
        if self.selected[card] then
          self.selected[card] = nil
        elseif n < r.max then
          self.selected[card] = true
        end
      end
    end
  elseif r.kind == "confirm_optional" then
    self:advance(true)
  elseif r.kind == "choose_color" or r.kind == "choose_mode" or r.kind == "choose_number"
      or r.kind == "choose_option" then
    if card.is_option then
      self:advance(card.value)
    end
  elseif r.kind == "arrange_top" then
    if self.row == 3 then
      self.selected[card] = not self.selected[card] or nil
    end
  end
end

function duel_ui:confirm()
  local r = self.request
  if r == nil then
    return
  end
  if r.kind == "game_over" then
    self.finished = true
  elseif r.kind == "confirm_optional" then
    self:advance(true)
  elseif PICK_KINDS[r.kind] then
    local chosen = {}
    for _, obj in ipairs(r.candidates) do
      if self.selected[obj] then
        chosen[#chosen + 1] = obj
      end
    end
    local controllers_ok = true
    if r.kind == "choose_targets" and r.ability.params.TargetsWithDifferentControllers == "True" then
      for i = 1, #chosen do
        for j = i + 1, #chosen do
          controllers_ok = controllers_ok and chosen[i].controller ~= chosen[j].controller
        end
      end
    end
    local power = 0
    for _, obj in ipairs(chosen) do
      power = power + (obj.life == nil and math.max(0, obj:power()) or 0)
    end
    if #chosen < r.min or #chosen > r.max then
      self.error_message = "Pick at least " .. r.min
    elseif r.power_needed and power < r.power_needed then
      self.error_message = "Need total power " .. r.power_needed
    elseif not controllers_ok then
      self.error_message = "Pick creatures of different players"
    else
      self:advance(chosen)
    end
  elseif r.kind == "arrange_top" then
    local top, away = {}, {}
    for _, card in ipairs(r.cards) do
      if self.selected[card] then
        away[#away + 1] = card
      else
        top[#top + 1] = card
      end
    end
    self:advance({ top = top, away = away })
  elseif r.kind == "choose_action" then
    if self.option_entries then
      return   -- choosing which ability: Space picks, Backspace goes back
    end
    self:advance(nil)
  elseif r.kind == "declare_attackers" then
    local attackers = {}
    for _, card in ipairs(r.candidates) do
      if self.selected[card] then
        attackers[#attackers + 1] = card
      end
    end
    self:advance(attackers)
  elseif r.kind == "declare_blockers" then
    local blocks = {}
    for _, blocker in ipairs(r.candidates) do
      if self.blocks[blocker] then
        blocks[#blocks + 1] = { blocker = blocker, attacker = self.blocks[blocker] }
      end
    end
    local ok, reason = combat.validate_blocks(self.game, self.human, blocks)
    if ok then
      self:advance(blocks)
    else
      self.error_message = reason
    end
  elseif r.kind == "choose_discard" then
    local cards = {}
    for _, card in ipairs(self.human.hand) do
      if self.selected[card] then
        cards[#cards + 1] = card
      end
    end
    if #cards == r.count then
      self:advance(cards)
    else
      self.error_message = "Pick exactly " .. r.count .. " to discard"
    end
  end
end

function duel_ui:press(input)
  if input == "left" then
    self.col = self.col - 1
    self:clamp_focus()
  elseif input == "right" then
    self.col = self.col + 1
    self:clamp_focus()
  elseif input == "up" then
    self.row = math.max(1, self.row - 1)
    self:clamp_focus()
  elseif input == "down" then
    self.row = math.min(3, self.row + 1)
    self:clamp_focus()
  elseif input == "select" then
    self:select()
  elseif input == "confirm" then
    self:confirm()
  elseif input == "cancel" then
    if self.request and self.request.kind == "confirm_optional" then
      self:advance(false)
    elseif self.request and self.request.kind == "choose_action" and self.option_entries then
      self.option_entries = nil
      self.row = 2
      self:clamp_focus()
    else
      self.pending_blocker = nil
      self.error_message = nil
    end
  end
end

-- An option box for one action on a card (when a card has several).
function duel_ui.action_option(action)
  local label, detail = "Cast", "Cast " .. action.card:name()
  if action.variant then
    local v = action.card.def.cast_variants[action.variant]
    label, detail = v.label, "Cast " .. action.card:name() .. ": " .. v.label
  elseif action.flashback then
    label, detail = "Flashback", "Cast " .. action.card:name() .. " with flashback"
  elseif action.kind == "play_land" then
    label, detail = "Play", "Play " .. action.card:name()
  elseif action.kind == "activate" then
    local ability = action.card:activated()[action.index].ability
    label = ability.api
    detail = (ability.params.SpellDescription or ability.api)
  end
  return { is_option = true, label = label, detail = detail, action = action }
end

-- Word-wraps text into lines of at most `width` characters.
function duel_ui.wrap(text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
    while #line > width do
      lines[#lines + 1] = line:sub(1, width)
      line = line:sub(width + 1)
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return lines
end

-- Text for the detail panel: { name, "cost  types", "P/T  keywords", oracle lines... }
function duel_ui.card_details(card)
  if card.is_option then
    return { card.label, "", "", card.detail }
  end
  if card.life ~= nil then
    local lines = { card.name, "Life " .. card.life, "Hand " .. #card.hand .. "  Library " .. #card.library }
    if #card.mana_pool > 0 then
      local pool = {}
      for _, entry in ipairs(card.mana_pool) do
        pool[#pool + 1] = "{" .. entry.color .. "}"
      end
      lines[4] = "Mana pool: " .. table.concat(pool)
    end
    return lines
  end
  local def = card.def
  local face = def.script.faces[1]
  local lines = { card:name() }
  if card.zone == "graveyard" or card.zone == "exile" then
    lines[1] = def.name .. " (in " .. card.zone .. ")"
  elseif card:name() ~= def.name then
    lines[1] = card:name() .. " (" .. def.name .. ")"
  end
  local cost = face.mana_cost == "no cost" and "" or ("{" .. (face.mana_cost or ""):gsub(" ", "}{") .. "}  ")
  lines[2] = cost .. (face.types or "")
  local kw = {}
  for k in pairs(def.keywords) do
    kw[#kw + 1] = k
  end
  table.sort(kw)
  local pt = def.power and (def.power .. "/" .. def.toughness .. "  ") or ""
  lines[3] = pt .. table.concat(kw, ", ")
  if card.attached_to then
    local target = card.attached_to
    lines[3] = lines[3] .. (lines[3] ~= "" and "  " or "") .. "On " .. (target.life ~= nil and target.name or target:name())
  end
  if card.zone == "battlefield" and card:abilities_lost() then
    lines[#lines + 1] = "It has lost all abilities."
  end
  local oracle = (face.oracle or ""):gsub("\\n", "\n")
  for paragraph in (oracle .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = paragraph
  end
  return lines
end

return duel_ui
