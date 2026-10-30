-- Card face layout on the owner's frames (scripts/duel/card_layout.lua).

local card_layout = require("scripts/duel/card_layout")
local Card = require("scripts/mtg/card")

return function(t)
  local function card(name)
    return Card.new(t.db.get(name), nil, 1, nil)
  end
  local function ops_of(name, mode)
    return card_layout.layout(card(name), mode)
  end
  local function texts(ops)
    local list = {}
    for _, o in ipairs(ops) do
      if o.op == "text" then
        list[#list + 1] = o.text
      end
    end
    return list
  end

  t.section("card layout: pieces")
  t.eq(table.concat(card_layout.cost_symbols("3 W W"), ","), "3,W,W", "mana cost symbols")
  t.eq(table.concat(card_layout.cost_symbols("UR UR"), ","), "U/R,U/R", "hybrid symbols")
  t.eq(#card_layout.cost_symbols("no cost"), 0, "no cost")
  t.eq(card_layout.type_line("Legendary Creature Human Warrior"), "Legendary Creature \226\128\148 Human Warrior", "type line dash")
  t.eq(card_layout.type_line("Instant"), "Instant", "no subtypes, no dash")
  t.eq(card_layout.strip_reminders("Crew 3 (Tap creatures.)"), "Crew 3", "reminder text dropped")
  local x, y = card_layout.symbol_cell("G")
  t.check(x == 50 and y == 20, "G is the last cell of the third row")
  t.eq(card_layout.text_width("Flying"), 30, "text width from the font metrics (PIL: 30)")

  t.section("card layout: frames")
  t.eq(card_layout.frame_color(card("Serra Angel")), "white", "white frame")
  t.eq(card_layout.frame_color(card("Island")), "colorless", "lands use the colorless frame")
  local color, multi = card_layout.frame_color(card("Mortify"))
  t.check(color == "colorless" and multi, "multicolor falls back to colorless (no gold frame yet)")
  local ops = ops_of("Serra Angel", "full")
  t.eq(ops[1].file, "cards/whiteback.png", "full frame")
  t.eq(ops_of("Shock", "snub")[1].file, "cards/redsnub.png", "snub frame")
  local all = table.concat(texts(ops), "|")
  t.check(all:find("Serra Angel", 1, true) and all:find("4/4", 1, true) and all:find("Flying, vigilance", 1, true),
          "name, P/T and rules text")
  t.check(not table.concat(texts(ops_of("Shock", "full")), "|"):find("/", 1, true), "no P/T on an instant")
  t.check(table.concat(texts(ops_of("Cultivator's Caravan", "full")), "|"):find("5/5", 1, true), "Vehicle shows its P/T")

  t.section("card layout: the whole pool")
  local overflow, out_of_bounds, wide = 0, 0, 0
  for i, def in ipairs(t.db.list) do
    for _, mode in ipairs({ "full", "snub" }) do
      local c = Card.new(def, nil, i, nil)
      local list, info = card_layout.layout(c, mode)
      if info.overflow then
        overflow = overflow + 1
      end
      for _, o in ipairs(list) do
        local w = o.w or (o.op == "text" and card_layout.text_width(o.text)) or 0
        if o.x < 0 or o.y < 0 or o.x + w > info.w or o.y + (o.h or 14) > info.h then
          out_of_bounds = out_of_bounds + 1
        end
        if o.op == "text" and o.y > 140 and o.x + card_layout.text_width(o.text) > 150 then
          wide = wide + 1
        end
      end
    end
  end
  t.eq(out_of_bounds, 0, "every operation stays inside the card")
  t.eq(wide, 0, "rules text stays inside the text box")
  t.check(overflow < #t.db.list * 2 / 10, "rules text fits on at least 90% of faces (" .. overflow .. " overflow)")

  t.section("duel ui: zoom")
  local duel_ui = require("scripts/duel/duel_ui")
  local game = t.setup({ { hand = { "Serra Angel" } }, {} })
  local ui = duel_ui.new(game, game.players[1])
  ui.row, ui.col = 3, 1
  t.eq(ui:zoomed_card(), nil, "no zoom by default")
  ui:press("zoom")
  t.eq(ui:zoomed_card() and ui:zoomed_card():name(), "Serra Angel", "zoom shows the focused card")
  ui:press("zoom")
  t.eq(ui:zoomed_card(), nil, "pressed again: closed")
end
