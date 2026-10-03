local addonName, ns = ...

-- Keep equal to ## Version in the .toc. The game reads the .toc only at client start, so the
-- chat lines use this, which /reload picks up.
local VERSION = "0.1.5"
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
local function Say(message)
	print(NORMAL_FONT_COLOR:WrapTextInColorCode(ADDON_TITLE) .. ": " .. message)
end

local function SayProblem(problem, advice)
	Say(RED_FONT_COLOR:WrapTextInColorCode(problem) .. " " .. advice)
end

local auctionFrame -- AuctionHouseFrame, once the auction house has loaded
local resultsFrame -- its BrowseResultsFrame: the search results list
local filterButton -- the search bar's Filter dropdown, with Blizzard's red X (ClearFiltersButton)
local linePatterns = {} -- stat key -> pattern for the stat's tooltip line

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
-- Test build only (0.1.2 to 0.1.5): times a filtered search's frames, and in 0.1.5 checks what
-- reading stats without tooltips leaves out. After each filtered search it says three lines in
-- chat. Remove this section and its Measured/Count/Diagnose calls after the test.
--------------------------------------------------------------------------------

-- The random suffix whose first tooltip in a session stalled the game for 14.2 s (0.1.2 to
-- 0.1.4). The check never reads a tooltip for an item with it.
local STALLING_SUFFIX = 14328
local CALL_NAMES = {
	instant = "item class",
	cached = "cache check",
	keyInfo = "key info",
	itemStats = "item stats",
	ask = "item ask",
	refresh = "list refresh",
	tooltip = "check tooltip",
}
local CALL_ORDER = { "itemStats", "keyInfo", "cached", "instant", "ask", "refresh", "tooltip" }
local COUNT_NAMES = { "pages", "results", "reads", "asks", "arrived", "waits", "redraws" }

local measure -- nil, or the search being measured
local monitor = CreateFrame("Frame") -- times every frame while a search is measured
monitor:Hide()

local function NewCounts()
	local counts = { addon = 0 }
	for _, name in ipairs(COUNT_NAMES) do
		counts[name] = 0
	end
	return counts
end

local function Count(name, amount)
	if measure then
		amount = amount or 1
		measure.total[name] = measure.total[name] + amount
		measure.frame[name] = measure.frame[name] + amount
	end
end

-- Calls func and remembers the slowest such call of the search.
local function Measured(callName, func, ...)
	if not measure then
		return func(...)
	end
	local start = GetTimePreciseSec()
	local a, b, c, d, e, f, g = func(...)
	local took = GetTimePreciseSec() - start
	if took > (measure.slowest[callName] or 0) then
		measure.slowest[callName] = took
	end
	return a, b, c, d, e, f, g
end

local function StartMeasuring()
	local now = GetTimePreciseSec()
	measure = {
		start = now, lastFrame = now, total = NewCounts(), frame = NewCounts(), slowest = {}, worstGap = 0,
		checked = 0, agree = 0, suffixed = 0, suffixAdds = 0, skipped = 0, bySuffix = {},
	}
	monitor:Show()
end

monitor:SetScript("OnUpdate", function()
	if not measure then
		monitor:Hide()
		return
	end
	local now = GetTimePreciseSec()
	local gap = now - measure.lastFrame
	if gap > measure.worstGap then
		measure.worstGap = gap
		measure.worst = measure.frame
	end
	measure.lastFrame = now
	measure.frame = NewCounts()
end)

local function SameSet(a, b)
	for key in pairs(a) do
		if not b[key] then
			return false
		end
	end
	for key in pairs(b) do
		if not a[key] then
			return false
		end
	end
	return true
end

local function SetText(set)
	local keys = {}
	for key in pairs(set) do
		keys[#keys + 1] = key:sub(1, 3):lower()
	end
	table.sort(keys)
	return #keys > 0 and table.concat(keys, "+") or "none"
end

-- The stat amounts of an item key's tooltip, with the given random suffix (0 for none).
local function TooltipAmounts(itemKey, suffix)
	local tooltip = Measured("tooltip", C_TooltipInfo.GetItemKey, itemKey.itemID, itemKey.itemLevel, suffix, C_AuctionHouse.GetItemKeyRequiredLevel(itemKey))
	return tooltip and tooltip.lines and ns.StatAmounts(tooltip.lines, linePatterns)
end

-- After an entry's stats were read from the game's stat table: does the item's tooltip without
-- its suffix agree, and does its suffix add stats in the tooltip?
local function Diagnose(entry)
	if not measure then
		return
	end
	local itemKey = entry.result.itemKey
	local suffix = itemKey.itemSuffix
	if suffix == STALLING_SUFFIX then
		measure.skipped = measure.skipped + 1
		return
	end
	local base = TooltipAmounts(itemKey, 0)
	if not base then
		return
	end
	measure.checked = measure.checked + 1
	local fromTooltip = ns.Raised(base)
	if SameSet(fromTooltip, entry.stats) then
		measure.agree = measure.agree + 1
	else
		measure.example = measure.example or string.format("%s: tooltip %s, item stats %s", entry.name or itemKey.itemID, SetText(fromTooltip), SetText(entry.stats))
	end
	if suffix ~= 0 then
		measure.suffixed = measure.suffixed + 1
		local withSuffix = TooltipAmounts(itemKey, suffix)
		local added = withSuffix and ns.SuffixStats(withSuffix, base)
		if added and next(added) then
			measure.suffixAdds = measure.suffixAdds + 1
			local seen = measure.bySuffix[suffix]
			if not seen then
				seen = { suffix = suffix, count = 0, stats = SetText(added), example = entry.name or tostring(itemKey.itemID) }
				measure.bySuffix[suffix] = seen
			end
			seen.count = seen.count + 1
		end
	end
end

local function CountsText(counts)
	local parts = {}
	for _, name in ipairs(COUNT_NAMES) do
		if counts[name] > 0 then
			parts[#parts + 1] = counts[name] .. " " .. name
		end
	end
	return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

local function ReportMeasure(how)
	if not measure then
		return
	end
	local m = measure
	measure = nil
	monitor:Hide()
	local worst = m.worst or NewCounts()
	local calls = {}
	for _, callName in ipairs(CALL_ORDER) do
		if m.slowest[callName] then
			calls[#calls + 1] = string.format("%s %.0f", CALL_NAMES[callName], m.slowest[callName] * 1000)
		end
	end
	local suffixes = {}
	for _, seen in pairs(m.bySuffix) do
		suffixes[#suffixes + 1] = seen
	end
	table.sort(suffixes, function(a, b)
		return a.count > b.count
	end)
	local top = {}
	for index = 1, math.min(4, #suffixes) do
		local seen = suffixes[index]
		top[index] = string.format("%d on %d items, %s, e.g. %s", seen.suffix, seen.count, seen.stats, seen.example)
	end
	Say(string.format("test %s: search %s in %.1f s. In all: %s.", VERSION, how, GetTimePreciseSec() - m.start, CountsText(m.total)))
	Say(string.format("Longest frame %.2f s, of it the addon %.3f s (%s). Slowest calls, ms: %s.",
		m.worstGap, worst.addon, CountsText(worst), #calls > 0 and table.concat(calls, ", ") or "none"))
	Say(string.format("Check: item stats vs tooltip %d of %d agree%s. Suffix adds stats on %d of %d suffixed items, %d suffixes%s. Suffix %d not checked, on %d items.",
		m.agree, m.checked, m.example and (" (first other: " .. m.example .. ")") or "",
		m.suffixAdds, m.suffixed, #suffixes, #top > 0 and (": " .. table.concat(top, "; ")) or "",
		STALLING_SUFFIX, m.skipped))
end

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
	if search and not IsWorking() then
		ReportMeasure("done")
	end
end

local function StopSearch()
	if search then
		ReportMeasure("stopped before it was done")
	end
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
	Count("waits")
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
-- No tooltip is built. In 0.1.0 to 0.1.4 the first tooltip in a session with random suffix 14328
-- (items 11968 and 6560) stalled the game for 14.2 s inside C_TooltipInfo.GetItemKey, while
-- GetItemStats never took a millisecond, for those items too. GetItemStats knows the item
-- itself, not what a random suffix ("of the Bear") adds: with the suffix in a link it ignored it
-- for all 4877 suffixed items, and it agreed with the tooltip on 5968 of 6030 items.
local function ReadStats(entry)
	local itemKey = entry.result.itemKey
	local itemID = itemKey.itemID
	local classID = select(6, Measured("instant", C_Item.GetItemInfoInstant, itemID))
	if classID and not GEAR_CLASSES[classID] then
		entry.stats = NO_STATS
		statsCache[entry.key] = NO_STATS
		return
	end
	if not Measured("cached", C_Item.IsItemDataCachedByID, itemID) then
		WaitForItem(itemID, entry)
		return
	end
	local info = Measured("keyInfo", C_AuctionHouse.GetItemKeyInfo, itemKey)
	if not (info and info.itemName) then
		WaitForKeyInfo(itemID, entry)
		return
	end
	entry.name = info.itemName
	nameCache[entry.key] = info.itemName
	Count("reads")
	entry.stats = ns.RaisedByItemStats(Measured("itemStats", C_Item.GetItemStats, "item:" .. itemID))
	statsCache[entry.key] = entry.stats
	Diagnose(entry)
end

-- Takes in a page of results. A result already there (the same search re-sorted) takes the
-- fresher price and quantity.
local function Merge(results)
	Count("pages")
	for _, result in ipairs(results) do
		local key = ns.ResultKey(result.itemKey)
		local entry = search.byKey[key]
		if entry then
			entry.result = result
		else
			Count("results")
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
	Count("redraws")
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
	Measured("refresh", resultsFrame.ItemList.RefreshScrollFrame, resultsFrame.ItemList)
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
			Count("asks")
			Measured("ask", C_Item.RequestLoadItemDataByID, itemID)
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
	Count("arrived")
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
	if searchStats then
		StartMeasuring()
	end
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
	local start = measure and GetTimePreciseSec()
	local ok = xpcall(func, CallErrorHandler, ...)
	if start and measure then
		measure.frame.addon = measure.frame.addon + GetTimePreciseSec() - start
	end
	if ok then
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
