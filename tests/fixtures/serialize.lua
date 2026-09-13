-- tests/fixtures/serialize.lua
--
-- The wire format, spec 000 section 5. Ops not yet implemented (OPEN, SUBMIT,
-- STATE, RESULT, ROLLS, SKLIST) gain cases with the specs that introduce them.

local ns = ...

local function run(input, ns)
    local S = ns.Serialize

    if input.kind == "envelope" then
        local wire = S.pack(input.op, input.body, input.msgId)
        local msg = S.unpack(wire[1])
        return { wire = wire[1], chunks = #wire, op = msg.op, seq = msg.seq,
                 total = msg.total, body = msg.body, proto = msg.proto }

    elseif input.kind == "malformed" then
        local msg, why = S.unpack(input.wire)
        return { ok = msg ~= nil, why = why }

    elseif input.kind == "chunking" then
        local body = string.rep(input.char or "x", input.length)
        local wire = S.pack("STATE", body, "9")
        local assembler = S.newAssembler()
        local joined
        for i = 1, #wire do
            joined = S.assemble(assembler, "Steve", S.unpack(wire[i]), 0)
        end
        local longest = 0
        for i = 1, #wire do
            if #wire[i] > longest then longest = #wire[i] end
        end
        return { chunks = #wire, roundTrip = (joined == body), withinCap = (longest <= 255) }

    elseif input.kind == "outOfOrder" then
        local body = string.rep("abcde", 100)
        local wire = S.pack("STATE", body, "9")
        local assembler = S.newAssembler()
        local joined
        for _, i in ipairs({ 3, 1, 2 }) do
            if wire[i] then joined = S.assemble(assembler, "Steve", S.unpack(wire[i]), 0) end
        end
        return { roundTrip = (joined == body) }

    elseif input.kind == "interleaved" then
        -- Two senders chunking at once must not corrupt each other.
        local a, b = string.rep("a", 300), string.rep("b", 300)
        local wa, wb = S.pack("STATE", a, "1"), S.pack("STATE", b, "1")
        local assembler = S.newAssembler()
        S.assemble(assembler, "Steve", S.unpack(wa[1]), 0)
        S.assemble(assembler, "Dave", S.unpack(wb[1]), 0)
        local doneB = S.assemble(assembler, "Dave", S.unpack(wb[2]), 0)
        local doneA = S.assemble(assembler, "Steve", S.unpack(wa[2]), 0)
        return { a = (doneA == a), b = (doneB == b) }

    elseif input.kind == "prune" then
        local wire = S.pack("STATE", string.rep("x", 300), "9")
        local assembler = S.newAssembler()
        S.assemble(assembler, "Steve", S.unpack(wire[1]), 0)
        local dropped = S.pruneAssembler(assembler, input.now, 10)
        return { dropped = #dropped }

    elseif input.kind == "roster" then
        local body, err = S.encodeRoster(input.order, input.chars)
        if not body then return { ok = false, err = err ~= nil } end
        local order, chars = S.decodeRoster(body)
        if not order then return { ok = false, err = true } end
        local classes = {}
        for i = 1, #order do classes[i] = chars[order[i]].class end
        return { ok = true, body = body, order = order, classes = classes }

    elseif input.kind == "rosterMsg" then
        -- The ROSTER envelope of spec 012 section 10. Encode and decode must agree
        -- about the campaign id: an encoder that emits what the decoder refuses
        -- turns one sender's bug into an unreadable-roster line in every raid
        -- member's chat.
        local body, err = S.encodeRosterMsg(input.campaignId, input.order, input.chars)
        if not body then return { ok = false, err = err } end
        local msg, why = S.decodeRosterMsg(body)
        if not msg then return { ok = false, err = why } end
        return { ok = true, body = body, campaignId = msg.campaignId, order = msg.order }

    elseif input.kind == "rosterDecode" then
        -- On success the second return is the chars map, not a reason.
        local order, second = S.decodeRoster(input.body)
        local err
        if not order then err = second end
        return { ok = order ~= nil, count = order and #order or 0, err = err }

    elseif input.kind == "unsafe" then
        local element, err = S.encodeElement(input.fields)
        return { ok = element ~= nil, err = err ~= nil }

    -- Round payloads, spec 002. Each case encodes, asserts the exact body, then
    -- decodes it back: a change to either side alone fails the case.
    elseif input.kind == "sklist" then
        local body = S.encodeSklist(input.campaignId, input.version, input.seed, input.order,
            input.events)
        local msg, why = S.decodeSklist(body)
        if not msg then return { ok = false, body = body, why = why } end
        local events = {}
        for i, e in ipairs(msg.events or {}) do
            events[i] = string.format("%d:%s:%s:%s", e.version or 0, e.kind, tostring(e.char),
                table.concat(e.present or {}, "+"))
        end
        return { ok = true, body = body, campaignId = msg.campaignId, version = msg.version,
                 seed = msg.seed, order = msg.order, events = events }

    elseif input.kind == "sync" then
        local msg = S.decodeSync(S.encodeSync(input.roundId, input.campaignId, input.version))
        return { roundId = msg.roundId or "", campaignId = msg.campaignId or "",
                 version = msg.priorityVersion }

    elseif input.kind == "cstate" then
        -- CSTATE is the campaign codec on the wire: the handover carries the log, so
        -- the log has to survive the round trip intact (spec 010 section 8).
        local body, err = S.encodeCampaign(input.campaign)
        if not body then return { ok = false, why = err } end
        local back, why = S.decodeCampaign(body)
        if not back then return { ok = false, why = why } end
        local kinds = {}
        for i, e in ipairs(back.priority.log) do
            kinds[i] = (e.version or 0) .. ":" .. e.kind .. ":" .. table.concat(e.present or {}, "+")
        end
        return { ok = true, lootMode = back.host.lootMode, tierCount = back.host.tierCount,
                 version = back.priority.version, seed = back.priority.seed,
                 seedChars = back.priority.seedChars, order = back.priority.order, log = kinds }

    elseif input.kind == "openMode" then
        local body = S.encodeOpen(input.campaignId, input.roundId, input.tierCount,
            input.secondsLeft, input.items, input.lootMode)
        local msg = S.decodeOpen(body)
        return { body = body, lootMode = msg.lootMode }

    elseif input.kind == "open" then
        local body = S.encodeOpen(input.campaignId, input.roundId, input.tierCount,
            input.secondsLeft, input.items)
        local msg, why = S.decodeOpen(body)
        if not msg then return { ok = false, body = body, why = why } end
        return { ok = true, body = body, campaignId = msg.campaignId, roundId = msg.roundId,
                 tierCount = msg.tierCount, secondsLeft = msg.secondsLeft,
                 items = msg.items }

    elseif input.kind == "submit" then
        local body = S.encodeSubmit(input.roundId, input.entries)
        local msg, why = S.decodeSubmit(body)
        if not msg then return { ok = false, body = body, why = why } end
        return { ok = true, body = body, roundId = msg.roundId, entries = msg.entries }

    elseif input.kind == "state" then
        local body = S.encodeState(input.roundId, input.submitted, input.entries)
        local msg, why = S.decodeState(body)
        if not msg then return { ok = false, body = body, why = why } end
        return { ok = true, body = body, submitted = msg.submitted, entries = msg.entries }

    elseif input.kind == "result" then
        local body = S.encodeResult(input.roundId, input.results)
        local msg, why = S.decodeResult(body)
        if not msg then return { ok = false, body = body, why = why } end
        return { ok = true, body = body, results = msg.results }

    elseif input.kind == "rolls" then
        local body = S.encodeRolls(input.roundId, input.rolls)
        local msg, why = S.decodeRolls(body)
        if not msg then return { ok = false, body = body, why = why } end
        return { ok = true, body = body, rolls = msg.rolls }

    elseif input.kind == "abort" then
        local body = S.encodeAbort(input.roundId, input.reason)
        local msg, why = S.decodeAbort(body)
        if not msg then return { ok = false, body = body, why = why } end
        return { ok = true, body = body, roundId = msg.roundId, reason = msg.reason }

    elseif input.kind == "config" then
        local body = S.encodeConfig(input.campaignId, input.tierCount, input.timerSeconds,
            input.lootMode, input.lockHierarchy)
        local msg, why = S.decodeConfig(body)
        if not msg then return { ok = false, body = body, why = why } end
        return { ok = true, body = body, campaignId = msg.campaignId, tierCount = msg.tierCount,
                 timerSeconds = msg.timerSeconds, lootMode = msg.lootMode,
                 lockHierarchy = msg.lockHierarchy }

    elseif input.kind == "decodeConfig" then
        local msg, why = S.decodeConfig(input.body)
        if not msg then return { ok = false, why = why } end
        return { ok = true, campaignId = msg.campaignId, tierCount = msg.tierCount,
                 timerSeconds = msg.timerSeconds, lootMode = msg.lootMode,
                 lockHierarchy = msg.lockHierarchy }

    elseif input.kind == "decodeOnly" then
        local msg, why = S[input.decoder](input.body)
        return { ok = msg ~= nil, why = why }

    elseif input.kind == "decodeRolls" then
        local msg, why = S.decodeRolls(input.body)
        if not msg then return { ok = false, why = why } end
        return { ok = true, roundId = msg.roundId, rolls = msg.rolls }
    end
    return nil
end

return {
    name = "serialize",
    run = run,
    cases = {
        {
            name = "HI round-trips through the envelope",
            input = { kind = "envelope", op = "HI", body = "0.1.0", msgId = "1" },
            expected = { wire = "2^HI^1^1^1^0.1.0", chunks = 1, op = "HI", seq = 1,
                         total = 1, body = "0.1.0", proto = 2 },
        },
        {
            name = "RREQ carries an empty body",
            input = { kind = "envelope", op = "RREQ", body = "", msgId = "2" },
            expected = { wire = "2^RREQ^2^1^1^", chunks = 1, op = "RREQ", seq = 1,
                         total = 1, body = "", proto = 2 },
        },
        {
            name = "a body containing field delimiters survives unpacking",
            input = { kind = "envelope", op = "OPEN", body = "s1^3^99^1=item:49623=1", msgId = "3" },
            expected = { wire = "2^OPEN^3^1^1^s1^3^99^1=item:49623=1", chunks = 1, op = "OPEN",
                         seq = 1, total = 1, body = "s1^3^99^1=item:49623=1", proto = 2 },
        },

        -- Malformed input is rejected, never half-parsed.
        {
            name = "an empty message is rejected",
            input = { kind = "malformed", wire = "" },
            expected = { ok = false, why = "empty message" },
        },
        {
            name = "a truncated envelope is rejected",
            input = { kind = "malformed", wire = "1^HI^1^1" },
            expected = { ok = false, why = "malformed envelope" },
        },
        {
            name = "a non-numeric sequence is rejected",
            input = { kind = "malformed", wire = "1^HI^1^x^1^body" },
            expected = { ok = false, why = "non-numeric envelope field" },
        },
        {
            name = "a sequence past the total is rejected",
            input = { kind = "malformed", wire = "1^HI^1^3^2^body" },
            expected = { ok = false, why = "bad chunk sequence" },
        },
        {
            name = "a missing op is rejected",
            input = { kind = "malformed", wire = "1^^1^1^1^body" },
            expected = { ok = false, why = "missing op or message id" },
        },

        -- Chunking.
        {
            name = "a 180-byte body is a single chunk",
            input = { kind = "chunking", length = 180 },
            expected = { chunks = 1, roundTrip = true, withinCap = true },
        },
        {
            name = "a 181-byte body splits into two chunks",
            input = { kind = "chunking", length = 181 },
            expected = { chunks = 2, roundTrip = true, withinCap = true },
        },
        {
            name = "a 1000-byte body splits into six chunks and rejoins",
            input = { kind = "chunking", length = 1000 },
            expected = { chunks = 6, roundTrip = true, withinCap = true },
        },
        {
            name = "chunks arriving out of order still rejoin",
            input = { kind = "outOfOrder" },
            expected = { roundTrip = true },
        },
        {
            name = "two senders using the same message id do not corrupt each other",
            input = { kind = "interleaved" },
            expected = { a = true, b = true },
        },
        {
            name = "an incomplete set is dropped after the timeout",
            input = { kind = "prune", now = 11 },
            expected = { dropped = 1 },
        },
        {
            name = "an incomplete set inside the timeout is kept",
            input = { kind = "prune", now = 9 },
            expected = { dropped = 0 },
        },

        -- ROSTER payload.
        {
            name = "ROSTER round-trips order and classes",
            input = {
                kind = "roster",
                order = { "Steve", "Sneaky", "Smash" },
                chars = { Steve = { class = "MAGE" }, Sneaky = { class = "ROGUE" },
                          Smash = { class = "WARRIOR" } },
            },
            expected = {
                ok = true,
                body = "Steve=MAGE~Sneaky=ROGUE~Smash=WARRIOR",
                order = { "Steve", "Sneaky", "Smash" },
                classes = { "MAGE", "ROGUE", "WARRIOR" },
            },
        },
        {
            name = "a ROSTER message round-trips its campaign id",
            input = {
                kind = "rosterMsg", campaignId = "Steve-1757155200",
                order = { "Steve", "Sneaky" },
                chars = { Steve = { class = "MAGE" }, Sneaky = { class = "ROGUE" } },
            },
            expected = {
                ok = true, body = "Steve-1757155200^Steve=MAGE~Sneaky=ROGUE",
                campaignId = "Steve-1757155200", order = { "Steve", "Sneaky" },
            },
        },
        {
            -- A client with no active campaign publishing anyway: refused here, by
            -- the sender, rather than broadcast for every receiver to reject aloud.
            name = "a ROSTER message with no campaign id is refused at encode",
            input = {
                kind = "rosterMsg", campaignId = "", order = { "Steve" },
                chars = { Steve = { class = "MAGE" } },
            },
            expected = { ok = false, err = "ROSTER has no campaign id" },
        },
        {
            name = "a ROSTER message with a missing campaign id is refused at encode",
            input = {
                kind = "rosterMsg", order = { "Steve" },
                chars = { Steve = { class = "MAGE" } },
            },
            expected = { ok = false, err = "ROSTER has no campaign id" },
        },
        {
            name = "an empty ROSTER decodes to an empty roster",
            input = { kind = "rosterDecode", body = "" },
            expected = { ok = true, count = 0 },
        },
        {
            name = "a duplicated name in ROSTER is rejected outright",
            input = { kind = "rosterDecode", body = "Steve=MAGE~steve=ROGUE" },
            expected = { ok = false, count = 0, err = "duplicate character: steve" },
        },
        {
            name = "an empty name in ROSTER is rejected outright",
            input = { kind = "rosterDecode", body = "Steve=MAGE~=ROGUE" },
            expected = { ok = false, count = 0, err = "empty character name" },
        },
        {
            name = "a reserved character in a field is refused, not escaped",
            input = { kind = "unsafe", fields = { "Ste^ve", "MAGE" } },
            expected = { ok = false, err = true },
        },
        {
            name = "a pipe in a field is refused",
            input = { kind = "unsafe", fields = { "Steve", "|cff00ff00" } },
            expected = { ok = false, err = true },
        },

        --------------------------------------------------------------------------
        -- Round payloads, spec 002.
        --------------------------------------------------------------------------
        {
            name = "OPEN round-trips its items and its remaining seconds",
            input = {
                kind = "open", campaignId = "Steve-1757155200", roundId = "Steve-100", tierCount = 3,
                secondsLeft = 180,
                items = { { idx = 1, itemString = "item:40395", count = 1 },
                          { idx = 2, itemString = "item:40474", count = 2 } },
            },
            expected = {
                ok = true,
                body = "Steve-1757155200^Steve-100^3^180^1=item:40395=1~2=item:40474=2",
                campaignId = "Steve-1757155200", roundId = "Steve-100", tierCount = 3, secondsLeft = 180,
                items = { { idx = 1, itemString = "item:40395", count = 1 },
                          { idx = 2, itemString = "item:40474", count = 2 } },
            },
        },
        {
            name = "an OPEN carrying no items is rejected rather than shown empty",
            input = { kind = "decodeOnly", decoder = "decodeOpen", body = "Steve-1757155200^Steve-100^3^180^" },
            expected = { ok = false, why = "OPEN carries no items" },
        },
        {
            name = "an OPEN with no round id is rejected",
            input = { kind = "decodeOnly", decoder = "decodeOpen", body = "Steve-1757155200^^3^180^1=item:1=1" },
            expected = { ok = false, why = "OPEN has no round id" },
        },
        {
            name = "SUBMIT round-trips the override and the star flags",
            input = {
                kind = "submit", roundId = "Steve-100",
                entries = { { itemIdx = 1, char = "Sneaky", override = true, star = false },
                            { itemIdx = 2, char = "Smash", override = false, star = true } },
            },
            expected = {
                ok = true,
                body = "Steve-100^1=Sneaky=1=0~2=Smash=0=1",
                roundId = "Steve-100",
                entries = { { itemIdx = 1, char = "Sneaky", override = true, star = false },
                            { itemIdx = 2, char = "Smash", override = false, star = true } },
            },
        },
        {
            name = "an empty SUBMIT is valid and means a full withdrawal",
            input = { kind = "submit", roundId = "Steve-100", entries = {} },
            expected = { ok = true, body = "Steve-100^", roundId = "Steve-100",
                         entries = {} },
        },
        {
            name = "STATE round-trips who submitted and every accepted entry",
            input = {
                kind = "state", roundId = "Steve-100",
                submitted = { "Dave", "Steve" },
                entries = { { itemIdx = 1, char = "Sneaky", owner = "Steve", tier = 2 },
                            { itemIdx = 1, char = "Bonk", owner = "Dave", tier = 1 } },
            },
            expected = {
                ok = true,
                body = "Steve-100^Dave~Steve^1=Sneaky=Steve=2~1=Bonk=Dave=1",
                submitted = { "Dave", "Steve" },
                entries = { { itemIdx = 1, char = "Sneaky", owner = "Steve", tier = 2 },
                            { itemIdx = 1, char = "Bonk", owner = "Dave", tier = 1 } },
            },
        },
        {
            name = "a STATE with nobody submitted yet round-trips",
            input = { kind = "state", roundId = "Steve-100", submitted = {}, entries = {} },
            expected = { ok = true, body = "Steve-100^^", submitted = {}, entries = {} },
        },
        {
            name = "RESULT round-trips a win and an unclaimed item",
            input = {
                kind = "result", roundId = "Steve-100",
                results = { { itemIdx = 1, winner = "Sneaky", tier = 2, roll = 87,
                              outcome = "WON" },
                            { itemIdx = 2, winner = "", tier = 0, roll = 0,
                              outcome = "UNCLAIMED" } },
            },
            expected = {
                ok = true,
                body = "Steve-100^1=Sneaky=2=87=WON~2==0=0=UNCLAIMED",
                results = { { itemIdx = 1, winner = "Sneaky", tier = 2, roll = 87,
                              outcome = "WON" },
                            { itemIdx = 2, tier = 0, roll = 0, outcome = "UNCLAIMED" } },
            },
        },
        {
            name = "a RESULT with no outcome is rejected",
            input = { kind = "decodeOnly", decoder = "decodeResult",
                      body = "Steve-100^1=Sneaky=2=87=" },
            expected = { ok = false, why = "RESULT for item 1 has no outcome" },
        },
        {
            name = "ROLLS round-trips an entry that never rolled",
            input = {
                kind = "rolls", roundId = "Steve-100",
                rolls = { { itemIdx = 1, char = "Sneaky", tier = 2, roll = 87, listIdx = 0 },
                          { itemIdx = 1, char = "Smash", tier = 3, roll = 0, listIdx = 0,
                            status = "NC" } },
            },
            expected = {
                ok = true,
                body = "Steve-100^1=Sneaky=2=87=0==~1=Smash=3=0=0=NC=",
                rolls = { { itemIdx = 1, char = "Sneaky", tier = 2, roll = 87, listIdx = 0,
                            status = "", rerolled = {} },
                          { itemIdx = 1, char = "Smash", tier = 3, roll = 0, listIdx = 0,
                            status = "NC", rerolled = {} } },
            },
        },
        {
            -- The results table shows "83 -> 47 (tie re-roll)" from this, and marks an
            -- SK entry the one-win rule removed. Neither is derivable from the roll alone.
            name = "ROLLS carries re-rolls and the withdrawn status",
            input = {
                kind = "rolls", roundId = "Steve-100",
                rolls = { { itemIdx = 1, char = "Sneaky", tier = 1, roll = 83, listIdx = 0,
                            rerolled = { 83, 47 } },
                          { itemIdx = 2, char = "Bonk", tier = 1, roll = 0, listIdx = 4,
                            status = "WD" } },
            },
            expected = {
                ok = true,
                body = "Steve-100^1=Sneaky=1=83=0==83+47~2=Bonk=1=0=4=WD=",
                rolls = { { itemIdx = 1, char = "Sneaky", tier = 1, roll = 83, listIdx = 0,
                            status = "", rerolled = { 83, 47 } },
                          { itemIdx = 2, char = "Bonk", tier = 1, roll = 0, listIdx = 4,
                            status = "WD", rerolled = {} } },
            },
        },
        {
            name = "a ROLLS row without the status fields decodes as rolled",
            input = { kind = "decodeRolls", body = "Steve-100^1=Sneaky=2=87=0" },
            expected = { ok = true, roundId = "Steve-100",
                         rolls = { { itemIdx = 1, char = "Sneaky", tier = 2, roll = 87,
                                     listIdx = 0, status = "", rerolled = {} } } },
        },
        {
            name = "OPEN carries its loot mode as a trailing field",
            input = { kind = "openMode", campaignId = "Steve-1757155200", roundId = "Steve-100", tierCount = 3,
                      secondsLeft = 180,
                      items = { { idx = 1, itemString = "item:49623", count = 1 } }, lootMode = "SK" },
            expected = { body = "Steve-1757155200^Steve-100^3^180^1=item:49623=1^SK", lootMode = "SK" },
        },
        {
            name = "an OPEN without a loot mode decodes as ROLL",
            input = { kind = "openMode", campaignId = "Steve-1757155200", roundId = "Steve-100", tierCount = 3,
                      secondsLeft = 180,
                      items = { { idx = 1, itemString = "item:49623", count = 1 } } },
            expected = { body = "Steve-1757155200^Steve-100^3^180^1=item:49623=1", lootMode = "ROLL" },
        },
        {
            name = "SKLIST round-trips version, seed and order",
            input = { kind = "sklist", campaignId = "Steve-1757155200", version = 47, seed = 1757155200,
                      order = { "Chop", "Sneaky", "Steve" } },
            expected = { ok = true, body = "Steve-1757155200^47^1757155200^Chop~Sneaky~Steve^",
                         campaignId = "Steve-1757155200", version = 47,
                         seed = 1757155200, order = { "Chop", "Sneaky", "Steve" }, events = {} },
        },
        {
            name = "SKLIST carries the events that produced the version",
            input = { kind = "sklist", campaignId = "Steve-1757155200", version = 48,
                      seed = 1757155200, order = { "Sneaky", "Steve", "Chop" },
                      events = { { kind = "suicide", char = "Chop", from = 1, version = 48,
                                   at = 1757155300, by = "Steve", present = { 1, 2, 3 } } } },
            expected = { ok = true,
                         body = "Steve-1757155200^48^1757155200^Sneaky~Steve~Chop^"
                             .. "suicide=Chop=1===48=1757155300=Steve=1+2+3=",
                         campaignId = "Steve-1757155200", version = 48, seed = 1757155200,
                         order = { "Sneaky", "Steve", "Chop" },
                         events = { "48:suicide:Chop:1+2+3" } },
        },
        {
            name = "a SYNC asks about a round and a campaign history at once",
            input = { kind = "sync", roundId = "Steve-100", campaignId = "Steve-1757155200",
                      version = 47 },
            expected = { roundId = "Steve-100", campaignId = "Steve-1757155200", version = 47 },
        },
        {
            name = "a CSTATE round-trips the host settings and the whole log",
            input = { kind = "cstate", campaign = {
                id = "Steve-1757155200", label = "Raid", createdAt = 1757155200,
                createdBy = "Steve",
                host = { tierCount = 2, timerSeconds = 120, qualityThreshold = 3, lootMode = "SK" },
                priority = {
                    version = 2, seed = 1757155200,
                    seedChars = { "Chop", "Sneaky", "Steve" },
                    order = { "Sneaky", "Steve", "Chop" },
                    log = {
                        { kind = "seed", seed = 1757155200, version = 1, at = 1757155200,
                          by = "Steve", chars = { "Chop", "Sneaky", "Steve" } },
                        { kind = "suicide", char = "Chop", from = 1, version = 2,
                          at = 1757155300, by = "Steve", present = { 1, 2, 3 } },
                    },
                },
            } },
            expected = { ok = true, lootMode = "SK", tierCount = 2, version = 2,
                         seed = 1757155200, seedChars = { "Chop", "Sneaky", "Steve" },
                         order = { "Sneaky", "Steve", "Chop" },
                         log = { "1:seed:", "2:suicide:1+2+3" } },
        },
        {
            name = "an empty SKLIST is a valid unseeded list",
            input = { kind = "sklist", campaignId = "Steve-1757155200", version = 0, seed = 0, order = {} },
            expected = { ok = true, body = "Steve-1757155200^0^0^^", campaignId = "Steve-1757155200", version = 0, seed = 0,
                         order = {}, events = {} },
        },
        {
            name = "an SKLIST naming a character twice is rejected",
            input = { kind = "decodeOnly", decoder = "decodeSklist", body = "Steve-1757155200^1^5^Ann~ann" },
            expected = { ok = false, why = "SKLIST lists ann twice" },
        },
        {
            name = "ABORT round-trips its reason code",
            input = { kind = "abort", roundId = "Steve-100", reason = "ML_CHANGED" },
            expected = { ok = true, body = "Steve-100^ML_CHANGED",
                         roundId = "Steve-100", reason = "ML_CHANGED" },
        },
        {
            name = "an ABORT with no reason is rejected",
            input = { kind = "decodeOnly", decoder = "decodeAbort", body = "Steve-100^" },
            expected = { ok = false, why = "ABORT has no reason code" },
        },
        {
            name = "CFG round-trips the tier count, the timer, the loot mode and the lock",
            input = { kind = "config", campaignId = "Steve-1757155200", tierCount = 3, timerSeconds = 180,
                      lootMode = "ROLL", lockHierarchy = true },
            expected = { ok = true, body = "Steve-1757155200^3^180^ROLL^1^0", campaignId = "Steve-1757155200", tierCount = 3,
                         timerSeconds = 180, lootMode = "ROLL", lockHierarchy = true },
        },
        {
            -- False is a real value, so it has to survive the trip; a lock that
            -- could only ever be turned on would trap every campaign.
            name = "an unlocked campaign encodes and decodes as unlocked",
            input = { kind = "config", campaignId = "Steve-1757155200", tierCount = 3, timerSeconds = 180,
                      lootMode = "ROLL", lockHierarchy = false },
            expected = { ok = true, body = "Steve-1757155200^3^180^ROLL^0^0", campaignId = "Steve-1757155200", tierCount = 3,
                         timerSeconds = 180, lootMode = "ROLL", lockHierarchy = false },
        },
        {
            -- A host running a build from before spec 014 sends four fields. The
            -- default is on, so their raid is not silently unlocked.
            name = "a CFG with no lock field reads as locked",
            input = { kind = "decodeConfig", body = "Steve-1757155200^3^180^ROLL" },
            expected = { ok = true, campaignId = "Steve-1757155200", tierCount = 3,
                         timerSeconds = 180, lootMode = "ROLL", lockHierarchy = true },
        },
        {
            name = "a CFG with a non-numeric timer is rejected",
            input = { kind = "decodeOnly", decoder = "decodeConfig", body = "Steve-1757155200^3^soon^ROLL" },
            expected = { ok = false, why = "CFG has a non-numeric field" },
        },
    },
}
