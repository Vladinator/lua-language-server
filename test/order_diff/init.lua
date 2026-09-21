-- Dev tool, not part of the default suite: run with
--     ODIFF_FILES=script/vm/tracer.lua,script/parser bin/lua-language-server test.lua -n=order_diff
-- The type of a source must not depend on which source was asked for first (the editor asks in one
-- order, the command line in another, diagnostics interleave). For every file it compiles the sources
-- once in source order (the reference), then again in a fresh state in other orders, and prints each
-- source whose type differs:
--     ODIFF<TAB>file:row: <source text> [<node type>]<TAB>ref=<type><TAB><order>=<type>
-- Env:
--     ODIFF_FILES  = comma separated files or directories, relative to the repository (required)
--     ODIFF_ORDERS = rev,shuf1,shuf2 (default) | any of rev, shuf<seed>, cold
--                    `cold` asks for each source alone in a fresh state (slow: one parse per source)
--     ODIFF_COLD_MAX = <n>  with `cold`: only n sources per file, evenly spread (default 200)
--     ODIFF_TYPES  = comma separated node types to look at (default local,getlocal,setlocal,
--                    tablefield,setfield,getfield,call)
local target = TARGET_TEST_NAME --[[@as string?]]
if not target or not ('order_diff'):match(target) then
    return
end

local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'
local util  = require 'utility'
local furi  = require 'file-uri'
local fs    = require 'bee.filesystem'

local wanted = os.getenv('ODIFF_FILES')
if not wanted or wanted == '' then
    error('order_diff: set ODIFF_FILES (comma separated files or directories)')
end

---@type table<string, true>
local kinds = {}
for kind in (os.getenv('ODIFF_TYPES') or 'local,getlocal,setlocal,tablefield,setfield,getfield,call'):gmatch('[^,]+') do
    kinds[kind] = true
end

---@type string[]
local orders = {}
for order in (os.getenv('ODIFF_ORDERS') or 'rev,shuf1,shuf2'):gmatch('[^,]+') do
    orders[#orders+1] = order
end
local coldMax = tonumber(os.getenv('ODIFF_COLD_MAX') or '') or 200

---@type string[]
local paths = {}
---@param path fs.path
local function collect(path)
    if fs.is_directory(path) then
        ---@type string[]
        local children = {}
        for child in fs.pairs(path) do
            children[#children+1] = child:string()
        end
        table.sort(children)
        for _, child in ipairs(children) do
            collect(fs.path(child))
        end
    elseif path:extension() == '.lua' then
        paths[#paths+1] = path:string()
    end
end
for item in wanted:gmatch('[^,]+') do
    collect(ROOT / item)
end

---@param uri  uri
---@param text string
---@return parser.state
local function fresh(uri, text)
    files.remove(uri)
    files.setText(uri, text)
    files.open(uri)
    local state = files.getState(uri)
    assert(state)
    return state
end

---@param state parser.state
---@return parser.object[]
local function collectSources(state)
    ---@type parser.object[]
    local list = {}
    guide.eachSource(state.ast, function (source)
        if kinds[source.type] then
            list[#list+1] = source
        end
    end)
    return list
end

---@param uri    uri
---@param source parser.object
---@return string
local function view(uri, source)
    return vm.getInfer(source):view(uri)
end

---@param state  parser.state
---@param source parser.object
---@return string
local function describe(state, source)
    local from = guide.positionToOffset(state, source.start)
    local to   = guide.positionToOffset(state, source.finish)
    local lua  = state.lua or ''
    local _, rows = lua:sub(1, from):gsub('\n', '')
    local text = lua:sub(from, to):gsub('\n.*', '')
    return ('%d: %s [%s]'):format(rows + 1, text, source.type)
end

---@param count integer
---@param order string
---@return integer[]
local function permutation(count, order)
    ---@type integer[]
    local list = {}
    for i = 1, count do
        list[i] = i
    end
    if order == 'rev' then
        for i = 1, count // 2 do
            list[i], list[count - i + 1] = list[count - i + 1], list[i]
        end
        return list
    end
    local seed = tonumber(order:match('^shuf(%d+)$'))
    if not seed then
        error('order_diff: unknown order ' .. order)
    end
    local state = seed * 7919
    for i = count, 2, -1 do
        state = (state * 1103515245 + 12345) % 2147483648
        local j = state % i + 1
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local differences = 0
local total       = 0
local filesWith   = 0
for _, path in ipairs(paths) do
    local text = util.loadFile(path)
    if text then
        local uri = furi.encode(path)
        local state = fresh(uri, text)
        local sources = collectSources(state)
        ---@type string[]
        local ref = {}
        for i, source in ipairs(sources) do
            ref[i] = view(uri, source)
        end
        total = total + #sources
        local relative = path:gsub('\\', '/'):match('lua%-language%-server/(.*)') or path
        local before = differences
        for _, order in ipairs(orders) do
            if order == 'cold' then
                local step = math.max(1, #sources // coldMax)
                for i = 1, #sources, step do
                    local coldState = fresh(uri, text)
                    local source = collectSources(coldState)[i]
                    local got = view(uri, source)
                    if got ~= ref[i] then
                        differences = differences + 1
                        print(('ODIFF\t%s:%s\tref=%s\tcold=%s'):format(relative, describe(coldState, source), ref[i], got))
                    end
                end
            else
                local orderState = fresh(uri, text)
                local list = collectSources(orderState)
                for _, i in ipairs(permutation(#list, order)) do
                    vm.getInfer(list[i])
                end
                for i, source in ipairs(list) do
                    local got = view(uri, source)
                    if got ~= ref[i] then
                        differences = differences + 1
                        print(('ODIFF\t%s:%s\tref=%s\t%s=%s'):format(relative, describe(orderState, source), ref[i], order, got))
                    end
                end
            end
        end
        if differences > before then
            filesWith = filesWith + 1
        end
        files.remove(uri)
    end
end
print(('order_diff: %d files, %d sources, %d differences in %d files'):format(#paths, total, differences, filesWith))
