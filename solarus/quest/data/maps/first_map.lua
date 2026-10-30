-- Lua script of map first_map.
-- This script is executed every time the hero enters this map.
-- See the Solarus Lua API documentation: http://www.solarus-games.org/doc/latest

local map = ...
local game = map:get_game()

local duel = require("scripts/menus/duel")
local decks = require("scripts/duel/decks")
local language_manager = require("scripts/language_manager")

-- Event called at initialization time, as soon as this map is loaded.
function map:on_started()

  -- The duelist NPC: talk to her to play Magic against the Green AI deck.
  -- Wins are counted in the savegame value "duelist_wins".
  local duelist = map:get_entity("duelist")
  function duelist:on_interaction()
    if sol.language.get_language() == nil then
      sol.language.set_language(language_manager:get_default_language())
    end
    game:start_dialog("duelist.challenge", function(answer)
      if answer ~= 1 then
        game:start_dialog("duelist.refused")
        return
      end
      duel.start(game, {
        player_deck = decks.rakdos,
        opponent_deck = decks.green,
        opponent_name = "Duelist",
        on_finished = function(result)
          if result == "won" then
            game:set_value("duelist_wins", (game:get_value("duelist_wins") or 0) + 1)
            game:start_dialog("duelist.player_won")
          elseif result == "lost" then
            game:start_dialog("duelist.player_lost")
          else
            game:start_dialog("duelist.draw")
          end
        end,
      })
    end)
  end
end

-- Event called after the opening transition effect of the map,
-- that is, when the player takes control of the hero.
function map:on_opening_transition_finished()

end
