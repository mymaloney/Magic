-- Triggered abilities. Only Mode$ ChangesZone (enters / dies / leaves the battlefield) so far.
-- Reference: forge-game trigger/TriggerHandler (runTrigger, look-back for leaves-the-battlefield),
-- trigger/TriggerChangesZone (performTest), zone/MagicStack.addAllTriggeredAbilitiesToStack,
-- trigger/WrappedAbility (optional "may" triggers are asked on resolution).
--
-- Flow: game:move() calls triggers.collect() for every zone change; matching triggers wait in
-- game.pending_triggers and go on the stack the next time a player would get priority
-- (game:put_triggers_on_stack, APNAP order). Targets are chosen then.

local abilities = require("scripts/mtg/abilities")
local filter = require("scripts/mtg/filter")
local script_parser = require("scripts/mtg/script_parser")

local triggers = {}

local ALLOWED = {
  Mode = true, Origin = true, Destination = true, ValidCard = true, TriggerZones = true,
  Execute = true, TriggerDescription = true, OptionalDecider = true, Secondary = true,
}

-- Parses a T: line. Returns a trigger table; problems are appended to `reasons`.
function triggers.parse(params, svars, reasons, effects)
  if params.Mode ~= "ChangesZone" then
    reasons[#reasons + 1] = "trigger " .. tostring(params.Mode)
    return nil
  end
  for key in pairs(params) do
    if not ALLOWED[key] then
      reasons[#reasons + 1] = "trigger parameter " .. key
    end
  end
  local trigger = { mode = params.Mode, params = params }
  for _, key in ipairs({ "Origin", "Destination" }) do
    local value = params[key]
    if value ~= nil and value ~= "Any" and abilities.ZONES[value] == nil then
      reasons[#reasons + 1] = "trigger " .. key .. "$ " .. value
    end
    trigger[key:lower()] = (value and value ~= "Any") and abilities.ZONES[value] or nil
  end
  if params.TriggerZones ~= nil and params.TriggerZones ~= "Battlefield" then
    reasons[#reasons + 1] = "TriggerZones$ " .. params.TriggerZones
  end
  if params.OptionalDecider ~= nil and params.OptionalDecider ~= "You" then
    reasons[#reasons + 1] = "OptionalDecider$ " .. params.OptionalDecider
  end
  trigger.optional = params.OptionalDecider == "You"
  local parsed, problem = filter.parse(params.ValidCard or "")
  if params.ValidCard == nil then
    reasons[#reasons + 1] = "trigger without ValidCard"
  elseif parsed == nil then
    reasons[#reasons + 1] = problem
  end
  trigger.valid_card = parsed
  local execute = params.Execute and svars[params.Execute]
  if execute == nil then
    reasons[#reasons + 1] = "trigger without Execute"
  else
    trigger.ability = abilities.build(script_parser.parse_params(execute), svars, reasons, effects)
  end
  return trigger
end

-- Called after `card` moved from `from` to `to`.
-- lki_controller: who controlled it before it moved; lookback: { { card =, controller = } } of the
-- battlefield as it was just before (CR 603.10: leaves-the-battlefield triggers "look back").
function triggers.collect(game, card, from, to, lki_controller, lookback)
  local sources = {}
  if from == "battlefield" and to ~= "battlefield" then
    sources = lookback
  else
    for _, player in ipairs(game.players) do
      for _, c in ipairs(player.battlefield) do
        sources[#sources + 1] = { card = c, controller = c.controller }
      end
    end
  end
  local moved_controller = (from == "battlefield") and lki_controller or card.controller
  for _, source in ipairs(sources) do
    for _, trigger in ipairs(source.card.def.triggers or {}) do
      if (trigger.origin == nil or trigger.origin == from)
          and (trigger.destination == nil or trigger.destination == to)
          and filter.matches(trigger.valid_card, card, {
            game = game, you = source.controller, self = source.card,
            controller = function(c) return c == card and moved_controller or c.controller end,
          }) then
        table.insert(game.pending_triggers, {
          source = source.card,
          controller = source.controller,
          trigger = trigger,
          event = { card = card, controller = moved_controller },
        })
      end
    end
  end
end

return triggers
