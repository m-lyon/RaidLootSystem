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

    elseif input.kind == "rosterDecode" then
        -- On success the second return is the chars map, not a reason.
        local order, second = S.decodeRoster(input.body)
        local err
        if not order then err = second end
        return { ok = order ~= nil, count = order and #order or 0, err = err }

    elseif input.kind == "unsafe" then
        local element, err = S.encodeElement(input.fields)
        return { ok = element ~= nil, err = err ~= nil }
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
            expected = { wire = "1^HI^1^1^1^0.1.0", chunks = 1, op = "HI", seq = 1,
                         total = 1, body = "0.1.0", proto = 1 },
        },
        {
            name = "RREQ carries an empty body",
            input = { kind = "envelope", op = "RREQ", body = "", msgId = "2" },
            expected = { wire = "1^RREQ^2^1^1^", chunks = 1, op = "RREQ", seq = 1,
                         total = 1, body = "", proto = 1 },
        },
        {
            name = "a body containing field delimiters survives unpacking",
            input = { kind = "envelope", op = "OPEN", body = "s1^3^99^1=item:49623=1", msgId = "3" },
            expected = { wire = "1^OPEN^3^1^1^s1^3^99^1=item:49623=1", chunks = 1, op = "OPEN",
                         seq = 1, total = 1, body = "s1^3^99^1=item:49623=1", proto = 1 },
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
    },
}
