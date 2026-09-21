-- Interactwit - Constants.lua
-- Static data: interaction type names, config defaults, and small helpers that
-- don't depend on anything else loading first. Loaded before everything.

local ADDON, ns = ...

ns.ADDON_NAME = ADDON
ns.VERSION = "0.1.0"

--------------------------------------------------------------------------------
-- Configuration defaults
--------------------------------------------------------------------------------
-- These bound how much we keep per player so the SavedVariables file stays small.
ns.CONFIG = {
    MAX_QUESTS_PER_PLAYER   = 250,  -- most recent quests kept per player
    MAX_DUNGEONS_PER_PLAYER = 100,  -- most recent dungeon runs kept per player
    MAX_TRADES_PER_PLAYER   = 100,  -- most recent trades kept per player
    -- A dungeon "run" is considered finished (finalized) this many seconds after
    -- you leave the instance, or immediately when a completion signal fires.
    RUN_STALE_SECONDS       = 60,
}

--------------------------------------------------------------------------------
-- Enum.RolodexType (from C_RecentAllies) -> friendly label
-- Source: warcraft.wiki.gg API C_RecentAllies.GetRecentAllies (confirmed present
-- in the "forever" game type / build 1.60.1).
--------------------------------------------------------------------------------
ns.ROLODEX = {
    [0]  = "None",
    [1]  = "Party member",
    [2]  = "Raid member",
    [3]  = "Trade",
    [4]  = "Whisper",
    [5]  = "Crafting order (public, filled by them)",
    [6]  = "Crafting order (public, filled by you)",
    [7]  = "Crafting order (personal, filled by them)",
    [8]  = "Crafting order (personal, filled by you)",
    [9]  = "Crafting order (guild, filled by them)",
    [10] = "Crafting order (guild, filled by you)",
    [11] = "Creature kill",
    [12] = "Completed dungeon",
    [13] = "Killed raid boss",
    [14] = "Killed LFR boss",
    [15] = "Completed delve",
    [16] = "Completed arena",
    [17] = "Completed battleground",
    [18] = "Duel",
    [19] = "Pet battle",
    [20] = "PvP kill",
    [23] = "Legacy friend",
}

function ns.RolodexName(t)
    return ns.ROLODEX[t] or ("Type " .. tostring(t))
end

--------------------------------------------------------------------------------
-- Internal interaction "source" tags. These describe how *we* recorded something,
-- separate from Blizzard's rolodex types above.
--------------------------------------------------------------------------------
ns.SOURCE = {
    QUEST            = "quest",
    DUNGEON_BOSS     = "dungeon_boss",
    DUNGEON_COMPLETE = "dungeon_complete",
    TRADE            = "trade",
    NATIVE           = "native", -- came from C_RecentAllies
}

-- UI palette
ns.COLORS = {
    header   = "|cff4fc3f7",   -- light blue
    good     = "|cff66bb6a",   -- green
    warn     = "|cffffa726",   -- orange
    dim      = "|cff9e9e9e",   -- grey
    accent   = "|cffba68c8",   -- purple
    white    = "|cffffffff",
    r        = "|r",
}

local C = ns.COLORS
function ns.Colorize(color, text)
    return (color or C.white) .. tostring(text) .. C.r
end
