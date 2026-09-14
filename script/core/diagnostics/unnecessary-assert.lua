local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Unnecessary assert: this expression is always truthy.'

-- Disabled upstream (09900e7daf, "too many false alert, disable
-- `unnecessary-assert` for now") -- e.g. `assert(arg[1])` where `arg` is
-- typed `T[]`. Confirmed root cause: indexing a `T[]`-typed value by an
-- integer literal infers the element as plain `T`, not `T?`, even though
-- Lua arrays carry no compile-time length -- an empty or short array
-- makes `arg[1]` genuinely nil at runtime, so alwaysTruthy() wrongly
-- calls it always-truthy. A real fix needs alwaysTruthy() (or this
-- diagnostic) to recognize "this is an array-element index" from
-- source.args[1]'s AST shape, since the compiled vm.node alone can't
-- distinguish that from any other same-typed expression; changing array
-- indexing to infer `T?` everywhere would ripple across the whole type
-- system (every `local x = arr[1]` would need new nil-checks). Uncomment
-- once that's resolved upstream; see the commented-out TEST blocks in
-- test/diagnostics/unnecessary-assert.lua for the cases that must still
-- pass first (verified against this file's own migrated logic already).
-- protoDiagnostic.register {
--     'unnecessary-assert',
-- } {
--     group    = 'type-check',
--     severity = 'Warning',
--     status   = 'Opened',
-- }

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'call', function (source)
        await.delay()
        local currentFunc = guide.getParentFunction(source)
        if currentFunc and source.node.special == 'assert' and source.args[1] then
            local argNode = vm.compileNode(source.args[1])
            if argNode:alwaysTruthy() then
                callback {
                    start   = source.node.start,
                    finish  = source.node.finish,
                    message = MESSAGE,
                }
            end
        end
    end)
end
