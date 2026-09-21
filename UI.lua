-- Interactwit - UI.lua
-- A simple, self-contained window: searchable list of players on the left, a
-- detailed breakdown on the right. Pure display code; it never writes game state.

local ADDON, ns = ...
local C = ns.COLORS

local UI = {}
ns.UI = UI

local ROW_HEIGHT = 22
local NUM_ROWS = 17
local LIST_WIDTH = 250
local selectedKey = nil

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------
local function splitKey(key)
    local name, realm = key:match("^(.-)%-(.+)$")
    return name or key, realm
end

local function fmtDate(ts)
    if not ts or ts == 0 then return "never" end
    return date("%Y-%m-%d %H:%M", ts)
end

local function fmtMoney(copper)
    if not copper or copper == 0 then return nil end
    if GetMoneyString then return GetMoneyString(copper, true) end
    return tostring(copper) .. "c"
end

local function className(classID)
    if classID and C_CreatureInfo and C_CreatureInfo.GetClassInfo then
        local info = C_CreatureInfo.GetClassInfo(classID)
        if info then return info.className end
    end
end

local function raceName(raceID)
    if raceID and C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
        local info = C_CreatureInfo.GetRaceInfo(raceID)
        if info then return info.raceName end
    end
end

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------
local f = CreateFrame("Frame", "InteractwitFrame", UIParent, "BackdropTemplate")
f:SetSize(760, 500)
f:SetPoint("CENTER")
f:SetFrameStrata("HIGH")
f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
})
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMoving)
f:SetClampedToScreen(true)
f:Hide()
tinsert(UISpecialFrames, "InteractwitFrame") -- Esc closes it

-- Title
local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -16)
title:SetText(ns.Colorize(C.header, "Interactwit") .. "  " .. ns.Colorize(C.dim, "· interaction journal"))

-- Close button
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

-- Sync button
local syncBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
syncBtn:SetSize(90, 22)
syncBtn:SetPoint("TOPRIGHT", -34, -12)
syncBtn:SetText("Sync")
syncBtn:SetScript("OnClick", function()
    if ns.SyncRecentAllies then ns.SyncRecentAllies() end
end)
syncBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine("Refresh from Blizzard's recent-allies feed")
    GameTooltip:Show()
end)
syncBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Search box
local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
search:SetSize(LIST_WIDTH - 18, 20)
search:SetPoint("TOPLEFT", 22, -48)
search:SetAutoFocus(false)
search:SetScript("OnTextChanged", function() UI:Refresh() end)
search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
searchLabel:SetPoint("BOTTOMLEFT", search, "TOPLEFT", 0, 2)
searchLabel:SetText("Search players")

-- Player list scroll
local listScroll = CreateFrame("ScrollFrame", "InteractwitListScroll", f, "FauxScrollFrameTemplate")
listScroll:SetPoint("TOPLEFT", 14, -78)
listScroll:SetSize(LIST_WIDTH, NUM_ROWS * ROW_HEIGHT)
listScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() UI:UpdateList() end)
end)

-- Row buttons
local rows = {}
for i = 1, NUM_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetSize(LIST_WIDTH - 4, ROW_HEIGHT)
    if i == 1 then
        row:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0)
    else
        row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0)
    end

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.10)

    local sel = row:CreateTexture(nil, "BACKGROUND")
    sel:SetAllPoints()
    sel:SetColorTexture(0.31, 0.40, 0.78, 0.35)
    sel:Hide()
    row.selected = sel

    local text = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("LEFT", 4, 0)
    text:SetPoint("RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    row.text = text

    row:SetScript("OnClick", function(self)
        selectedKey = self.key
        UI.selectedName = nil
        UI:UpdateList()
        UI:UpdateDetail()
    end)
    rows[i] = row
end

-- Detail scroll (right side)
local detailScroll = CreateFrame("ScrollFrame", "InteractwitDetailScroll", f, "UIPanelScrollFrameTemplate")
detailScroll:SetPoint("TOPLEFT", listScroll, "TOPRIGHT", 30, 0)
detailScroll:SetPoint("BOTTOMRIGHT", -34, 40)
local detailChild = CreateFrame("Frame", nil, detailScroll)
detailChild:SetSize(420, 1)
detailScroll:SetScrollChild(detailChild)
local detailText = detailChild:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
detailText:SetPoint("TOPLEFT", 4, -4)
detailText:SetWidth(410)
detailText:SetJustifyH("LEFT")
detailText:SetJustifyV("TOP")
detailText:SetSpacing(2)

-- Footer
local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
footer:SetPoint("BOTTOMLEFT", 16, 14)
footer:SetText(ns.Colorize(C.dim, "/iw sync · /iw wipe · passive & ToS-safe (reads only sanctioned APIs)"))

--------------------------------------------------------------------------------
-- List logic
--------------------------------------------------------------------------------
function UI:Refresh()
    if not f:IsShown() then return end
    local db = InteractwitDB
    local q = (search:GetText() or ""):lower()
    local list = {}
    if db and db.players then
        for key in pairs(db.players) do
            if q == "" or key:lower():find(q, 1, true) then
                list[#list + 1] = key
            end
        end
    end
    table.sort(list, function(a, b)
        local pa, pb = db.players[a], db.players[b]
        return (pa.lastSeen or 0) > (pb.lastSeen or 0)
    end)
    UI.filtered = list
    UI:UpdateList()
    UI:UpdateDetail()
end

function UI:UpdateList()
    local list = UI.filtered or {}
    local db = InteractwitDB
    FauxScrollFrame_Update(listScroll, #list, NUM_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(listScroll)
    for i = 1, NUM_ROWS do
        local row = rows[i]
        local idx = i + offset
        local key = list[idx]
        if key and db and db.players[key] then
            local p = db.players[key]
            local name, realm = splitKey(key)
            local cnt = p.counts or {}
            local label = ns.Colorize(C.white, name)
            if realm and realm ~= ns.OwnRealm() then
                label = label .. ns.Colorize(C.dim, "-" .. realm)
            end
            local bits = {}
            if (cnt.quests or 0) > 0 then bits[#bits + 1] = cnt.quests .. "q" end
            if (cnt.dungeonsComplete or 0) + (cnt.dungeonsIncomplete or 0) > 0 then
                bits[#bits + 1] = ((cnt.dungeonsComplete or 0) + (cnt.dungeonsIncomplete or 0)) .. "d"
            end
            if (cnt.trades or 0) > 0 then bits[#bits + 1] = cnt.trades .. "t" end
            if #bits > 0 then
                label = label .. "  " .. ns.Colorize(C.dim, "(" .. table.concat(bits, " ") .. ")")
            end
            row.text:SetText(label)
            row.key = key
            row.selected:SetShown(key == selectedKey)
            row:Show()
        else
            row.key = nil
            row.text:SetText("")
            row.selected:Hide()
            row:Hide()
        end
    end
end

--------------------------------------------------------------------------------
-- Detail logic
--------------------------------------------------------------------------------
local function addLine(t, s) t[#t + 1] = s or "" end

function UI:BuildDetail(key)
    local db = InteractwitDB
    local p = key and db and db.players and db.players[key]
    if not p then
        if key then
            local nm = UI.selectedName or select(1, splitKey(key))
            return ns.Colorize(C.header, nm) .. "\n\n" .. ns.Colorize(C.dim,
                "No interactions recorded with this player yet.\n\n" ..
                "This fills in automatically as you complete quests, run dungeons,\n" ..
                "or trade together while grouped.")
        end
        return ns.Colorize(C.dim, "Select a player on the left to see how you've interacted with them.")
    end
    local name, realm = splitKey(key)
    local L = {}

    -- Header
    local hdr = ns.Colorize(C.header, name) .. (realm and ns.Colorize(C.dim, "-" .. realm) or "")
    local meta = {}
    if p.level then meta[#meta + 1] = "level " .. p.level end
    local cn = className(p.classID); if cn then meta[#meta + 1] = cn end
    local rn = raceName(p.raceID); if rn then meta[#meta + 1] = rn end
    if #meta > 0 then hdr = hdr .. "  " .. ns.Colorize(C.dim, table.concat(meta, " · ")) end
    addLine(L, hdr)
    if p.native and p.native.currentLocation then
        addLine(L, ns.Colorize(C.dim, (p.native.isOnline and "Online" or "Offline") .. " — " .. p.native.currentLocation))
    end
    addLine(L, "")

    -- Last interaction
    if p.last then
        local kind = p.last.rolodexType and ns.RolodexName(p.last.rolodexType) or nil
        addLine(L, ns.Colorize(C.accent, "Last interaction"))
        addLine(L, "  " .. (p.last.description or kind or "?"))
        addLine(L, "  " .. ns.Colorize(C.dim, fmtDate(p.last.ts) ..
            (p.last.zone and ("  ·  " .. p.last.zone) or "")))
        addLine(L, "")
    end

    -- Summary counts
    local c = p.counts or {}
    addLine(L, ns.Colorize(C.accent, "Summary"))
    addLine(L, "  Quests together:   " .. ns.Colorize(C.good, c.quests or 0))
    addLine(L, "  Dungeons complete: " .. ns.Colorize(C.good, c.dungeonsComplete or 0)
        .. ns.Colorize(C.dim, "   incomplete: ") .. ns.Colorize(C.warn, c.dungeonsIncomplete or 0))
    addLine(L, "  Dungeon bosses:    " .. ns.Colorize(C.white, c.bossKills or 0))
    addLine(L, "  Trades:            " .. ns.Colorize(C.good, c.trades or 0))
    addLine(L, "")

    -- Zones (from quests)
    if p.zones and next(p.zones) then
        local zlist = {}
        for z, n in pairs(p.zones) do zlist[#zlist + 1] = { z = z, n = n } end
        table.sort(zlist, function(a, b) return a.n > b.n end)
        addLine(L, ns.Colorize(C.accent, "Quest zones"))
        for i = 1, math.min(#zlist, 8) do
            addLine(L, "  " .. zlist[i].z .. ns.Colorize(C.dim, "  ×" .. zlist[i].n))
        end
        addLine(L, "")
    end

    -- Recent quests
    if p.quests and #p.quests > 0 then
        addLine(L, ns.Colorize(C.accent, "Recent quests") .. ns.Colorize(C.dim, "  (" .. #p.quests .. " total)"))
        for i = #p.quests, math.max(1, #p.quests - 9), -1 do
            local qd = p.quests[i]
            addLine(L, "  • " .. ns.Colorize(C.white, qd.title))
            addLine(L, "     " .. ns.Colorize(C.dim, (qd.zone or "?") .. "  ·  " .. fmtDate(qd.ts)))
        end
        addLine(L, "")
    end

    -- Dungeons
    if p.dungeons and #p.dungeons > 0 then
        addLine(L, ns.Colorize(C.accent, "Dungeons"))
        for i = #p.dungeons, math.max(1, #p.dungeons - 11), -1 do
            local d = p.dungeons[i]
            local tag = d.complete and ns.Colorize(C.good, "[complete]") or ns.Colorize(C.warn, "[incomplete]")
            local diff = d.difficulty and (" " .. ns.Colorize(C.dim, d.difficulty)) or ""
            addLine(L, "  " .. tag .. " " .. ns.Colorize(C.white, d.name) .. diff)
            addLine(L, "     " .. ns.Colorize(C.dim, (d.bossCount or 0) .. " boss kill(s) together  ·  " .. fmtDate(d.ts)))
        end
        addLine(L, "")
    end

    -- Trades
    if p.trades and #p.trades > 0 then
        addLine(L, ns.Colorize(C.accent, "Trades"))
        for i = #p.trades, math.max(1, #p.trades - 7), -1 do
            local t = p.trades[i]
            addLine(L, "  • " .. ns.Colorize(C.dim, fmtDate(t.ts)))
            local given = {}
            for _, it in ipairs(t.myItems or {}) do
                given[#given + 1] = (it.link or "item") .. (it.count and it.count > 1 and ("x" .. it.count) or "")
            end
            local m1 = fmtMoney(t.myMoney); if m1 then given[#given + 1] = m1 end
            if #given > 0 then addLine(L, "     you gave: " .. table.concat(given, ", ")) end

            local got = {}
            for _, it in ipairs(t.theirItems or {}) do
                got[#got + 1] = (it.link or "item") .. (it.count and it.count > 1 and ("x" .. it.count) or "")
            end
            local m2 = fmtMoney(t.theirMoney); if m2 then got[#got + 1] = m2 end
            if #got > 0 then addLine(L, "     you got:  " .. table.concat(got, ", ")) end
        end
        addLine(L, "")
    end

    -- Blizzard's native recent feed
    if p.native and p.native.interactions and #p.native.interactions > 0 then
        addLine(L, ns.Colorize(C.accent, "Blizzard recent-allies feed"))
        if p.native.note and p.native.note ~= "" then
            addLine(L, "  " .. ns.Colorize(C.dim, "note: " .. p.native.note))
        end
        for i = 1, math.min(#p.native.interactions, 10) do
            local it = p.native.interactions[i]
            local d = (it.description and it.description ~= "" and it.description) or ns.RolodexName(it.type)
            addLine(L, "  • " .. d .. "  " .. ns.Colorize(C.dim, fmtDate(it.timestamp)))
        end
        addLine(L, "")
    end

    return table.concat(L, "\n")
end

function UI:UpdateDetail()
    detailText:SetText(UI:BuildDetail(selectedKey))
    local h = detailText:GetStringHeight() + 20
    detailChild:SetHeight(h)
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------
function UI:Toggle()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        if ns.SyncRecentAllies then ns.SyncRecentAllies() end
        UI:Refresh()
    end
end

-- Scroll the list so the currently selected player is visible.
function UI:ScrollToSelected()
    local list = UI.filtered or {}
    local idx
    for i, k in ipairs(list) do
        if k == selectedKey then idx = i; break end
    end
    if not idx then return end
    local maxOffset = math.max(0, #list - NUM_ROWS)
    local offset = math.max(0, math.min(idx - math.floor(NUM_ROWS / 2), maxOffset))
    local sb = _G["InteractwitListScrollScrollBar"]
    if sb and sb.SetValue then
        pcall(sb.SetValue, sb, offset * ROW_HEIGHT)
    end
    UI:UpdateList()
end

-- Open the window focused on a specific player (used by right-click menus).
function UI:OpenForPlayer(key, displayName)
    if not key then return end
    selectedKey = key
    UI.selectedName = displayName
    if not f:IsShown() then
        f:Show() -- OnShow triggers a Refresh
    end
    if ns.SyncRecentAllies then ns.SyncRecentAllies() end
    if (search:GetText() or "") ~= "" then
        search:SetText("") -- clear any filter so the player can be shown/scrolled to
    end
    UI:Refresh()
    UI:ScrollToSelected()
    UI:UpdateDetail()
end

f:SetScript("OnShow", function() UI:Refresh() end)

ns:RegisterEvent("IW_TOGGLE_UI", function() UI:Toggle() end)
ns:RegisterEvent("IW_DATA_CHANGED", function() UI:Refresh() end)
