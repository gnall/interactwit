-- Interactwit - Menus.lua
-- Adds an "Interactwit: View interactions" entry to right-click menus, using the
-- modern (11.0+) Menu.ModifyMenu hook system that Forever inherits. This is the
-- sanctioned, taint-free way to append to Blizzard menus -- we only add a button
-- that opens our own window; we never touch secure/protected actions.
--
-- Two request targets:
--   * Recent Allies list  -> its entries open UnitPopup_OpenMenu("RECENT_ALLY"/
--     "RECENT_ALLY_OFFLINE", contextData), which tags the menu "MENU_UNIT_RECENT_ALLY[_OFFLINE]".
--   * Unit frames / target / party / raid / chat rosters -> the standard MENU_UNIT_* tags.

local ADDON, ns = ...
local C = ns.COLORS

local BUTTON_TEXT = ns.Colorize(C.header, "Interactwit") .. "|cffffffff: View interactions|r"

-- Menus we append to. Tags that don't exist on this client simply never fire.
local MENU_TAGS = {
    -- Recent Allies list (the feature that inspired this addon)
    "MENU_UNIT_RECENT_ALLY",
    "MENU_UNIT_RECENT_ALLY_OFFLINE",
    -- Unit frames & world players
    "MENU_UNIT_PLAYER",
    "MENU_UNIT_ENEMY_PLAYER",
    "MENU_UNIT_PARTY",
    "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS",
    "MENU_UNIT_ARENAENEMY",
    -- Social rosters / chat name right-clicks
    "MENU_UNIT_FRIEND",
    "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_UNIT_CHAT_ROSTER",
}

-- Resolve a stored player key + display name from the menu's contextData.
-- UnitPopupManager normalizes contextData to have .name/.server (and .unit when a
-- unit frame was clicked); Recent Allies also passes .name/.server/.guid.
local function ResolvePlayer(data)
    if not data then return nil end
    local name, server, unit = data.name, data.server, data.unit
    if (not name or name == "") and unit then
        name, server = UnitName(unit)
    end
    if not name or name == "" then return nil end
    -- If a unit token is present, make sure it's actually a player.
    if unit and UnitExists(unit) and not UnitIsPlayer(unit) then return nil end
    local key = ns.PlayerKey(name, server)
    return key, name
end

local function Generator(owner, rootDescription, contextData)
    if not rootDescription then return end
    local key, name = ResolvePlayer(contextData)
    if not key then return end

    rootDescription:CreateDivider()
    rootDescription:CreateButton(BUTTON_TEXT, function()
        if ns.UI and ns.UI.OpenForPlayer then
            ns.UI:OpenForPlayer(key, name)
        end
    end)
end

local installed = false
local function Install()
    if installed then return end
    if not (Menu and Menu.ModifyMenu) then
        -- Old/Classic-style client without the new menu system: nothing to hook.
        return
    end
    for _, tag in ipairs(MENU_TAGS) do
        pcall(Menu.ModifyMenu, tag, Generator)
    end
    installed = true
end

-- Blizzard_Menu loads very early, so Menu is normally ready by the time our addon
-- runs; install now, and retry once after login only if it wasn't ready yet.
Install()
ns:RegisterEvent("PLAYER_LOGIN", Install)
