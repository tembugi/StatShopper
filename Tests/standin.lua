-- A stand-in for the game around FindMyStats.lua, for what Tests/run.lua can't check on its own:
-- the addon inside Blizzard's auction house, with a simulated server.
-- Run: luajit Tests/standin.lua <scenario>, in the addon folder (Tests/run.lua runs them all).
-- Exits non-zero when the scenario fails.
--
-- Blizzard's code below copies wow-ui-source (forever, 1.60.1): Shared/Blizzard_AuctionHouseFrame,
-- Blizzard_AuctionHouseBrowseResultsFrame and Blizzard_AuctionHouseItemList, cut to what the
-- addon touches. The server is a model; what it assumes beyond the game's code is marked
-- ASSUMED: a stand-in that behaves better than the game hides bugs.

-- This file runs under luajit, outside the game, and uses standard Lua's loadfile, os and io.
---@diagnostic disable: undefined-global, lowercase-global

local scenario = arg[1]
local now = 0
local log = {}
local function Log(text, ...)
	log[#log + 1] = string.format("%6.2f ", now) .. string.format(text, ...)
end

--------------------------------------------------------------------------------
-- Game basics
--------------------------------------------------------------------------------

Enum = {
	ItemClass = { Consumable = 0, Weapon = 2, Armor = 4 },
	AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4 },
}
NORMAL_FONT_COLOR = { WrapTextInColorCode = function(_, text) return text end }
RED_FONT_COLOR = NORMAL_FONT_COLOR
DISABLED_FONT_COLOR = { GetRGB = function() return 0.5, 0.5, 0.5 end }
for _, name in ipairs({ "STAT_CATEGORY_ATTRIBUTES", "STAT_CATEGORY_ATTACK", "STAT_CATEGORY_SPELL", "STAT_CATEGORY_DEFENSE", "STAT_CATEGORY_RESISTANCE", "TRADE_SKILLS" }) do
	_G[name] = name
end
AUCTION_HOUSE_DEFAULT_FILTERS = {}
AuctionHouseSearchContext = { BrowseAll = 1, AllFavorites = 2, BuyItems = 3, AllBids = 4 }
local chat = {}
local realPrint = print
print = function(...) chat[#chat + 1] = table.concat({ ... }, " ") end
function GetTime() return now end
function GetTimePreciseSec() return now end
function GetBuildInfo() return "1.60.1", "70205" end
function wipe(t) for key in pairs(t) do t[key] = nil end return t end
function tCompare() return true end
local errors = {}
function CallErrorHandler(message) errors[#errors + 1] = tostring(message) .. "\n" .. debug.traceback() end
function hooksecurefunc(owner, name, hook)
	local original = owner[name]
	owner[name] = function(...)
		local results = { original(...) }
		hook(...)
		return unpack(results)
	end
end

local frames = {}
function CreateFrame()
	local frame = { shown = true, events = {}, scripts = {} }
	function frame:Show() self.shown = true end
	function frame:Hide() self.shown = false end
	function frame:IsShown() return self.shown end
	function frame:SetShown(shown) self.shown = not not shown end
	function frame:SetScript(script, func) self.scripts[script] = func end
	function frame:HookScript(script, func)
		local old = self.scripts[script]
		self.scripts[script] = function(...) if old then old(...) end func(...) end
	end
	function frame:RegisterEvent(event) self.events[event] = true end
	function frame:UnregisterEvent(event) self.events[event] = nil end
	function frame:UnregisterAllEvents() self.events = {} end
	frames[#frames + 1] = frame
	return frame
end
local function FireEvent(event, ...)
	for _, frame in ipairs(frames) do
		if frame.events[event] and frame.scripts.OnEvent then
			frame.scripts.OnEvent(frame, event, ...)
		end
	end
end

Menu = { ModifyMenu = function(_, func) Menu.modify = func end }
EventUtil = { ContinueOnAddOnLoaded = function(_, func) func() end }

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------

local items = {} -- itemID -> { name, stats }
local cached = {}
local loads = {}
-- What an ending (the item key's itemSuffix) adds, in the stat table of an auction's real link.
local ENDINGS = { [500] = { ITEM_MOD_STRENGTH_SHORT = 5 } }
C_Item = {}
function C_Item.GetItemInfoInstant(itemID) return itemID, nil, nil, nil, nil, Enum.ItemClass.Armor end
function C_Item.IsItemDataCachedByID(itemID) return cached[itemID] == true end
function C_Item.RequestLoadItemDataByID(itemID)
	loads[#loads + 1] = { at = now + 0.05, itemID = itemID }
end
function C_Item.GetItemStats(link)
	local itemID, ending = link:match("^item:(%d+)"), link:match(":ending:(%d+)")
	local item = items[tonumber(itemID)]
	if not item then
		return nil
	end
	local stats = {}
	for name, amount in pairs(item.stats) do stats[name] = amount end
	for name, amount in pairs(ending and ENDINGS[tonumber(ending)] or {}) do stats[name] = (stats[name] or 0) + amount end
	return stats
end

--------------------------------------------------------------------------------
-- The server. In game: a throttled message is sent when the system is ready, and one sent
-- while it isn't waits (AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED, seen in game). ASSUMED: one
-- message at a time, answered after LATENCY, and the queue holds QUEUE_SIZE; a message beyond
-- that is dropped (..._DROPPED). ASSUMED: sending a new browse search makes HasFullBrowseResults
-- false until it is answered (Blizzard's list then shows its spinner, as its code expects).
--------------------------------------------------------------------------------

local server = { inFlight = nil, queue = {}, LATENCY = 0.3, QUEUE_SIZE = tonumber(os.getenv("QUEUE_SIZE")) or 3, PAGE = 50 }
local counts = { sent = 0, queued = 0, dropped = 0, more = 0 }
local client = { results = {}, full = true, query = nil, served = 0, itemSearch = {} }
local queries = {} -- name -> every result of that search, in the server's order
local favorites = {}

local function Send(message)
	if server.inFlight then
		if #server.queue >= server.QUEUE_SIZE then
			counts.dropped = counts.dropped + 1
			Log("DROPPED %s", message.kind)
			return
		end
		counts.queued = counts.queued + 1
		server.queue[#server.queue + 1] = message
		Log("QUEUED %s", message.kind)
	else
		counts.sent = counts.sent + 1
		message.due = now + server.LATENCY
		server.inFlight = message
		Log("SENT %s", message.kind)
	end
end

local function ServePage(all, first)
	local added = {}
	for index = first, math.min(first + server.PAGE - 1, #all) do
		added[#added + 1] = all[index]
	end
	return added
end

local function Answer(message)
	if message.kind == "browse" or message.kind == "favorites" then
		client.query = message.all
		client.results = ServePage(message.all, 1)
		client.served = #client.results
		client.full = client.served >= #message.all
		Log("ANSWER %s: %d results", message.kind, #client.results)
		FireEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
	elseif message.kind == "more" then
		if not client.query then
			return
		end
		local added = ServePage(client.query, client.served + 1)
		for _, result in ipairs(added) do client.results[#client.results + 1] = result end
		client.served = client.served + #added
		client.full = client.served >= #client.query
		Log("ANSWER more: %d results", #added)
		FireEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", added)
	elseif message.kind == "item" then
		client.itemSearch[message.key] = message.auctions
		Log("ANSWER item search")
		FireEvent("ITEM_SEARCH_RESULTS_UPDATED", message.itemKey)
		-- Blizzard: "the browse results can be updated when the player retrieves specific item
		-- and commodity results" (BrowseResultsFrame). ASSUMED: every item search does, the worst
		-- case. In game it doesn't every time: while the addon learned endings, the list never
		-- jumped to the top (2026-10-04), which every such update would make it do.
		if client.query then
			FireEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
		end
	end
end

local function ServerTick()
	local message = server.inFlight
	if message and now >= message.due then
		server.inFlight = nil
		Answer(message)
		local nextMessage = table.remove(server.queue, 1)
		if nextMessage then
			counts.sent = counts.sent + 1
			nextMessage.due = now + server.LATENCY
			server.inFlight = nextMessage
		else
			FireEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
		end
	end
end

local function KeyString(itemKey)
	return itemKey.itemID .. ":" .. itemKey.itemSuffix
end

C_AuctionHouse = {}
function C_AuctionHouse.SendBrowseQuery(query)
	client.full = false
	Send({ kind = "browse", all = queries[query.searchString] })
end
function C_AuctionHouse.SearchForFavorites()
	client.full = false
	Send({ kind = "favorites", all = favorites })
end
function C_AuctionHouse.RequestMoreBrowseResults()
	counts.more = counts.more + 1
	Send({ kind = "more" })
end
function C_AuctionHouse.IsThrottledMessageSystemReady() return server.inFlight == nil end
function C_AuctionHouse.HasFullBrowseResults() return client.full end
function C_AuctionHouse.GetBrowseResults()
	local copy = {}
	for index, result in ipairs(client.results) do copy[index] = result end
	return copy
end
function C_AuctionHouse.GetItemKeyInfo(itemKey)
	local item = items[itemKey.itemID]
	return item and { itemName = item.name }
end
function C_AuctionHouse.SendSearchQuery(itemKey)
	local link = "item:" .. itemKey.itemID .. ":ending:" .. itemKey.itemSuffix
	Send({ kind = "item", itemKey = itemKey, key = KeyString(itemKey), auctions = { { itemLink = link } } })
end
function C_AuctionHouse.HasSearchResults(itemKey) return client.itemSearch[KeyString(itemKey)] ~= nil end
function C_AuctionHouse.HasFullItemSearchResults(itemKey) return client.itemSearch[KeyString(itemKey)] ~= nil end
function C_AuctionHouse.GetNumItemSearchResults(itemKey)
	local auctions = client.itemSearch[KeyString(itemKey)]
	return auctions and #auctions or 0
end
function C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
	local auctions = client.itemSearch[KeyString(itemKey)]
	return auctions and auctions[index]
end

--------------------------------------------------------------------------------
-- Blizzard's results list (Blizzard_AuctionHouseItemList, BrowseResultsFrame)
--------------------------------------------------------------------------------

local ItemListState = { NoSearch = 1, NoResults = 2, ResultsPending = 3, ShowResults = 4 }
local ROWS_ON_SCREEN = 10
local BROWSE_SCROLL_OFFSET_REFRESH_THRESHOLD = 30

local list = { ResultsText = CreateFrame(), LoadingSpinner = CreateFrame(), isInitialized = true, scroll = 1 }
list.LoadingSpinner:Hide()
local results = { ItemList = list, browseResults = {}, searchStarted = false, shown = true }
function list:IsShown() return results.shown end
function list:SetRefreshCallback(callback) self.refreshCallback = callback end
function list:SetState(state)
	if self.state == state then
		return
	end
	self.state = state
	self.ResultsText:SetShown(state ~= ItemListState.ShowResults and state ~= ItemListState.ResultsPending)
	self.LoadingSpinner:Hide()
	if state == ItemListState.ResultsPending then
		self.LoadingSpinner:Show()
	end
end
function list:DirtyScrollFrame() self.scrollFrameDirty = true end
function list:CallRefreshCallback()
	if self.refreshCallback ~= nil then
		local lastDisplayedEntry = math.min(self.scroll + ROWS_ON_SCREEN - 1, #results.browseResults)
		self.refreshCallback(lastDisplayedEntry)
	end
end
function list:RefreshScrollFrame()
	self.scrollFrameDirty = false
	if not self.isInitialized or not self:IsShown() then
		return
	end
	if not results.searchStarted then
		self:SetState(ItemListState.NoSearch)
		return
	end
	if #results.browseResults == 0 then
		self:SetState(C_AuctionHouse.HasFullBrowseResults() and ItemListState.NoResults or ItemListState.ResultsPending)
		return
	end
	self:SetState(ItemListState.ShowResults)
	self:CallRefreshCallback()
end
function list:Reset()
	self.scroll = 1
	self:RefreshScrollFrame()
end

function results:GetNumBrowseResults() return #self.browseResults end
function results:Reset()
	self.browseResults = {}
	self.searchStarted = false
end
function results:OnBrowseSearchStarted()
	self.searchStarted = true
	self.browseResults = {}
	self.ItemList:DirtyScrollFrame()
end
function results:UpdateBrowseResults(addedBrowseResults)
	self.searchStarted = true
	if addedBrowseResults then
		for _, result in ipairs(addedBrowseResults) do self.browseResults[#self.browseResults + 1] = result end
	else
		self.browseResults = C_AuctionHouse.GetBrowseResults()
	end
	if C_AuctionHouse.HasFullBrowseResults() then
		self.ItemList:SetRefreshCallback(nil)
	else
		self.ItemList:SetRefreshCallback(function(lastDisplayEntry)
			if C_AuctionHouse.HasFullBrowseResults() then
				self.ItemList:SetRefreshCallback(nil)
			elseif self:GetNumBrowseResults() - lastDisplayEntry < BROWSE_SCROLL_OFFSET_REFRESH_THRESHOLD then
				C_AuctionHouse.RequestMoreBrowseResults()
			end
		end)
	end
	if addedBrowseResults then
		self.ItemList:DirtyScrollFrame()
	else
		self.ItemList:Reset()
	end
end
function results:SetSortOrder(sortOrder) AuctionHouseFrame:SetBrowseSortOrder(sortOrder) end

local resultsEvents = CreateFrame()
resultsEvents:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
resultsEvents:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
resultsEvents:SetScript("OnEvent", function(_, event, added)
	if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
		results:UpdateBrowseResults()
	else
		results:UpdateBrowseResults(added)
	end
end)

local filterButton = { ClearFiltersButton = CreateFrame() }
function filterButton:Reset() end
function filterButton:GetFilters() return {} end
function filterButton:GetLevelRange() return 0, 0 end
local searchBar = CreateFrame()
searchBar.FilterButton = filterButton
function searchBar:UpdateClearFiltersButton() end

AuctionHouseFrameDisplayMode = { Buy = { "BrowseResultsFrame" }, ItemBuy = { "ItemBuyFrame" } }
AuctionHouseFrame = { BrowseResultsFrame = results, SearchBar = searchBar, sorts = {}, activeSearches = {} }
function AuctionHouseFrame:SetDisplayMode(displayMode)
	if self.displayMode == displayMode then
		return
	end
	self.displayMode = displayMode
	results.shown = displayMode == AuctionHouseFrameDisplayMode.Buy
	if results.shown then
		list:RefreshScrollFrame() -- BrowseResultsFrame:OnShow
	end
end
function AuctionHouseFrame:GetDisplayMode() return self.displayMode end
function AuctionHouseFrame:GetBrowseSearchContext()
	return self.isDisplayingFavorites and AuctionHouseSearchContext.AllFavorites or AuctionHouseSearchContext.BrowseAll
end
function AuctionHouseFrame:GetSortsForContext(searchContext)
	return self.sorts[searchContext] or { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
end
function AuctionHouseFrame:SendBrowseQueryInternal(searchContext, searchString)
	self.activeSearches[searchContext] = { searchContext, searchString }
	self.isDisplayingFavorites = searchContext == AuctionHouseSearchContext.AllFavorites
	C_AuctionHouse.SendBrowseQuery({ searchString = searchString })
	self:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
end
function AuctionHouseFrame:SendBrowseQuery(searchString)
	self:SendBrowseQueryInternal(AuctionHouseSearchContext.BrowseAll, searchString)
	results:OnBrowseSearchStarted()
end
function AuctionHouseFrame:QueryAll(searchContext)
	self.activeSearches[searchContext] = { searchContext }
	self.isDisplayingFavorites = searchContext == AuctionHouseSearchContext.AllFavorites
	if searchContext == AuctionHouseSearchContext.AllFavorites then
		C_AuctionHouse.SearchForFavorites()
		results:OnBrowseSearchStarted()
		self:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
	end
end
function AuctionHouseFrame:QueryItem(searchContext, itemKey)
	self.activeSearches[searchContext] = { searchContext, itemKey }
	self.isDisplayingFavorites = false
	C_AuctionHouse.SendSearchQuery(itemKey)
end
function AuctionHouseFrame:SetBrowseSortOrder(sortOrder)
	local searchContext = self:GetBrowseSearchContext()
	local activeSearch = self.activeSearches[searchContext]
	if not activeSearch then
		return
	end
	self.sorts[searchContext] = { { sortOrder = sortOrder, reverseSort = false } }
	if searchContext == AuctionHouseSearchContext.AllFavorites then
		self:QueryAll(searchContext)
	else
		self:SendBrowseQueryInternal(unpack(activeSearch))
	end
end
AuctionHouseFrame.displayMode = AuctionHouseFrameDisplayMode.Buy

--------------------------------------------------------------------------------
-- Load the addon
--------------------------------------------------------------------------------

local ns = {}
assert(loadfile("Stats.lua"))("FindMyStats", ns)
assert(loadfile("FindMyStats.lua"))("FindMyStats", ns)

--------------------------------------------------------------------------------
-- Playing
--------------------------------------------------------------------------------

local function Tick()
	now = now + 0.05
	for index = #loads, 1, -1 do
		local load = loads[index]
		if now >= load.at then
			table.remove(loads, index)
			cached[load.itemID] = true
			FireEvent("ITEM_DATA_LOAD_RESULT", load.itemID, true)
		end
	end
	ServerTick()
	for _, frame in ipairs(frames) do
		if frame.shown and frame.scripts.OnUpdate then
			frame.scripts.OnUpdate(frame)
		end
	end
	if list.scrollFrameDirty then
		list:RefreshScrollFrame()
	end
end

-- What the player sees: "rows", "spinner", "no results" or "blank".
local function Look()
	if #results.browseResults > 0 then
		return "rows"
	elseif list.LoadingSpinner:IsShown() then
		return "spinner"
	elseif list.ResultsText:IsShown() then
		return "no results"
	end
	return "blank"
end

-- Runs the game; watch(look) is called every frame.
local function Run(seconds, watch)
	local stop = now + seconds
	while now < stop do
		Tick()
		if watch then
			watch(Look())
		end
	end
end

local function Shown()
	local names = {}
	for _, result in ipairs(results.browseResults) do
		names[#names + 1] = items[result.itemKey.itemID].name .. (result.itemKey.itemSuffix > 0 and "*" or "")
	end
	table.sort(names)
	return table.concat(names, ",")
end

local function Result(itemID, ending)
	return { itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = ending or 0, battlePetSpeciesID = 0 }, minPrice = itemID * 100 }
end

-- Items 1-9: Strength only through ending 500 (items 7-9), Intellect on 2, 4 and 9.
local function MakeItems(uncachedEvery)
	local stats = {
		{ ITEM_MOD_STAMINA_SHORT = 1 }, { ITEM_MOD_INTELLECT_SHORT = 3 }, { ITEM_MOD_STAMINA_SHORT = 2 },
		{ ITEM_MOD_INTELLECT_SHORT = 1 }, { ITEM_MOD_SPIRIT_SHORT = 1 }, { ITEM_MOD_SPIRIT_SHORT = 2 },
		{ ITEM_MOD_STAMINA_SHORT = 1 }, { ITEM_MOD_SPIRIT_SHORT = 1 }, { ITEM_MOD_INTELLECT_SHORT = 2 },
	}
	for itemID, itemStats in ipairs(stats) do
		items[itemID] = { name = "item" .. itemID, stats = itemStats }
		cached[itemID] = not uncachedEvery or itemID % uncachedEvery ~= 0
	end
	-- 200 more items with Spirit only, so pages are long, as in game (500 results a page):
	-- Blizzard's list asks for more by itself only near its end (30 rows).
	for itemID = 10, 209 do
		items[itemID] = { name = "filler" .. itemID, stats = { ITEM_MOD_SPIRIT_SHORT = 1 } }
		cached[itemID] = true
	end
	local all = {}
	for itemID = 10, 209 do all[#all + 1] = Result(itemID) end
	-- The nine items spread over the pages.
	for index, itemID in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9 }) do
		table.insert(all, index * 22, Result(itemID, itemID >= 7 and 500 or nil))
	end
	queries.everything = all
	favorites = { Result(1), Result(5), Result(9, 500) }
end

local function TickStats(stats)
	FindMyStatsDB.stats = {}
	for _, key in ipairs(stats) do FindMyStatsDB.stats[key] = true end
end

--------------------------------------------------------------------------------
-- Scenarios: each returns true when it passes, or false and why.
--------------------------------------------------------------------------------

local scenarios = {}

-- A second search, sent at any moment of the first, shows its own matches and never a wrong
-- "No results" or an empty list without its spinner.
scenarios["second search"] = function(first, uncachedEvery)
	MakeItems(uncachedEvery ~= 0 and uncachedEvery or nil)
	TickStats({ "STRENGTH" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(first)
	TickStats({ "INTELLECT" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	local wrong
	local lastLook
	Run(8, function(look)
		if os.getenv("TRACE") and look ~= lastLook then
			Log("LOOK %s (Blizzard's state %s, spinner %s, text %s)", look, tostring(list.state), tostring(list.LoadingSpinner:IsShown()), tostring(list.ResultsText:IsShown()))
			lastLook = look
		end
		if (look == "blank" or look == "no results") and not wrong then
			wrong = look .. " at " .. now
		end
	end)
	if Shown() ~= "item2,item4,item9*" then
		return false, "shown: " .. Shown()
	end
	if wrong then
		return false, "the list showed " .. wrong
	end
	return true
end

-- Without the player doing anything, the addon never queues a request behind another: every
-- page and every ending is one request at a time, and Blizzard's own asking for more pages is
-- off while the filtered list is on screen.
scenarios["one request at a time"] = function()
	MakeItems()
	TickStats({ "INTELLECT" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(15)
	if Shown() ~= "item2,item4,item9*" then
		return false, "shown: " .. Shown()
	end
	if counts.queued > 0 or counts.dropped > 0 then
		return false, string.format("%d requests queued, %d dropped, %d asked for more pages", counts.queued, counts.dropped, counts.more)
	end
	if counts.more ~= 4 then
		return false, counts.more .. " requests for more pages, 4 needed"
	end
	return true
end

-- Paging waits while the player views an item, and goes on when the list is back.
scenarios["paging waits while viewing an item"] = function()
	MakeItems()
	TickStats({ "INTELLECT" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(0.4)
	AuctionHouseFrame:QueryItem(AuctionHouseSearchContext.BuyItems, Result(2).itemKey)
	AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.ItemBuy)
	local before = counts.more
	Run(3)
	if counts.more ~= before then
		return false, "asked for more pages while the player viewed an item"
	end
	AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
	Run(10)
	if Shown() ~= "item2,item4,item9*" then
		return false, "shown after coming back: " .. Shown()
	end
	return true
end

-- Favorites stay unfiltered, also after one of them is opened and the list updates.
scenarios["favorites stay unfiltered"] = function()
	MakeItems()
	TickStats({ "INTELLECT" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(10)
	AuctionHouseFrame:QueryAll(AuctionHouseSearchContext.AllFavorites)
	Run(2)
	if Shown() ~= "item1,item5,item9*" then
		return false, "favorites shown: " .. Shown()
	end
	AuctionHouseFrame:QueryItem(AuctionHouseSearchContext.BuyItems, Result(5).itemKey)
	AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.ItemBuy)
	Run(2)
	AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
	Run(2)
	if Shown() ~= "item1,item5,item9*" then
		return false, "favorites after opening one: " .. Shown()
	end
	return true
end

-- A header click sorts the matches the other way without fetching every page again.
scenarios["re-sort"] = function()
	MakeItems()
	TickStats({ "INTELLECT" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(10)
	local before = counts.more
	results:SetSortOrder(Enum.AuctionHouseSortOrder.Name)
	Run(5)
	if Shown() ~= "item2,item4,item9*" then
		return false, "shown: " .. Shown()
	end
	if counts.more ~= before then
		return false, "fetched pages again after a re-sort"
	end
	return true
end

-- An error in the addon puts the whole list back, with Blizzard's own asking for more pages.
scenarios["error puts the list back"] = function()
	MakeItems()
	TickStats({ "INTELLECT" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(0.5)
	ns.HasAll = function() error("test error") end
	Run(10)
	if #errors ~= 1 or #chat ~= 1 then
		return false, string.format("%d errors reported, %d chat lines", #errors, #chat)
	end
	-- Everything fetched so far is back unfiltered, and Blizzard's list asks for the rest itself
	-- again when the player scrolls near its end.
	if #results.browseResults ~= client.served or not list.refreshCallback then
		return false, string.format("after the error: %d of %d results on screen, Blizzard's paging %s", #results.browseResults, client.served, tostring(list.refreshCallback))
	end
	errors = {}
	return true
end

-- The menu's title: the addon's name, and its version right-aligned in grey on the same row.
scenarios["menu title"] = function()
	local function FontString(text)
		local fontString = { text = text, points = {} }
		function fontString:GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
		function fontString:SetFont(...) self.font = { ... } end
		function fontString:SetHeight() end
		function fontString:SetPoint(point) self.points[#self.points + 1] = point end
		function fontString:SetJustifyH(justify) self.justify = justify end
		function fontString:SetTextColor(r, g, b) self.color = { r, g, b } end
		function fontString:SetText(newText) self.text = newText end
		function fontString:GetUnboundedStringWidth() return #self.text * 6 end
		return fontString
	end
	local title, initializers
	local root = {}
	function root:CreateTitle(text)
		title = text
		initializers = {}
		return { AddInitializer = function(_, initializer) initializers[#initializers + 1] = initializer end }
	end
	function root:CreateButton()
		return { CreateCheckbox = function() end, CreateDivider = function() end }
	end
	Menu.modify(nil, root)
	local attached
	local frame = { fontString = FontString(title) }
	function frame:AttachFontString() attached = FontString("") return attached end
	local width, height = initializers[1](frame)
	if title ~= "Find My Stats" then
		return false, "title " .. tostring(title)
	end
	if not (attached and attached.text:match("^v%d+%.%d+%.%d+$") and attached.justify == "RIGHT" and attached.points[1] == "RIGHT") then
		return false, "version " .. tostring(attached and attached.text)
	end
	if attached.color[1] ~= 0.5 or attached.font[2] ~= 12 or width < (#title + #attached.text) * 6 or height ~= 20 then
		return false, "version's look or the row's size"
	end
	return true
end

--------------------------------------------------------------------------------

local function Main()
	local run = scenarios[scenario]
	if not run then
		local names = {}
		for name in pairs(scenarios) do names[#names + 1] = name end
		table.sort(names)
		realPrint("scenarios: " .. table.concat(names, "; "))
		os.exit(2)
	end
	local ok, why = run(tonumber(arg[2]), tonumber(arg[3]))
	if ok and #errors > 0 then
		ok, why = false, "addon error: " .. errors[1]
	end
	if not ok then
		realPrint("FAIL  " .. scenario .. (arg[2] and (" " .. table.concat({ select(2, unpack(arg)) }, " ")) or "") .. ": " .. tostring(why))
		for _, line in ipairs(log) do realPrint("      " .. line) end
		os.exit(1)
	end
	os.exit(0)
end

Main()
