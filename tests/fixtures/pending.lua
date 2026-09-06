-- tests/fixtures/pending.lua
--
-- The pure half of Modules/Pending.lua (spec 007 section 5): the record and its
-- expiry, the countdown text and urgency, and the login reminder.

local ns = ...

local function run(input, ns)
    local Pending = ns.Pending

    if input.op == "new" then
        local r = Pending.NewRecord(input.award, input.now)
        return { winner = r.winner, takenAt = r.takenAt, expiresAt = r.expiresAt,
                 delivered = r.delivered, expired = r.expired, copy = r.copy }

    elseif input.op == "expire" then
        local records = input.records
        local newly = Pending.Expire(records, input.now)
        local names = {}
        for i, r in ipairs(newly) do names[i] = r.winner end
        local kept = {}
        for i, r in ipairs(records) do kept[i] = r.winner .. (r.expired and " expired" or "") end
        return { newly = names, records = kept }

    elseif input.op == "left" then
        local text, urgency = Pending.TimeLeft(input.record, input.now)
        return { text = text, urgency = urgency }

    elseif input.op == "reminder" then
        return Pending.ReminderLines(input.records, input.now, function(s) return "[" .. s .. "]" end)
    end
    error("unknown op: " .. tostring(input.op))
end

local T = 1757155200

return {
    name = "pending",
    run = run,
    cases = {
        {
            -- Acceptance: a pending record has a correct two-hour expiry.
            name = "a new record expires two hours after it was taken",
            input = { op = "new", now = T,
                      award = { char = "Bonk", owner = "Dave", itemString = "item:1",
                                sessionId = "Steve-100", itemIdx = 1, copy = 2 } },
            expected = { winner = "Bonk", takenAt = T, expiresAt = T + 7200,
                         delivered = false, expired = false, copy = 2 },
        },
        {
            -- Acceptance: an expired item is retained and marked, not deleted.
            name = "expiry marks what ran out and keeps everything",
            input = { op = "expire", now = T + 7200, records = {
                { winner = "Bonk", takenAt = T, expiresAt = T + 7200, delivered = false },
                { winner = "Ann", takenAt = T + 100, expiresAt = T + 7300, delivered = false },
                { winner = "Cat", takenAt = T - 5000, expiresAt = T + 2200, delivered = true },
            } },
            expected = { newly = { "Bonk" }, records = { "Bonk expired", "Ann", "Cat" } },
        },
        {
            name = "an already-expired record is not reported again",
            input = { op = "expire", now = T + 9000, records = {
                { winner = "Bonk", takenAt = T, expiresAt = T + 7200, delivered = false, expired = true },
            } },
            expected = { newly = {}, records = { "Bonk expired" } },
        },
        { name = "over an hour left reads as hours and minutes",
          input = { op = "left", now = T, record = { expiresAt = T + 5520 } },
          expected = { text = "1h 32m", urgency = "ok" } },
        { name = "under thirty minutes is amber",
          input = { op = "left", now = T, record = { expiresAt = T + 1500 } },
          expected = { text = "25m", urgency = "amber" } },
        { name = "under ten minutes is red",
          input = { op = "left", now = T, record = { expiresAt = T + 300 } },
          expected = { text = "5m", urgency = "red" } },
        { name = "nothing left is expired",
          input = { op = "left", now = T + 7200, record = { expiresAt = T + 7200 } },
          expected = { text = "expired", urgency = "expired" } },
        {
            -- Acceptance: a login reminder names item, recipient and remaining time.
            name = "the reminder names item, recipient and time left, oldest first",
            input = { op = "reminder", now = T, records = {
                { itemString = "item:2", winner = "Ann", owner = "Anna", takenAt = T - 60,
                  expiresAt = T + 7140, delivered = false },
                { itemString = "item:1", winner = "Bonk", owner = "Dave", takenAt = T - 8000,
                  expiresAt = T - 800, delivered = false, expired = true },
                { itemString = "item:3", winner = "Cat", owner = "C", takenAt = T - 100,
                  expiresAt = T + 7100, delivered = true },
            } },
            expected = {
                "[item:1] for Bonk (Dave) -- the trade window has EXPIRED; it is bound to you.",
                "[item:2] for Ann (Anna) -- 1h 59m left to trade it.",
            },
        },
        { name = "nothing outstanding means no reminder",
          input = { op = "reminder", now = T, records = {} }, expected = {} },
    },
}
