-- Placeholder duel screen, shown between the Solarus logo and the game
-- (see scripts/menus/initial_menus_config.lua).
-- Browses the card pool with left/right to prove the card scripts load and parse inside Solarus.
-- Return/space continues to the game; Escape quits (handled in main.lua).

local script_parser = require("scripts/mtg/script_parser")
local pool = require("cards/pool")

local board_menu = {}

local screen_width, screen_height = sol.video.get_quest_size()
local index = 1

local background = sol.surface.create(screen_width, screen_height)
background:fill_color({ 20, 60, 40 })
local opponent_side = sol.surface.create(screen_width - 16, 72)
opponent_side:fill_color({ 30, 80, 55 })
local player_side = sol.surface.create(screen_width - 16, 72)
player_side:fill_color({ 30, 80, 55 })

local lines = {}
for i = 1, 6 do
  lines[i] = sol.text_surface.create({ font = "8_bit", horizontal_alignment = "left" })
end

local function read_card(file_name)
  local file = sol.file.open("cards/" .. file_name)
  local text = file:read("*a")
  file:close()
  return script_parser.parse(text)
end

local function show_card()
  local entry = pool[index]
  local face = read_card(entry.file).faces[1]
  lines[1]:set_text(string.format("Card %d / %d  (x%d)", index, #pool, entry.copies))
  lines[2]:set_text(face.name or "?")
  lines[3]:set_text("Cost: " .. (face.mana_cost or "-"))
  lines[4]:set_text(face.types or "")
  lines[5]:set_text(face.pt and ("P/T: " .. face.pt) or "")
  lines[6]:set_text("<- -> browse   Return: start game")
end

function board_menu:on_started()
  index = 1
  show_card()
end

function board_menu:on_draw(dst_surface)
  background:draw(dst_surface)
  opponent_side:draw(dst_surface, 8, 8)
  player_side:draw(dst_surface, 8, screen_height - 80)
  for i, line in ipairs(lines) do
    line:draw(dst_surface, 16, 92 + (i - 1) * 12)
  end
end

function board_menu:on_key_pressed(key)
  if key == "right" then
    index = index % #pool + 1
    show_card()
    return true
  elseif key == "left" then
    index = (index - 2) % #pool + 1
    show_card()
    return true
  elseif key == "return" or key == "space" then
    sol.menu.stop(self)
    return true
  end
  return false
end

return board_menu
