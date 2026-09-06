-- tests/fixtures/history.lua
--
-- The pure half of Modules/History.lua (spec 008): the record built from a host
-- session and from a client mirror, upsert, pruning, delivery updated in place,
-- filtering, the per-character summary, and both exports.

local ns = ...

local T = 1757155200

local function run(input, ns)
    local H = ns.History

    if input.op == "host" then
        return H.FromHost(input.session, input.ctx)
    elseif input.op == "client" then
        return H.FromClient(input.session, input.ctx)
    elseif input.op == "upsert" then
        local records = input.records
        local _, added = H.Upsert(records, input.record)
        local keys = {}
        for i, r in ipairs(records) do
            keys[i] = r.sessionId .. (r.recordedAsHost and "/host" or "/client") .. ":" .. tostring(r.tag)
        end
        return { added = added, keys = keys }
    elseif input.op == "prune" then
        local kept, removed, unexported = H.Prune(input.records, input.now, input.opts)
        local k, r = {}, {}
        for i, rec in ipairs(kept) do k[i] = rec.sessionId end
        for i, rec in ipairs(removed) do r[i] = rec.sessionId end
        return { kept = k, removed = r, unexported = unexported }
    elseif input.op == "delivery" then
        local records = input.records
        local updated = H.UpdateDelivery(records, input.award)
        local awards = {}
        for _, rec in ipairs(records) do
            for _, item in ipairs(rec.items) do
                for _, a in ipairs(item.awards) do
                    awards[#awards + 1] = string.format("%s/%d/%d %s %s", rec.sessionId,
                        item.itemIdx, a.copy, a.delivery, tostring(a.priorIndex))
                end
            end
        end
        return { updated = updated ~= nil, awards = awards, count = #records }
    elseif input.op == "filter" then
        local out = {}
        for i, r in ipairs(H.Filter(input.records, input.filter)) do out[i] = r.sessionId end
        return out
    elseif input.op == "summary" then
        local out = {}
        for i, w in ipairs(H.CharacterSummary(input.records, input.char)) do
            out[i] = w.itemString .. " " .. tostring(w.delivery)
        end
        return out
    elseif input.op == "text" then
        return H.ExportText(input.records, { labelOf = function(s) return "[" .. s .. "]" end,
                                             formatDate = function(t) return "D" .. t end })
    elseif input.op == "csv" then
        local text = H.ExportCSV(input.records, { nameOf = function(s) return "Item " .. s end })
        local lines = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        return lines
    elseif input.op == "view" then
        local v = H.ToView(input.record)
        local rolls, results = {}, {}
        for i, r in ipairs(v.rolls) do rolls[i] = r.char .. ":" .. r.status end
        for i, r in ipairs(v.results) do results[i] = tostring(r.winner) .. ":" .. r.outcome end
        return { isSK = v.isSK, tierCount = v.tierCount, rolls = rolls, results = results,
                 items = #v.items }
    end
    error("unknown op: " .. tostring(input.op))
end

-- A resolved host session: two items, one with a re-roll and a not-consulted entry,
-- one unclaimed; the winner's award delivered.
local HOST_SESSION = {
    id = "Steve-100", host = "Steve", state = "CLOSED", tierCount = 3,
    openedAt = T, closedAt = T + 180, lootMode = "ROLL",
    priorityAtOpen = { version = 3, order = { "Bonk", "Steve" } },
    items = {
        { idx = 1, itemString = "item:49623", count = 1, lootSlot = 2,
          info = { itemLevel = 264, quality = 4, equipLoc = "INVTYPE_CHEST" } },
        { idx = 2, itemString = "item:50000", count = 1, lootSlot = 3,
          info = { itemLevel = 251, quality = 4, equipLoc = "INVTYPE_FINGER" } },
    },
    entries = {
        [1] = { { char = "Bonk", owner = "Dave", tier = 1, star = true, override = false,
                  submittedAt = T + 30, revisedAt = nil },
                { char = "Sneaky", owner = "Steve", tier = 2, submittedAt = T + 40, revisedAt = T + 60 } },
        [2] = {},
    },
    results = {
        { itemIdx = 1, unclaimed = false, degraded = false,
          awards = { { char = "Bonk", owner = "Dave", tier = 1, roll = 91 } },
          record = { { char = "Bonk", owner = "Dave", tier = 1, listIdx = 0, rolled = true, roll = 91, rerolled = { 91, 95 } },
                     { char = "Sneaky", owner = "Steve", tier = 2, listIdx = 0, rolled = false, roll = 0, rerolled = {}, reason = "not consulted" } } },
        { itemIdx = 2, unclaimed = true, degraded = false, awards = {}, record = {} },
    },
    awards = {
        [1] = { { copy = 1, char = "Bonk", delivery = "DELIVERED", deliveryPath = "MASTER_LOOT",
                  deliveredAt = T + 190, priorIndex = 1 } },
        [2] = {},
    },
}

local HOST_CTX = { now = T + 200, zone = "Icecrown Citadel", source = "Lord Marrowgar",
                   raid = { "Steve", "Dave" }, timerSeconds = 180, qualityThreshold = 4 }

local EXPECTED_HOST = {
    sessionId = "Steve-100", recordedAsHost = true, timestamp = T, closedAt = T + 180,
    zone = "Icecrown Citadel", source = "Lord Marrowgar", host = "Steve",
    settings = { tierCount = 3, timerSeconds = 180, qualityThreshold = 4, lootMode = "ROLL" },
    priorityAtOpen = { version = 3, order = { "Bonk", "Steve" } },
    raid = { "Steve", "Dave" },
    outcome = "RESOLVED",
    items = {
        { itemIdx = 1, itemString = "item:49623", count = 1, lootSlot = 2, unclaimed = false, degraded = false,
          itemLevel = 264, quality = 4, equipLoc = "INVTYPE_CHEST",
          entries = {
              { char = "Bonk", owner = "Dave", tier = 1, listIdx = 0, star = true, override = false,
                rolled = true, roll = 91, rerolled = { 91, 95 }, withdrawn = false,
                submittedAt = T + 30 },
              { char = "Sneaky", owner = "Steve", tier = 2, listIdx = 0, star = false, override = false,
                rolled = false, roll = 0, rerolled = {}, withdrawn = false, reason = "not consulted",
                submittedAt = T + 40, revisedAt = T + 60 },
          },
          awards = { { copy = 1, char = "Bonk", owner = "Dave", tier = 1, roll = 91, listIdx = 0,
                       priorIndex = 1, delivery = "DELIVERED", deliveryPath = "MASTER_LOOT",
                       deliveredAt = T + 190 } } },
        { itemIdx = 2, itemString = "item:50000", count = 1, lootSlot = 3, unclaimed = true, degraded = false,
          itemLevel = 251, quality = 4, equipLoc = "INVTYPE_FINGER",
          entries = {}, awards = {} },
    },
}

-- The same batch as a client saw it.
local CLIENT_SESSION = {
    id = "Steve-100", host = "Steve", state = "CLOSED", tierCount = 3, lootMode = "ROLL",
    openedAt = T + 1, closedAt = T + 181,
    items = { { idx = 1, itemString = "item:49623", count = 1 },
              { idx = 2, itemString = "item:50000", count = 1 } },
    entries = { [1] = { { char = "Bonk", owner = "Dave", tier = 1 }, { char = "Sneaky", owner = "Steve", tier = 2 } } },
    results = { { itemIdx = 1, winner = "Bonk", tier = 1, roll = 91, outcome = "WON" },
                { itemIdx = 2, winner = nil, tier = 0, roll = 0, outcome = "UNCLAIMED" } },
    rolls = { { itemIdx = 1, char = "Bonk", tier = 1, roll = 91, listIdx = 0, status = "", rerolled = { 91, 95 } },
              { itemIdx = 1, char = "Sneaky", tier = 2, roll = 0, listIdx = 0, status = "NC", rerolled = {} } },
}

local CLIENT_CTX = { now = T + 200, zone = "Icecrown Citadel", raid = { "Dave", "Steve" },
                     infoOf = function(s)
                         if s == "item:49623" then return { itemLevel = 264, quality = 4, equipLoc = "INVTYPE_CHEST" } end
                         return { itemLevel = 251, quality = 4, equipLoc = "INVTYPE_FINGER" }
                     end }

local function rec(id, ts, fields)
    local r = { sessionId = id, recordedAsHost = true, timestamp = ts, zone = "ICC", source = "Boss",
                host = "Steve", settings = { tierCount = 3, lootMode = "ROLL" }, raid = {}, outcome = "RESOLVED",
                items = {} }
    for k, v in pairs(fields or {}) do r[k] = v end
    return r
end

local function won(id, ts, char, owner, itemString, delivery, extra)
    local r = rec(id, ts, extra)
    r.items[1] = { itemIdx = 1, itemString = itemString, count = 1, unclaimed = false, degraded = false,
                   itemLevel = 264, quality = 4, equipLoc = "INVTYPE_CHEST",
                   entries = { { char = char, owner = owner, tier = 1, listIdx = 0, star = false,
                                 rolled = true, roll = 80, rerolled = {}, withdrawn = false },
                               { char = "Loser", owner = "Anna", tier = 2, listIdx = 0, star = false,
                                 rolled = false, roll = 0, rerolled = {}, withdrawn = false } },
                   awards = { { copy = 1, char = char, owner = owner, tier = 1, roll = 80, listIdx = 0,
                                delivery = delivery } } }
    return r
end

return {
    name = "history",
    run = run,
    cases = {
        {
            -- Acceptance: a resolved batch produces exactly one record with every item
            -- and every entry, including entries that never rolled; the settings block
            -- captures the tier count in force at open; itemLevel/quality/equipLoc are
            -- written under ROLL.
            name = "the host record carries every item, every entry and the delivery",
            input = { op = "host", session = HOST_SESSION, ctx = HOST_CTX },
            expected = EXPECTED_HOST,
        },
        {
            -- Acceptance: an aborted batch is recorded with its reason and entries.
            name = "an aborted batch keeps its reason and what was submitted",
            input = { op = "host", ctx = HOST_CTX, session = {
                id = "Steve-101", host = "Steve", state = "ABORTED", abortReason = "MANUAL",
                tierCount = 2, openedAt = T, closedAt = T + 50, lootMode = "ROLL",
                items = { { idx = 1, itemString = "item:1", count = 1, info = { itemLevel = 200, quality = 4, equipLoc = "INVTYPE_HEAD" } } },
                entries = { [1] = { { char = "Bonk", owner = "Dave", tier = 1, submittedAt = T + 10 } } },
            } },
            expected = {
                sessionId = "Steve-101", recordedAsHost = true, timestamp = T, closedAt = T + 50,
                zone = "Icecrown Citadel", source = "Lord Marrowgar", host = "Steve",
                settings = { tierCount = 2, timerSeconds = 180, qualityThreshold = 4, lootMode = "ROLL" },
                raid = { "Steve", "Dave" }, outcome = "ABORTED", abortReason = "MANUAL",
                items = { { itemIdx = 1, itemString = "item:1", count = 1, unclaimed = false, degraded = false,
                            itemLevel = 200, quality = 4, equipLoc = "INVTYPE_HEAD",
                            entries = { { char = "Bonk", owner = "Dave", tier = 1, listIdx = 0, star = false,
                                          override = false, rolled = false, roll = 0, rerolled = {},
                                          withdrawn = false, submittedAt = T + 10 } },
                            awards = {} } },
            },
        },
        {
            -- Acceptance: client and host records of one batch are distinguishable.
            name = "the client record is built from STATE, RESULT and ROLLS",
            input = { op = "client", session = CLIENT_SESSION, ctx = CLIENT_CTX },
            expected = {
                sessionId = "Steve-100", recordedAsHost = false, timestamp = T + 1, closedAt = T + 181,
                zone = "Icecrown Citadel", host = "Steve",
                settings = { tierCount = 3, lootMode = "ROLL" },
                raid = { "Dave", "Steve" }, outcome = "RESOLVED",
                items = {
                    { itemIdx = 1, itemString = "item:49623", count = 1, unclaimed = false, degraded = false,
                      itemLevel = 264, quality = 4, equipLoc = "INVTYPE_CHEST",
                      entries = {
                          { char = "Bonk", owner = "Dave", tier = 1, listIdx = 0, star = false, override = false,
                            rolled = true, roll = 91, rerolled = { 91, 95 }, withdrawn = false },
                          { char = "Sneaky", owner = "Steve", tier = 2, listIdx = 0, star = false, override = false,
                            rolled = false, roll = 0, rerolled = {}, withdrawn = false, reason = "not consulted" },
                      },
                      awards = { { copy = 1, char = "Bonk", owner = "Dave", tier = 1, roll = 91, listIdx = 0 } } },
                    { itemIdx = 2, itemString = "item:50000", count = 1, unclaimed = true, degraded = false,
                      itemLevel = 251, quality = 4, equipLoc = "INVTYPE_FINGER", entries = {}, awards = {} },
                },
            },
        },
        {
            name = "upsert replaces a same-side record and keeps the other side's",
            input = { op = "upsert",
                      records = { { sessionId = "S1", recordedAsHost = true, tag = "a" },
                                  { sessionId = "S1", recordedAsHost = false, tag = "b" } },
                      record = { sessionId = "S1", recordedAsHost = true, tag = "c" } },
            expected = { added = false, keys = { "S1/host:c", "S1/client:b" } },
        },
        {
            -- Acceptance: loading with 501 batches prunes to 500, oldest first.
            name = "pruning drops the oldest past the cap and counts the unexported",
            input = (function()
                local records = {}
                for i = 1, 6 do
                    records[i] = rec("S" .. i, T + i * 100, { exported = (i == 1) })
                end
                return { op = "prune", records = records, now = T + 1000, opts = { max = 4, maxAge = 90 * 86400 } }
            end)(),
            expected = { kept = { "S3", "S4", "S5", "S6" }, removed = { "S1", "S2" }, unexported = 1 },
        },
        {
            name = "pruning drops records older than the age limit whatever the count",
            input = { op = "prune", now = T + 100 * 86400, opts = { max = 500, maxAge = 90 * 86400 },
                      records = { rec("OLD", T), rec("NEW", T + 50 * 86400) } },
            expected = { kept = { "NEW" }, removed = { "OLD" }, unexported = 1 },
        },
        {
            -- Acceptance: a pending item delivered later updates the original record
            -- in place; no second record is created.
            name = "a delivery update changes the original award in place",
            input = { op = "delivery",
                      records = { won("S1", T, "Bonk", "Dave", "item:1", "PENDING") },
                      award = { sessionId = "S1", itemIdx = 1, copy = 1, delivery = "DELIVERED",
                                deliveryPath = "TRADE", deliveredAt = T + 2400, priorIndex = 4 } },
            expected = { updated = true, awards = { "S1/1/1 DELIVERED 4" }, count = 1 },
        },
        {
            name = "a delivery update for an unknown batch changes nothing",
            input = { op = "delivery", records = { won("S1", T, "Bonk", "Dave", "item:1", "PENDING") },
                      award = { sessionId = "S9", itemIdx = 1, copy = 1, delivery = "DELIVERED" } },
            expected = { updated = false, awards = { "S1/1/1 PENDING nil" }, count = 1 },
        },
        {
            name = "filters: by character, owner, item, date and roster, newest first",
            input = { op = "filter", filter = { char = "bonk" }, records = {
                won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED"),
                won("S2", T + 10, "Sneaky", "Steve", "item:2", "DELIVERED"),
                won("S3", T + 20, "Bonk", "Dave", "item:3", "PENDING"),
            } },
            expected = { "S3", "S1" },
        },
        {
            name = "filter by owner",
            input = { op = "filter", filter = { owner = "Steve" }, records = {
                won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED"),
                won("S2", T + 10, "Sneaky", "Steve", "item:2", "DELIVERED"),
            } },
            expected = { "S2" },
        },
        {
            name = "filter by item label substring",
            input = { op = "filter", filter = { item = "item:2", labelOf = function(s) return s end }, records = {
                won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED"),
                won("S2", T + 10, "Sneaky", "Steve", "item:2", "DELIVERED"),
            } },
            expected = { "S2" },
        },
        {
            name = "filter by date and by my roster",
            input = { op = "filter", filter = { since = T + 5, roster = { sneaky = true } }, records = {
                won("S1", T, "Sneaky", "Steve", "item:1", "DELIVERED"),
                won("S2", T + 10, "Sneaky", "Steve", "item:2", "DELIVERED"),
                won("S3", T + 20, "Bonk", "Dave", "item:3", "DELIVERED"),
            } },
            expected = { "S2" },
        },
        {
            -- Acceptance (009): a simulated batch does not appear by default.
            name = "simulated records are hidden unless asked for",
            input = { op = "filter", filter = {}, records = {
                won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED", { simulated = true }),
                won("S2", T + 10, "Sneaky", "Steve", "item:2", "DELIVERED"),
            } },
            expected = { "S2" },
        },
        {
            name = "simulated records appear when asked for",
            input = { op = "filter", filter = { includeSimulated = true }, records = {
                won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED", { simulated = true }),
                won("S2", T + 10, "Sneaky", "Steve", "item:2", "DELIVERED"),
            } },
            expected = { "S2", "S1" },
        },
        {
            -- Acceptance: the per-character summary lists what it was awarded, not
            -- what it merely rolled on.
            name = "the character summary is awards only, newest first",
            input = { op = "summary", char = "loser", records = {
                won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED"),
                won("S2", T + 10, "Loser", "Anna", "item:2", "PENDING"),
                won("S3", T + 20, "Loser", "Anna", "item:3", "DELIVERED"),
            } },
            expected = { "item:3 DELIVERED", "item:2 PENDING" },
        },
        {
            name = "plain text export: a batch header and one line per award",
            input = { op = "text", records = { EXPECTED_HOST } },
            expected = "D" .. T .. "  Icecrown Citadel / Lord Marrowgar  (host Steve, ROLL, 3 tiers)\n"
                .. "  [item:49623] -> Bonk (Dave) T1, roll 91, delivered\n"
                .. "  [item:50000] -> unclaimed\n",
        },
        {
            -- Acceptance: CSV of N entries is N rows plus a header.
            name = "CSV export: the header and one row per entry",
            input = { op = "csv", records = { EXPECTED_HOST } },
            expected = {
                "timestamp,zone,source,item,itemLevel,quality,equipLoc,character,owner,tier,listIdx,star,rolled,roll,withdrawn,awarded,delivery",
                T .. ",Icecrown Citadel,Lord Marrowgar,Item item:49623,264,4,INVTYPE_CHEST,Bonk,Dave,1,0,true,true,91,false,true,DELIVERED",
                T .. ",Icecrown Citadel,Lord Marrowgar,Item item:49623,264,4,INVTYPE_CHEST,Sneaky,Steve,2,0,false,false,0,false,false,",
            },
        },
        {
            name = "CSV quotes a field holding a comma",
            input = { op = "csv", records = { won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED", { source = "Lady, Deathwhisper" }) } },
            expected = {
                "timestamp,zone,source,item,itemLevel,quality,equipLoc,character,owner,tier,listIdx,star,rolled,roll,withdrawn,awarded,delivery",
                T .. ',ICC,"Lady, Deathwhisper",Item item:1,264,4,INVTYPE_CHEST,Bonk,Dave,1,0,false,true,80,false,true,DELIVERED',
                T .. ',ICC,"Lady, Deathwhisper",Item item:1,264,4,INVTYPE_CHEST,Loser,Anna,2,0,false,false,0,false,false,',
            },
        },
        {
            -- An item level the cache never supplied is a hole in the row; the booleans
            -- after it must still come out right.
            name = "CSV keeps its columns when an item level is missing",
            input = { op = "csv", records = { (function()
                local r = won("S1", T, "Bonk", "Dave", "item:1", "DELIVERED")
                r.items[1].itemLevel = nil
                r.items[1].equipLoc = nil
                return r
            end)() } },
            expected = {
                "timestamp,zone,source,item,itemLevel,quality,equipLoc,character,owner,tier,listIdx,star,rolled,roll,withdrawn,awarded,delivery",
                T .. ",ICC,Boss,Item item:1,,4,,Bonk,Dave,1,0,false,true,80,false,true,DELIVERED",
                T .. ",ICC,Boss,Item item:1,,4,,Loser,Anna,2,0,false,false,0,false,false,",
            },
        },
        {
            name = "a record converts to the results view the renderer takes",
            input = { op = "view", record = EXPECTED_HOST },
            expected = { isSK = false, tierCount = 3, items = 2,
                         rolls = { "Bonk:", "Sneaky:NC" },
                         results = { "Bonk:WON", "nil:UNCLAIMED" } },
        },
    },
}
