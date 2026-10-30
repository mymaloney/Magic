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

local filter = require("scripts/mtg/filter")

local function check_params(params, allowed, reasons)
  for key in pairs(params) do
    if not allowed[key] then
      reasons[#reasons + 1] = "replacement parameter " .. key
    end
  end
end

-- "If a source you control would deal damage to ..., it deals double that damage instead."
local function parse_damage_doubler(def, params, svars, reasons)
  check_params(params, { Event = true, ActiveZones = true, ValidSource = true, ValidTarget = true,
                         ReplaceWith = true, Description = true }, reasons)
  local with = svars[params.ReplaceWith or ""] or ""
  local var = with:match("VarValue%$%s*(%w+)")
  if not with:match("^DB%$%s*ReplaceEffect") or not (svars[var or ""] or ""):match("/Twice$") then
    reasons[#reasons + 1] = "DamageDone replacement " .. tostring(params.ReplaceWith)
    return
  end
  local source, p1 = filter.parse((params.ValidSource or "Card"):gsub(",Emblem%.YouCtrl", ""))
  local target, p2 = filter.parse(params.ValidTarget or "Any")
  if source == nil or target == nil then
    reasons[#reasons + 1] = tostring(p1 or p2)
    return
  end
  def.damage_doublers = def.damage_doublers or {}
  table.insert(def.damage_doublers, { source = source, target = target })
end

-- Parses an R: line. Supported replacements are recorded on the definition.
function replacements.parse(def, params, svars, reasons, effects)
  if params.Event == "DamageDone" then
    return parse_damage_doubler(def, params, svars, reasons)
  elseif params.Event == "Untap" and params.Layer == "CantHappen" then
    -- "Enchanted creature doesn't untap during its controller's untap step."
    check_params(params, { Event = true, ActiveZones = true, ValidCard = true, ValidStepTurnToController = true,
                           Layer = true, Description = true }, reasons)
    local parsed, problem = filter.parse(params.ValidCard or "")
    if parsed == nil then
      reasons[#reasons + 1] = problem
    end
    def.untap_lock = parsed
    return
  elseif (params.Event == "GameLoss" and params.ValidPlayer == "You")
      or (params.Event == "GameWin" and params.ValidPlayer == "Opponent") then
    -- "You can't lose the game and your opponents can't win the game."
    check_params(params, { Event = true, ActiveZones = true, ValidPlayer = true, Layer = true,
                           Secondary = true, Description = true }, reasons)
    def.cant_lose = true
    return
  end
  if params.Event ~= "Moved" then
    reasons[#reasons + 1] = "replacement " .. tostring(params.Event)
    return
  end
  if params.Discard == "True" then
    -- "If a spell or ability an opponent controls causes you to discard this, put it onto the
    -- battlefield instead" (Wilt-Leaf Liege); handled by Game:discard.
    check_params(params, { Event = true, ActiveZones = true, ValidCard = true, ValidCause = true, Discard = true,
                           EffectOnly = true, ReplaceWith = true, Description = true }, reasons)
    local text = params.ReplaceWith and svars[params.ReplaceWith] or ""
    if params.ValidCard ~= "Card.Self" or params.ValidCause ~= "SpellAbility.OppCtrl"
        or not text:find("Destination$ Battlefield", 1, true) then
      reasons[#reasons + 1] = "replacement Moved on discard"
    end
    def.opponent_discard_to_battlefield = true
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

local function battlefield(game)
  local list = {}
  for _, player in ipairs(game.players) do
    for _, card in ipairs(player.battlefield) do
      list[#list + 1] = card
    end
  end
  return list
end

-- Damage amount after doubling replacements (each applies once, CR 616).
function replacements.damage_amount(game, hit)
  local amount = hit.amount
  for _, source in ipairs(battlefield(game)) do
    for _, d in ipairs(source.def.damage_doublers or {}) do
      local ctx = { game = game, you = source.controller, self = source }
      if filter.matches(d.source, hit.source, ctx) and filter.matches(d.target, hit.target, ctx) then
        amount = amount * 2
      end
    end
  end
  return amount
end

function replacements.untap_locked(game, card)
  for _, source in ipairs(battlefield(game)) do
    if source.def.untap_lock
        and filter.matches(source.def.untap_lock, card, { game = game, you = source.controller, self = source }) then
      return true
    end
  end
  return false
end

function replacements.cant_lose(game, player)
  for _, card in ipairs(player.battlefield) do
    if card.def.cant_lose then
      return true
    end
  end
  return false
end

return replacements
