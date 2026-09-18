local core     = require 'core.completion'
local files    = require 'files'
local catch    = require 'catch'
local guide    = require 'parser.guide'
local compare  = require 'compare'

EXISTS = compare.EXISTS

---@param a any
---@param b any
local function include(a, b)
    if a == EXISTS and b ~= nil then
        return true
    end
    local tp1, tp2 = type(a), type(b)
    if tp1 ~= tp2 then
        return false
    end
    if tp1 == 'table' then
        -- a / b are array of completion results
        -- when checking `include`, the array index order is not important
        -- thus need to check every results in b
        for _, v1 in ipairs(a --[[@as any[] ]]) do
            local ok = false
            for _, v2 in ipairs(b --[[@as any[] ]]) do
                if compare.eq(v1, v2) then
                    ok = true
                    break
                end
            end
            if not ok then
                return false
            end
        end
        return true
    end
    return compare.eq(a, b)
end

rawset(_G, 'TEST', true)

Cared = {
    ['label']               = true,
    ['kind']                = true,
    ['textEdit']            = true,
    ['additionalTextEdits'] = true,
    ['deprecated']          = true,
}

IgnoreFunction = false
ContinueTyping = false

function TEST(script)
    return function (expect)
        ---@diagnostic disable: await-in-sync
        local expect = expect --[[@as any]]
        local newScript, catched = catch(script, '?')

        files.setText(TESTURI, newScript)
        local state = files.getState(TESTURI)
        assert(state)
        local inputPos = catched['?'][1][2] --[[@as integer]]
        if ContinueTyping then
            ---@type string?
            local triggerCharacter = script:sub(inputPos - 1, inputPos - 1)
            if triggerCharacter == '\n'
            or (triggerCharacter --[[@as string]]):find '%w_' then
                triggerCharacter = nil
            end
            core.completion(TESTURI, inputPos, triggerCharacter)
        end
        local offset = guide.positionToOffset(state, inputPos)
        ---@type string?
        local triggerCharacter = script:sub(offset, offset)
        if triggerCharacter == '\n'
        or (triggerCharacter --[[@as string]]):find '%w_' then
            triggerCharacter = nil
        end
        local result = core.completion(TESTURI, inputPos, triggerCharacter)

        if not expect then
            assert(result == nil)
            return
        end
        assert(result ~= nil)
        result.enableCommon = nil
        for _, item in ipairs(result) do
            if item.id then
                local r = core.resolve(item.id --[[@as integer]])
                for k, v in pairs((r or {}) --[[@as table<any, any>]]) do
                    (item --[[@as table<any, any>]])[k] = v
                end
            end
            for k in pairs(item --[[@as table<any, any>]]) do
                if not Cared[k] then
                    (item --[[@as table<any, any>]])[k] = nil
                end
            end
            if item.description then
                item.description = tostring(item.description)
            end
        end
        if IgnoreFunction then
            for i = #result, 1, -1 do
                local item = result[i]
                if item.label:find '%('
                and not item.label:find 'function' then
                    result[i] = result[#result]
                    result[#result] = nil
                end
            end
        end
        assert(result)
        ---@diagnostic disable-next-line: inject-field, no-unknown -- test-only: clears a legacy field that no longer exists on the type
        result.complete = nil
        if type(expect) == 'function' then
            expect(result)
        else
            local expectT = expect --[[@as table<any, any>]]
            if expectT.include then
                expectT.include = nil
                assert(include(expect, result))
            else
                assert(compare.eq(expect, result))
            end
        end
        files.remove(TESTURI)
    end
end

require 'completion.common'
require 'completion.continue'
