-- Preconstructed decks built only from cards the engine supports (see cardpool/support_report.md).
-- Used by the duel menu and the tests. Each deck maps card name -> copies (40 cards).

local decks = {}

decks.white = {
  name = "White Weenie",
  cards = {
    ["Plains"] = 17, ["Savannah Lions"] = 4, ["Elite Vanguard"] = 4, ["Healer's Hawk"] = 3,
    ["Bishop's Soldier"] = 4, ["Leonin Skyhunter"] = 3, ["Warclamp Mastiff"] = 2, ["Serra Angel"] = 3,
  },
}

decks.green = {
  name = "Green Stompy",
  cards = {
    ["Forest"] = 17, ["Llanowar Elves"] = 4, ["Thornweald Archer"] = 4, ["Deadly Recluse"] = 3,
    ["Druid of the Cowl"] = 3, ["Ambush Viper"] = 3, ["Tajuru Pathwarden"] = 4, ["Gigantosaurus"] = 2,
  },
}

return decks
