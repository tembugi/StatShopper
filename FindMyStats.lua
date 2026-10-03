local addonName, ns = ...

-- Keep equal to ## Version in the .toc. The game reads the .toc only at client start, so the
-- chat line about a changed auction house uses this, which /reload picks up.
local VERSION = "0.1.0"
-- The addon's name as the player sees it: the start of chat lines.
local ADDON_TITLE = "Find My Stats"

-- Blizzard's auction house loads when it is first opened. Its Filter dropdown carries this
-- tag, which Blizzard's menu system lets addons add elements to (Menu.ModifyMenu).
local AUCTION_UI = "Blizzard_AuctionHouseUI"
local FILTER_MENU_TAG = "MENU_AUCTION_HOUSE_SEARCH_FILTER"

-- Only weapons and armor can match. Other items' tooltips can show stats too: a recipe shows
-- the item it makes.
local GEAR_CLASSES = {
	[Enum.ItemClass.Weapon] = true,
	[Enum.ItemClass.Armor] = true,
}
local NO_STATS = {}

-- Every chat line starts with the addon's name in gold. The addon writes to chat only when
-- something stopped working: what stopped, in red, then what the player can do.
local function SayProblem(problem, advice)
	print(NORMAL_FONT_COLOR:WrapTextInColorCode(ADDON_TITLE) .. ": " .. RED_FONT_COLOR:WrapTextInColorCode(problem) .. " " .. advice)
end

local auctionFrame -- AuctionHouseFrame, once the auction house has loaded
local resultsFrame -- its BrowseResultsFrame: the search results list
local filterButton -- the search bar's Filter dropdown, with Blizzard's red X (ClearFiltersButton)
local linePatterns = {} -- stat key -> pattern for the stat's tooltip line

local searchStats -- the stats ticked when the last search was sent; nil when none were
local activeStats -- the stats the list on screen is filtered by; nil while it isn't filtered
local allResults -- every result of that search so far, in the server's order
local shownResults -- the matching ones: the list the addon handed to the results frame
local statsCache = {} -- "itemID:itemLevel:itemSuffix" -> the stats that item raises
local loadingItems = {} -- itemID -> true while its data is on the way, false if it failed

local itemEvents = CreateFrame("Frame")
-- Filters the list again on the next frame, once for a whole burst of arriving item data.
local refilter = CreateFrame("Frame")
refilter:Hide()

local stopped -- true after an error: the filters stay off until /reload

local function Forget()
	activeStats, allResults, shownResults = nil, nil, nil
	wipe(loadingItems)
	itemEvents:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
	refilter:Hide()
end

-- Puts the search's full list back on screen, if the filtered one is still there.
local function ShowAllResults()
	if allResults and resultsFrame.browseResults == shownResults then
		resultsFrame.browseResults = allResults
		resultsFrame.ItemList:DirtyScrollFrame()
	end
	Forget()
end

-- The filters run inside Blizzard's auction house code, right after it gets results. An error
-- there must not break the code that called it, nor repeat on every batch. The first error is
-- reported through the game's error handler and said once in chat; the search's full list
-- goes back on screen, and the filters stay off until /reload.
local function Guarded(func, ...)
	if stopped then
		return
	end
	if xpcall(func, CallErrorHandler, ...) then
		return
	end
	stopped = true
	SayProblem("The stat filters stopped working and are off.", "Type /reload to turn them back on.")
	xpcall(ShowAllResults, CallErrorHandler)
end

--------------------------------------------------------------------------------
-- Filtering the results
--------------------------------------------------------------------------------

-- The stats an auction's item raises, read from the tooltip the auction house shows for it
-- (the same SetItemKey arguments Blizzard uses for a results row, random suffix included).
-- Nil while the item's data is loading; the list is filtered again when it arrives.
local function StatsOf(itemKey)
	local itemID = itemKey.itemID
	local cacheKey = itemID .. ":" .. itemKey.itemLevel .. ":" .. itemKey.itemSuffix
	local stats = statsCache[cacheKey]
	if stats then
		return stats
	end
	local classID = select(6, C_Item.GetItemInfoInstant(itemID))
	if classID and not GEAR_CLASSES[classID] then
		statsCache[cacheKey] = NO_STATS
		return NO_STATS
	end
	if not C_Item.IsItemDataCachedByID(itemID) then
		local loading = loadingItems[itemID]
		if loading == false then
			-- The server had no data for it: left out, and not asked for again this search.
			return NO_STATS
		end
		if loading == nil then
			loadingItems[itemID] = true
			C_Item.RequestLoadItemDataByID(itemID)
		end
		return nil
	end
	local tooltip = C_TooltipInfo.GetItemKey(itemID, itemKey.itemLevel, itemKey.itemSuffix, C_AuctionHouse.GetItemKeyRequiredLevel(itemKey))
	if not (tooltip and tooltip.lines) then
		-- Left out this time but not remembered: the next pass reads it again.
		return NO_STATS
	end
	stats = ns.RaisedStats(tooltip.lines, linePatterns)
	statsCache[cacheKey] = stats
	return stats
end

-- Hands Blizzard's results frame the results that raise every stat the search was sent with,
-- in the server's order, and marks its list for redraw.
-- Blizzard's list asks the server for the next batch only while it shows results
-- (RefreshScrollFrame stops at an empty list). So when a batch arrives (askForMore) and no
-- match is on screen, the addon asks for the next batch, to reach the matches further on.
local function ShowMatches(askForMore)
	local shown, loading = ns.Filter(allResults, activeStats, StatsOf)
	shownResults = shown
	resultsFrame.browseResults = shown
	resultsFrame.ItemList:DirtyScrollFrame()
	if askForMore and #shown == 0 and not C_AuctionHouse.HasFullBrowseResults() then
		C_AuctionHouse.RequestMoreBrowseResults()
	end
	if loading > 0 then
		itemEvents:RegisterEvent("ITEM_DATA_LOAD_RESULT")
	else
		itemEvents:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
	end
end

-- Runs right after the results frame takes a search's results (added is nil) or appends a
-- further batch to them (added).
local function OnResults(added)
	if added then
		if not activeStats then
			return
		end
		-- Blizzard appended the batch to the list on screen. Go on only if that list is still
		-- the one the addon handed over: a new search or a closed auction house replaces it.
		if resultsFrame.browseResults ~= shownResults then
			Forget()
			return
		end
		for _, result in ipairs(added) do
			allResults[#allResults + 1] = result
		end
	else
		Forget()
		-- Favorites are never filtered, as Blizzard's own filters don't apply to them.
		if not searchStats or auctionFrame.isDisplayingFavorites then
			return
		end
		activeStats = searchStats
		allResults = {}
		for index, result in ipairs(resultsFrame.browseResults) do
			allResults[index] = result
		end
	end
	ShowMatches(true)
end

local function RefilterNow()
	if activeStats and resultsFrame.browseResults == shownResults then
		ShowMatches(false)
	end
end

refilter:SetScript("OnUpdate", function(self)
	self:Hide()
	Guarded(RefilterNow)
end)

local function OnItemData(itemID, success)
	if loadingItems[itemID] then
		if success then
			loadingItems[itemID] = nil
		else
			loadingItems[itemID] = false
		end
		refilter:Show()
	end
end

itemEvents:SetScript("OnEvent", function(_, _, itemID, success)
	Guarded(OnItemData, itemID, success)
end)

-- A search was sent with the ticks of this moment. Blizzard's code gets its results later,
-- after this returns.
local function OnSearchSent()
	searchStats = ns.Ticked(FindMyStatsDB.stats)
end

-- Closing the auction house empties the results list (AuctionHouseFrameMixin:OnHide).
local function OnClosed()
	Forget()
	wipe(statsCache)
end

--------------------------------------------------------------------------------
-- The Filter menu and its red X
--------------------------------------------------------------------------------

local function IsTicked(key)
	return FindMyStatsDB.stats[key] == true
end

local function AnyTicked()
	return next(FindMyStatsDB.stats) ~= nil
end

-- Blizzard shows the red X on the Filter button while its filters differ from the defaults,
-- and clicking it puts them back. Ticked stats are filters too: the X also shows while any is
-- ticked, and clicking it unticks them.
local function ShowClearButtonIfTicked()
	if AnyTicked() then
		filterButton.ClearFiltersButton:Show()
	end
end

-- After a tick changes. With no stat ticked, the X follows Blizzard's own rule
-- (AuctionHouseSearchBarMixin:UpdateClearFiltersButton), read through the Filter button:
-- calling that method from here would write Blizzard's saved filters from addon code.
local function UpdateClearButton()
	if AnyTicked() then
		filterButton.ClearFiltersButton:Show()
		return
	end
	local minLevel, maxLevel = filterButton:GetLevelRange()
	local isDefault = tCompare(filterButton:GetFilters(), AUCTION_HOUSE_DEFAULT_FILTERS) and minLevel == 0 and maxLevel == 0
	filterButton.ClearFiltersButton:SetShown(not isDefault)
end

local function ToggleStat(key)
	FindMyStatsDB.stats[key] = not IsTicked(key) or nil
	UpdateClearButton()
end

local function OnStatClicked(key)
	Guarded(ToggleStat, key)
end

local function UntickAll()
	wipe(FindMyStatsDB.stats)
end

-- A "Stats" title and a submenu per group at the end of Blizzard's Filter dropdown, after the
-- spacer Blizzard queues behind its last group. A stat whose label or tooltip format the game
-- doesn't have is left out.
local function AddStatsMenu(root)
	root:CreateTitle(PET_BATTLE_STATS_LABEL)
	for _, group in ipairs(ns.STAT_GROUPS) do
		local submenu = root:CreateButton(_G[group.name])
		for _, stat in ipairs(group.stats) do
			local label = _G[stat.label]
			if type(label) == "string" and linePatterns[stat.key] then
				submenu:CreateCheckbox(label, IsTicked, OnStatClicked, stat.key)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

-- The pieces of Blizzard's auction house the filters plug into, or nothing if one is missing:
-- then the auction house has changed since this version.
local function FindPieces()
	local frame = AuctionHouseFrame
	local results = frame and frame.BrowseResultsFrame
	local searchBar = frame and frame.SearchBar
	local filter = searchBar and searchBar.FilterButton
	local groupsNamed = true
	for _, group in ipairs(ns.STAT_GROUPS) do
		groupsNamed = groupsNamed and type(_G[group.name]) == "string"
	end
	if frame and frame.SendBrowseQuery
		and results and results.UpdateBrowseResults and results.Reset
		and results.ItemList and results.ItemList.DirtyScrollFrame
		and searchBar and searchBar.UpdateClearFiltersButton
		and filter and filter.Reset and filter.GetFilters and filter.GetLevelRange and filter.ClearFiltersButton
		and type(PET_BATTLE_STATS_LABEL) == "string" and groupsNamed
	then
		return frame, results, searchBar, filter
	end
end

local function Install()
	local frame, results, searchBar, filter = FindPieces()
	if not frame then
		SayProblem("The stat filters are off: the auction house has changed since version " .. VERSION .. ".", "Look for an update.")
		return
	end
	auctionFrame, resultsFrame, filterButton = frame, results, filter

	hooksecurefunc(frame, "SendBrowseQuery", function()
		Guarded(OnSearchSent)
	end)
	hooksecurefunc(results, "UpdateBrowseResults", function(_, added)
		Guarded(OnResults, added)
	end)
	hooksecurefunc(results, "Reset", function()
		Guarded(OnClosed)
	end)
	hooksecurefunc(filter, "Reset", function()
		Guarded(UntickAll)
	end)
	hooksecurefunc(searchBar, "UpdateClearFiltersButton", function()
		Guarded(ShowClearButtonIfTicked)
	end)
	searchBar:HookScript("OnShow", function()
		Guarded(ShowClearButtonIfTicked)
	end)
	Menu.ModifyMenu(FILTER_MENU_TAG, function(_, root)
		Guarded(AddStatsMenu, root)
	end)
end

EventUtil.ContinueOnAddOnLoaded(addonName, function()
	FindMyStatsDB = ns.NormalizeSaved(FindMyStatsDB)
	for _, group in ipairs(ns.STAT_GROUPS) do
		for _, stat in ipairs(group.stats) do
			local format = _G[stat.line]
			if type(format) == "string" then
				linePatterns[stat.key] = ns.LinePattern(format)
			end
		end
	end
	EventUtil.ContinueOnAddOnLoaded(AUCTION_UI, function()
		Guarded(Install)
	end)
end)
