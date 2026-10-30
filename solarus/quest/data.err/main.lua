-- Entry point of the quest. For now it opens the placeholder board menu directly;
-- later this becomes the title screen / savegame menu that starts the overworld game.

local board_menu = require("scripts/menus/board")

function sol.main:on_started()
  sol.menu.start(sol.main, board_menu)
end
