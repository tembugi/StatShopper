-- The rules that don't need the game: which stats there are, reading them from tooltip lines,
-- matching and the saved ticks. Tests/run.lua loads this file on its own.
local _, ns = ...

-- The stat filters in the Filter menu, one submenu per group. `key` is the stat's saved name
-- (never change one: it is in players' saved data), `label` the game's string for its menu
-- entry and `line` the game's format for its tooltip line, such as "%c%s Strength".
ns.STAT_GROUPS = {
	{
		name = "STAT_CATEGORY_ATTRIBUTES",
		stats = {
			{ key = "STRENGTH", label = "ITEM_MOD_STRENGTH_SHORT", line = "ITEM_MOD_STRENGTH" },
			{ key = "AGILITY", label = "ITEM_MOD_AGILITY_SHORT", line = "ITEM_MOD_AGILITY" },
			{ key = "STAMINA", label = "ITEM_MOD_STAMINA_SHORT", line = "ITEM_MOD_STAMINA" },
			{ key = "INTELLECT", label = "ITEM_MOD_INTELLECT_SHORT", line = "ITEM_MOD_INTELLECT" },
			{ key = "SPIRIT", label = "ITEM_MOD_SPIRIT_SHORT", line = "ITEM_MOD_SPIRIT" },
		},
	},
}

-- Stat key -> true, for every stat above.
ns.KNOWN_STATS = {}
for _, group in ipairs(ns.STAT_GROUPS) do
	for _, stat in ipairs(group.stats) do
		ns.KNOWN_STATS[stat.key] = true
	end
end

-- Turns one of the game's stat line formats into a pattern for a whole tooltip line that
-- captures the sign and the number. In every language the game writes the sign (%c) and then
-- the number (%s); only where the stat's name goes differs ("%c%s Strength", "힘 %c%s").
function ns.LinePattern(format)
	local pattern = format:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
	pattern = pattern:gsub("%%c", "([+-])"):gsub("%%s", "([%%d.,]+)")
	return "^" .. pattern .. "$"
end

-- The stats an item's tooltip lines raise, as a set of stat keys. A line counts when it is
-- the game's whole line for a stat with a plus sign and a number above zero; a line that
-- lowers a stat ("-5 Spirit") doesn't.
function ns.RaisedStats(lines, patterns)
	local raised = {}
	for _, line in ipairs(lines) do
		local text = line.leftText
		if type(text) == "string" then
			for key, pattern in pairs(patterns) do
				local sign, number = text:match(pattern)
				if sign == "+" and number:find("[1-9]") then
					raised[key] = true
				end
			end
		end
	end
	return raised
end

-- True when the item raises every wanted stat.
function ns.HasAll(raised, wanted)
	for key in pairs(wanted) do
		if not raised[key] then
			return false
		end
	end
	return true
end

-- What tells one result row from another: the item, its item level and its random suffix
-- ("of the Bear"), as in the auction house's own item keys.
function ns.ResultKey(itemKey)
	return itemKey.itemID .. ":" .. itemKey.itemLevel .. ":" .. itemKey.itemSuffix .. ":" .. itemKey.battlePetSpeciesID
end

-- The entries whose items raise every wanted stat, in the order given. Entries whose stats
-- aren't read yet (entry.stats is nil) are left out.
function ns.Matching(entries, wanted)
	local matching = {}
	for _, entry in ipairs(entries) do
		if entry.stats and ns.HasAll(entry.stats, wanted) then
			matching[#matching + 1] = entry
		end
	end
	return matching
end

-- Sorts entries the way the auction house sorts its list: by each of its sorts in turn
-- ({ sortOrder, reverseSort }, most important first), then by arrival (entry.order).
-- valueOf[sortOrder](entry) gives the value a sort compares; a sort without one is skipped.
-- An entry without a value (a name still loading) goes last either way.
function ns.SortEntries(entries, sorts, valueOf)
	table.sort(entries, function(a, b)
		for _, sort in ipairs(sorts) do
			local get = valueOf[sort.sortOrder]
			if get then
				local x, y = get(a), get(b)
				if x ~= y then
					if x == nil then
						return false
					elseif y == nil then
						return true
					elseif sort.reverseSort then
						return x > y
					end
					return x < y
				end
			end
		end
		return a.order < b.order
	end)
end

-- The ticked stats as a set of their own, or nil when none are ticked. A search keeps the
-- stats it was sent with, as the auction house keeps its own filters for a search.
function ns.Ticked(stats)
	local ticked
	for key in pairs(stats) do
		ticked = ticked or {}
		ticked[key] = true
	end
	return ticked
end

-- The saved layout's version. Raise it only when a change stores the ticks differently, and
-- convert the older layout in NormalizeSaved.
local SAVE_FORMAT = 1

-- Runs on every load with the saved FindMyStatsDB (per character) and returns it rebuilt from
-- the fields the addon uses: the save format and the ticked stats, by key. Anything else, left
-- by older versions or damaged, is dropped. A new saved field has to be added here too, or it
-- is dropped on the next load.
function ns.NormalizeSaved(old)
	local clean = {
		format = SAVE_FORMAT,
		stats = {},
	}
	if type(old) == "table" and type(old.stats) == "table" then
		for key, ticked in pairs(old.stats) do
			if ns.KNOWN_STATS[key] and ticked == true then
				clean.stats[key] = true
			end
		end
	end
	return clean
end
