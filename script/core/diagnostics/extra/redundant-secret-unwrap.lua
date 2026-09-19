-- Companion of need-check-secret.lua (the plugin that owns `@secret-unwrap`).
-- `---@secret-unwrap` on a local only has a purpose when that local would
-- otherwise be secret; when it clears nothing, the tag is dead weight (or the
-- code it guarded was fixed): report it, like `unfulfilled-expect` does for
-- `expect-next-line`.

local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = '`@secret-unwrap` has nothing to unwrap here: the value is not secret.'

protoDiagnostic.register {
    'redundant-secret-unwrap',
} {
    group    = 'secret',
    severity = 'Warning',
    status   = 'Opened',
}

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end

    ---@type table<parser.object, boolean> unwrap doc -> cleared something
    local used = {}
    ---@type parser.object[]
    local docs = {}

    ---@async
    guide.eachSourceType(state.ast, 'local', function (source)
        if not source.bindDocs then
            return
        end
        for _, doc in ipairs(source.bindDocs) do
            if doc.type == 'doc.secret-unwrap' then
                await.delay()
                -- compiling runs the genesis rule that clears the flag
                vm.compileNode(source)
                if used[doc] == nil then
                    docs[#docs+1] = doc
                    used[doc] = false
                end
                if doc.secretUnwrapUsed then
                    used[doc] = true
                end
            end
        end
    end)

    for _, doc in ipairs(docs) do
        if not used[doc] then
            callback {
                start   = doc.start,
                finish  = doc.finish,
                message = MESSAGE,
            }
        end
    end
end
