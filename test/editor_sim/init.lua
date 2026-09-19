-- Dev harness, not part of the default suite: run with
--     bin/lua-language-server test.lua -n=editor_sim
-- Diagnoses every file under script/ CONCURRENTLY (one coroutine per file, diagnostics
-- interleaving the way the editor's workspace diagnostics do) and lists the `no-unknown`
-- findings. The CLI check goes file by file, so it can hide order-dependent inference
-- (the compile of a node depends on which node was requested first). Env:
--     SIM_ORDER = forward (default) | reverse | shuffle:<seed>    file launch order
--     SIM_JOBS  = <n>                                             limit the number of files
--     SIM_ONLY  = <path fragment>                                 only those files, opened like editor tabs
--     SIM_CODE  = <diagnostic code>                               list this code (default no-unknown)
--     SIM_TOUCH = <path fragment>                                 re-set the text of the matching
--                 files, then diagnose everything again (editor invalidation)
--     SIM_TOUCH_MODE = recreate                                   remove + add back instead
local target = TARGET_TEST_NAME --[[@as string?]]
if not target or not ('editor_sim'):match(target) then
    return
end

local files       = require 'files'
local guide       = require 'parser.guide'
local await       = require 'await'
local furi        = require 'file-uri'
local diagnostics = require 'core.diagnostics'

local wantCode   = os.getenv('SIM_CODE') or 'no-unknown'
-- keeps the client loop (script/lclient.lua) running after the last test returned
SIM_KEEPALIVE = true
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
-- SIM_ONLY = <path fragment>: only these files, opened like editor tabs (diagnosed first)
local only = os.getenv('SIM_ONLY')
if only then
    ---@type uri[]
    local picked = {}
    for _, uri in ipairs(uris) do
        if furi.decode(uri):gsub('[\\]', '/'):find(only, 1, true) then
            files.open(uri)
            picked[#picked+1] = uri
        end
    end
    uris = picked
end
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
local function pass(label)
    unknownLines = {}
    jobs = 0
    for _, uri in ipairs(uris) do
        if jobs >= jobsWanted then
            break
        end
        jobs = jobs + 1
        pending = pending + 1
        ---@async
        await.call(function ()
            diagnostics(uri, false, function (result)
                if wantCode == '*' or result.code == wantCode then
                    local state = files.getState(uri)
                    local text = ''
                    if state and state.lua then
                        local off = guide.positionToOffset(state, result.start)
                        text = state.lua:sub(off, off + 70):match('^[^\n]*') or ''
                    end
                    unknownLines[#unknownLines+1] = furi.decode(uri):gsub('[\\]', '/'):match('script/.*') .. ' [' .. tostring(result.code) .. '] :: ' .. text
                end
            end)
            pending = pending - 1
        end)
    end
    print('editor_sim: launched', jobs, 'concurrent diagnostics' .. label)
    while pending > 0 do
        await.sleep(0.2)
    end
    table.sort(unknownLines)
    print('editor_sim: ' .. wantCode .. ' findings:', #unknownLines)
    for _, l in ipairs(unknownLines) do
        print('   ' .. l)
    end
end

---@async
await.call(function ()
    pass('')
    -- SIM_TOUCH = <path fragment>: re-set the text of the matching files (as an editor
    -- does on every keystroke) and diagnose again, to catch invalidation bugs where a
    -- dependent file loses what the edited file defines.
    local touch = os.getenv('SIM_TOUCH')
    if touch then
        for _, uri in ipairs(uris) do
            if furi.decode(uri):gsub('[\\]', '/'):find(touch, 1, true) then
                local text = files.getText(uri) or ''
                if os.getenv('SIM_TOUCH_MODE') == 'recreate' then
                    -- what a file watcher does when an editor saves via rename: remove, then add back
                    files.remove(uri)
                    files.setText(uri, text .. '\n', false)
                else
                    files.open(uri)
                    files.setText(uri, text .. '\n', false)
                end
                print('editor_sim: touched', uri)
            end
        end
        await.sleep(1)
        pass(' after touching ' .. touch)
    end
    os.exit(0)
end)
