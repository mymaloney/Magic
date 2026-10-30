-- Lays out a card face on the owner's card frames (sprites/cards/, synced from ART/ by
-- tools/sync_art.py) as a list of drawing operations. Pure Lua (no sol.*) so it can be tested
-- headless; scripts/menus/duel.lua executes the operations.
--
--   local ops, info = card_layout.layout(card, "full")   -- 160x224 frame with an art window
--   local ops, info = card_layout.layout(card, "snub")   -- 160x120 frame without art
--
-- Operations, all positions relative to the card's top-left corner:
--   { op = "image", file = "cards/whiteback.png", x, y }
--   { op = "region", file = "cards/manasymbols.png", sx, sy, w, h, x, y }   part of a sheet
--   { op = "text", text = "...", x, y }   in card_layout.FONT, top-left aligned, dark ink
--   { op = "fill", color = { r, g, b }, x, y, w, h }
-- info.overflow is true when the rules text didn't fit (the duel screen's detail panel has it all).

local metrics = require("scripts/duel/font_metrics")

local card_layout = {}

card_layout.FONT = { font = metrics.font, size = metrics.size }
card_layout.INK = { 56, 57, 55 }
card_layout.ART_PLACEHOLDER = { 64, 64, 72 }

local LINE = 9          -- rules text line spacing (glyphs, descenders included, span rows 4-12)
local SYMBOL = 10       -- mana symbols are 10x10 cells in a 6-column sheet
local SYMBOL_STEP = 11

-- Frame geometry, measured from the art: interior of each bar/box.
local FRAMES = {
  full = { w = 160, h = 224, title = 6, type = 129, art = { x = 5, y = 22, w = 150, h = 105 },
           text_top = 146, text_bottom = 210, pt_y = 199 },
  snub = { w = 160, h = 120, title = 6, type = 24,
           text_top = 41, text_bottom = 106, pt_y = 95 },
}
local TEXT_LEFT, TEXT_RIGHT = 11, 148
local BAR_LEFT, BAR_RIGHT = 8, 152
local PT_X, PT_W, PT_H = 114, 40, 20

local COLOR_NAMES = { W = "white", U = "blue", B = "black", R = "red", G = "green" }
-- P/T plates: a 2-column sheet of 40x20 cells, in the order white, blue / black, red / green, colorless.
local PT_CELL = { white = { 0, 0 }, blue = { 1, 0 }, black = { 0, 1 }, red = { 1, 1 }, green = { 0, 2 }, colorless = { 1, 2 } }

-- Symbol name -> cell index in manasymbols.png (row-major, 6 per row).
local SYMBOLS = { C = 12, W = 13, U = 14, B = 15, R = 16, G = 17, T = 18, X = 19 }
for n = 1, 12 do
  SYMBOLS[tostring(n)] = n - 1
end

function card_layout.symbol_cell(name)
  local index = SYMBOLS[name]
  if index == nil then
    return nil
  end
  return (index % 6) * SYMBOL, math.floor(index / 6) * SYMBOL
end

local EM_DASH = "\226\128\148"

-- Text width in pixels (characters outside the font's ASCII table count as a space).
function card_layout.text_width(str)
  local dashes
  str, dashes = str:gsub(EM_DASH, "")
  local w = dashes * metrics.em_dash
  for i = 1, #str do
    w = w + (metrics.widths[str:byte(i)] or metrics.widths[32])
  end
  return w
end

-- The font has no glyphs beyond ASCII except the em dash; replace what it can't draw.
local function clean(str)
  return (str:gsub("\226\128\162", "-"):gsub("\226\136\146", "-"):gsub("\226\128\153", "'"))
end

-- Width of a symbol like "T" or "R/G" (hybrids are drawn as two halves of one cell).
local function symbol_width(name)
  return SYMBOL
end

-- Operations drawing one symbol ("W", "3", "R/G"); nil if there's no art for it.
local function symbol_ops(ops, name, x, y)
  local a, b = name:match("^(%a)/(%a)$")
  if a then
    local ax, ay = card_layout.symbol_cell(a)
    local bx, by = card_layout.symbol_cell(b)
    if not ax or not bx then
      return false
    end
    ops[#ops + 1] = { op = "region", file = "cards/manasymbols.png", sx = ax, sy = ay, w = SYMBOL / 2, h = SYMBOL, x = x, y = y }
    ops[#ops + 1] = { op = "region", file = "cards/manasymbols.png", sx = bx + SYMBOL / 2, sy = by, w = SYMBOL / 2, h = SYMBOL,
                      x = x + SYMBOL / 2, y = y }
    return true
  end
  local sx, sy = card_layout.symbol_cell(name)
  if not sx then
    return false
  end
  ops[#ops + 1] = { op = "region", file = "cards/manasymbols.png", sx = sx, sy = sy, w = SYMBOL, h = SYMBOL, x = x, y = y }
  return true
end

local function is_drawable_symbol(name)
  local a, b = name:match("^(%a)/(%a)$")
  if a then
    return SYMBOLS[a] ~= nil and SYMBOLS[b] ~= nil
  end
  return SYMBOLS[name] ~= nil
end

-- "3 W W" / "UR UR" / "X R" (Forge's ManaCost format) -> { "3", "W", "W" } / { "U/R", "U/R" }.
function card_layout.cost_symbols(mana_cost)
  local list = {}
  if mana_cost == nil or mana_cost == "no cost" then
    return list
  end
  for token in mana_cost:gmatch("%S+") do
    if #token == 2 and token:match("^%a%a$") then
      list[#list + 1] = token:sub(1, 1) .. "/" .. token:sub(2, 2)
    else
      list[#list + 1] = token
    end
  end
  return list
end

-- Splits text into pieces: { kind = "text", text = "Flying." } and { kind = "symbol", name = "T" }.
local function pieces_of(word)
  local list = {}
  local pos = 1
  while pos <= #word do
    local s, e, name = word:find("{([^}]+)}", pos)
    if s == nil then
      list[#list + 1] = { kind = "text", text = word:sub(pos) }
      break
    end
    if s > pos then
      list[#list + 1] = { kind = "text", text = word:sub(pos, s - 1) }
    end
    if is_drawable_symbol(name) then
      list[#list + 1] = { kind = "symbol", name = name }
    else
      list[#list + 1] = { kind = "text", text = "{" .. name .. "}" }
    end
    pos = e + 1
  end
  return list
end

local function pieces_width(pieces)
  local w = 0
  for i, p in ipairs(pieces) do
    if p.kind == "symbol" then
      w = w + symbol_width(p.name) + ((i < #pieces) and 1 or 0)
    else
      w = w + card_layout.text_width(p.text)
    end
  end
  return w
end

-- Word-wraps rules text into lines of pieces. `max_width(line_index)` gives each line's room.
-- Returns lines ({ { pieces = {...} }, ... }) and whether a word had to be cut.
function card_layout.wrap(text, max_width)
  local lines = {}
  local space = card_layout.text_width(" ")
  for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = { pieces = {}, width = 0 }
    for word in paragraph:gmatch("%S+") do
      local pieces = pieces_of(word)
      local w = pieces_width(pieces)
      local room = max_width(#lines + 1)
      local needed = (#line.pieces > 0) and (line.width + space + w) or w
      if #line.pieces > 0 and needed > room then
        lines[#lines + 1] = line
        line = { pieces = {}, width = 0 }
        needed = w
      end
      if #line.pieces > 0 then
        line.pieces[#line.pieces + 1] = { kind = "space" }
      end
      for _, p in ipairs(pieces) do
        line.pieces[#line.pieces + 1] = p
      end
      line.width = needed
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- Which frame color a card uses: its single color, else colorless (no multicolor frame yet).
function card_layout.frame_color(card)
  local found
  for letter, name in pairs(COLOR_NAMES) do
    if card:has_color(letter) then
      if found then
        return "colorless", true
      end
      found = name
    end
  end
  return found or "colorless", false
end

-- Draws a line of pieces at (x, y); text pieces become text ops, symbols region ops.
local function line_ops(ops, line, x, y)
  local buffer = ""
  local function flush()
    if buffer ~= "" then
      ops[#ops + 1] = { op = "text", text = buffer, x = x, y = y }
      x = x + card_layout.text_width(buffer)
      buffer = ""
    end
  end
  for i, p in ipairs(line.pieces) do
    if p.kind == "space" then
      buffer = buffer .. " "
    elseif p.kind == "text" then
      buffer = buffer .. p.text
    else
      flush()
      symbol_ops(ops, p.name, x, y + 3)
      x = x + symbol_width(p.name) + ((line.pieces[i + 1] and line.pieces[i + 1].kind == "symbol") and 1 or 0)
    end
  end
  flush()
end

-- Shortens `str` with a trailing "." so it fits `width` pixels.
local function fit(str, width)
  if card_layout.text_width(str) <= width then
    return str
  end
  while #str > 1 and card_layout.text_width(str .. ".") > width do
    str = str:sub(1, -2)
  end
  return str .. "."
end

-- "Creature Angel" -> "Creature — Angel" (types and supertypes, then subtypes).
local TYPE_WORDS = { Legendary = true, Basic = true, Snow = true, World = true, Kindred = true, Artifact = true,
                     Creature = true, Enchantment = true, Land = true, Instant = true, Sorcery = true,
                     Planeswalker = true, Battle = true }
function card_layout.type_line(types)
  local before, after = {}, {}
  for word in (types or ""):gmatch("%S+") do
    if TYPE_WORDS[word] and #after == 0 then
      before[#before + 1] = word
    else
      after[#after + 1] = word
    end
  end
  if #after == 0 then
    return table.concat(before, " ")
  end
  return table.concat(before, " ") .. " \226\128\148 " .. table.concat(after, " ")
end

-- Drops parenthesized reminder text, e.g. "Crew 3 (Tap any number of ...)" -> "Crew 3".
function card_layout.strip_reminders(text)
  return (text:gsub("%s*%b()", ""))
end

function card_layout.layout(card, mode)
  local frame = FRAMES[mode or "full"]
  local color, multicolor = card_layout.frame_color(card)
  local face = card.def.script.faces[1]
  local ops, info = {}, { color = color, multicolor = multicolor, overflow = false, w = frame.w, h = frame.h }

  ops[#ops + 1] = { op = "image", file = "cards/" .. color .. (mode == "snub" and "snub" or "back") .. ".png", x = 0, y = 0 }
  if frame.art then
    ops[#ops + 1] = { op = "fill", color = card_layout.ART_PLACEHOLDER, x = frame.art.x, y = frame.art.y,
                      w = frame.art.w, h = frame.art.h }
  end

  -- title bar: name, mana cost right-aligned
  local cost = card_layout.cost_symbols(face.mana_cost)
  local cost_x = BAR_RIGHT + 1
  for i = #cost, 1, -1 do
    local name = cost[i]
    if is_drawable_symbol(name) then
      cost_x = cost_x - SYMBOL_STEP
      symbol_ops(ops, name, cost_x + 1, frame.title + 2)
    else
      local w = card_layout.text_width(name)
      cost_x = cost_x - w - 1
      ops[#ops + 1] = { op = "text", text = name, x = cost_x, y = frame.title - 1 }
    end
  end
  ops[#ops + 1] = { op = "text", text = fit(clean(card:name()), cost_x - BAR_LEFT - 2), x = BAR_LEFT, y = frame.title - 1 }

  -- type line
  ops[#ops + 1] = { op = "text", text = fit(clean(card_layout.type_line(face.types)), BAR_RIGHT - BAR_LEFT), x = BAR_LEFT,
                    y = frame.type - 1 }

  -- P/T plate
  local pt_text
  if card:is_creature() then
    pt_text = card:power() .. "/" .. card:toughness()
  elseif face.pt then
    pt_text = face.pt   -- Vehicles: printed P/T while not a creature
  end
  if pt_text then
    local cell = PT_CELL[color]
    ops[#ops + 1] = { op = "region", file = "cards/powertoughness.png", sx = cell[1] * PT_W, sy = cell[2] * PT_H,
                      w = PT_W, h = PT_H, x = PT_X, y = frame.pt_y }
    ops[#ops + 1] = { op = "text", text = pt_text, x = PT_X + math.floor((PT_W - card_layout.text_width(pt_text)) / 2),
                      y = frame.pt_y + 2 }
  end

  -- rules text, kept clear of the P/T plate
  local first_top = frame.text_top - 3   -- capitals start 1px below the box's top edge
  local max_lines = math.floor((frame.text_bottom + 1 - 13 - first_top) / LINE) + 1
  local function line_room(i)
    local top = first_top + (i - 1) * LINE
    if pt_text and top + 13 > frame.pt_y + 1 then
      return PT_X - TEXT_LEFT - 2
    end
    return TEXT_RIGHT - TEXT_LEFT
  end
  local oracle = clean((face.oracle or ""):gsub("\\n", "\n"))
  local lines = card_layout.wrap(oracle, line_room)
  if #lines > max_lines then
    lines = card_layout.wrap(card_layout.strip_reminders(oracle), line_room)
  end
  if #lines > max_lines then
    info.overflow = true
    local last = lines[max_lines]
    last.pieces[#last.pieces + 1] = { kind = "text", text = "..." }
    for i = #lines, max_lines + 1, -1 do
      lines[i] = nil
    end
  end
  for i, line in ipairs(lines) do
    line_ops(ops, line, TEXT_LEFT, first_top + (i - 1) * LINE)
  end
  info.lines = #lines
  return ops, info
end

return card_layout
