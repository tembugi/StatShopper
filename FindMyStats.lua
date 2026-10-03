local addonName, ns = ...

-- Keep equal to ## Version in the .toc. The game reads the .toc only at client start, so the
-- chat line about a changed auction house uses this, which /reload picks up.
local VERSION = "0.1.6"
-- The addon's name as the player sees it: the start of chat lines.
local ADDON_TITLE = "Find My Stats"

-- Blizzard's auction house loads when it is first opened. Its Filter dropdown carries this
-- tag, which Blizzard's menu system lets addons add elements to (Menu.ModifyMenu).
local AUCTION_UI = "Blizzard_AuctionHouseUI"
local FILTER_MENU_TAG = "MENU_AUCTION_HOUSE_SEARCH_FILTER"

-- Only weapons and armor can match.
local GEAR_CLASSES = {
	[Enum.ItemClass.Weapon] = true,
	[Enum.ItemClass.Armor] = true,
}
local NO_STATS = {}

-- Work on items stops for the frame after this many seconds, so even a search of the whole
-- auction house never stalls the game. Timed with GetTimePreciseSec: debugprofilestop counts
-- from the last debugprofilestart, which any addon may call.
local FRAME_BUDGET = 0.004
-- Items the addon asks the server about at a time. 0.1.0 asked about every item of a search at
-- once, and the game stalled for seconds.
local MAX_ITEM_LOADS = 30
-- Seconds between redraws of the list while matches still come in.
local REDRAW_INTERVAL = 0.25

-- The values the list's sorts compare, by Blizzard's sort order. A browse list sorts by Price
-- (the lowest buyout) and Name; Level, the extra column of containers, consumables and
-- recipes, never shows with gear.
local SORT_VALUES = {
	[Enum.AuctionHouseSortOrder.Price] = function(entry)
		return entry.result.minPrice
	end,
	[Enum.AuctionHouseSortOrder.Name] = function(entry)
		return entry.name
	end,
}

-- Every chat line starts with the addon's name in gold. The addon writes to chat only when
-- something stopped working: what stopped, in red, then what the player can do.
local function SayProblem(problem, advice)
	print(NORMAL_FONT_COLOR:WrapTextInColorCode(ADDON_TITLE) .. ": " .. RED_FONT_COLOR:WrapTextInColorCode(problem) .. " " .. advice)
end

local auctionFrame -- AuctionHouseFrame, once the auction house has loaded
local resultsFrame -- its BrowseResultsFrame: the search results list
local filterButton -- the search bar's Filter dropdown, with Blizzard's red X (ClearFiltersButton)

local searchStats -- the stats ticked when the last search was sent; nil when none were
-- The stat-filtered search whose results are on screen, or nil:
--   stats     the stats it was sent with
--   entries   every result so far, in arrival order: { key, result, order, stats, name }
--   byKey     ResultKey -> entry
--   complete  true once every page of results has arrived
--   shown     the list handed to the results frame
local search

-- Kept for the session: an item key's stats and name never change.
local statsCache = {} -- ResultKey -> the stats the item raises
local nameCache = {} -- ResultKey -> the item's name as the list shows it

-- First in, first out. Taken items are cleared, so the queue keeps its own ends: the length
-- operator is unreliable on a table with holes.
local function NewQueue()
	return { head = 1, tail = 0 }
end

local function Push(queue, value)
	queue.tail = queue.tail + 1
	queue[queue.tail] = value
end

local function Take(queue)
	local value = queue[queue.head]
	queue[queue.head] = nil
	queue.head = queue.head + 1
	return value
end

local function IsEmpty(queue)
	return queue.head > queue.tail
end

local readQueue = NewQueue() -- entries whose stats aren't read yet
local itemWaits = {} -- itemID -> { entries = waiting for the item's data, loading = asked for }
local loadQueue = NewQueue() -- itemIDs to ask the server about
local loadsInFlight = 0
local keyWaits = {} -- itemID -> entries waiting for the auction house's info on their item key
local redrawPending, lastRedraw = false, 0
local spinnerShown -- the addon shows Blizzard's spinner in place of "No results"

local worker = CreateFrame("Frame") -- reads items and redraws, a little each frame
worker:Hide()
local events = CreateFrame("Frame")

local stopped -- true after an error: the filters stay off until /reload
local Guarded -- runs addon code inside Blizzard's without breaking it (defined below)

--------------------------------------------------------------------------------
-- Filtering the results
--------------------------------------------------------------------------------

local function IsWorking()
	return search ~= nil and (not IsEmpty(readQueue) or not IsEmpty(loadQueue) or loadsInFlight > 0 or not search.complete)
end

-- Blizzard's list says "No results" once every page has arrived, and shows its loading
-- spinner only before that. While the addon still reads items and nothing matches yet, the
-- list shows Blizzard's spinner instead of "No results".
local function UpdateEmptyList()
	if not resultsFrame then
		return
	end
	local list = resultsFrame.ItemList
	local empty = resultsFrame:GetNumBrowseResults() == 0
	local everyPageIn = C_AuctionHouse.HasFullBrowseResults()
	if search and empty and everyPageIn and IsWorking() then
		list.ResultsText:Hide()
		list.LoadingSpinner:Show()
		spinnerShown = true
	elseif spinnerShown then
		spinnerShown = false
		list.LoadingSpinner:Hide()
		list.ResultsText:SetShown(empty and everyPageIn)
	end
end

local function StopSearch()
	search = nil
	readQueue = NewQueue()
	itemWaits = {}
	loadQueue = NewQueue()
	loadsInFlight = 0
	keyWaits = {}
	redrawPending = false
	events:UnregisterAllEvents()
	worker:Hide()
	UpdateEmptyList()
end

local function StartSearch(stats)
	StopSearch()
	search = { stats = stats, entries = {}, byKey = {}, complete = false, shown = {} }
end

local function Enqueue(entry)
	Push(readQueue, entry)
	worker:Show()
end

local function WaitForItem(itemID, entry)
	local wait = itemWaits[itemID]
	if not wait then
		wait = { entries = {} }
		itemWaits[itemID] = wait
		Push(loadQueue, itemID)
	end
	wait.entries[#wait.entries + 1] = entry
end

local function WaitForKeyInfo(itemID, entry)
	local waiting = keyWaits[itemID] or {}
	waiting[#waiting + 1] = entry
	keyWaits[itemID] = waiting
	events:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
end

local function IsMatch(entry)
	return entry.stats ~= nil and ns.HasAll(entry.stats, search.stats)
end

-- Reads the stats an entry's item raises from the game's stat table for the item
-- (C_Item.GetItemStats). An item whose data isn't on the client yet waits for it, and the
-- auction house's info on the item key gives the name the list shows and sorts by; a listing it
-- can't name stays out of the results.
-- Never from a tooltip: the first tooltip in a session with random suffix 14328 stalled the game
-- for 14.2 s inside C_TooltipInfo.GetItemKey (0.1.0 to 0.1.4), and the addon must never freeze
-- the game. GetItemStats never took a millisecond. It knows the item itself, not what a random
-- suffix adds, but in 0.1.5's in-game check (6007 items) it matched the item's tooltip every
-- time, and no suffix added stats, on any of 4856 suffixed items. The one exception, suffix
-- 14328 (71 listings), adds Stamina that this doesn't see: reading it is what stalls the game.
local function ReadStats(entry)
	local itemKey = entry.result.itemKey
	local itemID = itemKey.itemID
	local classID = select(6, C_Item.GetItemInfoInstant(itemID))
	if classID and not GEAR_CLASSES[classID] then
		entry.stats = NO_STATS
		statsCache[entry.key] = NO_STATS
		return
	end
	if not C_Item.IsItemDataCachedByID(itemID) then
		WaitForItem(itemID, entry)
		return
	end
	local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
	if not (info and info.itemName) then
		WaitForKeyInfo(itemID, entry)
		return
	end
	entry.name = info.itemName
	nameCache[entry.key] = info.itemName
	entry.stats = ns.RaisedByItemStats(C_Item.GetItemStats("item:" .. itemID))
	statsCache[entry.key] = entry.stats
end

-- Takes in a page of results. A result already there (the same search re-sorted) takes the
-- fresher price and quantity.
local function Merge(results)
	for _, result in ipairs(results) do
		local key = ns.ResultKey(result.itemKey)
		local entry = search.byKey[key]
		if entry then
			entry.result = result
		else
			entry = { key = key, result = result, order = #search.entries + 1, stats = statsCache[key], name = nameCache[key] }
			search.byKey[key] = entry
			search.entries[#search.entries + 1] = entry
			if not entry.stats then
				Enqueue(entry)
			end
		end
	end
end

-- Hands the results frame the matches, sorted as its headers say, and redraws its list.
local function Redraw()
	redrawPending = false
	lastRedraw = GetTime()
	local matching = ns.Matching(search.entries, search.stats)
	ns.SortEntries(matching, auctionFrame:GetSortsForContext(auctionFrame:GetBrowseSearchContext()), SORT_VALUES)
	local shown = {}
	for index, entry in ipairs(matching) do
		shown[index] = entry.result
	end
	search.shown = shown
	resultsFrame.browseResults = shown
	resultsFrame.ItemList:RefreshScrollFrame()
	UpdateEmptyList()
end

local function OwnsList()
	return search ~= nil and resultsFrame.browseResults == search.shown
end

-- Asks for the search's next page of results. Blizzard's list asks only while it shows few
-- results, but filtering and sorting need them all: the addon asks after each page, when the
-- auction house's throttle is ready. Once every page has arrived, a re-sorted search needs no
-- more; Blizzard's list still asks by itself while it shows few results, but an empty list
-- never asks, so the addon does, until the server has no more.
local function RequestNextPage()
	if not search then
		return
	end
	if C_AuctionHouse.HasFullBrowseResults() then
		search.complete = true
		events:UnregisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
		UpdateEmptyList()
		return
	end
	if search.complete and #search.shown > 0 then
		return
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady() then
		events:UnregisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
		C_AuctionHouse.RequestMoreBrowseResults()
	else
		events:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
	end
end

local function IssueLoads()
	while loadsInFlight < MAX_ITEM_LOADS and not IsEmpty(loadQueue) do
		local itemID = Take(loadQueue)
		local wait = itemWaits[itemID]
		if wait and not wait.loading then
			wait.loading = true
			loadsInFlight = loadsInFlight + 1
			events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
			C_Item.RequestLoadItemDataByID(itemID)
		end
	end
end

-- One frame's work: ask about more items, read items until the frame's budget is spent, and
-- redraw when matches came in (at most every REDRAW_INTERVAL while more are coming).
local function Work()
	if not search then
		worker:Hide()
		return
	end
	IssueLoads()
	local deadline = GetTimePreciseSec() + FRAME_BUDGET
	while not IsEmpty(readQueue) and GetTimePreciseSec() < deadline do
		local entry = Take(readQueue)
		if not entry.stats then
			ReadStats(entry)
		end
		if IsMatch(entry) then
			redrawPending = true
		end
	end
	if redrawPending then
		if not OwnsList() then
			-- A new search or a closed auction house replaced the list.
			redrawPending = false
		elseif not IsWorking() or GetTime() - lastRedraw >= REDRAW_INTERVAL then
			Redraw()
		end
	end
	-- Asleep until an event brings more to do: item data, a page, or item key info.
	if IsEmpty(readQueue) and (IsEmpty(loadQueue) or loadsInFlight >= MAX_ITEM_LOADS) and not redrawPending then
		worker:Hide()
	end
	UpdateEmptyList()
end

worker:SetScript("OnUpdate", function()
	Guarded(Work)
end)

local function OnItemData(itemID, success)
	local wait = itemWaits[itemID]
	if not wait then
		return
	end
	itemWaits[itemID] = nil
	if wait.loading then
		loadsInFlight = loadsInFlight - 1
		if loadsInFlight == 0 and IsEmpty(loadQueue) then
			events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
		end
	end
	for _, entry in ipairs(wait.entries) do
		if success then
			Enqueue(entry)
		else
			-- The server had no data for it: left out of this search.
			entry.stats = NO_STATS
		end
	end
	worker:Show()
end

-- The auction house has the info on an item's keys: their entries are read again.
local function OnItemKeyInfo(itemID)
	local waiting = keyWaits[itemID]
	if not waiting then
		return
	end
	keyWaits[itemID] = nil
	if not next(keyWaits) then
		events:UnregisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
	end
	for _, entry in ipairs(waiting) do
		Enqueue(entry)
	end
end

events:SetScript("OnEvent", function(_, event, ...)
	if event == "ITEM_DATA_LOAD_RESULT" then
		Guarded(OnItemData, ...)
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		Guarded(RequestNextPage)
	elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
		Guarded(OnItemKeyInfo, ...)
	end
end)

-- Runs right after the results frame takes a search's first results or the same search's
-- re-sorted results (added is nil), or appends a further page to them (added).
local function OnResults(added)
	if added then
		-- Blizzard appended the page to the list on screen. Go on only if that list is the one
		-- the addon handed over.
		if not OwnsList() then
			return
		end
		Merge(added)
	else
		-- Favorites are never filtered, as Blizzard's own filters don't apply to them.
		if not searchStats or auctionFrame.isDisplayingFavorites then
			StopSearch()
			return
		end
		-- A new search starts over (OnSearchSent stops the old one). The same search re-sorted
		-- keeps what it has and takes in the fresher results.
		if not search then
			StartSearch(searchStats)
		end
		Merge(resultsFrame.browseResults)
	end
	Redraw()
	RequestNextPage()
end

-- A search was sent with the ticks of this moment. Blizzard's code gets its results later,
-- after this returns.
local function OnSearchSent()
	searchStats = ns.Ticked(FindMyStatsDB.stats)
	StopSearch()
end

-- A column header was clicked: Blizzard sends the search again in the new order. The matches
-- already found are sorted at once; the search's new results merge in when they arrive.
local function OnSortChanged()
	if OwnsList() then
		Redraw()
	end
end

-- Puts every result of the search back on screen, unfiltered.
local function ShowAllResults()
	if OwnsList() then
		local all = {}
		for index, entry in ipairs(search.entries) do
			all[index] = entry.result
		end
		resultsFrame.browseResults = all
		resultsFrame.ItemList:DirtyScrollFrame()
	end
	StopSearch()
end

-- The filters run inside Blizzard's auction house code, right after it gets results. An error
-- there must not break the code that called it, nor repeat on every page. The first error is
-- reported through the game's error handler and said once in chat; the search's results go
-- back on screen unfiltered, and the filters stay off until /reload.
Guarded = function(func, ...)
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
-- spacer Blizzard queues behind its last group. A stat whose name the game doesn't have is left
-- out.
local function AddStatsMenu(root)
	root:CreateTitle(PET_BATTLE_STATS_LABEL)
	for _, group in ipairs(ns.STAT_GROUPS) do
		local submenu = root:CreateButton(_G[group.name])
		for _, stat in ipairs(group.stats) do
			local label = _G[stat.label]
			if type(label) == "string" then
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
	local list = results and results.ItemList
	local searchBar = frame and frame.SearchBar
	local filter = searchBar and searchBar.FilterButton
	local groupsNamed = true
	for _, group in ipairs(ns.STAT_GROUPS) do
		groupsNamed = groupsNamed and type(_G[group.name]) == "string"
	end
	if frame and frame.SendBrowseQuery and frame.GetSortsForContext and frame.GetBrowseSearchContext
		and results and results.UpdateBrowseResults and results.Reset and results.SetSortOrder and results.GetNumBrowseResults
		and list and list.RefreshScrollFrame and list.DirtyScrollFrame and list.ResultsText and list.LoadingSpinner
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
	hooksecurefunc(results, "SetSortOrder", function()
		Guarded(OnSortChanged)
	end)
	-- Closing the auction house empties the results list (AuctionHouseFrameMixin:OnHide).
	hooksecurefunc(results, "Reset", function()
		Guarded(StopSearch)
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
	EventUtil.ContinueOnAddOnLoaded(AUCTION_UI, function()
		Guarded(Install)
	end)
end)
