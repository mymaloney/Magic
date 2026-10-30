-- The duel screen model (scripts/duel/duel_ui.lua), driven by the same inputs the Solarus menu sends.

local Game = require("scripts/mtg/game")
local ai = require("scripts/mtg/controllers/ai")
local prompt = require("scripts/mtg/controllers/prompt")
local duel_ui = require("scripts/duel/duel_ui")
local decks = require("scripts/duel/decks")

local function focus(ui, row, name)
  ui.row = row
  for i, card in ipairs(ui:row_cards(row)) do
    if card:name() == name then
      ui.col = i
      return card
    end
  end
  error("no " .. name .. " in row " .. row)
end

local function has_log(ui, text)
  for _, line in ipairs(ui.log) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

return function(t)
  t.section("duel ui: play a land and cast a creature")
  do
    local game = t.setup({ { controller = prompt.new(), battlefield = { "Plains" }, hand = { "Plains", "Savannah Lions" } },
                           { controller = ai.new() } })
    local ui = duel_ui.new(game, game.players[1])
    ui:start()
    t.eq(ui.request.kind, "choose_action", "first stop is a real choice (upkeep/draw auto-passed)")
    t.eq(game.step, "main1", "in the main phase")
    t.eq(ui.row, 3, "cursor on the hand")
    t.check(ui:card_marks(focus(ui, 3, "Savannah Lions")).playable, "castable card is marked playable")
    focus(ui, 3, "Plains")
    ui:press("select")
    t.eq(#game.players[1].battlefield, 2, "land played")
    focus(ui, 3, "Savannah Lions")
    ui:press("select")
    t.check(t.find(game.players[1].battlefield, "Savannah Lions") ~= nil, "creature resolved")
    t.check(has_log(ui, "You cast Savannah Lions"), "log shows the cast")
  end

  t.section("duel ui: attack")
  do
    local game = t.setup({ { controller = prompt.new(), battlefield = { "Savannah Lions", "Elite Vanguard" } },
                           { controller = ai.new() } })
    local ui = duel_ui.new(game, game.players[1])
    ui:start()
    t.eq(ui.request.kind, "choose_action", "main phase stops first: the drawn Plains is playable")
    ui:press("confirm")
    t.eq(ui.request.kind, "declare_attackers", "passing moves on to attacks")
    t.eq(ui.row, 2, "cursor on own creatures")
    focus(ui, 2, "Savannah Lions")
    ui:press("select")
    t.check(ui:card_marks(ui:focused_card()).selected, "attacker marked")
    ui:press("confirm")
    t.eq(game.players[2].life, 18, "only the selected creature attacked")
  end

  t.section("duel ui: block")
  do
    local game = t.setup({ { controller = prompt.new(), battlefield = { "Elite Vanguard" } },
                           { controller = ai.new(), battlefield = { "Savannah Lions", "Air Elemental" } } })
    game.active = game.players[2]
    local ui = duel_ui.new(game, game.players[1])
    ui:start()
    t.eq(ui.request.kind, "declare_blockers", "asked to block")
    focus(ui, 2, "Elite Vanguard")
    ui:press("select")
    t.eq(ui.row, 1, "cursor jumps to the attackers")
    focus(ui, 1, "Air Elemental")
    ui:press("select")
    t.check(ui.error_message ~= nil, "can't block a flyer: error shown")
    t.check(ui.pending_blocker ~= nil, "still choosing")
    focus(ui, 1, "Savannah Lions")
    ui:press("select")
    t.check(ui.blocks[t.find(game.players[1].battlefield, "Elite Vanguard")] ~= nil, "block recorded")
    ui:press("confirm")
    t.eq(t.find(game.players[2].battlefield, "Savannah Lions"), nil, "blocked attacker died")
    t.eq(game.players[1].life, 16, "Air Elemental's 4 got through")
  end

  t.section("duel ui: details and wrapping")
  do
    local lines = duel_ui.card_details({ def = t.db.get("Serra Angel") })
    t.eq(lines[1], "Serra Angel", "name line")
    t.eq(lines[2], "{3}{W}{W}  Creature Angel", "cost and type line")
    t.eq(lines[3], "4/4  Flying, Vigilance", "P/T and keywords")
    local wrapped = duel_ui.wrap("Whenever another creature enters, you gain 1 life.", 20)
    t.eq(#wrapped, 3, "wrapped into 3 lines")
    for _, line in ipairs(wrapped) do
      t.check(#line <= 20, "line fits: " .. line)
    end
  end

  t.section("duel ui: cast a targeted spell and answer a may-trigger")
  do
    local game = t.setup({ { controller = prompt.new(), battlefield = { "Mountain" }, hand = { "Shock" } },
                           { controller = ai.new(), battlefield = { "Savannah Lions" } } })
    local ui = duel_ui.new(game, game.players[1])
    ui:start()
    focus(ui, 3, "Shock")
    ui:press("select")
    t.eq(ui.request.kind, "choose_targets", "casting asks for a target")
    t.eq(#ui:row_cards(3), 3, "candidates: both players and the creature")
    local title = ui:prompt_text()
    t.eq(title, "Target for Shock", "prompt names the spell")
    ui.col = 1
    while ui:focused_card() ~= game.players[2] do
      ui:press("right")
    end
    ui:press("select")
    t.eq(game.players[2].life, 18, "Shock hit the opponent")
    t.check(has_log(ui, "You cast Shock -> Opp") or has_log(ui, "You cast Shock -> P2"), "log names the target")

    local optional = t.setup({ { controller = prompt.new(), battlefield = { "Swamp", "Swamp", "Swamp", "Swamp" },
                                 hand = { "Gravedigger" }, graveyard = { "Savannah Lions" } },
                               { controller = ai.new() } })
    local ui2 = duel_ui.new(optional, optional.players[1])
    ui2:start()
    focus(ui2, 3, "Gravedigger")
    ui2:press("select")
    t.eq(ui2.request.kind, "choose_targets", "trigger target chosen when it goes on the stack")
    ui2:press("select")
    t.eq(ui2.request.kind, "confirm_optional", "may-trigger asks on resolution")
    ui2:press("cancel")
    t.check(t.find(optional.players[1].graveyard, "Savannah Lions") ~= nil, "saying no leaves the card in the graveyard")
  end

  t.section("duel ui: random inputs through whole games")
  for seed = 1, 6 do
    local state = seed
    local function rng(n)
      state = (state * 16807) % 2147483647
      return state % n + 1
    end
    local game = Game.new({
      players = {
        { name = "You", deck = t.db.make_deck(decks.rakdos.cards), controller = prompt.new() },
        { name = "AI", deck = t.db.make_deck((seed % 2 == 0 and decks.white or decks.green).cards), controller = ai.new() },
      },
      rng = rng, max_turns = 400,
    })
    local ui = duel_ui.new(game, game.players[1])
    ui:start()
    local inputs = { "left", "right", "up", "down", "select", "select", "select", "confirm", "confirm", "cancel" }
    local presses = 0
    local long_prompt
    while not ui.finished and presses < 50000 do
      ui:press(inputs[rng(#inputs)])
      presses = presses + 1
      local title, help = ui:prompt_text()
      if (#title > 35 and ui.error_message == nil) or #help > 35 then
        long_prompt = title .. " / " .. help
      end
    end
    t.eq(long_prompt, nil, "seed " .. seed .. ": prompts fit a 35-character line")
    t.check(ui.finished, "seed " .. seed .. ": game reached the end screen and was dismissed (" .. presses .. " inputs)")
    t.check(game.over or game.turn >= 400, "seed " .. seed .. ": game over")
  end
end
