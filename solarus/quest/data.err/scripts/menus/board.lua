-- Placeholder duel screen: two battlefields and a cursor moved with the arrow keys.
-- Proves the quest boots and that the Lua rules modules load inside Solarus.
-- Drawn with plain colored surfaces so it needs no image or font assets yet.

local script_parser = require("scripts/mtg/script_parser")
local pool = require("cards/pool")

local board_menu = {}

local screen_width, screen_height = 320, 240
local cursor_x, cursor_y = 152, 176

local background = sol.surface.create(screen_width, screen_height)
background:fill_color({ 20, 60, 40 })
local opponent_side = sol.surface.create(304, 100)
opponent_side:fill_color({ 30, 80, 55 })
local player_side = sol.surface.create(304, 100)
player_side:fill_color({ 30, 80, 55 })
local cursor = sol.surface.create(16, 16)
cursor:fill_color({ 255, 215, 0 })

function board_menu:on_started()
  -- Parse the first card of the pool to check the data path works inside the engine.
  local file = sol.file.open("cards/" .. pool[1].file)
  local card = script_parser.parse(file:read("*a"))
  file:close()
  print("Loaded " .. #pool .. " pool entries; first card: " .. tostring(card.faces[1].name))
end

function board_menu:on_draw(dst_surface)
  background:draw(dst_surface)
  opponent_side:draw(dst_surface, 8, 8)
  player_side:draw(dst_surface, 8, 132)
  cursor:draw(dst_surface, cursor_x, cursor_y)
end

local moves = { left = { -16, 0 }, right = { 16, 0 }, up = { 0, -16 }, down = { 0, 16 } }

function board_menu:on_key_pressed(key)
  local move = moves[key]
  if move then
    cursor_x = math.max(0, math.min(screen_width - 16, cursor_x + move[1]))
    cursor_y = math.max(0, math.min(screen_height - 16, cursor_y + move[2]))
    return true
  end
  return false
end

return board_menu
