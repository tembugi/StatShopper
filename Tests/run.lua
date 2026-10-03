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

Test("every stat in the menu has a key and the game's name for it", function()
	local seen = {}
	for _, group in ipairs(ns.STAT_GROUPS) do
		Equal(type(group.name), "string", "group name")
		for _, stat in ipairs(group.stats) do
			Equal(seen[stat.key], nil, "key used once: " .. tostring(stat.key))
			seen[stat.key] = true
			Equal(ns.KNOWN_STATS[stat.key], true, "known stat " .. stat.key)
			Equal(type(stat.label) == "string" and stat.label:match("^ITEM_MOD_.+_SHORT$") ~= nil, true, stat.key .. " label")
		end
	end
end)

Test("the game's stat table gives the stats an item raises", function()
	local raised = ns.RaisedByItemStats({
		ITEM_MOD_STRENGTH_SHORT = 8,
		ITEM_MOD_STAMINA_SHORT = 5,
		ITEM_MOD_SPIRIT_SHORT = -3,
		ITEM_MOD_AGILITY_SHORT = 0,
		ITEM_MOD_INTELLECT_SHORT = "7",
		RESISTANCE0_NAME = 120,
	})
	SameSet(raised, SetOf("STRENGTH", "STAMINA"), "raised")
	SameSet(ns.RaisedByItemStats(nil), {}, "no table")
	SameSet(ns.RaisedByItemStats({}), {}, "an item without stats")
end)

Test("an item matches only with every wanted stat", function()
	local raised = SetOf("STRENGTH", "STAMINA")
	Equal(ns.HasAll(raised, SetOf("STRENGTH")), true, "one of them")
	Equal(ns.HasAll(raised, SetOf("STRENGTH", "STAMINA")), true, "both")
	Equal(ns.HasAll(raised, SetOf("STRENGTH", "AGILITY")), false, "one missing")
	Equal(ns.HasAll({}, SetOf("SPIRIT")), false, "no stats")
end)

local function ItemKey(itemID, itemLevel, itemSuffix)
	return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0, battlePetSpeciesID = 0 }
end

Test("results are told apart by item, item level and random suffix", function()
	local plain = ns.ResultKey(ItemKey(100))
	Equal(ns.ResultKey(ItemKey(100)), plain, "the same item key")
	Equal(ns.ResultKey(ItemKey(100, 0, 1001)) ~= plain, true, "another suffix")
	Equal(ns.ResultKey(ItemKey(100, 0, 1001)) ~= ns.ResultKey(ItemKey(100, 0, 1002)), true, "two suffixes")
	Equal(ns.ResultKey(ItemKey(100, 45)) ~= plain, true, "another item level")
	Equal(ns.ResultKey(ItemKey(10, 0)) ~= ns.ResultKey(ItemKey(1, 0)), true, "item 10 against item 1")
end)

Test("matching keeps entries with every wanted stat, in their order", function()
	local entries = {
		{ order = 1, stats = SetOf("STRENGTH", "STAMINA") },
		{ order = 2, stats = SetOf("STRENGTH") },
		{ order = 3, stats = nil }, -- not read yet
		{ order = 4, stats = SetOf("STAMINA", "STRENGTH", "SPIRIT") },
		{ order = 5, stats = {} },
	}
	local matching = ns.Matching(entries, SetOf("STRENGTH", "STAMINA"))
	Equal(#matching, 2, "matches")
	Equal(matching[1], entries[1], "first match")
	Equal(matching[2], entries[4], "second match")
end)

-- The auction house's sort orders (AuctionHouseSortOrder in the game's API documentation).
local PRICE, NAME, LEVEL = 0, 1, 2
local SORT_VALUES = {
	[PRICE] = function(entry) return entry.price end,
	[NAME] = function(entry) return entry.name end,
}

local function Entry(order, price, name)
	return { order = order, price = price, name = name }
end

local function Orders(entries)
	local orders = {}
	for index, entry in ipairs(entries) do
		orders[index] = entry.order
	end
	return table.concat(orders, ",")
end

Test("sorting by price, then name, as the browse list does by default", function()
	local entries = { Entry(1, 500, "Brigade Boots"), Entry(2, 120, "Ridge Cleaver"), Entry(3, 500, "Augural Shroud"), Entry(4, 9000, "Lionheart Helm") }
	ns.SortEntries(entries, { { sortOrder = PRICE, reverseSort = false }, { sortOrder = NAME, reverseSort = false } }, SORT_VALUES)
	Equal(Orders(entries), "2,3,1,4", "cheapest first, same price by name")
end)

Test("a reversed sort puts the highest first", function()
	local entries = { Entry(1, 500, "B"), Entry(2, 120, "A"), Entry(3, 9000, "C") }
	ns.SortEntries(entries, { { sortOrder = PRICE, reverseSort = true }, { sortOrder = NAME, reverseSort = false } }, SORT_VALUES)
	Equal(Orders(entries), "3,1,2", "dearest first")
	ns.SortEntries(entries, { { sortOrder = NAME, reverseSort = true }, { sortOrder = PRICE, reverseSort = false } }, SORT_VALUES)
	Equal(Orders(entries), "3,1,2", "names Z to A")
end)

Test("names still loading go last, and ties keep their arrival order", function()
	local entries = { Entry(4, 100, nil), Entry(1, 100, "Bracers"), Entry(3, 100, nil), Entry(2, 100, "Amulet") }
	ns.SortEntries(entries, { { sortOrder = NAME, reverseSort = false } }, SORT_VALUES)
	Equal(Orders(entries), "2,1,3,4", "named first, then the rest by arrival")
	ns.SortEntries(entries, { { sortOrder = NAME, reverseSort = true } }, SORT_VALUES)
	Equal(Orders(entries), "1,2,3,4", "still last when reversed")
end)

Test("a sort the list can't compare is skipped", function()
	local entries = { Entry(2, 300, "B"), Entry(1, 300, "A"), Entry(3, 100, "C") }
	ns.SortEntries(entries, { { sortOrder = LEVEL, reverseSort = false }, { sortOrder = PRICE, reverseSort = false } }, SORT_VALUES)
	Equal(Orders(entries), "3,1,2", "by price, then arrival")
	ns.SortEntries(entries, {}, SORT_VALUES)
	Equal(Orders(entries), "1,2,3", "no sorts: arrival")
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
