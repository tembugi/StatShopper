# Find My Stats

Rules for this addon. The shared rules are in `../AGENTS.md`.

Stat filters for the auction house: the player ticks stats in the auction house's own Filter menu, and a search shows only gear that raises every ticked stat. Agreed with the user (2026-10-03).

The name is "Find My Stats" (the user's choice; `ADDON_TITLE` in the code, also the start of chat lines). Folder, repo (`tembugi/FindMyStats`, private) and packages are `FindMyStats`. CurseForge project ID: none yet. Design canvas: https://claude.ai/artifact/U3xXPZ79hi25vV1sm17YH6

## Look

- A "Stats" title (`PET_BATTLE_STATS_LABEL`) at the end of Blizzard's Filter dropdown, after the spacer Blizzard queues behind its last group, then one submenu per stat group with the game's checkboxes. Added with `Menu.ModifyMenu("MENU_AUCTION_HOUSE_SEARCH_FILTER")`. Every label is a game string (`STAT_CATEGORY_*`, `ITEM_MOD_*_SHORT`).
- 0.1.0 has the Attributes group only (Strength, Agility, Stamina, Intellect, Spirit): a test round for the approach, above all buying from a filtered list. After it passes, the plan is all the stats Forever's gear has, in groups as on the canvas: Melee, Ranged, Spell, Defense, Resistances, Weapon Skills.
- The red X on the Filter button shows while any stat is ticked, as it does for Blizzard's own filters, and clicking it unticks them too.
- Nothing else on screen and no chat lines in normal use.
- Look changes are mocked on the design canvas first and built after the user picks.

## Filtering (agreed with the user)

- An item must raise every ticked stat ("all of them"). Raising means the game's line for the stat with a plus sign and a number above zero. No minimum amounts.
- Ticks apply when a search is sent, like Blizzard's own filters: a search keeps the stats it was sent with (also when it is re-sorted), and changing ticks changes nothing until the next search.
- Favorites (the star button, and the list the auction house opens with) are never filtered, as Blizzard's filters don't apply to them.
- Ticks are saved per character, like the auction house's own filters (`SavedVariablesPerCharacter`).
- The server can't filter by stats, so the addon filters the browse results it gets. Each result is one item with its random suffix ("of the Bear"). Its stats are read from the tooltip the auction house shows for that row (`C_TooltipInfo.GetItemKey` with the arguments Blizzard passes to `SetItemKey`), matching each whole line against the game's own format for the stat (`ITEM_MOD_STRENGTH` = "%c%s Strength"). Every locale writes the sign and then the number, so this works in all of them.
- Only weapons and armor can match (`C_Item.GetItemInfoInstant` class). A recipe's tooltip shows the stats of the item it makes.
- How the list changes: a `hooksecurefunc` on the results frame's `UpdateBrowseResults` takes each page of results into the search's collection (one entry per item key: item, item level, random suffix) and hands the frame the matching ones (`browseResults`), then redraws its list (`ItemList:RefreshScrollFrame`).
- Every page: the server sends results in pages, and Blizzard's list asks for the next one only while it shows few results. Filtering and sorting need them all, so after each page the addon asks for the next (`C_AuctionHouse.RequestMoreBrowseResults`) when the auction house's throttle is ready (`IsThrottledMessageSystemReady`, else `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`), until `HasFullBrowseResults`. This continues the player's own search, as scrolling to the end would; the addon sends no searches of its own.
- Never stalling: items are read a little each frame (`FRAME_BUDGET_MS`, 4 ms), and at most 30 items' data is asked for at a time (`MAX_ITEM_LOADS`); the rest wait their turn. An item whose data isn't loaded waits for `ITEM_DATA_LOAD_RESULT`; one whose load fails stays out of that search. Stats and names are cached for the session by item key. The list redraws at most every 0.25 s while matches still come in. 0.1.0 read every result and asked about every unknown item in one frame, and a whole-auction-house search froze the game for seconds (the user's test, 2026-10-03).
- Sorting: the addon sorts the matches itself, by Blizzard's own sorts for the search (`GetSortsForContext(GetBrowseSearchContext())`: up to two of Price (`minPrice`) and Name (the item key's `itemName`), each possibly reversed), ties by arrival. A header click (`hooksecurefunc` on the results frame's `SetSortOrder`) sorts the matches at once; Blizzard's re-sent search merges in (fresher prices) instead of starting over, and once every page has arrived it fetches no pages again. 0.1.0 showed pages in arrival order and restarted on every re-sort, so the user never saw a sorted list.
- Empty list: Blizzard's list shows "No results" once every page is in, even while the addon still reads items. Until the addon is done, it shows Blizzard's own loading spinner (`ItemList.LoadingSpinner`) in its place, then puts "No results" back if nothing matched.
- A new search (`SendBrowseQuery` hook), favorites or a closed auction house ends the collection; the addon only ever changes the list it handed over.

## Taint

- The filtered list is the addon's table, so while a filtered list is on screen, Blizzard's results list and what a click on a row starts (the item's buy page) run tainted. Nothing in the auction house API is protected: `IsProtectedFunction` marks only widget methods, and `PlaceBid` and `StartCommoditiesPurchase` carry `HasRestrictions`, like `SendChatMessage`. Buying from a filtered list is the main thing to test: watch for "action blocked" and read `Logs/taint.log`.
- The menu entries use `Menu.ModifyMenu`, which Blizzard made for addons.
- The X follows Blizzard's rule by reading the Filter button (`GetFilters`, `GetLevelRange`), never by calling `UpdateClearFiltersButton`, which writes Blizzard's saved filters.

## Chat and errors

- Lines start with "Find My Stats:" in gold. The addon writes only when something stopped working: what stopped in red, then what the player can do.
- When the auction house loads, the addon checks the Blizzard pieces it plugs into. If one is missing, it says so once (with its version) and adds nothing.
- Every hook and handler runs through `Guarded` (`xpcall` with `CallErrorHandler`), so an error never breaks Blizzard's code. The first error is reported, said once in chat, the search's full list goes back on screen, and the filters stay off until /reload.

## Tests

`luajit Tests/run.lua` checks the rules in `Stats.lua`: the line patterns with the game's formats in several locales, reading raised stats from tooltip lines, the all-of rule, telling results apart, sorting like the browse list, and `NormalizeSaved`. `FindMyStats.lua` plugs into Blizzard's code and is tested in game; before a round it also runs in a luajit stand-in with a simulated server (pages, throttle, slow item data), copying Blizzard's list code from `wow-ui-source`.

## Never

- Never replace a Blizzard function or the results frame's data provider: only `hooksecurefunc`, `HookScript` and `Menu.ModifyMenu`.
- Never send searches of its own, and never filter favorites.
- Never change Blizzard's saved filters (`g_auctionHouseFilters`).
