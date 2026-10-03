# Find My Stats

Rules for this addon. The shared rules are in `../AGENTS.md`.

Stat filters for the auction house: the player ticks stats in the auction house's own Filter menu, and a search shows only gear that raises every ticked stat. Agreed with the user (2026-10-03).

The name is "Find My Stats" (the user's choice; `ADDON_TITLE` in the code, also the start of chat lines). Folder, repo (`tembugi/FindMyStats`, private) and packages are `FindMyStats`. CurseForge project ID: none yet. Design canvas: https://claude.ai/artifact/U3xXPZ79hi25vV1sm17YH6

## Look

- A "Stats" title (`PET_BATTLE_STATS_LABEL`) at the end of Blizzard's Filter dropdown, after the spacer Blizzard queues behind its last group, then one submenu per stat group with the game's checkboxes. Added with `Menu.ModifyMenu("MENU_AUCTION_HOUSE_SEARCH_FILTER")`. Every label is a game string (`STAT_CATEGORY_*`, `ITEM_MOD_*_SHORT`).
- The Attributes group only so far (Strength, Agility, Stamina, Intellect, Spirit). The plan is all the stats Forever's gear has, in groups as on the canvas: Melee, Ranged, Spell, Defense, Resistances, Weapon Skills. A real auction's stat table already includes "Equip:" effects (healing, spell damage on "of the Physician"); before adding a group, check in game that the stat table reports its stats the way auctions show them.
- The red X on the Filter button shows while any stat is ticked, as it does for Blizzard's own filters, and clicking it unticks them too.
- Nothing else on screen and no chat lines in normal use.
- Look changes are mocked on the design canvas first and built after the user picks.

## Filtering (agreed with the user)

- An item must raise every ticked stat ("all of them"): a positive amount for the stat in the game's stat table. No minimum amounts.
- Ticks apply when a search is sent, like Blizzard's own filters: a search keeps the stats it was sent with (also when it is re-sorted), and changing ticks changes nothing until the next search.
- Favorites (the star button, and the list the auction house opens with) are never filtered, as Blizzard's filters don't apply to them.
- Ticks are saved per character, like the auction house's own filters (`SavedVariablesPerCharacter: FindMyStatsDB`). Learned endings are saved for the account (`SavedVariables: FindMyStatsAccountDB`).
- The server can't filter by stats, so the addon filters the browse results it gets. Each result is one item key: the item, its item level and its random ending ("of the Whale", the key's `itemSuffix`). Its stats are the item's own, from the game's stat table (`C_Item.GetItemStats("item:<id>")`, amounts keyed by the `ITEM_MOD_*_SHORT` names the menu shows), plus what its ending adds. Never from a tooltip.
- Only weapons and armor can match (`C_Item.GetItemInfoInstant` class).
- How the list changes: a `hooksecurefunc` on the results frame's `UpdateBrowseResults` takes each page of results into the search's collection (one entry per item key: item, item level, random suffix) and hands the frame the matching ones (`browseResults`), then redraws its list (`ItemList:RefreshScrollFrame`).
- Every page: the server sends results in pages, and Blizzard's list asks for the next one only while it shows few results. Filtering and sorting need them all, so after each page the addon asks for the next (`C_AuctionHouse.RequestMoreBrowseResults`) when the auction house's throttle is ready (`IsThrottledMessageSystemReady`, else `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`), until `HasFullBrowseResults`. This continues the player's own search, as scrolling to the end would; the addon sends no searches of its own.
- Never stalling: items are read a little each frame (`FRAME_BUDGET`, 4 ms, timed with `GetTimePreciseSec`: `debugprofilestop` counts from the last `debugprofilestart`, which any addon may call), and at most 30 items' data is asked for at a time (`MAX_ITEM_LOADS`); the rest wait their turn. An item whose data isn't loaded waits for `ITEM_DATA_LOAD_RESULT`; one whose load fails stays out of that search.
- Why no tooltips (found with the measuring builds 0.1.2 to 0.1.5, 2026-10-03/04): the first tooltip in a session with ending 14328 ("of the Physician", items 11968, 6560 and others) stalled the game for 14.2 s inside `C_TooltipInfo.GetItemKey`, in every session; hovering such a row in Blizzard's own list does the same. Reading the tooltip once to learn the ending was rejected by the user (2026-10-04): the addon must never freeze anyone's game, not even once. The auction house's info on the item key (`C_AuctionHouse.GetItemKeyInfo`) gives the name the list shows and sorts by; an entry waits for `ITEM_KEY_ITEM_INFO_RECEIVED` until it has it, and a listing it can't name stays out of the results.
- Endings (found in game, 2026-10-04): a row's tooltip shows an ending's stats as ranges ("+5-9 Intellect") or not at all ("of the Whale": none, "Items in this group may vary in stats"). The item key holds only the ending's number (Whale 14301, Physician 14328); the stats come with a bonus in each auction's real link (`item:14178::::::::15:1482::1:1:12719…`, Whale). The game's stat table reads that link instantly, even for Physician (0.13 ms: Intellect 5, Stamina 9, healing 8, spell damage 3, armor 36), but not a link built from the item key (0.1.3: the suffix in the seventh field changed nothing on 4877 items). 0.1.5's check that "no ending adds stats" was wrong: it couldn't read ranges, and most rows' tooltips show none.
- Learning an ending (agreed with the user, 2026-10-04): the first time a search meets an ending the account hasn't learned, the addon asks the server for one row's auctions (`C_AuctionHouse.SendSearchQuery`, as clicking the row would) and reads one auction's real link: what the ending adds is what that link's stat table has beyond the item's own (`ns.EndingAdds`, every stat name, so stats added to the menu later need no new learning). An ending adds the same stats to every item. Requests go one at a time, at least 0.7 s apart (the server allows 100 a minute), only while the results list is showing (viewing an item sends the player's own request, which goes first); a row the auction house has already searched needs none; a row with nothing to learn from (sold, or no answer in 10 s) gives way to another with the same ending, up to 3 per search. Learned endings are saved for the account (`FindMyStatsAccountDB`, per game build: an update may change them). Until its ending is learned, an item matches by its own stats; the list grows as endings are learned. A whole-auction-house search learns every ending in it once (at 0.7 s each); a narrow one only its few.
- Sorting: the addon sorts the matches itself, by Blizzard's own sorts for the search (`GetSortsForContext(GetBrowseSearchContext())`: up to two of Price (`minPrice`) and Name (the item key's `itemName`), each possibly reversed), ties by arrival. A header click (`hooksecurefunc` on the results frame's `SetSortOrder`) sorts the matches at once; Blizzard's re-sent search merges in (fresher prices) instead of starting over, and once every page has arrived it fetches no pages again. 0.1.0 showed pages in arrival order and restarted on every re-sort, so the user never saw a sorted list.
- Empty list: Blizzard's list shows "No results" once every page is in, even while the addon still reads items. Until the addon is done, it shows Blizzard's own loading spinner (`ItemList.LoadingSpinner`) in its place, then puts "No results" back if nothing matched.
- A new search (`SendBrowseQuery` hook), favorites or a closed auction house ends the collection; the addon only ever changes the list it handed over.

## Taint

- The filtered list is the addon's table, so while a filtered list is on screen, Blizzard's results list and what a click on a row starts (the item's buy page) run tainted. Nothing in the auction house API is protected: `IsProtectedFunction` marks only widget methods, and `PlaceBid` and `StartCommoditiesPurchase` carry `HasRestrictions`, like `SendChatMessage`. Buying from a filtered list is the main thing to test: watch for "action blocked" and read `Logs/taint.log`. In the user's tests (2026-10-03, taint logging on) buying worked and the game wrote no taint.log at all.
- The menu entries use `Menu.ModifyMenu`, which Blizzard made for addons.
- The X follows Blizzard's rule by reading the Filter button (`GetFilters`, `GetLevelRange`), never by calling `UpdateClearFiltersButton`, which writes Blizzard's saved filters.

## Chat and errors

- Lines start with "Find My Stats:" in gold. The addon writes only when something stopped working: what stopped in red, then what the player can do.
- When the auction house loads, the addon checks the Blizzard pieces it plugs into. If one is missing, it says so once (with its version) and adds nothing.
- Every hook and handler runs through `Guarded` (`xpcall` with `CallErrorHandler`), so an error never breaks Blizzard's code. The first error is reported, said once in chat, the search's full list goes back on screen, and the filters stay off until /reload.

## Tests

`luajit Tests/run.lua` checks the rules in `Stats.lua`: the stat list, reading stats from the game's stat table with and without an ending, what an ending adds (with the in-game numbers for Watcher's Cap of the Whale and of the Physician), the all-of rule, telling results apart, sorting like the browse list, the ticks a search keeps, `NormalizeSaved` and `NormalizeAccount`. `FindMyStats.lua` plugs into Blizzard's code and is tested in game; before a round it also runs in a luajit stand-in with a simulated server (pages, throttle, slow item data, a row's auctions with real links), copying Blizzard's list code from `wow-ui-source`.

## Never

- Never replace a Blizzard function or the results frame's data provider: only `hooksecurefunc`, `HookScript` and `Menu.ModifyMenu`.
- Never send requests of its own except these two, both paced: the next page of the player's own search, and one row's auctions to learn an ending the account hasn't seen (see Filtering). Never filter favorites.
- Never change Blizzard's saved filters (`g_auctionHouseFilters`).
- Never call anything that builds a tooltip (`C_TooltipInfo`, `GameTooltip`): one random suffix makes it stall the game for 14 s (see Filtering).
