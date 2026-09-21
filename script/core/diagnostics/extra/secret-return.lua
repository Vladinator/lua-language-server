-- Companion of need-check-secret.lua (which owns the flag that says a value is secret).
-- `---@return nosecret string` (one slot) and `---@nosecret` above a function (every return) say that
-- the function must not return a secret value: a `return` statement whose value is known to be secret is
-- reported on that value. A value that was checked with a `---@secret-check` function is not secret any
-- more. The call of a `nosecret` function is not cleared of secrecy by this tag: the coder unwraps it
-- (`---@secret-unwrap`) where the secret becomes plain.
--
-- Only what is known is reported: `return f()` with an unannotated `f` is unknown, and a call that
-- returns several values is checked in its first slot only.
--
-- A function that is declared both secret (`---@secret`, `---@return secret ...`) and `nosecret` is a
-- contradiction: it is reported on the `nosecret` tag and its returns are not checked.
-- The `nosecret` keyword and tag belong to the secret vocabulary (need-check-secret.lua); this file
-- only reads them.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'This function is declared `nosecret`, but this value is secret. Check it with a `---@secret-check` function or unwrap it (`---@secret-unwrap`) first.'
local CONTRADICTION = '`secret` and `nosecret` contradict each other on this function; keep one.'

protoDiagnostic.register {
    'secret-return',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for returning a secret value from a function declared `nosecret` (`---@nosecret`, `---@return nosecret string`), and for a function declared both secret and `nosecret`.',
}

-- what the docs above a function say about the secrecy of its returns
---@class secret.returnDecl
---@field all?     parser.object -- the `---@nosecret` tag
---@field slots    table<integer, parser.object> -- return slot to its `nosecret` type item
---@field anySlot? parser.object -- one of the `nosecret` slots
---@field declaredSecret boolean -- `---@secret` or a `secret` slot

--- What the docs above a function say about secrecy of its returns, without compiling anything.
---@param func parser.object
---@return secret.returnDecl?
local function getDecl(func)
    -- (`M.f = function () end` keeps the docs on the assignment, as `---@secret` there reads them)
    local parent = func.parent
    ---@type parser.object[]?
    local docs   = func.bindDocs
    ---@type parser.object[]?
    local outer  = parent and parent.value == func and parent.bindDocs or nil
    if not docs and not outer then
        return nil
    end
    ---@type parser.object[]
    local all = {}
    for _, list in ipairs { docs or {}, outer or {} } do
        for i = 1, #list do
            all[#all+1] = list[i]
        end
    end
    ---@type secret.returnDecl
    local decl = { slots = {}, declaredSecret = false }
    local found = false
    for i = 1, #all do
        ---@type parser.object
        local doc = all[i]
        if doc.type == 'doc.nosecret' then
            decl.all = doc
            found    = true
        elseif doc.type == 'doc.secret' then
            decl.declaredSecret = true
        elseif doc.type == 'doc.return' and doc.returns then
            for j = 1, #doc.returns do
                ---@type parser.object
                local item = doc.returns[j]
                if item.nosecret then
                    decl.slots[item.returnIndex or j] = item
                    decl.anySlot = decl.anySlot or item
                    found = true
                elseif item.secret then
                    decl.declaredSecret = true
                end
            end
        end
    end
    if not found then
        return nil
    end
    return decl
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'function', function (func)
        local decl = getDecl(func)
        if not decl then
            return
        end
        if decl.declaredSecret then
            local at = decl.all or decl.anySlot --[[@as parser.object]]
            callback {
                start   = at.start,
                finish  = at.finish,
                message = CONTRADICTION,
            }
            return
        end
        local returns = func.returns
        if not returns then
            return
        end
        for i = 1, #returns do
            ---@type parser.object
            local ret = returns[i]
            for slot = 1, #ret do
                if decl.all or decl.slots[slot] then
                    local value = ret[slot]
                    await.delay()
                    if vm.compileNode(value):hasFlag('secret') then
                        callback {
                            start   = value.start,
                            finish  = value.finish,
                            message = MESSAGE,
                        }
                    end
                end
            end
        end
    end)
end
