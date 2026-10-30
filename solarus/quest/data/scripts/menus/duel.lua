-- Duel screen: you (Rakdos deck) against the AI (Green deck).
-- Draws the state held by scripts/duel/duel_ui.lua and forwards keys to it; all game logic lives there
-- and in scripts/mtg/. Shown as a pre-game menu for now (see scripts/menus/initial_menus_config.lua).
--
-- Keys: arrows move the cursor, Space selects, Return confirms/passes, Backspace cancels a block or
-- says no to a "may" ability.
-- Layout (320x240, 8_bit font = 9x12 px per character, about 35 characters per line):
--   opponent status, opponent lands, opponent permanents, prompt, last log line,
--   your permanents, your lands, your hand, your status, card detail panel (focused card, or the
--   log when nothing is focused), key help.

local card_db = require("scripts/mtg/card_db")
local Game = require("scripts/mtg/game")
local ai = require("scripts/mtg/controllers/ai")
local prompt = require("scripts/mtg/controllers/prompt")
local duel_ui = require("scripts/duel/duel_ui")
local decks = require("scripts/duel/decks")
local pool = require("cards/pool")

local duel_menu = {}

local CHARS = 35
local BOX_W, BOX_H, BOX_STEP = 38, 26, 40
local MAX_BOXES = 8

local Y = {
  opponent_status = 1, opponent_lands = 14, opponent_row = 27, prompt = 56, log = 69,
  my_row = 82, my_lands = 111, hand_row = 124, my_status = 153, details = 166,
}

local COLORS = {
  background = { 20, 60, 40 },
  panel = { 15, 30, 25 },
  card = { 70, 70, 85 },
  tapped = { 35, 35, 45 },
  playable = { 40, 120, 55 },
  selected = { 160, 45, 45 },
  attacking = { 160, 45, 45 },
  blocking = { 45, 75, 160 },
  pending = { 130, 60, 160 },
  focus = { 255, 215, 0 },
}

local ui
local text_cache = {}

local function text(dst, str, x, y)
  if str == nil or str == "" then
    return
  end
  local surface = text_cache[str]
  if surface == nil then
    surface = sol.text_surface.create({
      font = "8_bit", text = str,
      horizontal_alignment = "left", vertical_alignment = "top",
    })
    text_cache[str] = surface
  end
  surface:draw(dst, x, y)
end

local function clip(str)
  if #str > CHARS then
    return str:sub(1, CHARS)
  end
  return str
end

local function read_file(path)
  local file = sol.file.open(path)
  local content = file:read("*a")
  file:close()
  return content
end

function duel_menu:on_started()
  text_cache = {}
  local db = card_db.new(pool, read_file)
  local game = Game.new({
    players = {
      { name = "You", deck = db.make_deck(decks.rakdos.cards), controller = prompt.new() },
      { name = "Green", deck = db.make_deck(decks.green.cards), controller = ai.new() },
    },
  })
  ui = duel_ui.new(game, game.players[1])
  ui:start()
end

local function status_line(player, label)
  return string.format("%s  Life %d  Hand %d  Lib %d  GY %d",
      label, player.life, #player.hand, #player.library, #player.graveyard)
end

local function lands_line(player)
  local parts = {}
  for _, group in ipairs(ui:land_summary(player)) do
    parts[#parts + 1] = group.name .. " " .. group.untapped .. "/" .. group.total
  end
  if #parts == 0 then
    return "No lands"
  end
  return table.concat(parts, "  ")
end

local function box_color(marks)
  if marks.pending then
    return COLORS.pending
  elseif marks.selected or marks.attacking then
    return COLORS.attacking
  elseif marks.blocking then
    return COLORS.blocking
  elseif marks.playable then
    return COLORS.playable
  elseif marks.tapped then
    return COLORS.tapped
  end
  return COLORS.card
end

local function draw_row(dst, row, y)
  local cards = ui:row_cards(row)
  local first = 1
  if ui.row == row and ui.col > MAX_BOXES then
    first = ui.col - MAX_BOXES + 1
  end
  for i = first, math.min(#cards, first + MAX_BOXES - 1) do
    local card = cards[i]
    local x = 1 + (i - first) * BOX_STEP
    local marks = ui:card_marks(card)
    if marks.focused and ui.row == row then
      dst:fill_color(COLORS.focus, x - 1, y - 1, BOX_W + 2, BOX_H + 2)
    end
    dst:fill_color(box_color(marks), x, y, BOX_W, BOX_H)
    if card.life ~= nil then  -- a player, offered as a target
      text(dst, card == ui.human and "You" or "Opp", x + 1, y + 1)
      text(dst, tostring(card.life), x + 1, y + 13)
    else
      text(dst, card:name():gsub("[^%w]", ""):sub(1, 4), x + 1, y + 1)
    end
    if card.life == nil and card:is_creature() then
      local toughness_left = card:toughness() - card.damage
      text(dst, card:power() .. "/" .. toughness_left, x + 1, y + 13)
    end
  end
  if #cards == 0 and ui.row == row then
    dst:fill_color(COLORS.focus, 1, y + BOX_H / 2, 8, 2)
  end
end

local function draw_details(dst, help)
  dst:fill_color(COLORS.panel, 0, Y.details, 320, 240 - Y.details)
  local card = ui:focused_card()
  local lines = {}
  if card then
    local detail = duel_ui.card_details(card)
    for i = 1, 3 do
      lines[#lines + 1] = clip(detail[i] or "")
    end
    for i = 4, #detail do
      for _, wrapped in ipairs(duel_ui.wrap(detail[i], CHARS)) do
        lines[#lines + 1] = wrapped
      end
    end
  else
    for _, entry in ipairs(ui.log) do
      lines[#lines + 1] = clip(entry)
    end
  end
  for i = 1, math.min(#lines, 5) do
    text(dst, lines[i], 4, Y.details + 2 + (i - 1) * 12)
  end
  text(dst, clip(help), 4, Y.details + 2 + 5 * 12)
end

function duel_menu:on_draw(dst)
  if ui == nil then
    return
  end
  local game = ui.game
  dst:fill_color(COLORS.background)
  text(dst, clip(status_line(ui.opponent, ui.opponent.name)), 2, Y.opponent_status)
  text(dst, clip(lands_line(ui.opponent)), 2, Y.opponent_lands)
  draw_row(dst, 1, Y.opponent_row)
  dst:fill_color(COLORS.panel, 0, Y.prompt - 1, 320, 26)
  local title, help = ui:prompt_text()
  text(dst, clip(title), 2, Y.prompt)
  text(dst, clip(ui.log[#ui.log] or ""), 2, Y.log)
  draw_row(dst, 2, Y.my_row)
  text(dst, clip(lands_line(ui.human)), 2, Y.my_lands)
  draw_row(dst, 3, Y.hand_row)
  text(dst, clip(status_line(ui.human, "You") .. "  T" .. game.turn), 2, Y.my_status)
  draw_details(dst, help)
end

local KEYS = {
  left = "left", right = "right", up = "up", down = "down",
  space = "select", ["return"] = "confirm", ["kp return"] = "confirm", backspace = "cancel",
}

function duel_menu:on_key_pressed(key, modifiers)
  local input = KEYS[key]
  if input == nil or (input == "confirm" and (modifiers.alt or modifiers.control)) then
    return false  -- let main.lua handle Escape, Alt+Return, F11...
  end
  ui:press(input)
  if ui.finished then
    sol.menu.stop(self)
  end
  return true
end

return duel_menu
