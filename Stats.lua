-- The rules that don't need the game: which stats there are, reading them from the game's stat
-- table, matching, sorting and the saved ticks. Tests/run.lua loads this file on its own.
local _, ns = ...

-- One stat in the menu. `key` is its saved name (never change one: it is in players' saved data).
-- `label` is the game's global string for it: the menu entry, and a name its amount has in the
-- game's stat table (C_Item.GetItemStats). Any further names also count: an item raises the stat
-- when it has a positive amount under any of them.
local function Stat(key, label, ...)
	return { key = key, label = label, names = { label, ... } }
end

-- A line between sections of a submenu.
local DIVIDER = { divider = true }

-- The stat filters in the Filter menu, one submenu per group, named by the game's global string.
-- Which stats are here (agreed with the user, 2026-10-04): every one seen on real Forever gear
-- (the auction house, and a scan of every item the game had loaded), every one on Forever's
-- character sheet, all 12 professions, and every enemy type for the "Vs" stats, which Forever
-- added to the game's text itself. Armor and damage per second, on almost every item, are left
-- out. A stat found later is one more line. Hit, Critical Strike and Haste count for melee and
-- spells alike in Forever, so they are in Attack and in Spell: one key, ticked in both. Spell
-- Power gear ("Increases damage and healing done by magical spells and effects", Staff of
-- Jordan) counts for Spell Damage and for Spell Healing, with no entry of its own. A resistance
-- has two names in the stat table, and only RESISTANCEn_NAME has a game string.
ns.STAT_GROUPS = {
	{
		name = "STAT_CATEGORY_ATTRIBUTES",
		stats = {
			Stat("STRENGTH", "ITEM_MOD_STRENGTH_SHORT"),
			Stat("AGILITY", "ITEM_MOD_AGILITY_SHORT"),
			Stat("STAMINA", "ITEM_MOD_STAMINA_SHORT"),
			Stat("INTELLECT", "ITEM_MOD_INTELLECT_SHORT"),
			Stat("SPIRIT", "ITEM_MOD_SPIRIT_SHORT"),
		},
	},
	{
		name = "STAT_CATEGORY_ATTACK",
		stats = {
			Stat("ATTACK_POWER", "ITEM_MOD_ATTACK_POWER_SHORT"),
			Stat("MELEE_ATTACK_POWER", "ITEM_MOD_MELEE_ATTACK_POWER_SHORT"),
			Stat("RANGED_ATTACK_POWER", "ITEM_MOD_RANGED_ATTACK_POWER_SHORT"),
			Stat("HIT", "ITEM_MOD_HIT_RATING_SHORT"),
			Stat("CRIT", "ITEM_MOD_CRIT_RATING_SHORT"),
			Stat("HASTE", "ITEM_MOD_HASTE_RATING_SHORT"),
			Stat("EXPERTISE", "ITEM_MOD_EXPERTISE_RATING_SHORT"),
			Stat("ARMOR_PIERCING", "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT"),
			Stat("PHYSICAL_DAMAGE", "ITEM_MOD_PHYSICAL_DAMAGE_DONE_SHORT"),
			DIVIDER,
			Stat("ATTACK_POWER_VS_BEAST", "ITEM_MOD_ATTACK_POWER_VS_BEAST_SHORT"),
			Stat("ATTACK_POWER_VS_DEMON", "ITEM_MOD_ATTACK_POWER_VS_DEMON_SHORT"),
			Stat("ATTACK_POWER_VS_DRAGONKIN", "ITEM_MOD_ATTACK_POWER_VS_DRAGONKIN_SHORT"),
			Stat("ATTACK_POWER_VS_ELEMENTAL", "ITEM_MOD_ATTACK_POWER_VS_ELEMENTAL_SHORT"),
			Stat("ATTACK_POWER_VS_GIANT", "ITEM_MOD_ATTACK_POWER_VS_GIANT_SHORT"),
			Stat("ATTACK_POWER_VS_HUMANOID", "ITEM_MOD_ATTACK_POWER_VS_HUMANOID_SHORT"),
			Stat("ATTACK_POWER_VS_MECHANICAL", "ITEM_MOD_ATTACK_POWER_VS_MECHANICAL_SHORT"),
			Stat("ATTACK_POWER_VS_UNDEAD", "ITEM_MOD_ATTACK_POWER_VS_UNDEAD_SHORT"),
		},
	},
	{
		name = "STAT_CATEGORY_SPELL",
		stats = {
			Stat("SPELL_DAMAGE", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT", "ITEM_MOD_SPELL_POWER_SHORT"),
			Stat("SPELL_HEALING", "ITEM_MOD_SPELL_HEALING_DONE_SHORT", "ITEM_MOD_SPELL_POWER_SHORT"),
			Stat("HIT", "ITEM_MOD_HIT_RATING_SHORT"),
			Stat("CRIT", "ITEM_MOD_CRIT_RATING_SHORT"),
			Stat("HASTE", "ITEM_MOD_HASTE_RATING_SHORT"),
			Stat("SPELL_PIERCING", "ITEM_MOD_SPELL_PENETRATION_SHORT"),
			Stat("MANA_REGENERATION", "ITEM_MOD_MANA_REGENERATION_SHORT"),
			DIVIDER,
			Stat("ARCANE_DAMAGE", "ITEM_MOD_ARCANE_DAMAGE_DONE_SHORT"),
			Stat("FIRE_DAMAGE", "ITEM_MOD_FIRE_DAMAGE_DONE_SHORT"),
			Stat("FROST_DAMAGE", "ITEM_MOD_FROST_DAMAGE_DONE_SHORT"),
			Stat("HOLY_DAMAGE", "ITEM_MOD_HOLY_DAMAGE_DONE_SHORT"),
			Stat("NATURE_DAMAGE", "ITEM_MOD_NATURE_DAMAGE_DONE_SHORT"),
			Stat("SHADOW_DAMAGE", "ITEM_MOD_SHADOW_DAMAGE_DONE_SHORT"),
			DIVIDER,
			Stat("SPELL_DAMAGE_VS_BEAST", "ITEM_MOD_SPELL_DAMAGE_VS_BEAST_SHORT"),
			Stat("SPELL_DAMAGE_VS_DEMON", "ITEM_MOD_SPELL_DAMAGE_VS_DEMON_SHORT"),
			Stat("SPELL_DAMAGE_VS_DRAGONKIN", "ITEM_MOD_SPELL_DAMAGE_VS_DRAGONKIN_SHORT"),
			Stat("SPELL_DAMAGE_VS_ELEMENTAL", "ITEM_MOD_SPELL_DAMAGE_VS_ELEMENTAL_SHORT"),
			Stat("SPELL_DAMAGE_VS_GIANT", "ITEM_MOD_SPELL_DAMAGE_VS_GIANT_SHORT"),
			Stat("SPELL_DAMAGE_VS_HUMANOID", "ITEM_MOD_SPELL_DAMAGE_VS_HUMANOID_SHORT"),
			Stat("SPELL_DAMAGE_VS_MECHANICAL", "ITEM_MOD_SPELL_DAMAGE_VS_MECHANICAL_SHORT"),
			Stat("SPELL_DAMAGE_VS_UNDEAD", "ITEM_MOD_SPELL_DAMAGE_VS_UNDEAD_SHORT"),
		},
	},
	{
		name = "STAT_CATEGORY_DEFENSE",
		stats = {
			Stat("DEFENSE", "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT"),
			Stat("DODGE", "ITEM_MOD_DODGE_RATING_SHORT"),
			Stat("PARRY", "ITEM_MOD_PARRY_RATING_SHORT"),
			Stat("BLOCK", "ITEM_MOD_BLOCK_RATING_SHORT"),
			Stat("BLOCK_VALUE", "ITEM_MOD_BLOCK_VALUE_SHORT"),
			Stat("HEALTH_REGENERATION", "ITEM_MOD_HEALTH_REGEN_SHORT"),
		},
	},
	{
		name = "STAT_CATEGORY_RESISTANCE",
		stats = {
			Stat("FIRE_RESISTANCE", "RESISTANCE2_NAME", "ITEM_MOD_FIRE_RESISTANCE_SHORT"),
			Stat("NATURE_RESISTANCE", "RESISTANCE3_NAME", "ITEM_MOD_NATURE_RESISTANCE_SHORT"),
			Stat("FROST_RESISTANCE", "RESISTANCE4_NAME", "ITEM_MOD_FROST_RESISTANCE_SHORT"),
			Stat("SHADOW_RESISTANCE", "RESISTANCE5_NAME", "ITEM_MOD_SHADOW_RESISTANCE_SHORT"),
			Stat("ARCANE_RESISTANCE", "RESISTANCE6_NAME", "ITEM_MOD_ARCANE_RESISTANCE_SHORT"),
		},
	},
	{
		name = "TRADE_SKILLS",
		stats = {
			Stat("ALCHEMY", "ITEM_MOD_ALCHEMY_SHORT"),
			Stat("BLACKSMITHING", "ITEM_MOD_BLACKSMITHING_SHORT"),
			Stat("COOKING", "ITEM_MOD_COOKING_SHORT"),
			Stat("ENCHANTING", "ITEM_MOD_ENCHANTING_SHORT"),
			Stat("ENGINEERING", "ITEM_MOD_ENGINEERING_SHORT"),
			Stat("FIRST_AID", "ITEM_MOD_FIRST_AID_SHORT"),
			Stat("FISHING", "ITEM_MOD_FISHING_SHORT"),
			Stat("HERBALISM", "ITEM_MOD_HERBALISM_SHORT"),
			Stat("LEATHERWORKING", "ITEM_MOD_LEATHERWORKING_SHORT"),
			Stat("MINING", "ITEM_MOD_MINING_SHORT"),
			Stat("SKINNING", "ITEM_MOD_SKINNING_SHORT"),
			Stat("TAILORING", "ITEM_MOD_TAILORING_SHORT"),
		},
	},
}

-- Every stat once (one listed in two groups is the same stat), in menu order.
ns.STATS = {}
-- Stat key -> true, for every stat above.
ns.KNOWN_STATS = {}
for _, group in ipairs(ns.STAT_GROUPS) do
	for _, stat in ipairs(group.stats) do
		if not stat.divider and not ns.KNOWN_STATS[stat.key] then
			ns.KNOWN_STATS[stat.key] = true
			ns.STATS[#ns.STATS + 1] = stat
		end
	end
end

-- The stats an item raises, as a set of stat keys: those with a positive amount under any of
-- their names in the game's stat table for the item, plus those its random ending adds. The
-- table comes from C_Item.GetItemStats: amounts keyed by global string names
-- (ITEM_MOD_STRENGTH_SHORT and the like). endingAdds is a set of those names (see EndingAdds),
-- or nil for an item without an ending. No table means no stats of its own.
function ns.RaisedByItemStats(itemStats, endingAdds)
	local raised = {}
	for _, stat in ipairs(ns.STATS) do
		for _, name in ipairs(stat.names) do
			local amount = type(itemStats) == "table" and itemStats[name]
			if (type(amount) == "number" and amount > 0) or (endingAdds and endingAdds[name]) then
				raised[stat.key] = true
			end
		end
	end
	return raised
end

-- What a random ending ("of the Whale") adds to an item, as a set of stat names: those with a
-- higher amount in the stat table of a real auction's link (which carries the ending) than in
-- the item's own (C_Item.GetItemStats("item:<id>"), which doesn't). An ending adds the same
-- stats to every item, so one auction tells them all. Every stat name is kept, not only the ones
-- in the menu, so stats added to the menu later need no new learning.
function ns.EndingAdds(withEnding, withoutEnding)
	local adds = {}
	if type(withEnding) == "table" then
		for name, amount in pairs(withEnding) do
			local own = type(withoutEnding) == "table" and withoutEnding[name]
			if type(name) == "string" and type(amount) == "number" and amount > (type(own) == "number" and own or 0) then
				adds[name] = true
			end
		end
	end
	return adds
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

-- Runs on every load with the saved StatShopperDB (per character) and returns it rebuilt from
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

-- The account-wide saved layout's version (StatShopperAccountDB). Raise it only when a change
-- stores the endings differently, and convert the older layout in NormalizeAccount.
local ACCOUNT_FORMAT = 1

-- Runs on every load with the saved StatShopperAccountDB and the game's build number, and
-- returns it rebuilt: the random endings learned so far, by the auction house's ending number,
-- each with the stat names it adds (a set, possibly empty). They are kept only for the build they
-- were learned on: a game update may change what an ending adds, and they are learned again.
-- Anything else is dropped.
function ns.NormalizeAccount(old, build)
	local clean = {
		format = ACCOUNT_FORMAT,
		build = build,
		endings = {},
	}
	if type(old) == "table" and old.format == ACCOUNT_FORMAT and old.build == build and type(old.endings) == "table" then
		for ending, adds in pairs(old.endings) do
			if type(ending) == "number" and ending ~= 0 and ending % 1 == 0 and type(adds) == "table" then
				local kept = {}
				for name, added in pairs(adds) do
					if type(name) == "string" and added == true then
						kept[name] = true
					end
				end
				clean.endings[ending] = kept
			end
		end
	end
	return clean
end
