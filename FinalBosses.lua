-- Interactwit - FinalBosses.lua
-- Helper data for deciding when a dungeon run is "complete".
--
-- How completion is detected (in priority order, see Tracker.lua):
--   1. LFG_COMPLETION_REWARD  -> fires for finished Dungeon Finder / random runs.
--   2. Blizzard's own RolodexType.CompleteDungeon from C_RecentAllies for a
--      participant during the current run.
--   3. This table: the ENCOUNTER_END "encounterID" (a DungeonEncounterID) of a
--      dungeon's LAST boss. When that boss dies successfully, the run is complete.
--
-- For manually-formed (non-Finder) groups, signals 1 and 2 may not fire, so this
-- table is the reliable fallback. It ships mostly empty on purpose: DungeonEncounterIDs
-- differ between game versions and WoW: Forever is in beta, so hard-coding a full
-- list now would rot. It's trivial to populate yourself:
--
--   1. Run a dungeon and kill the final boss.
--   2. Interactwit prints the encounterID of every boss to chat (see Tracker.lua's
--      debug line, toggle with /run InteractwitDB.debug = true).
--   3. Add:  ns.FINAL_BOSSES[<encounterID>] = "Dungeon Name"
--
-- Even with this table empty, runs are still tracked: you'll see how many bosses
-- you killed together, and runs finished via Dungeon Finder are marked complete.

local ADDON, ns = ...

ns.FINAL_BOSSES = {
    -- [63]   = "Deadmines (Edwin VanCleef)",   -- example only; verify the ID on your client
    -- [1064] = "Shadowfang Keep",
}

function ns.IsFinalBoss(encounterID)
    return encounterID ~= nil and ns.FINAL_BOSSES[encounterID] ~= nil
end
