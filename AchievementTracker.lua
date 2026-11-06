----------------------------------------------------------------------
-- VoidQuest Achievement Tracker
-- Surfaces in-progress achievements ranked by completion %
----------------------------------------------------------------------
local VQ = VoidQuest
local mod = VQ:NewModule("AchievementTracker")
VQ.AchievementTracker = mod

-- Limit how many in-progress achievements to scan per category to avoid frame spike
local MAX_PER_CATEGORY = 50
local MIN_PROGRESS_PCT = 10  -- only show achievements at least 10% complete

----------------------------------------------------------------------
-- Walks a category tree looking for in-progress achievements
----------------------------------------------------------------------
local function ScanCategory(categoryID, results)
    local count = GetCategoryNumAchievements and GetCategoryNumAchievements(categoryID) or 0
    if count == 0 then return end

    for i = 1, math.min(count, MAX_PER_CATEGORY) do
        local id, name, _, completed, _, _, _, description = GetAchievementInfo(categoryID, i)
        if id and not completed then
            -- Check criteria progress
            local numCriteria = GetAchievementNumCriteria(id) or 0
            if numCriteria > 1 then
                local done = 0
                for c = 1, numCriteria do
                    local _, _, isDone = GetAchievementCriteriaInfo(id, c)
                    if isDone then done = done + 1 end
                end
                local pct = (done / numCriteria) * 100
                if pct >= MIN_PROGRESS_PCT and done > 0 then
                    table.insert(results, {
                        id = id,
                        name = name,
                        progress = done,
                        max = numCriteria,
                        pct = pct,
                        description = description,
                    })
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Get top N in-progress achievements across categories
----------------------------------------------------------------------
function mod:GetInProgress(limit)
    limit = limit or 12
    local results = {}

    -- Common active categories in current expansion content
    -- Midnight = Expansion 11
    local categories = {
        15536,  -- Midnight Mythic+ category (placeholder ID)
        15537,  -- Midnight Raid
        15538,  -- Midnight Quest
        15539,  -- Midnight Exploration
        15540,  -- Midnight Reputation
        15541,  -- Midnight Dungeon
        15535,  -- Midnight category
    }

    for _, catID in ipairs(categories) do
        ScanCategory(catID, results)
    end

    -- Sort by % descending, return top N
    table.sort(results, function(a, b)
        if a.pct ~= b.pct then return a.pct > b.pct end
        return a.progress > b.progress
    end)

    local truncated = {}
    for i = 1, math.min(limit, #results) do
        table.insert(truncated, results[i])
    end
    return truncated
end

function mod:Init()
    -- No init needed
end
