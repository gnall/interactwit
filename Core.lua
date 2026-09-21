-- Interactwit - Core.lua
-- Database bootstrap, shared utilities, and a tiny event-dispatch layer that the
-- other modules hook into. Everything here is passive/read-only and uses only
-- sanctioned APIs -- nothing that touches combat/secret values or automation.

local ADDON, ns = ...
local C = ns.COLORS

--------------------------------------------------------------------------------
-- Event dispatch
-- Modules call ns:RegisterEvent("EVENT", handler). Multiple handlers per event
-- are supported. Handlers receive (event, ...). We also expose ns:Fire for
-- internal pseudo-events (e.g. "IW_DATA_CHANGED") used by the UI.
--------------------------------------------------------------------------------
local handlers = {}   -- event -> { fn, fn, ... }
local frame = CreateFrame("Frame", "InteractwitEventFrame")
ns.frame = frame

function ns:RegisterEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        -- Only register real game events with the frame; internal ones start IW_.
        if not event:find("^IW_") then
            pcall(frame.RegisterEvent, frame, event)
        end
    end
    table.insert(handlers[event], fn)
end

function ns:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, event, ...)
        if not ok then
            geterrorhandler()(("Interactwit: error in %s handler: %s"):format(event, tostring(err)))
        end
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    ns:Fire(event, ...)
end)

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------
function ns.Now()
    return time()
end

-- Realm we default to when a unit reports no realm (same-realm players).
local function OwnRealm()
    return (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName and GetRealmName():gsub("%s+", ""))
        or "Unknown"
end
ns.OwnRealm = OwnRealm

local function NormalizeRealm(realm)
    if not realm or realm == "" then
        return OwnRealm()
    end
    return (realm:gsub("%s+", ""))
end
ns.NormalizeRealm = NormalizeRealm

-- Canonical key we store players under: "Name-Realm".
function ns.PlayerKey(name, realm)
    if not name or name == "" then return nil end
    -- If the name already carries a realm ("Name-Realm"), split it.
    local n, r = name:match("^(.-)%-(.+)$")
    if n then
        name, realm = n, realm or r
    end
    return name .. "-" .. NormalizeRealm(realm)
end

-- Extract identity from a unit token. Returns nil unless it's another player.
function ns.UnitKeyInfo(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    if UnitIsUnit(unit, "player") then return nil end
    local name, realm = UnitName(unit)
    if not name then return nil end
    local key = ns.PlayerKey(name, realm)
    return {
        key   = key,
        name  = name,
        realm = NormalizeRealm(realm),
        guid  = UnitGUID(unit),
    }
end

-- Current zone as a readable string, e.g. "Deadmines" or "Elwynn Forest / Goldshire".
function ns.CurrentZone()
    local zone = GetRealZoneText() or GetZoneText() or "Unknown"
    local sub = GetSubZoneText()
    if sub and sub ~= "" and sub ~= zone then
        return zone .. " / " .. sub
    end
    return zone
end

-- All *other* players currently grouped with you (party or raid).
function ns.GetGroupMembers()
    local out = {}
    local n = GetNumGroupMembers() or 0
    if n == 0 then return out end
    local isRaid = IsInRaid()
    local prefix = isRaid and "raid" or "party"
    local count = isRaid and n or (n - 1) -- party count includes you in GetNumGroupMembers
    for i = 1, count do
        local info = ns.UnitKeyInfo(prefix .. i)
        if info then
            out[#out + 1] = info
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Database
--------------------------------------------------------------------------------
local DB_DEFAULTS = function()
    return {
        version = 1,
        players = {},                    -- key -> player record
        meta = {
            character = nil,             -- "You-Realm"
            created   = ns.Now(),
            lastLogin = ns.Now(),
        },
    }
end

-- Returns (creating if needed) the record for a player key.
function ns.GetPlayer(key, seedInfo)
    if not key then return nil end
    local db = InteractwitDB
    if not db then return nil end
    local p = db.players[key]
    if not p then
        p = {
            name  = seedInfo and seedInfo.name,
            realm = seedInfo and seedInfo.realm,
            guid  = seedInfo and seedInfo.guid,
            firstSeen = ns.Now(),
            lastSeen  = ns.Now(),
            counts = {
                quests = 0, dungeonsComplete = 0, dungeonsIncomplete = 0,
                bossKills = 0, trades = 0,
            },
            last = nil,           -- { source, rolodexType, description, ts, zone }
            quests = {},          -- { { questID, title, zone, ts }, ... }
            dungeons = {},        -- { { name, difficulty, bossCount, bosses={}, complete, ts }, ... }
            trades = {},          -- { { ts, myMoney, theirMoney, myItems={}, theirItems={} }, ... }
            zones = {},           -- zoneName -> quest count
        }
        db.players[key] = p
    end
    -- Refresh identity fields when we learn more.
    if seedInfo then
        p.name  = p.name  or seedInfo.name
        p.realm = p.realm or seedInfo.realm
        if seedInfo.guid then p.guid = seedInfo.guid end
    end
    p.lastSeen = ns.Now()
    return p
end

-- Trim a list to the newest N entries (assumes newest appended at the end).
function ns.TrimList(list, max)
    local over = #list - max
    if over > 0 then
        for _ = 1, over do
            table.remove(list, 1)
        end
    end
end

-- Update a player's "last interaction" summary + fire UI refresh.
function ns.SetLastInteraction(player, info)
    player.last = {
        source       = info.source,
        rolodexType  = info.rolodexType,
        description  = info.description,
        ts           = info.ts or ns.Now(),
        zone         = info.zone,
    }
    player.lastSeen = player.last.ts
    ns:Fire("IW_DATA_CHANGED")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON then return end

    if type(InteractwitDB) ~= "table" then
        InteractwitDB = DB_DEFAULTS()
    end
    -- Fill any missing top-level fields (forward-compatible migrations).
    local defaults = DB_DEFAULTS()
    for k, v in pairs(defaults) do
        if InteractwitDB[k] == nil then InteractwitDB[k] = v end
    end
    InteractwitDB.players = InteractwitDB.players or {}
    InteractwitDB.meta = InteractwitDB.meta or {}
    InteractwitDB.meta.lastLogin = ns.Now()

    ns.loaded = true
    ns:Fire("IW_READY")
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    local me = ns.PlayerKey(UnitName("player"))
    if InteractwitDB and InteractwitDB.meta then
        InteractwitDB.meta.character = me
    end
    print(ns.Colorize(C.header, "Interactwit") .. " v" .. ns.VERSION ..
        " loaded. Type " .. ns.Colorize(C.accent, "/iw") .. " to open your interaction journal.")
end)

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------
SLASH_INTERACTWIT1 = "/interactwit"
SLASH_INTERACTWIT2 = "/iw"
local function SlashCmdHandler(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "sync" then
        ns:Fire("IW_REQUEST_SYNC")
        print(ns.Colorize(C.header, "Interactwit") .. ": requested recent-allies sync.")
    elseif msg == "wipe" then
        InteractwitDB = DB_DEFAULTS()
        ns:Fire("IW_DATA_CHANGED")
        print(ns.Colorize(C.header, "Interactwit") .. ": " .. ns.Colorize(C.warn, "all data wiped."))
    else
        ns:Fire("IW_TOGGLE_UI")
    end
end
SlashCmdList["INTERACTWIT"] = SlashCmdHandler
