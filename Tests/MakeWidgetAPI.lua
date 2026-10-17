-- Makes Tests/WidgetAPI.lua from Ketho/BlizzardInterfaceResources (the forever branch):
-- `luajit Tests/MakeWidgetAPI.lua <path to BlizzardInterfaceResources>`, in the addon folder.

-- This file runs under luajit, outside the game, and uses standard Lua's loadfile and io.
---@diagnostic disable: undefined-global

local resources = assert(arg[1], "usage: luajit Tests/MakeWidgetAPI.lua <path to BlizzardInterfaceResources>")
local api = assert(loadfile(resources .. "/Resources/WidgetAPI.lua"))()
-- The file lists Region as inheriting itself; its WidgetHierarchy.png puts Region after ScriptRegion.
if api.Region.inherits[1] == "Region" then
	api.Region.inherits = { "ScriptRegion" }
end
-- The build the resources were made from: each commit is named after it ("1.60.1 (70338)").
local git = assert(io.popen('git -C "' .. resources .. '" log -1 --format=%s'))
local subject = git:read("*l")
git:close()
local version, build = (subject or ""):match("^(%d+%.%d+%.%d+) %((%d+)%)$")
assert(version, "no build in the resources' last commit: " .. tostring(subject))

-- The widget types the addon and the stand-in make: Blizzard's auction house frames, the menu's
-- attached frames, buttons, textures and text.
local TYPES = { "Frame", "Button", "Texture", "FontString" }

local function Collect(widgetType, set, seen)
	if seen[widgetType] then
		return set
	end
	seen[widgetType] = true
	for _, name in ipairs(api[widgetType].methods) do
		set[name] = true
	end
	for _, parent in ipairs(api[widgetType].inherits) do
		Collect(parent, set, seen)
	end
	return set
end

local out = {
	"-- The methods each widget type has in Forever, from Ketho/BlizzardInterfaceResources (forever,",
	"-- " .. version .. " build " .. build .. ") Resources/WidgetAPI.lua, with the methods each type inherits. That file",
	"-- lists Region as inheriting itself; its WidgetHierarchy.png puts Region after ScriptRegion, so",
	"-- Region takes ScriptRegion's methods here.",
	"-- The stand-in's widgets have only these: calling any other method fails, as in the game.",
	"-- Made by Tests/MakeWidgetAPI.lua; to update, run it again.",
	"return {",
}
for _, widgetType in ipairs(TYPES) do
	local names = {}
	for name in pairs(Collect(widgetType, {}, {})) do
		names[#names + 1] = name
	end
	table.sort(names)
	out[#out + 1] = "\t" .. widgetType .. " = {"
	local line = "\t\t"
	for _, name in ipairs(names) do
		local item = '"' .. name .. '", '
		if #line + #item > 100 then
			out[#out + 1] = (line:gsub("%s+$", ""))
			line = "\t\t"
		end
		line = line .. item
	end
	out[#out + 1] = (line:gsub("%s+$", ""))
	out[#out + 1] = "\t},"
end
out[#out + 1] = "}"
local file = assert(io.open("Tests/WidgetAPI.lua", "w"))
file:write(table.concat(out, "\n") .. "\n")
file:close()
