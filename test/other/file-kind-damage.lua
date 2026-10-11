-- Every registered file kind (script/file-kinds.lua) is fed damaged documents: a text that is being typed is damaged most of the time, and
-- a scan that runs for ever (it did, in config-hygiene on `["a" }`) freezes the whole server. Starting from the `samples` of each kind,
-- every text with one character deleted and every start of the text goes through diagnose, completion, hover, definition and the code
-- actions. A call that runs past an instruction budget, or raises an error, fails the test (the budget is a debug count hook, so an
-- endless loop ends instead of hanging the suite). Plugins that register a kind bring their own samples; with no kind, nothing is tested.
local kinds = require 'file-kinds'

local TICK   = 1000000   -- instructions between two looks of the hook
local TICKS  = 60        -- a single call may use this many: far beyond any honest scan of a text this size

--- Run `fn(...)` in this coroutine under the instruction budget.
---@param fn  function
---@param ... any
---@return boolean ok
---@return any     result
local function guarded(fn, ...)
    local ticks = 0
    debug.sethook(function ()
        ticks = ticks + 1
        if ticks > TICKS then
            error('over the instruction budget (an endless loop?)', 2)
        end
    end, '', TICK)
    local ok, result = pcall(fn, ...)
    debug.sethook()
    return ok, result
end

---@param text string
---@return fileKind.position[]
local function positions(text)
    ---@type fileKind.position[]
    local found = { { line = 0, character = 0 } }
    local row = 0
    for line in (text .. string.char(10)):gmatch('(.-)' .. string.char(10)) do
        if row == 1 or row == 3 then
            found[#found+1] = { line = row, character = #line }
            found[#found+1] = { line = row, character = math.max(0, #line // 2) }
        end
        row = row + 1
    end
    found[#found+1] = { line = row - 1, character = 0 }
    return found
end

local base = TESTROOTURI:gsub('/$', '')
local tested = 0

for _, kind in ipairs(kinds.all()) do
    for _, sample in ipairs(kind.samples or {}) do
        local uri = base .. sample.name
        assert(kind.match(uri), ('the sample %s is a document of the kind %s'):format(sample.name, kind.id))

        ---@param text string
        ---@param what string
        local function attempt(text, what)
            local ok, found = guarded(kind.diagnose, uri, text)
            assert(ok, ('%s: diagnose of %s: %s'):format(kind.id, what, tostring(found)))
            ---@type fileKind.clientDiagnostic[]
            local client = {}
            for _, diag in ipairs(found --[[@as fileKind.diagnostic[] ]]) do
                client[#client+1] = { code = diag.code, message = diag.message, range = diag.range }
            end
            for _, position in ipairs(positions(text)) do
                for _, name in ipairs { 'complete', 'hover', 'definition' } do
                    local fn = kind[name]
                    if fn then
                        local ok2, err = guarded(fn, uri, text, position)
                        assert(ok2, ('%s: %s of %s at %d:%d: %s'):format(kind.id, name, what, position.line, position.character, tostring(err)))
                    end
                end
            end
            if kind.codeAction then
                local range = { start = { line = 0, character = 0 }, ['end'] = { line = 1000, character = 0 } }
                local ok3, err = guarded(kind.codeAction, uri, text, range, client)
                assert(ok3, ('%s: codeAction of %s: %s'):format(kind.id, what, tostring(err)))
            end
            tested = tested + 1
        end

        attempt(sample.text, 'the sample')
        attempt('', 'an empty text')
        for i = 1, #sample.text do
            attempt(sample.text:sub(1, i - 1) .. sample.text:sub(i + 1), ('the sample without character %d'):format(i))
            attempt(sample.text:sub(1, i), ('the first %d characters of the sample'):format(i))
        end
    end
end

assert(tested > 0 or #kinds.all() == 0, 'at least one kind brings samples')
