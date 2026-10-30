-- Smoke test of the Solarus side (maps/first_map.lua and scripts/menus/duel.lua) with a stub of
-- the sol.* API: the duelist NPC starts a duel, random key presses play it out, and every frame
-- is drawn. Checks that images exist, card text fits its fonts, and the game is resumed after.
-- This can't show what Solarus really draws; it only catches errors in the drawing code.

local DATA = "solarus/quest/data/"

return function(t)
  local surface = {}
  surface.__index = surface
  local images_loaded, regions = {}, 0
  function surface:fill_color() end
  function surface:draw() end
  function surface:draw_region(sx, sy, w, h, dst, x, y)
    assert(self.width and sx >= 0 and sy >= 0 and sx + w <= self.width and sy + h <= self.height,
           "region outside " .. tostring(self.file))
    regions = regions + 1
  end
  local function png_size(path)
    local f = io.open(path, "rb")
    if f == nil then
      return nil
    end
    local header = f:read(24)
    f:close()
    local function u32(i)
      local a, b, c, d = header:byte(i, i + 3)
      return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return u32(17), u32(21)
  end

  local menus, language = {}, nil
  local previous_sol = sol
  sol = {
    surface = {
      create = function(file)
        local w, h = png_size(DATA .. "sprites/" .. file)
        assert(w, "missing image sprites/" .. file)
        images_loaded[file] = true
        return setmetatable({ file = file, width = w, height = h }, surface)
      end,
    },
    text_surface = {
      create = function(p)
        if p.font == "8_bit" then
          assert(#p.text <= 35, "8_bit line too long: " .. p.text)
        else
          assert(p.font == "enter_command" and p.font_size == 16, "card font")
        end
        return setmetatable({}, surface)
      end,
    },
    file = { open = function(p) return io.open(DATA .. p, "rb") end },
    language = { get_language = function() return language end, set_language = function(l) language = l end },
    menu = {
      start = function(ctx, m)
        menus[#menus + 1] = m
        if m.on_started then
          m:on_started()
        end
      end,
      stop = function(m)
        for i, x in ipairs(menus) do
          if x == m then
            table.remove(menus, i)
          end
        end
        if m.on_finished then
          m:on_finished()
        end
      end,
    },
  }

  local dialogs, values, suspended = {}, {}, false
  local game = {
    set_suspended = function(self, v) suspended = v end,
    get_value = function(self, k) return values[k] end,
    set_value = function(self, k, v) values[k] = v end,
    start_dialog = function(self, id, cb)
      dialogs[#dialogs + 1] = id
      if cb then
        cb(self.next_answer)
      end
    end,
  }
  local npc = {}
  local map = { get_game = function() return game end,
                get_entity = function(self, name) assert(name == "duelist") return npc end }
  assert(loadfile(DATA .. "maps/first_map.lua"))(map)
  map:on_started()

  t.section("duel menu: NPC flow and drawing (sol stub)")
  local ok, err = pcall(function()
    for seed, answer in ipairs({ 2, 1, 1 }) do
      math.randomseed(seed)
      game.next_answer = answer
      dialogs = {}
      npc:on_interaction()
      if answer == 2 then
        t.check(dialogs[2] == "duelist.refused" and #menus == 0, "refusing doesn't start a duel")
      else
        t.check(#menus == 1 and suspended, "duel running with the game suspended")
        local duel = menus[1]
        local keys = { "left", "right", "up", "down", "space", "space", "return", "return", "backspace", "c", "x" }
        local n = 0
        while #menus > 0 and n < 200000 do
          assert(duel:on_key_pressed(keys[math.random(#keys)], {}) == true, "keys swallowed")
          duel:on_draw(setmetatable({}, surface))
          n = n + 1
        end
        t.check(#menus == 0 and not suspended, "duel ended and the game resumed (seed " .. seed .. ")")
        t.check(dialogs[#dialogs] and dialogs[#dialogs]:match("^duelist%.") ~= nil, "closing dialog played")
      end
    end
  end)
  sol = previous_sol
  t.check(ok, "no error in the duel menu: " .. tostring(err))
  t.check(images_loaded["cards/manasymbols.png"] and regions > 0, "zoomed cards were drawn with the card art")
end
