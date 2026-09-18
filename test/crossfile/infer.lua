local files   = require 'files'
local furi    = require 'file-uri'
local vm      = require 'vm'
local guide   = require 'parser.guide'
local catch   = require 'catch'
local compare = require 'compare'

rawset(_G, 'TEST', true)

---@param uri uri?
---@param pos integer?
---@return parser.object?
local function getSource(uri, pos)
    if not uri or not pos then
        return
    end
    local state = files.getState(uri)
    if not state then
        return
    end
    ---@type parser.object?
    local result
    guide.eachSourceContain(state.ast, pos, function (source)
        if source.type == 'local'
        or source.type == 'getlocal'
        or source.type == 'setlocal'
        or source.type == 'setglobal'
        or source.type == 'getglobal'
        or source.type == 'field'
        or source.type == 'method'
        or source.type == 'function'
        or source.type == 'table'
        or source.type == 'doc.type.name' then
            result = source
        end
    end)
    return result
end

---@diagnostic disable: await-in-sync
---@param expect any
local function TEST(expect)
    ---@type integer?
    local sourcePos
    ---@type uri?
    local sourceUri
    for _, file in ipairs(expect --[[@as any[] ]]) do
        local script, list = catch(file.content, '?')
        local uri          = furi.encode(TESTROOT .. file.path)
        files.setText(uri, script)
        files.compileState(uri)
        if #list['?'] > 0 then
            sourceUri = uri
            sourcePos = ((list['?'][1][1] --[[@as integer]]) + (list['?'][1][2] --[[@as integer]])) // 2
        end
    end

    local _ <close> = function ()
        for _, info in ipairs(expect --[[@as any[] ]]) do
            files.remove(furi.encode(info.path))
        end
    end

    local source = getSource(sourceUri, sourcePos)
    assert(source)
    local view = vm.getInfer(source):view(sourceUri --[[@as uri]])
    assert(compare.eq(view, expect.infer))
end

TEST {
    {
        path = 'a.lua',
        content = [[
---@class T
local x

---@class V
x.y = 1
]],
    },
    {
        path = 'b.lua',
        content = [[
---@type T
local x

if x.y then
    print(x.<?y?>)
end
        ]],
    },
    infer = 'V',
}

TEST {
    { path = 'a.lua', content = [[
X = 1
X = true
]], },
    { path = 'b.lua', content = [[
print(<?X?>)
]], },
    infer = 'integer',
}

TEST {
    { path = 'a.lua', content = [[
---@meta
X = 1
X = true
]], },
    { path = 'b.lua', content = [[
print(<?X?>)
]], },
    infer = 'boolean|integer',
}

TEST {
    { path = 'a.lua', content = [[
return 1337, "string", true
]], },
    { path = 'b.lua', content = [[
local <?a?>, b, c = require 'a
]], },
    infer = 'integer',
}

TEST {
    { path = 'a.lua', content = [[
return 1337, "string", true
]], },
    { path = 'b.lua', content = [[
local a, <?b?>, c = require 'a
]], },
    infer = 'unknown',
}

TEST {
    { path = 'a.lua', content = [[
return 1337, "string", true
]], },
    { path = 'b.lua', content = [[
local a, b, <?c?> = require 'a
]], },
    infer = 'nil',
}

TEST {
    { path = 'a.lua', content = [[
return 1337, "string", true
]], },
    { path = 'b.lua', content = [[
local a, b, <?c?> = dofile 'a'
]], },
    infer = 'unknown',
}

TEST {
    { path = 'a.lua', content = [[
return 1337, "string", true
]], },
    { path = 'b.lua', content = [[
local <?a?>, b, c = dofile 'a.lua'
]], },
    infer = 'integer',
}
