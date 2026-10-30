-- Parses Forge card script text (forge-gui/res/cardsfolder format) into Lua tables.
--
-- Pure Lua 5.1 (no sol.* calls) so it runs both inside Solarus and under plain LuaJIT tests.
-- Mirrors forge-core CardRules.Reader for the fields the game needs; parameter maps follow
-- forge-core FileSection.parseToMap: split on every "|", key/value split at the first "$", trimmed.
--
-- Result:
--   card = { faces = { face1, face2? }, layout = "DoubleFaced"|nil }
--   face = { name, mana_cost, types, pt, loyalty, colors, oracle, text,
--            abilities = { params... },   -- A: lines (SP$/AB$)
--            triggers = { params... },    -- T: lines
--            statics = { params... },     -- S: lines
--            replacements = { params... },-- R: lines
--            keywords = { "Flying", "Equip:2", ... },
--            svars = { Name = "raw value" },
--            meta = { AI = {...}, DeckHints = {...}, ... } }
-- SVar values stay raw strings: they may be sub-abilities ("DB$ ..."), amounts ("Count$..."),
-- or AI hints. Use parse_params on them when they are abilities.

local script_parser = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "SP$ DealDamage | ValidTgts$ Any | NumDmg$ 3" -> { SP = "DealDamage", ValidTgts = "Any", NumDmg = "3" }
function script_parser.parse_params(line)
  local params = {}
  for part in (line .. "|"):gmatch("([^|]*)|") do
    local dollar = part:find("$", 1, true)
    if dollar then
      params[trim(part:sub(1, dollar - 1))] = trim(part:sub(dollar + 1))
    elseif trim(part) ~= "" then
      params[trim(part)] = ""
    end
  end
  return params
end

local face_fields = {
  Name = "name", ManaCost = "mana_cost", Types = "types", PT = "pt",
  Loyalty = "loyalty", Colors = "colors", Oracle = "oracle", Text = "text",
}

local trait_lists = { A = "abilities", T = "triggers", S = "statics", R = "replacements" }

local function new_face()
  return {
    abilities = {}, triggers = {}, statics = {}, replacements = {},
    keywords = {}, svars = {}, meta = {},
  }
end

function script_parser.parse(text)
  local card = { faces = {} }
  local face = new_face()
  card.faces[1] = face

  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = trim(raw)
    if line == "ALTERNATE" then
      face = new_face()
      card.faces[#card.faces + 1] = face
    elseif line ~= "" then
      local colon = line:find(":", 1, true)
      if colon then
        local key, value = line:sub(1, colon - 1), line:sub(colon + 1)
        if face_fields[key] then
          face[face_fields[key]] = value
        elseif trait_lists[key] then
          local list = face[trait_lists[key]]
          list[#list + 1] = script_parser.parse_params(value)
        elseif key == "K" then
          face.keywords[#face.keywords + 1] = value
        elseif key == "SVar" then
          local sep = value:find(":", 1, true)
          if sep then
            face.svars[value:sub(1, sep - 1)] = value:sub(sep + 1)
          else
            face.svars[value] = ""
          end
        elseif key == "AlternateMode" then
          card.layout = value
        else
          face.meta[key] = face.meta[key] or {}
          table.insert(face.meta[key], value)
        end
      end
    end
  end

  return card
end

return script_parser
