-- Keywords the rules engine implements. Add a keyword here only once it really works
-- (combat.lua, game.lua and abilities.lua check them via card:has_keyword).

return {
  SUPPORTED = {
    ["Flying"] = true, ["Reach"] = true, ["Vigilance"] = true, ["Haste"] = true, ["Defender"] = true,
    ["First Strike"] = true, ["Double Strike"] = true, ["Trample"] = true, ["Deathtouch"] = true,
    ["Lifelink"] = true, ["Menace"] = true, ["Flash"] = true, ["Indestructible"] = true,
    ["Hexproof"] = true, ["Changeling"] = true, ["Prowess"] = true,
    -- granted by "HIDDEN" pumps (Forge's internal keywords)
    ["HIDDEN CARDNAME can't block."] = true,
    ["All creatures able to block CARDNAME do so."] = true,
    ["HIDDEN This card doesn't untap during your next untap step."] = true,
  },
}
