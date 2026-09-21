-- Interactwit - Tracker.lua
-- Records interactions with other players. Everything here is read-only /
-- event-driven and uses only sanctioned APIs:
--   * QUEST_TURNED_IN                 -> quests done together (+ zone)
--   * ENCOUNTER_END / LFG_COMPLETION  -> dungeon bosses + completion state
--   * Trade events + ERR_TRADE_COMPLETE -> completed trades
--   * C_RecentAllies                  -> Blizzard's own "recently interacted" feed
-- No combat/secret values are ever read; nothing here automates gameplay.

local ADDON, ns = ...
local C = ns.COLORS
local CFG = ns.CONFIG

-- Forward declarations so handlers can call helpers defined lower in the file.
local finalizeRun, startRunIfNeeded, commitTrade, syncRecentAllies

-- Runtime-only dungeon run state (never saved directly).
local activeRun = nil

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------
local function splitKey(key)
    local name, realm = key:match("^(.-)%-(.+)$")
    return name or key, realm or ns.OwnRealm()
end

local function debug(fmt, ...)
    if InteractwitDB and InteractwitDB.debug then
        print("|cff9e9e9eInteractwit debug:|r " .. fmt:format(...))
    end
end

--------------------------------------------------------------------------------
-- Quests
--------------------------------------------------------------------------------
ns:RegisterEvent("QUEST_TURNED_IN", function(_, questID)
    local members = ns.GetGroupMembers()
    if #members == 0 then return end -- solo turn-ins aren't "with" anyone

    local title
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        title = C_QuestLog.GetTitleForQuestID(questID)
    end
    title = title or ("Quest " .. tostring(questID))
    local zone = ns.CurrentZone()
    local ts = ns.Now()

    for _, m in ipairs(members) do
        local p = ns.GetPlayer(m.key, m)
        table.insert(p.quests, { questID = questID, title = title, zone = zone, ts = ts })
        ns.TrimList(p.quests, CFG.MAX_QUESTS_PER_PLAYER)
        p.counts.quests = p.counts.quests + 1
        p.zones[zone] = (p.zones[zone] or 0) + 1
        ns.SetLastInteraction(p, {
            source = ns.SOURCE.QUEST,
            description = 'Completed quest "' .. title .. '"',
            ts = ts, zone = zone,
        })
    end
    debug("QUEST_TURNED_IN %s (%s) with %d member(s)", tostring(questID), title, #members)
end)

--------------------------------------------------------------------------------
-- Dungeons
--------------------------------------------------------------------------------
startRunIfNeeded = function()
    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType ~= "party" then return end

    local name, _, _, difficultyName, _, _, _, instanceID = GetInstanceInfo()
    if activeRun and activeRun.instanceID == instanceID and not activeRun.finalized then
        return -- already tracking this run
    end
    finalizeRun("new-instance") -- close out any dangling run first

    activeRun = {
        instanceID = instanceID,
        name = name or "Unknown Dungeon",
        difficulty = difficultyName,
        start = ns.Now(),
        bosses = {},        -- ordered { name = , id = , ts = }
        participants = {},  -- key -> { info = , bossCount = }
        complete = false,
        finalized = false,
    }
    debug("Started dungeon run: %s (instanceID %s)", activeRun.name, tostring(instanceID))
end

finalizeRun = function(reason)
    if not activeRun or activeRun.finalized then return end
    -- Nothing meaningful happened; just drop it.
    if #activeRun.bosses == 0 and next(activeRun.participants) == nil then
        activeRun = nil
        return
    end
    activeRun.finalized = true
    local complete = activeRun.complete

    local bossNames = {}
    for _, b in ipairs(activeRun.bosses) do bossNames[#bossNames + 1] = b.name end

    for key, rec in pairs(activeRun.participants) do
        local p = ns.GetPlayer(key, rec.info)
        table.insert(p.dungeons, {
            name = activeRun.name,
            difficulty = activeRun.difficulty,
            bossCount = rec.bossCount,
            bosses = bossNames,
            complete = complete,
            ts = ns.Now(),
        })
        ns.TrimList(p.dungeons, CFG.MAX_DUNGEONS_PER_PLAYER)
        if complete then
            p.counts.dungeonsComplete = p.counts.dungeonsComplete + 1
        else
            p.counts.dungeonsIncomplete = p.counts.dungeonsIncomplete + 1
        end
        ns.SetLastInteraction(p, {
            source = complete and ns.SOURCE.DUNGEON_COMPLETE or ns.SOURCE.DUNGEON_BOSS,
            description = (complete and "Completed " or "Ran (incomplete) ") .. activeRun.name,
            ts = ns.Now(), zone = activeRun.name,
        })
    end
    debug("Finalized run '%s' complete=%s reason=%s", activeRun.name, tostring(complete), tostring(reason))
    activeRun = nil
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "party" then
        startRunIfNeeded()
    else
        finalizeRun("left-instance")
    end
end)

ns:RegisterEvent("ENCOUNTER_END", function(_, encounterID, encounterName, difficultyID, groupSize, success)
    debug("ENCOUNTER_END id=%s name=%s success=%s", tostring(encounterID), tostring(encounterName), tostring(success))
    if not activeRun then startRunIfNeeded() end
    if not activeRun then return end
    if success ~= 1 then return end -- only count actual kills

    table.insert(activeRun.bosses, { name = encounterName, id = encounterID, ts = ns.Now() })

    for _, m in ipairs(ns.GetGroupMembers()) do
        local rec = activeRun.participants[m.key]
        if not rec then
            rec = { info = m, bossCount = 0 }
            activeRun.participants[m.key] = rec
        end
        rec.info = m
        rec.bossCount = rec.bossCount + 1

        local p = ns.GetPlayer(m.key, m)
        p.counts.bossKills = p.counts.bossKills + 1
        ns.SetLastInteraction(p, {
            source = ns.SOURCE.DUNGEON_BOSS,
            description = "Killed " .. (encounterName or "a boss") .. " in " .. activeRun.name,
            ts = ns.Now(), zone = activeRun.name,
        })
    end

    -- Completion signal #3: known final boss (see FinalBosses.lua).
    if ns.IsFinalBoss(encounterID) then
        activeRun.complete = true
        finalizeRun("final-boss")
    end
end)

-- Completion signal #1: Dungeon Finder / random-dungeon reward.
ns:RegisterEvent("LFG_COMPLETION_REWARD", function()
    if activeRun then
        activeRun.complete = true
        finalizeRun("lfg-reward")
    end
end)

--------------------------------------------------------------------------------
-- Trades
-- Snapshot on both-accepted, then confirm with ERR_TRADE_COMPLETE. TRADE_CLOSED
-- alone is unreliable (fires on cancel too), so we don't use it as success.
--------------------------------------------------------------------------------
local pendingTrade = nil

commitTrade = function(t)
    local name = splitKey(t.key)
    local p = ns.GetPlayer(t.key, { name = name })
    table.insert(p.trades, {
        ts = ns.Now(),
        myMoney = t.myMoney, theirMoney = t.theirMoney,
        myItems = t.myItems, theirItems = t.theirItems,
    })
    ns.TrimList(p.trades, CFG.MAX_TRADES_PER_PLAYER)
    p.counts.trades = p.counts.trades + 1
    ns.SetLastInteraction(p, {
        source = ns.SOURCE.TRADE,
        description = "Completed a trade",
        ts = ns.Now(), zone = ns.CurrentZone(),
    })
    debug("Committed trade with %s", t.key)
end

ns:RegisterEvent("TRADE_ACCEPT_UPDATE", function(_, playerAccepted, targetAccepted)
    if playerAccepted ~= 1 or targetAccepted ~= 1 then return end
    local partner = GetUnitName("NPC", true) -- "Name" or "Name-Realm" of trade partner
    if not partner then return end

    local snap = {
        key = ns.PlayerKey(partner),
        myMoney = GetPlayerTradeMoney(),
        theirMoney = GetTargetTradeMoney(),
        myItems = {}, theirItems = {},
    }
    for i = 1, 6 do -- slots 1-6 are actually traded; slot 7 is the "will not be traded" slot
        local link = GetTradePlayerItemLink(i)
        if link then
            local count = select(3, GetTradePlayerItemInfo(i))
            snap.myItems[#snap.myItems + 1] = { link = link, count = count or 1 }
        end
        local tlink = GetTradeTargetItemLink(i)
        if tlink then
            local tcount = select(3, GetTradeTargetItemInfo(i))
            snap.theirItems[#snap.theirItems + 1] = { link = tlink, count = tcount or 1 }
        end
    end
    pendingTrade = snap
end)

ns:RegisterEvent("TRADE_REQUEST_CANCEL", function()
    pendingTrade = nil
end)

ns:RegisterEvent("UI_INFO_MESSAGE", function(_, arg1, arg2)
    -- Signature varies by client: (message) or (errorType, message).
    local text = arg2 or arg1
    if text == ERR_TRADE_COMPLETE then
        if pendingTrade and pendingTrade.key then
            commitTrade(pendingTrade)
        end
        pendingTrade = nil
    end
end)

--------------------------------------------------------------------------------
-- C_RecentAllies sync -- mirrors Blizzard's own "recently interacted" feed and
-- enriches our records (class/race/level, notes, latest interaction, and an extra
-- signal that a dungeon was completed with someone).
--------------------------------------------------------------------------------
syncRecentAllies = function()
    if not C_RecentAllies or not C_RecentAllies.GetRecentAllies then return end
    if C_RecentAllies.IsSystemSupported and not C_RecentAllies.IsSystemSupported() then return end
    -- NOTE: We deliberately do NOT call C_RecentAllies.TryRequestRecentAlliesData().
    -- That function is protected (HasRestrictions = true) and only Blizzard's secure
    -- UI may call it -- doing so from an addon triggers the "blocked from an action
    -- only available to the Blizzard UI" taint popup. Instead we just read whatever
    -- Blizzard has already cached, and refresh when the data-updated events fire.
    if C_RecentAllies.IsRecentAllyDataReady and not C_RecentAllies.IsRecentAllyDataReady() then
        return -- nothing cached yet; a RECENT_ALLIES_* event will call us again later
    end

    local data = C_RecentAllies.GetRecentAllies()
    if type(data) ~= "table" then return end

    for _, ally in ipairs(data) do
        local cd = ally.characterData
        if cd and cd.fullName then
            local key = ns.PlayerKey(cd.fullName)
            local p = ns.GetPlayer(key, { name = cd.name, realm = cd.realmName, guid = cd.guid })
            p.classID = cd.classID or p.classID
            p.raceID = cd.raceID or p.raceID
            p.level = cd.level or p.level
            p.native = p.native or {}

            local latest
            if ally.interactionData then
                p.native.note = ally.interactionData.note
                if ally.interactionData.interactions then
                    p.native.interactions = {}
                    for _, it in ipairs(ally.interactionData.interactions) do
                        local ctx = it.contextData
                        p.native.interactions[#p.native.interactions + 1] = {
                            type = it.type,
                            description = it.description,
                            timestamp = it.timestamp,
                            itemID = ctx and ctx.itemID,
                            locationName = ctx and ctx.locationName,
                        }
                        if not latest or (it.timestamp or 0) > (latest.timestamp or 0) then
                            latest = it
                        end
                        -- Completion signal #2: Blizzard says we completed a dungeon
                        -- with this ally during the current run.
                        if activeRun and activeRun.participants[key]
                            and it.type == 12 and (it.timestamp or 0) >= activeRun.start then
                            activeRun.complete = true
                        end
                    end
                end
            end
            if ally.stateData then
                p.native.isOnline = ally.stateData.isOnline
                p.native.currentLocation = ally.stateData.currentLocation
            end

            if latest and (not p.last or (latest.timestamp or 0) > (p.last.ts or 0)) then
                ns.SetLastInteraction(p, {
                    source = ns.SOURCE.NATIVE,
                    rolodexType = latest.type,
                    description = (latest.description and latest.description ~= "" and latest.description)
                        or ns.RolodexName(latest.type),
                    ts = latest.timestamp,
                    zone = latest.contextData and latest.contextData.locationName,
                })
            end
        end
    end
    ns:Fire("IW_DATA_CHANGED")
    debug("Synced %d recent allies", #data)
end

-- All read-only refresh triggers (none of these are protected).
ns:RegisterEvent("RECENT_ALLY_DATA_UPDATED", syncRecentAllies)
ns:RegisterEvent("RECENT_ALLIES_DATA_READY", syncRecentAllies)
ns:RegisterEvent("RECENT_ALLIES_CACHE_UPDATE", syncRecentAllies)
ns:RegisterEvent("RECENT_ALLIES_SYSTEM_STATUS_UPDATED", syncRecentAllies)
ns:RegisterEvent("IW_REQUEST_SYNC", syncRecentAllies)

-- Initial sync shortly after login (data may not be ready immediately).
ns:RegisterEvent("PLAYER_LOGIN", function()
    if C_Timer and C_Timer.After then
        C_Timer.After(5, syncRecentAllies)
    else
        syncRecentAllies()
    end
end)

-- Expose for the UI / other modules.
ns.SyncRecentAllies = syncRecentAllies
ns.GetActiveRun = function() return activeRun end
