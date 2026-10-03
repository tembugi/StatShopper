-- Runs every test of the rules in Stats.lua: `luajit Tests/run.lua` in the addon folder.
-- Exits non-zero when a test fails.

-- This file runs under luajit, outside the game, and uses standard Lua's loadfile and os,
-- which the game doesn't have.
---@diagnostic disable: undefined-global

local ns = {}
assert(loadfile("Stats.lua"))("FindMyStats", ns)

local failures = 0

local function Test(name, func)
	local ok, problem = pcall(func)
	if ok then
		print("ok    " .. name)
	else
		failures = failures + 1
		print("FAIL  " .. name .. ": " .. tostring(problem))
	end
end

local function Equal(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
	end
end

local function SetOf(...)
	local set = {}
	for _, key in ipairs({ ... }) do
		set[key] = true
	end
	return set
end

local function SameSet(actual, expected, what)
	for key in pairs(expected) do
		Equal(actual[key], true, what .. " has " .. key)
	end
	for key in pairs(actual) do
		Equal(expected[key], true, what .. " has no " .. key)
	end
end

-- The game's tooltip line formats for the five attributes, copied from the Forever client's
-- global strings (BlizzardInterfaceResources, branch forever).
local FORMATS = {
	enUS = {
		STRENGTH = "%c%s Strength",
		AGILITY = "%c%s Agility",
		STAMINA = "%c%s Stamina",
		INTELLECT = "%c%s Intellect",
		SPIRIT = "%c%s Spirit",
	},
	deDE = { STRENGTH = "%c%s Stärke" },
	esES = { STRENGTH = "%c%s p. de fuerza" },
	frFR = { STRENGTH = "%c%s Force" },
	koKR = { STRENGTH = "힘 %c%s" },
	ruRU = { STRENGTH = "%c%s к силе" },
	zhCN = { STRENGTH = "%c%s 力量" },
	zhTW = { STRENGTH = "%c%s力量" },
}

local PLUS, MINUS = 43, 45 -- the sign characters the game puts in for %c

-- A tooltip line the way the game fills in its format: the sign, then the number.
local function Line(format, sign, number)
	return { leftText = string.format(format, sign, number) }
end

local function Patterns(formats)
	local patterns = {}
	for key, format in pairs(formats) do
		patterns[key] = ns.LinePattern(format)
	end
	return patterns
end

Test("every stat in the menu has a key, a label and a tooltip format", function()
	local seen = {}
	for _, group in ipairs(ns.STAT_GROUPS) do
		Equal(type(group.name), "string", "group name")
		for _, stat in ipairs(group.stats) do
			Equal(seen[stat.key], nil, "key used once: " .. tostring(stat.key))
			seen[stat.key] = true
			Equal(ns.KNOWN_STATS[stat.key], true, "known stat " .. stat.key)
			Equal(type(stat.label), "string", stat.key .. " label")
			Equal(type(stat.line), "string", stat.key .. " line")
			Equal(FORMATS.enUS[stat.key] ~= nil, true, stat.key .. " has a format in the tests")
		end
	end
end)

Test("a line pattern reads the sign and the number in every language", function()
	for locale, formats in pairs(FORMATS) do
		for key, format in pairs(formats) do
			local pattern = ns.LinePattern(format)
			local sign, number = Line(format, PLUS, "12").leftText:match(pattern)
			Equal(sign, "+", locale .. " " .. key .. " sign")
			Equal(number, "12", locale .. " " .. key .. " number")
			sign, number = Line(format, MINUS, "5").leftText:match(pattern)
			Equal(sign, "-", locale .. " " .. key .. " minus sign")
			Equal(number, "5", locale .. " " .. key .. " minus number")
		end
	end
end)

Test("a line pattern matches only the whole line", function()
	local pattern = ns.LinePattern(FORMATS.enUS.STRENGTH)
	Equal(("12 Strength"):match(pattern), nil, "no sign")
	Equal(("+12 Strength and more"):match(pattern), nil, "text after")
	Equal(("Equip: +12 Strength"):match(pattern), nil, "text before")
	Equal(("+12 Stamina"):match(pattern), nil, "another stat")
	Equal(("+ Strength"):match(pattern), nil, "no number")
end)

Test("characters with a meaning in patterns are taken literally", function()
	local pattern = ns.LinePattern(FORMATS.esES.STRENGTH)
	Equal(("+12 p. de fuerza"):match(pattern), "+", "the dot itself")
	Equal(("+12 px de fuerza"):match(pattern), nil, "any character in place of the dot")
end)

Test("an item raises the stats its lines add", function()
	local formats = FORMATS.enUS
	local lines = {
		{ leftText = "Brigade Boots of the Bear" },
		{ leftText = "Binds when equipped" },
		Line(formats.STRENGTH, PLUS, "8"),
		Line(formats.STAMINA, PLUS, "8"),
		{ leftText = "Durability 50 / 50" },
		{ leftText = "Requires Level 42" },
	}
	SameSet(ns.RaisedStats(lines, Patterns(formats)), SetOf("STRENGTH", "STAMINA"), "raised")
end)

Test("lowered and zero stats don't count", function()
	local formats = FORMATS.enUS
	local lines = {
		Line(formats.SPIRIT, MINUS, "5"),
		Line(formats.AGILITY, PLUS, "0"),
		Line(formats.INTELLECT, PLUS, "10"),
	}
	SameSet(ns.RaisedStats(lines, Patterns(formats)), SetOf("INTELLECT"), "raised")
end)

Test("lines without text are skipped", function()
	local lines = { {}, { leftText = false }, Line(FORMATS.enUS.STRENGTH, PLUS, "3") }
	SameSet(ns.RaisedStats(lines, Patterns(FORMATS.enUS)), SetOf("STRENGTH"), "raised")
end)

Test("an item matches only with every wanted stat", function()
	local raised = SetOf("STRENGTH", "STAMINA")
	Equal(ns.HasAll(raised, SetOf("STRENGTH")), true, "one of them")
	Equal(ns.HasAll(raised, SetOf("STRENGTH", "STAMINA")), true, "both")
	Equal(ns.HasAll(raised, SetOf("STRENGTH", "AGILITY")), false, "one missing")
	Equal(ns.HasAll({}, SetOf("SPIRIT")), false, "no stats")
end)

Test("the filter keeps matches in order and counts what is still loading", function()
	local stats = {
		[1] = SetOf("STRENGTH", "STAMINA"),
		[2] = SetOf("STRENGTH"),
		[3] = nil, -- loading
		[4] = SetOf("STAMINA", "STRENGTH", "SPIRIT"),
		[5] = {},
	}
	local results = {}
	for itemID = 1, 5 do
		results[itemID] = { itemKey = { itemID = itemID } }
	end
	local shown, loading = ns.Filter(results, SetOf("STRENGTH", "STAMINA"), function(itemKey)
		return stats[itemKey.itemID]
	end)
	Equal(#shown, 2, "matches")
	Equal(shown[1], results[1], "first match")
	Equal(shown[2], results[4], "second match")
	Equal(loading, 1, "loading")
end)

Test("a search keeps its own copy of the ticks", function()
	Equal(ns.Ticked({}), nil, "nothing ticked")
	local saved = SetOf("STRENGTH", "SPIRIT")
	local ticked = ns.Ticked(saved)
	SameSet(ticked, SetOf("STRENGTH", "SPIRIT"), "ticked")
	saved.AGILITY = true
	saved.STRENGTH = nil
	SameSet(ticked, SetOf("STRENGTH", "SPIRIT"), "ticked after the saved ticks changed")
end)

Test("saved data starts empty", function()
	for _, old in ipairs({ false, 7, "text", {} }) do
		local clean = ns.NormalizeSaved(old)
		Equal(clean.format, 1, "format")
		Equal(next(clean.stats), nil, "no ticks from " .. tostring(old))
	end
	local clean = ns.NormalizeSaved(nil)
	Equal(next(clean.stats), nil, "no ticks from nothing")
end)

Test("saved ticks are kept", function()
	local clean = ns.NormalizeSaved({ format = 1, stats = { STRENGTH = true, STAMINA = true } })
	Equal(clean.format, 1, "format")
	SameSet(clean.stats, SetOf("STRENGTH", "STAMINA"), "ticks")
end)

Test("broken and leftover saved data is dropped", function()
	local clean = ns.NormalizeSaved({
		format = 99,
		stats = {
			STRENGTH = true,
			AGILITY = "yes",
			SPIRIT = false,
			MASTERY = true,
			[1] = true,
			[true] = true,
		},
		filters = { INTELLECT = true },
		version = "0.0.1",
	})
	Equal(clean.format, 1, "format")
	SameSet(clean.stats, SetOf("STRENGTH"), "ticks")
	Equal(clean.filters, nil, "leftover field")
	Equal(clean.version, nil, "leftover field")
	clean = ns.NormalizeSaved({ stats = "STRENGTH" })
	Equal(next(clean.stats), nil, "stats that aren't a table")
end)

if failures > 0 then
	print(failures .. " failed")
	os.exit(1)
end
print("all passed")
