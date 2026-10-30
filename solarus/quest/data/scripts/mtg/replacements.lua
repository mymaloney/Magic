-- Replacement effects. So far: how a permanent enters the battlefield (CR 614.1c-d):
--   R:Event$ Moved | ValidCard$ Card.Self | Destination$ Battlefield | ReplaceWith$ ETBTapped
--   SVar:ETBTapped:DB$ Tap | Defined$ Self | ETB$ True [| ConditionCheckSVar$ ...]
--   K:ETBReplacement:Other:ChooseColor   (SVar:ChooseColor:DB$ ChooseColor ...)
-- These modify the event itself, so they're applied as the card enters (game:move), before any
-- enters-the-battlefield triggers look at it. The ReplaceWith abilities resolve with ctx.etb = true;
-- effects that support it (Tap with ETB$ True) change the entering card instead of acting later.
-- Reference: forge-game replacement/ReplaceMoved, ReplacementHandler; CardFactoryUtil (ETBReplacement).

local abilities = require("scripts/mtg/abilities")
local script_parser = require("scripts/mtg/script_parser")

local replacements = {}

local MOVED_PARAMS = {
  Event = true, ValidCard = true, Destination = true, ReplaceWith = true, ReplacementResult = true,
  Description = true,
}

-- Parses an R: line. Supported replacements are added to def.etb_replacements.
function replacements.parse(def, params, svars, reasons, effects)
  if params.Event ~= "Moved" then
    reasons[#reasons + 1] = "replacement " .. tostring(params.Event)
    return
  end
  for key in pairs(params) do
    if not MOVED_PARAMS[key] then
      reasons[#reasons + 1] = "replacement parameter " .. key
    end
  end
  if params.ValidCard ~= "Card.Self" or params.Destination ~= "Battlefield" then
    reasons[#reasons + 1] = "replacement Moved " .. tostring(params.ValidCard) .. " -> " .. tostring(params.Destination)
    return
  end
  local text = params.ReplaceWith and svars[params.ReplaceWith]
  if text == nil then
    reasons[#reasons + 1] = "replacement without ReplaceWith"
    return
  end
  local ability = abilities.build(script_parser.parse_params(text), svars, reasons, effects)
  if ability.api ~= "Tap" or ability.params.ETB ~= "True" or ability.sub ~= nil then
    reasons[#reasons + 1] = "enters-the-battlefield replacement " .. tostring(ability.api)
  end
  table.insert(def.etb_replacements, ability)
end

-- K:ETBReplacement:Other:<SVar> — "As this enters, ..." (e.g. choose a color).
function replacements.parse_keyword(def, keyword, svars, reasons, effects)
  local kind, svar = keyword:match("^ETBReplacement:(%a+):(%w+)$")
  if kind ~= "Other" or svars[svar or ""] == nil then
    reasons[#reasons + 1] = "keyword " .. keyword
    return
  end
  table.insert(def.etb_replacements, abilities.build(script_parser.parse_params(svars[svar]), svars, reasons, effects))
end

-- Applies the entering card's own replacements. Called by game:move once the card is on the
-- battlefield but before anything else sees it enter.
function replacements.apply_etb(game, card, effects)
  for _, ability in ipairs(card.def.etb_replacements or {}) do
    local ctx = { game = game, source = card, controller = card.controller, targets = {}, etb = true }
    abilities.resolve(game, ability, ctx, effects)
  end
end

return replacements
