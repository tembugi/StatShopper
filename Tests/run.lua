-- Runs every test of the rules in Stats.lua: `luajit Tests/run.lua` in the addon folder.
-- Exits non-zero when a test fails.

-- This file runs under luajit, outside the game, and uses standard Lua's loadfile and os,
-- which the game doesn't have.
---@diagnostic disable: undefined-global

local ns = {}
assert(loadfile("Stats.lua"))("StatShopper", ns)

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
		local groupKeys = {}
		for index, stat in ipairs(group.stats) do
			if stat.divider then
				Equal(index > 1 and index < #group.stats and not group.stats[index - 1].divider, true, group.name .. " divider between stats")
			else
				Equal(groupKeys[stat.key], nil, "key once in " .. group.name .. ": " .. tostring(stat.key))
				groupKeys[stat.key] = true
				Equal(ns.KNOWN_STATS[stat.key], true, "known stat " .. stat.key)
				local label = stat.label
				Equal(type(label) == "string" and (label:match("^ITEM_MOD_.+_SHORT$") or label:match("^RESISTANCE%d_NAME$")) ~= nil, true, stat.key .. " label")
				Equal(stat.names[1], label, stat.key .. " counts its own name")
				-- A stat in two groups (Hit, Critical Strike, Haste) is the same stat in both.
				local first = seen[stat.key]
				if first then
					Equal(table.concat(stat.names, ","), table.concat(first.names, ","), stat.key .. " the same in every group")
				end
				seen[stat.key] = stat
			end
		end
	end
	Equal(#ns.STATS, 63, "stats")
end)

Test("Hit, Critical Strike and Haste are in Attack and in Spell", function()
	local function Keys(groupName)
		for _, group in ipairs(ns.STAT_GROUPS) do
			if group.name == groupName then
				local keys = {}
				for _, stat in ipairs(group.stats) do
					if stat.key then
						keys[stat.key] = true
					end
				end
				return keys
			end
		end
	end
	for _, key in ipairs({ "HIT", "CRIT", "HASTE" }) do
		Equal(Keys("STAT_CATEGORY_ATTACK")[key], true, key .. " in Attack")
		Equal(Keys("STAT_CATEGORY_SPELL")[key], true, key .. " in Spell")
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

-- What the game's stat table gave in game (2026-10-04) for Watcher's Cap: the item alone, and a
-- real auction's link with "of the Whale" and with "of the Physician".
local CAP = { RESISTANCE0_NAME = 36 }
local CAP_OF_THE_WHALE = { RESISTANCE0_NAME = 36, ITEM_MOD_STAMINA_SHORT = 8, ITEM_MOD_SPIRIT_SHORT = 8 }
local CAP_OF_THE_PHYSICIAN = {
	RESISTANCE0_NAME = 36,
	ITEM_MOD_INTELLECT_SHORT = 5,
	ITEM_MOD_STAMINA_SHORT = 9,
	ITEM_MOD_SPELL_HEALING_DONE_SHORT = 8,
	ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 3,
}

Test("an ending adds what the real auction has beyond the item itself", function()
	SameSet(ns.EndingAdds(CAP_OF_THE_WHALE, CAP), SetOf("ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_SPIRIT_SHORT"), "of the Whale")
	SameSet(ns.EndingAdds(CAP_OF_THE_PHYSICIAN, CAP), SetOf("ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_SPELL_HEALING_DONE_SHORT", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT"), "of the Physician, stats not in the menu kept too")
	SameSet(ns.EndingAdds({ ITEM_MOD_STAMINA_SHORT = 13 }, { ITEM_MOD_STAMINA_SHORT = 5 }), SetOf("ITEM_MOD_STAMINA_SHORT"), "more of a stat the item has")
	SameSet(ns.EndingAdds(CAP, CAP), {}, "an ending that adds nothing")
	SameSet(ns.EndingAdds(CAP_OF_THE_WHALE, nil), SetOf("RESISTANCE0_NAME", "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_SPIRIT_SHORT"), "no table for the item")
	SameSet(ns.EndingAdds(nil, CAP), {}, "no table for the auction")
end)

Test("an item raises its own stats and what its ending adds", function()
	SameSet(ns.RaisedByItemStats(CAP, ns.EndingAdds(CAP_OF_THE_WHALE, CAP)), SetOf("STAMINA", "SPIRIT"), "Watcher's Cap of the Whale")
	SameSet(ns.RaisedByItemStats({ ITEM_MOD_STRENGTH_SHORT = 4 }, SetOf("ITEM_MOD_STAMINA_SHORT")), SetOf("STRENGTH", "STAMINA"), "own stats and the ending's")
	SameSet(ns.RaisedByItemStats(nil, SetOf("ITEM_MOD_INTELLECT_SHORT")), SetOf("INTELLECT"), "no table, ending only")
	SameSet(ns.RaisedByItemStats(CAP, {}), {}, "an ending that adds nothing")
end)

-- Staff of Jordan (873) in game (2026-10-04): the scan found Intellect, Spirit and Spell Power
-- in its stat table; its tooltip says +11 Intellect, +11 Spirit and "Increases damage and
-- healing done by magical spells and effects by up to 60".
local STAFF_OF_JORDAN = { ITEM_MOD_INTELLECT_SHORT = 11, ITEM_MOD_SPIRIT_SHORT = 11, ITEM_MOD_SPELL_POWER_SHORT = 60 }

Test("Spell Power gear counts for Spell Damage and for Spell Healing", function()
	SameSet(ns.RaisedByItemStats(STAFF_OF_JORDAN), SetOf("INTELLECT", "SPIRIT", "SPELL_DAMAGE", "SPELL_HEALING"), "Staff of Jordan")
	SameSet(ns.RaisedByItemStats({ ITEM_MOD_SPELL_HEALING_DONE_SHORT = 20 }), SetOf("SPELL_HEALING"), "healing only")
	SameSet(ns.RaisedByItemStats({ ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 7 }), SetOf("SPELL_DAMAGE"), "damage only")
	SameSet(ns.RaisedByItemStats(CAP, ns.EndingAdds(CAP_OF_THE_PHYSICIAN, CAP)), SetOf("INTELLECT", "STAMINA", "SPELL_DAMAGE", "SPELL_HEALING"), "of the Physician: healing and a little damage")
	local both = SetOf("SPELL_DAMAGE", "SPELL_HEALING")
	Equal(ns.HasAll(ns.RaisedByItemStats(STAFF_OF_JORDAN), both), true, "both ticked: Staff of Jordan")
	Equal(ns.HasAll(ns.RaisedByItemStats({ ITEM_MOD_SPELL_HEALING_DONE_SHORT = 20 }), both), false, "both ticked: healing only")
end)

Test("a resistance counts under either of its names", function()
	-- In game both names come together on the same items (the scan, 2026-10-04).
	SameSet(ns.RaisedByItemStats({ RESISTANCE2_NAME = 10, ITEM_MOD_FIRE_RESISTANCE_SHORT = 10 }), SetOf("FIRE_RESISTANCE"), "both names")
	SameSet(ns.RaisedByItemStats({ ITEM_MOD_SHADOW_RESISTANCE_SHORT = 5 }), SetOf("SHADOW_RESISTANCE"), "the stat's name")
	SameSet(ns.RaisedByItemStats({ RESISTANCE6_NAME = 5 }), SetOf("ARCANE_RESISTANCE"), "the resistance's name")
	SameSet(ns.RaisedByItemStats({ RESISTANCE0_NAME = 300, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 29.9 }), {}, "armor and damage per second aren't in the menu")
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

Test("learned endings start empty, with the build", function()
	for _, old in ipairs({ false, 7, "text", {} }) do
		local clean = ns.NormalizeAccount(old, "70205")
		Equal(clean.format, 1, "format")
		Equal(clean.build, "70205", "build")
		Equal(next(clean.endings), nil, "no endings from " .. tostring(old))
	end
	Equal(next(ns.NormalizeAccount(nil, "70205").endings), nil, "no endings from nothing")
end)

Test("learned endings are kept on the same build", function()
	local clean = ns.NormalizeAccount({ format = 1, build = "70205", endings = {
		[14301] = SetOf("ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_SPIRIT_SHORT"),
		[200] = {},
	} }, "70205")
	SameSet(clean.endings[14301], SetOf("ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_SPIRIT_SHORT"), "of the Whale")
	SameSet(clean.endings[200], {}, "an ending that adds nothing is still known")
end)

Test("learned endings are dropped on another build or format", function()
	local saved = { format = 1, build = "70205", endings = { [14301] = SetOf("ITEM_MOD_STAMINA_SHORT") } }
	Equal(next(ns.NormalizeAccount(saved, "70300").endings), nil, "a game update")
	saved.format = 0
	Equal(next(ns.NormalizeAccount(saved, "70205").endings), nil, "an older format")
end)

Test("broken learned endings are dropped", function()
	local clean = ns.NormalizeAccount({
		format = 1,
		build = "70205",
		endings = {
			[14301] = { ITEM_MOD_STAMINA_SHORT = true, ITEM_MOD_SPIRIT_SHORT = "yes", [5] = true },
			[0] = SetOf("ITEM_MOD_STAMINA_SHORT"),
			[1.5] = SetOf("ITEM_MOD_STAMINA_SHORT"),
			["14301"] = SetOf("ITEM_MOD_STAMINA_SHORT"),
			[99] = "ITEM_MOD_STAMINA_SHORT",
		},
		leftover = true,
	}, "70205")
	SameSet(clean.endings[14301], SetOf("ITEM_MOD_STAMINA_SHORT"), "only names marked true")
	Equal(clean.endings[0], nil, "no ending")
	Equal(clean.endings[1.5], nil, "not a whole number")
	Equal(clean.endings["14301"], nil, "not a number")
	Equal(clean.endings[99], nil, "adds that aren't a table")
	Equal(clean.leftover, nil, "leftover field")
end)

-- The stand-in (Tests/standin.lua): the addon inside a copy of Blizzard's auction house code,
-- with a simulated server. Each scenario runs in its own luajit, as the addon keeps its state in
-- its file. QUEUE_SIZE is how many requests the simulated server lets wait (unknown in game).
local function StandIn(scenario, arguments, queueSize)
	local command = string.format('QUEUE_SIZE=%d luajit Tests/standin.lua "%s" %s', queueSize or 3, scenario, arguments or "")
	local result = os.execute(command)
	if result ~= 0 and result ~= true then
		error("failed: " .. command, 2)
	end
end

for _, scenario in ipairs({ "menu title", "one request at a time", "paging waits while viewing an item", "favorites stay unfiltered", "re-sort", "error puts the list back" }) do
	Test("stand-in: " .. scenario, function()
		StandIn(scenario)
	end)
end

Test("stand-in: a second search at any moment of the first", function()
	for _, queueSize in ipairs({ 1, 3 }) do
		for _, uncachedEvery in ipairs({ 0, 3 }) do
			for step = 1, 30 do
				StandIn("second search", ("%.2f %d"):format(step * 0.1, uncachedEvery), queueSize)
			end
		end
	end
end)

if failures > 0 then
	print(failures .. " failed")
	os.exit(1)
end
print("all passed")
