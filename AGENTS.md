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
- An item whose data isn't loaded is left out and requested; the list is filtered again on the next frame after its data arrives (`ITEM_DATA_LOAD_RESULT`). An item whose load fails stays out for that search.
- How the list changes: a `hooksecurefunc` on the results frame's `UpdateBrowseResults` keeps the search's results in the server's order and hands the frame the matching ones (`browseResults`), then marks its list for redraw (`ItemList:DirtyScrollFrame`). Blizzard's list asks the server for more only while it shows results, so after a batch with no match on screen the addon asks for the next batch (`C_AuctionHouse.RequestMoreBrowseResults`), once per batch. A narrow filter thus pages through the search's results, as scrolling to the end would. The addon sends no searches of its own.
- A new search or a closed auction house replaces the list; the addon only ever changes the list it handed over.

## Taint

- The filtered list is the addon's table, so while a filtered list is on screen, Blizzard's results list and what a click on a row starts (the item's buy page) run tainted. Nothing in the auction house API is protected: `IsProtectedFunction` marks only widget methods, and `PlaceBid` and `StartCommoditiesPurchase` carry `HasRestrictions`, like `SendChatMessage`. Buying from a filtered list is the main thing to test: watch for "action blocked" and read `Logs/taint.log`.
- The menu entries use `Menu.ModifyMenu`, which Blizzard made for addons.
- The X follows Blizzard's rule by reading the Filter button (`GetFilters`, `GetLevelRange`), never by calling `UpdateClearFiltersButton`, which writes Blizzard's saved filters.

## Chat and errors

- Lines start with "Find My Stats:" in gold. The addon writes only when something stopped working: what stopped in red, then what the player can do.
- When the auction house loads, the addon checks the Blizzard pieces it plugs into. If one is missing, it says so once (with its version) and adds nothing.
- Every hook and handler runs through `Guarded` (`xpcall` with `CallErrorHandler`), so an error never breaks Blizzard's code. The first error is reported, said once in chat, the search's full list goes back on screen, and the filters stay off until /reload.

## Tests

`luajit Tests/run.lua` checks the rules in `Stats.lua`: the line patterns with the game's formats in several locales, reading raised stats from tooltip lines, the all-of rule, keeping order while items load, and `NormalizeSaved`. `FindMyStats.lua` plugs into Blizzard's code and is tested in game.

## Never

- Never replace a Blizzard function or the results frame's data provider: only `hooksecurefunc`, `HookScript` and `Menu.ModifyMenu`.
- Never send searches of its own, and never filter favorites.
- Never change Blizzard's saved filters (`g_auctionHouseFilters`).
