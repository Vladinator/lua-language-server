-- Dev harness, not part of the default suite: run with
--     bin/lua-language-server test.lua -n=editor_sim
-- Diagnoses every file under script/ CONCURRENTLY (one coroutine per file, diagnostics
-- interleaving the way the editor's workspace diagnostics do) and lists the `no-unknown`
-- findings. The CLI check goes file by file, so it can hide order-dependent inference
-- (the compile of a node depends on which node was requested first). Env:
--     SIM_ORDER = forward (default) | reverse | shuffle:<seed>    file launch order
--     SIM_JOBS  = <n>                                             limit the number of files
local target = TARGET_TEST_NAME --[[@as string?]]
if not target or not ('editor_sim'):match(target) then
    return
end

local files       = require 'files'
local guide       = require 'parser.guide'
local await       = require 'await'
local furi        = require 'file-uri'
local diagnostics = require 'core.diagnostics'

local jobsWanted = tonumber(os.getenv('SIM_JOBS') or '') or 100000
---@type string[]
local unknownLines = {}
local pending = 0
local jobs = 0
---@type uri[]
local uris = {}
for uri in files.eachFile() do
    local path = furi.decode(uri):gsub('[\\]', '/')
    if path:find('/script/', 1, true)
    and not path:find('/script/plugins/', 1, true)
    and not path:find('/script/meta/', 1, true) then
        uris[#uris+1] = uri
    end
end
table.sort(uris)
-- SIM_ORDER: forward (default) | reverse | shuffle:<seed>. The checker's result depends on
-- which node is compiled first, so different orders expose order-dependent unknowns.
local order = os.getenv('SIM_ORDER') or 'forward'
if order == 'reverse' then
    for i = 1, #uris // 2 do
        uris[i], uris[#uris - i + 1] = uris[#uris - i + 1], uris[i]
    end
elseif order:sub(1, 8) == 'shuffle:' then
    local state = tonumber(order:sub(9)) or 1
    for i = #uris, 2, -1 do
        state = (state * 1103515245 + 12345) % 2147483648
        local j = state % i + 1
        uris[i], uris[j] = uris[j], uris[i]
    end
end

---@async
await.call(function ()
    for _, uri in ipairs(uris) do
        if jobs >= jobsWanted then
            break
        end
        jobs = jobs + 1
        pending = pending + 1
        ---@async
        await.call(function ()
            diagnostics(uri, false, function (result)
                if result.code == 'no-unknown' then
                    local state = files.getState(uri)
                    local text = ''
                    if state and state.lua then
                        local off = guide.positionToOffset(state, result.start)
                        text = state.lua:sub(off, off + 70):match('^[^\n]*') or ''
                    end
                    unknownLines[#unknownLines+1] = furi.decode(uri):gsub('[\\]', '/'):match('script/.*') .. ' :: ' .. text
                end
            end)
            pending = pending - 1
        end)
    end
    print('editor_sim: launched', jobs, 'concurrent diagnostics')
    while pending > 0 do
        await.sleep(0.2)
    end
    table.sort(unknownLines)
    print('editor_sim: no-unknown findings:', #unknownLines)
    for _, l in ipairs(unknownLines) do
        print('   ' .. l)
    end
    os.exit(0)
end)
