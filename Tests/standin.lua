-- A stand-in for the game around StatShopper.lua, for what Tests/run.lua can't check on its own:
-- the addon inside Blizzard's auction house, with a simulated server.
-- Run: luajit Tests/standin.lua <scenario>, in the addon folder (Tests/run.lua runs them all).
-- Exits non-zero when the scenario fails.
--
-- Blizzard's code below copies wow-ui-source (forever, 1.60.1): Shared/Blizzard_AuctionHouseFrame,
-- Blizzard_AuctionHouseBrowseResultsFrame and Blizzard_AuctionHouseItemList, and Blizzard_Menu's
-- Menu.lua, Compositor.lua, MenuTemplates.lua and MenuVariants.lua, cut to what the addon
-- touches. The widgets have only the methods Forever's widgets have (Tests/WidgetAPI.lua). The
-- server is a model; what the stand-in assumes beyond the game's code is marked ASSUMED: a
-- stand-in that behaves better than the game hides bugs.

-- This file runs under luajit, outside the game, and uses standard Lua's dofile, loadfile, os
-- and io. It plays the game, so it sets the game's globals.
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
-- Two stats' names (BlizzardInterfaceResources, GlobalStrings/enUS.lua): the menu leaves out a
-- stat the game has no name for, so these two get checkboxes.
ITEM_MOD_STRENGTH_SHORT = "Strength"
ITEM_MOD_INTELLECT_SHORT = "Intellect"
AUCTION_HOUSE_DEFAULT_FILTERS = {}
TextureKitConstants = { UseAtlasSize = true, IgnoreAtlasSize = false }
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 856 }
function PlaySound() end
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

EventUtil = { ContinueOnAddOnLoaded = function(_, func) func() end }

--------------------------------------------------------------------------------
-- Widgets. A widget has only the methods its type has in Forever (Tests/WidgetAPI.lua): any
-- other is nil, and calling it is an error, as in the game. The ones below do what the game does
-- with what the scenarios look at; any other method only records its last arguments in
-- widget.calls. Blizzard's frames are widgets with their mixins' methods as fields.
--------------------------------------------------------------------------------

local WIDGET_METHODS = {}
for widgetType, names in pairs(dofile("Tests/WidgetAPI.lua")) do
	local set = {}
	for _, name in ipairs(names) do
		set[name] = true
	end
	WIDGET_METHODS[widgetType] = set
end

local widgets = {} -- every widget, in the order made
-- The player's mouse: a button held down, and the widget it is over (see Playing).
local mouse = { down = false, over = nil, pressOnRows = false }

local Widget = {}
local recorders = {}

local function Recorder(name)
	local recorder = recorders[name]
	if not recorder then
		recorder = function(self, ...)
			self.calls[name] = { ... }
		end
		recorders[name] = recorder
	end
	return recorder
end

-- Blizzard's menu refuses some methods on what it makes (`refused`, see Blizzard's menu below):
-- as Compositor.lua's ConfigureMetatable, asking for one reports an error through the error
-- handler, and calling it reports another, without stopping the code (assertsafe).
local function Refused(name)
	CallErrorHandler(string.format("Use of function '%s' is disallowed. (Index)", name))
	return function()
		CallErrorHandler(string.format("Use of function '%s' is disallowed (Call).", name))
	end
end

local WidgetMeta = {
	__index = function(widget, key)
		local refused = rawget(widget, "refused")
		if refused and refused[key] then
			return Refused(key)
		end
		if WIDGET_METHODS[rawget(widget, "widgetType")][key] then
			return Widget[key] or Recorder(key)
		end
		return nil
	end,
}

local function NewWidget(widgetType, parent)
	assert(WIDGET_METHODS[widgetType], "no such widget type: " .. tostring(widgetType))
	local widget = setmetatable({
		widgetType = widgetType,
		parent = parent,
		children = {},
		shown = true,
		width = 0,
		height = 0,
		points = {},
		scripts = {},
		events = {},
		calls = {},
	}, WidgetMeta)
	if parent then
		parent.children[#parent.children + 1] = widget
	end
	widgets[#widgets + 1] = widget
	return widget
end

function CreateFrame(frameType, _, parent)
	return NewWidget(frameType, parent)
end

function Widget:GetObjectType()
	return self.widgetType
end
function Widget:GetParent()
	return self.parent
end
function Widget:SetParent(parent)
	if parent == self.parent then
		return
	end
	if self.parent then
		local siblings = self.parent.children
		for index = #siblings, 1, -1 do
			if siblings[index] == self then
				table.remove(siblings, index)
			end
		end
	end
	self.parent = parent
	if parent then
		parent.children[#parent.children + 1] = self
	end
end

-- Shown and visible. OnShow and OnHide run for a widget and its shown children when it becomes
-- visible or stops being visible.
function Widget:IsShown()
	return self.shown
end
function Widget:IsVisible()
	return self.shown and (self.parent == nil or self.parent:IsVisible())
end
local function RunVisibilityScripts(widget, name)
	local script = widget.scripts[name]
	if script then
		script(widget)
	end
	for _, child in ipairs(widget.children) do
		if child.shown then
			RunVisibilityScripts(child, name)
		end
	end
end
function Widget:SetShown(shown)
	shown = not not shown
	if shown == self.shown then
		return
	end
	local parentVisible = self.parent == nil or self.parent:IsVisible()
	self.shown = shown
	if parentVisible then
		RunVisibilityScripts(self, shown and "OnShow" or "OnHide")
	end
end
function Widget:Show()
	self:SetShown(true)
end
function Widget:Hide()
	self:SetShown(false)
end

function Widget:SetScript(name, func)
	self.scripts[name] = func
end
function Widget:GetScript(name)
	return self.scripts[name]
end
function Widget:HookScript(name, func)
	local old = self.scripts[name]
	self.scripts[name] = old and function(...)
		old(...)
		func(...)
	end or func
end

-- Events reach every frame registered for them, shown or not, in the order the frames were made.
function Widget:RegisterEvent(event)
	self.events[event] = true
end
function Widget:UnregisterEvent(event)
	self.events[event] = nil
end
function Widget:UnregisterAllEvents()
	self.events = {}
end
function Widget:IsEventRegistered(event)
	return self.events[event] == true
end
local function FireEvent(event, ...)
	for _, widget in ipairs(widgets) do
		local onEvent = widget.scripts.OnEvent
		if widget.events[event] and onEvent then
			onEvent(widget, event, ...)
		end
	end
end

-- Anchors: kept as given. A point set again replaces its earlier anchor, as in the game.
function Widget:SetPoint(point, a, b, c, d)
	local relativeTo, relativePoint, x, y = self.parent, point, 0, 0
	if type(a) == "number" then
		x, y = a, b or 0
	elseif a ~= nil then
		relativeTo = a
		if type(b) == "string" then
			relativePoint, x, y = b, c or 0, d or 0
		elseif type(b) == "number" then
			x, y = b, c or 0
		end
	end
	local anchor = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
	for index, old in ipairs(self.points) do
		if old.point == point then
			self.points[index] = anchor
			return
		end
	end
	self.points[#self.points + 1] = anchor
end
function Widget:SetAllPoints(relativeTo)
	self:SetPoint("TOPLEFT", relativeTo or self.parent, "TOPLEFT")
	self:SetPoint("BOTTOMRIGHT", relativeTo or self.parent, "BOTTOMRIGHT")
end
function Widget:ClearAllPoints()
	self.points = {}
end
-- ASSUMED: the stand-in does no layout; a widget is the size it was last given.
function Widget:SetSize(width, height)
	self.width, self.height = width, height
end
function Widget:SetWidth(width)
	self.width = width
end
function Widget:SetHeight(height)
	self.height = height
end
function Widget:GetWidth()
	return self.width
end
function Widget:GetHeight()
	return self.height
end
function Widget:GetSize()
	return self.width, self.height
end
-- A frame without a strata of its own is on its parent's.
function Widget:SetFrameStrata(strata)
	self.strata = strata
end
function Widget:GetFrameStrata()
	return self.strata or (self.parent and self.parent:GetFrameStrata()) or "MEDIUM"
end

-- The mouse.
function Widget:SetMouseClickEnabled(enabled)
	self.mouseClick = enabled
end
function Widget:SetMouseMotionEnabled(enabled)
	self.mouseMotion = enabled
end
function Widget:EnableMouse(enabled)
	self.mouseClick, self.mouseMotion = enabled, enabled
end
function Widget:IsMouseClickEnabled()
	return self.mouseClick == true
end
function Widget:IsMouseMotionEnabled()
	return self.mouseMotion == true
end
function Widget:RegisterForClicks(...)
	self.clicks = { ... }
end
-- ASSUMED: a widget's children lie inside it, so the mouse over a child is over the widget too.
function Widget:IsMouseOver()
	local over = mouse.over
	while over do
		if over == self then
			return true
		end
		over = over.parent
	end
	return false
end

-- Text. ASSUMED: a glyph is 6 wide in every font; the scenarios only compare widths.
function Widget:SetText(text)
	self.text = text
end
function Widget:GetText()
	return self.text
end
function Widget:GetUnboundedStringWidth()
	return #(self.text or "") * 6
end
function Widget:SetTextToFit(text)
	self.text = text
	self.width = self:GetUnboundedStringWidth()
end
function Widget:SetFontObject(fontObject)
	self.fontObject = fontObject
end
function Widget:SetTextColor(r, g, b, a)
	self.color = { r, g, b, a }
end
function Widget:SetJustifyH(justify)
	self.justifyH = justify
end

-- Textures. ASSUMED: every atlas is 16 by 16; the scenarios only compare positions.
function Widget:SetAtlas(atlas, useAtlasSize)
	self.atlas = atlas
	if useAtlasSize then
		self.width, self.height = 16, 16
	end
end
function Widget:SetTexture(file)
	self.file = file
end
function Widget:SetDrawLayer(layer, level)
	self.layer, self.level = layer, level or 0
end
function Widget:GetDrawLayer()
	return self.layer or "ARTWORK", self.level or 0
end

-- What it resets is in Blizzard's comments (Compositor.lua, MenuTemplates.lua): anchors cleared,
-- size 0 by 0, scripts removed and a button's state wiped; and, seen in game, hidden (1.2.0's
-- first build attached buttons without showing them again, and the row stayed empty). ASSUMED:
-- the mouse off, the strata MEDIUM, and no text or art.
function Widget:SetToDefaults()
	self.points, self.width, self.height, self.scripts = {}, 0, 0, {}
	self.shown = false
	self.mouseClick, self.mouseMotion, self.clicks = false, false, nil
	self.strata = "MEDIUM"
	self.text, self.atlas, self.file = nil, nil, nil
end

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
local counts = { sent = 0, queued = 0, dropped = 0, more = 0, rebuilds = 0, lostClicks = 0 }
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
-- Blizzard's auction house frames: Blizzard_AuctionHouseFrame.xml, its SearchBar (with the
-- Filter button, a DropdownButton: an intrinsic Button, Blizzard_Menu/DropdownButton.xml), and
-- the results list (BrowseResultsFrame, its ItemList: Mainline/Blizzard_AuctionHouseItemList.xml).
-- The auction house is open on its results list.
--------------------------------------------------------------------------------

local ItemListState = { NoSearch = 1, NoResults = 2, ResultsPending = 3, ShowResults = 4 }
local ROWS_ON_SCREEN = 10
local BROWSE_SCROLL_OFFSET_REFRESH_THRESHOLD = 30

AuctionHouseFrame = NewWidget("Frame")
local searchBar = NewWidget("Frame", AuctionHouseFrame)
local filterButton = NewWidget("Button", searchBar)
filterButton.ClearFiltersButton = NewWidget("Button", filterButton)
local results = NewWidget("Frame", AuctionHouseFrame)
local list = NewWidget("Frame", results)
local scrollBox = NewWidget("Frame", list)
list.ScrollBox = scrollBox
list.ResultsText = NewWidget("FontString", list)
list.LoadingSpinner = NewWidget("Frame", list)
local itemBuy = NewWidget("Frame", AuctionHouseFrame)
AuctionHouseFrame.BrowseResultsFrame, AuctionHouseFrame.SearchBar, AuctionHouseFrame.ItemBuyFrame = results, searchBar, itemBuy
searchBar.FilterButton = filterButton
results.ItemList = list
-- Hidden in the XML, and not shown yet.
list.ResultsText:Hide()
list.LoadingSpinner:Hide()
filterButton.ClearFiltersButton:Hide()
itemBuy:Hide()

-- The player's mouse (`mouse`): a press on a row is a click once let go, unless the rows were
-- rebuilt meanwhile. ASSUMED: a rebuild while the button is held loses the click, as it releases
-- the row being pressed and makes it again (the cause suspected of a first click that didn't
-- open an item, 2026-10-13; not measured in game).
function IsMouseButtonDown() return mouse.down end

-- The rows on screen: the scroll box shows ROWS_ON_SCREEN rows from `scroll`, out of the data it
-- was given at its last rebuild (`dataSize`); an empty list has none (SetState removes its data
-- provider).
list.isInitialized, list.scroll, list.dataSize = true, 1, 0
function scrollBox:GetDataIndexBegin() return list.dataSize > 0 and list.scroll or 0 end
function scrollBox:GetDataIndexEnd() return list.dataSize > 0 and math.min(list.scroll + ROWS_ON_SCREEN - 1, list.dataSize) or 0 end
results.browseResults, results.searchStarted = {}, false
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
	if state ~= ItemListState.ShowResults then
		self.dataSize = 0 -- self.ScrollBox:RemoveDataProvider()
	end
end
function list:DirtyScrollFrame() self.scrollFrameDirty = true end
function list:CallRefreshCallback()
	if self.refreshCallback ~= nil then
		local lastDisplayedEntry = self.ScrollBox:GetDataIndexEnd()
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
	-- self.ScrollBox:SetDataProvider(CreateIndexRangeDataProvider(numResults), RetainScrollPosition):
	-- every row on screen is released and made again.
	self.dataSize = #results.browseResults
	self.scroll = math.max(1, math.min(self.scroll, self.dataSize))
	counts.rebuilds = counts.rebuilds + 1
	if mouse.down and mouse.pressOnRows then
		counts.lostClicks = counts.lostClicks + 1
	end
	self:CallRefreshCallback()
end
-- The player scrolls: the first row on screen becomes `row` (OnScrollBoxScroll).
local function ScrollTo(row)
	list.scroll = math.max(1, math.min(row, list.dataSize))
	list:CallRefreshCallback()
end
function list:Reset()
	self.scroll = 1
	self:RefreshScrollFrame()
end
-- OnShow without Init and the table's layout, which the stand-in leaves out.
function list:OnShow() self:RefreshScrollFrame() end
function list:OnUpdate()
	if self.scrollFrameDirty then
		self:RefreshScrollFrame()
	end
end
list:SetScript("OnShow", list.OnShow)
list:SetScript("OnUpdate", list.OnUpdate)

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
-- OnShow without the auction house's callbacks, which the stand-in leaves out.
function results:OnShow() self.ItemList:RefreshScrollFrame() end
function results:OnEvent(event, added)
	if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
		self:UpdateBrowseResults()
	else
		self:UpdateBrowseResults(added)
	end
end
results:SetScript("OnShow", results.OnShow)
results:SetScript("OnEvent", results.OnEvent)
-- OnLoad: the browse results can change while the list isn't on screen.
results:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
results:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")

-- The red X starts hidden, and Blizzard's Reset (its click) hides it again
-- (AuctionHouseFilterButtonMixin:Reset).
function filterButton:Reset() self.ClearFiltersButton:Hide() end
function filterButton:GetFilters() return {} end
function filterButton:GetLevelRange() return 0, 0 end
function searchBar:UpdateClearFiltersButton() end

AuctionHouseFrameDisplayMode = { Buy = { "BrowseResultsFrame" }, ItemBuy = { "ItemBuyFrame" } }
AuctionHouseFrame.sorts, AuctionHouseFrame.activeSearches = {}, {}
-- Without the selling and token modes, tabs, dialogs and popups.
function AuctionHouseFrame:SetDisplayMode(displayMode)
	if self.displayMode == displayMode then
		return
	end
	self.displayMode = displayMode
	local subframesToUpdate = {}
	for _, mode in pairs(AuctionHouseFrameDisplayMode) do
		for _, subframe in ipairs(mode) do
			subframesToUpdate[subframe] = subframesToUpdate[subframe] or mode == displayMode
		end
	end
	for subframe, shouldShow in pairs(subframesToUpdate) do
		if not shouldShow then
			self[subframe]:Hide()
		end
	end
	for i = 1, #displayMode do
		self[displayMode[i]]:Show()
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
-- Blizzard's menu (Blizzard_Menu), cut to the rows the addon adds to the Filter menu: when the
-- menu opens it makes each row's frame and calls the row's initializers on it. A frame the menu
-- makes refuses the methods that would make regions it doesn't know of, and text attached to it
-- refuses SetFont (1.0.0 and 1.0.1 called it: an error each time the menu opened).
--------------------------------------------------------------------------------

Menu = { ModifyMenu = function(_, func) Menu.modify = func end }

-- Compositor.lua: the methods refused on what the menu makes.
local FRAME_REFUSALS = { SetForbidden = true, CreateTexture = true, CreateMaskTexture = true, CreateFontString = true, CreateAnimationGroup = true, CreateLine = true }
local FONT_STRING_REFUSALS = { SetFont = true }
local REGION_REFUSALS = {}

local Compositor = {}

-- ConfigureMetatable: what the menu makes refuses some methods, and a frame can attach
-- textures, text and frames (frameRedirectFunctions), which the menu releases when it closes.
local function Configure(region)
	local objectType = region:GetObjectType()
	if objectType == "FontString" then
		region.refused = FONT_STRING_REFUSALS
	elseif objectType == "Texture" then
		region.refused = REGION_REFUSALS
	else
		region.refused = FRAME_REFUSALS
		region.AttachTexture = Compositor.AttachTexture
		region.AttachFontString = Compositor.AttachFontString
		region.AttachFrame = Compositor.AttachFrame
	end
	return region
end

-- CreateWithPool, with SetTextureToDefaults and SetFontStringToDefaults. ASSUMED: each comes new
-- from its pool (a reused one is reset the same way first).
function Compositor.AttachTexture(parent)
	local texture = NewWidget("Texture", parent)
	texture:SetToDefaults()
	texture:SetSize(1, 1)
	texture:SetDrawLayer("ARTWORK")
	Configure(texture)
	texture:Show()
	return texture
end
function Compositor.AttachFontString(parent)
	local fontString = NewWidget("FontString", parent)
	fontString:SetToDefaults()
	fontString:SetSize(1, 1)
	fontString:SetFontObject("GameFontHighlight")
	fontString:SetTextColor(1, 1, 1, 1)
	fontString:SetWidth(150)
	fontString:SetMaxLines(1)
	fontString:SetJustifyH("LEFT")
	fontString:SetJustifyV("MIDDLE")
	Configure(fontString)
	fontString:Show()
	return fontString
end
-- AcquireFrame (shown), then Configure with SetFrameToDefaults (hidden again).
function Compositor.AttachFrame(parent, frameType)
	local frame = NewWidget(frameType, parent)
	frame:SetParent(parent)
	frame:SetFrameStrata(parent:GetFrameStrata())
	frame:Show()
	frame:SetToDefaults()
	frame:SetSize(1, 1)
	return Configure(frame)
end

-- MenuTemplates.lua's local delegate. ASSUMED: it calls the frame's own SetPropagateMouseMotion
-- (CreateSecureDelegate isn't in wow-ui-source).
local function SetPropagateMouseMotionDelegate(frame, propagate)
	frame:SetPropagateMouseMotion(propagate)
end

-- Copied from Blizzard_Menu/MenuTemplates.lua (forever).
MenuTemplates = {}
function MenuTemplates.AttachBasicButton(parent, width, height)
	local button = parent:AttachFrame("Button")
	button:SetFrameStrata(parent:GetFrameStrata()) -- Machinery is broken.

	-- SetToDefaults wipes button state, desired states must be explicitly set now.
	button:Show()

	SetPropagateMouseMotionDelegate(button, true)

	button:SetMouseClickEnabled(true)
	button:SetMouseMotionEnabled(true)
	button:SetSize(width or 16, height or 16)

	return button
end

-- MenuTemplates.CreateTitle's initializer, with MenuVariants.CreateFontString.
local function TitleInitializer(text)
	return function(frame)
		local fontString = frame:AttachFontString()
		fontString:SetPoint("LEFT")
		fontString:SetHeight(20)
		frame.fontString = fontString
		fontString:SetTextToFit(text)
	end
end

-- Errors from the addon's code that reached Blizzard's menu.
local menuErrors = 0

-- The menu calls what an addon gives it through securecallfunction and secureexecuterange
-- (Menu.lua: the Menu.ModifyMenu callbacks, each initializer, a checkbox's responder). ASSUMED
-- (they are C functions, not in wow-ui-source): an error goes to the error handler, and the menu
-- goes on as if the call returned nothing.
local function Rest(_, ...)
	return ...
end
local function MenuCall(func, ...)
	return Rest(xpcall(func, function(message)
		menuErrors = menuErrors + 1
		CallErrorHandler(message)
	end, ...))
end

-- The Filter menu opens with the addon's rows (Menu.ModifyMenu). The menu (Menu.lua, on the
-- FULLSCREEN_DIALOG strata) makes a frame for each title and frame row, sizes it 1 by 1, and
-- calls its initializers: the row's own first, then the ones added to it; the last size one
-- returns is the row's (CallInitializers). The stat submenus are Blizzard's own buttons and
-- checkboxes, left out; each checkbox is kept as { text, isSelected, setSelected, data }.
-- Returns the rows ({ kind, frame, width, height }) and the checkboxes.
local function OpenFilterMenu()
	local rows = {}
	local checkboxes = {}
	local function Row(kind, initializer)
		local row = { kind = kind, initializers = { initializer } }
		function row:AddInitializer(func) self.initializers[#self.initializers + 1] = func end
		rows[#rows + 1] = row
		return row
	end
	local submenu = {}
	function submenu:CreateCheckbox(text, isSelected, setSelected, data)
		checkboxes[#checkboxes + 1] = { text = text, isSelected = isSelected, setSelected = setSelected, data = data }
	end
	function submenu:CreateDivider() end
	local root = {}
	function root:CreateTitle(text) return Row("title", TitleInitializer(text)) end
	function root:CreateFrame() return Row("frame", function() end) end
	function root:CreateButton() return submenu end
	MenuCall(Menu.modify, nil, root)
	local menu = NewWidget("Frame")
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	for _, row in ipairs(rows) do
		local frame = Configure(NewWidget("Frame", menu))
		frame:SetSize(1, 1)
		for _, initializer in ipairs(row.initializers) do
			local width, height = MenuCall(initializer, frame)
			if width and height then
				row.width, row.height = width, height
			end
		end
		row.frame = frame
	end
	return rows, checkboxes
end

-- A checkbox in a stat submenu: drawn (its initializer asks whether it is ticked:
-- MenuTemplates.CreateSelectionTextures) and clicked (Pick calls its responder).
local function DrawCheckbox(checkbox)
	return MenuCall(checkbox.isSelected, checkbox.data)
end
local function ClickCheckbox(checkbox)
	MenuCall(checkbox.setSelected, checkbox.data)
end

-- What is attached to a frame of the menu, of one type, in the order attached.
local function Attached(frame, objectType)
	local found = {}
	for _, child in ipairs(frame.children) do
		if child:GetObjectType() == objectType then
			found[#found + 1] = child
		end
	end
	return found
end

--------------------------------------------------------------------------------
-- Load the addon
--------------------------------------------------------------------------------

local ns = {}
assert(loadfile("Stats.lua"))("StatShopper", ns)
assert(loadfile("StatShopper.lua"))("StatShopper", ns)

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
	-- Each visible frame's OnUpdate. ASSUMED: in the order the frames were made, so Blizzard's
	-- list (redrawing when marked) goes before the addon's frames.
	for _, widget in ipairs(widgets) do
		local onUpdate = widget.scripts.OnUpdate
		if onUpdate and widget:IsVisible() then
			onUpdate(widget, 0.05)
		end
	end
end

-- The player presses the mouse button on the list (on a row, if there are rows), or lets it go.
local function Press()
	mouse.down, mouse.over, mouse.pressOnRows = true, scrollBox, list.dataSize > 0
end
local function Release()
	mouse.down, mouse.pressOnRows = false, false
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

local function TickStats(stats, matchAny)
	StatShopperDB.stats = {}
	for _, key in ipairs(stats) do StatShopperDB.stats[key] = true end
	StatShopperDB.matchAny = matchAny == true
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

-- The menu's title: the addon's name, and its version right-aligned in grey on the same row, in
-- the title's font: attached text, which refuses SetFont.
scenarios["menu title"] = function()
	local rows = OpenFilterMenu()
	local title = rows[1]
	if not (title and title.kind == "title") then
		return false, "the addon's rows don't start with a title"
	end
	local texts = Attached(title.frame, "FontString")
	local name, version = texts[1], texts[2]
	if #texts ~= 2 or name ~= title.frame.fontString or name:GetText() ~= "Stat Shopper" then
		return false, "title " .. tostring(name and name:GetText())
	end
	local text = version:GetText() or ""
	if not (text:match("^v%d+%.%d+%.%d+$") and version.justifyH == "RIGHT" and version.points[1] and version.points[1].point == "RIGHT") then
		return false, "version " .. text
	end
	if version.color[1] ~= 0.5 or version.fontObject ~= name.fontObject or title.width < (#name:GetText() + #text) * 6 or title.height ~= 20 then
		return false, "version's look or the row's size"
	end
	return true
end

-- Match any: a search finds items with at least one ticked stat; Match all, only those with
-- every one. The choice of the moment a search is sent counts, as the ticks do.
scenarios["match any"] = function()
	MakeItems()
	TickStats({ "INTELLECT", "STAMINA" }, true)
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(15)
	if Shown() ~= "item1,item2,item3,item4,item7*,item9*" then
		return false, "match any shows: " .. Shown()
	end
	StatShopperDB.matchAny = false
	results:SetSortOrder(Enum.AuctionHouseSortOrder.Name)
	Run(5)
	if Shown() ~= "item1,item2,item3,item4,item7*,item9*" then
		return false, "after a re-sort with Match all chosen but not searched: " .. Shown()
	end
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(15)
	if Shown() ~= "" then
		return false, "match all shows: " .. Shown()
	end
	return true
end

-- The row under the title: Match all and Match any side by side, built from what Blizzard's menu
-- attaches (frames, textures and text; CreateTexture and CreateFontString are refused on the
-- menu's frames, SetFont on attached text). A click moves the tick. The red X shows while Match
-- any is chosen, also with nothing ticked, and goes back to Match all.
scenarios["match choice"] = function()
	TickStats({})
	local rows = OpenFilterMenu()
	local own = {}
	for _, row in ipairs(rows) do
		if row.kind == "frame" then
			own[#own + 1] = row
		end
	end
	if #own ~= 1 then
		return false, #own .. " rows of the addon's own"
	end
	local row = own[1]
	local buttons = Attached(row.frame, "Button")
	local all, any = buttons[1], buttons[2]
	local function Text(button)
		local text = Attached(button, "FontString")[1]
		return text and text:GetText()
	end
	if #row.frame.children ~= 2 or #buttons ~= 2 or Text(all) ~= "Match all" or Text(any) ~= "Match any" then
		return false, "the row's choices"
	end
	local function TickMark(button)
		for _, texture in ipairs(Attached(button, "Texture")) do
			if texture.atlas == "common-dropdown-icon-radialtick-yellow" then
				return texture
			end
		end
	end
	if not (TickMark(all) and TickMark(any) and TickMark(all):IsShown() and not TickMark(any):IsShown()) then
		return false, "Match all isn't the one ticked at first"
	end
	if any.points[1].x < all.points[1].x + all:GetWidth() or row.width < any.points[1].x + any:GetWidth() or row.height ~= 20 then
		return false, "the choices aren't side by side inside the row"
	end
	for _, button in ipairs(buttons) do
		if not (button:IsShown() and button:GetFrameStrata() == row.frame:GetFrameStrata()) then
			return false, "a choice isn't shown with the menu"
		end
		if not (button:IsMouseClickEnabled() and button:IsMouseMotionEnabled() and button:GetScript("OnClick") and button:GetScript("OnEnter") and button:GetScript("OnLeave")) then
			return false, "a choice can't be clicked or highlighted"
		end
	end
	local x = filterButton.ClearFiltersButton
	any:GetScript("OnClick")(any, "LeftButton")
	if StatShopperDB.matchAny ~= true or TickMark(all):IsShown() or not TickMark(any):IsShown() then
		return false, "clicking Match any"
	end
	if not x:IsShown() then
		return false, "no red X with Match any chosen and nothing ticked"
	end
	all:GetScript("OnClick")(all, "LeftButton")
	if StatShopperDB.matchAny ~= false or x:IsShown() then
		return false, "back to Match all with nothing ticked: the red X stayed"
	end
	-- The red X (Blizzard's Reset on the Filter button, hooked).
	TickStats({ "STRENGTH" })
	any:GetScript("OnClick")(any, "LeftButton")
	x:Show()
	filterButton:Reset()
	if StatShopperDB.matchAny ~= false or next(StatShopperDB.stats) or x:IsShown() then
		return false, "the red X left Match any, a tick or itself"
	end
	return true
end

-- An error inside the addon's rows of the menu is the addon's: reported once and said once in
-- chat, it never reaches Blizzard's menu. What is left of the rows then does nothing: the choices
-- don't change or light up, every stat shows unticked and a click changes nothing. The menu opens
-- again without the addon's rows.
scenarios["menu error"] = function()
	TickStats({ "STRENGTH" })
	local _, checkboxes = OpenFilterMenu()
	local strength
	for _, checkbox in ipairs(checkboxes) do
		if checkbox.data == "STRENGTH" then
			strength = checkbox
		end
	end
	if not strength or DrawCheckbox(strength) ~= true then
		return false, "Strength isn't ticked before the error"
	end
	-- The second choice of the Match row fails to attach, after the first is built.
	local attach, attached = MenuTemplates.AttachBasicButton, 0
	MenuTemplates.AttachBasicButton = function(...)
		attached = attached + 1
		if attached == 2 then
			error("test error")
		end
		return attach(...)
	end
	local rows
	rows, checkboxes = OpenFilterMenu()
	MenuTemplates.AttachBasicButton = attach
	if menuErrors > 0 then
		return false, menuErrors .. " errors reached Blizzard's menu"
	end
	if #errors ~= 1 or #chat ~= 1 then
		return false, string.format("%d errors reported, %d chat lines", #errors, #chat)
	end
	local matchRow = rows[2]
	local all = matchRow and Attached(matchRow.frame, "Button")[1]
	if not all then
		return false, "the error came before the first choice was attached"
	end
	if matchRow.width then
		return false, "the Match row still gave the menu its size"
	end
	local highlight
	for _, texture in ipairs(Attached(all, "Texture")) do
		if texture.file == "Interface\\QuestFrame\\UI-QuestTitleHighlight" then
			highlight = texture
		end
	end
	StatShopperDB.matchAny = true
	all:GetScript("OnEnter")(all)
	all:GetScript("OnClick")(all, "LeftButton")
	all:GetScript("OnLeave")(all)
	if not highlight or highlight:IsShown() or StatShopperDB.matchAny ~= true then
		return false, "Match all lit up or changed the choice after the error"
	end
	for _, checkbox in ipairs(checkboxes) do
		if DrawCheckbox(checkbox) ~= false then
			return false, checkbox.text .. " doesn't show unticked after the error"
		end
	end
	ClickCheckbox(strength)
	if StatShopperDB.stats.STRENGTH ~= true then
		return false, "a click on Strength changed the ticks after the error"
	end
	rows = OpenFilterMenu()
	if #rows > 0 or menuErrors > 0 or #errors ~= 1 or #chat ~= 1 then
		return false, string.format("opened again: %d rows of the addon's, %d more errors", #rows, #errors - 1 + menuErrors)
	end
	errors = {}
	return true
end

-- While the player looks at the top of a long list, the rows on screen are never rebuilt: the
-- pages that arrive add matches far below, which show as the player scrolls toward them, like
-- the pages Blizzard's own list loads. ASSUMED for this scenario: the server sends the results
-- in the order of the search's sort (Price), as Blizzard's list, which never sorts, expects.
-- The ending is learned already (once per account and game build): the answer to an item search
-- can make Blizzard's list start over by itself (see Answer), which the addon doesn't control.
local function LearnEnding()
	StatShopperAccountDB.endings[500] = { ITEM_MOD_STRENGTH_SHORT = true }
end

scenarios["list stays still"] = function()
	MakeItems()
	LearnEnding()
	local sorted = {}
	for _, result in ipairs(queries.everything) do sorted[#sorted + 1] = result end
	table.sort(sorted, function(a, b) return a.minPrice < b.minPrice end)
	queries.sorted = sorted
	TickStats({ "SPIRIT" })
	AuctionHouseFrame:SendBrowseQuery("sorted")
	Run(1)
	if #results.browseResults < ROWS_ON_SCREEN then
		return false, "first page: " .. #results.browseResults .. " rows"
	end
	local top = {}
	for row = 1, ROWS_ON_SCREEN do top[row] = results.browseResults[row] end
	local before = counts.rebuilds
	Run(15)
	if counts.rebuilds ~= before then
		return false, (counts.rebuilds - before) .. " rebuilds while the player looked at the top"
	end
	if counts.more ~= 4 then
		return false, counts.more .. " requests for more pages, 4 needed"
	end
	-- Scrolling toward the end shows the rest, and the rows above don't move.
	ScrollTo(list.dataSize - ROWS_ON_SCREEN + 1)
	Run(0.5)
	local spirit = 0
	for _, item in pairs(items) do
		if item.stats.ITEM_MOD_SPIRIT_SHORT then spirit = spirit + 1 end
	end
	if #results.browseResults ~= spirit then
		return false, string.format("after scrolling down: %d of %d matches", #results.browseResults, spirit)
	end
	for row = 1, ROWS_ON_SCREEN do
		if results.browseResults[row] ~= top[row] then
			return false, "row " .. row .. " moved"
		end
	end
	return true
end

-- A click on a row is never lost: while the player holds the button on a row, the rows aren't
-- rebuilt; the list catches up once the button is let go. The player clicks again and again
-- while a short list fills in. The ending is learned already, as in "list stays still".
scenarios["clicks are never lost"] = function()
	MakeItems(3)
	LearnEnding()
	TickStats({ "INTELLECT" })
	AuctionHouseFrame:SendBrowseQuery("everything")
	Run(0.5)
	for _ = 1, 50 do
		Press()
		Run(0.15)
		Release()
		Run(0.15)
	end
	Run(5)
	if counts.lostClicks > 0 then
		return false, counts.lostClicks .. " clicks lost to a rebuild"
	end
	if Shown() ~= "item2,item4,item9*" then
		return false, "shown: " .. Shown()
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
