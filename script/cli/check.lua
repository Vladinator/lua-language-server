local lang       = require 'language'
---@type { os: string }
local platform   = require 'bee.platform'
local json       = require 'json'
local jsonb      = require 'json-beautify'
local util       = require 'utility'

-- `json`'s `beautify` field is only set once `json-beautify.lua` is required (as above),
-- so it's declared optional on the shared `json` class; narrow it here via a fresh local.
local jsonBeautify = jsonb.beautify
assert(jsonBeautify, 'json-beautify was not loaded')

---@class proc
---@field wait fun(self: proc): integer?, string?

---@type { spawn: fun(...): proc?, string? }
local subprocess = require 'bee.subprocess'

local export = {}

---@param threadId integer
local function logFileForThread(threadId)
    return LOGPATH .. '/check-partial-' .. threadId .. '.json'
end

---@param minIndex integer
---@param numThreads number
---@param threadId integer
---@param format string
---@param quiet boolean
---@return string[]
local function buildArgs(minIndex, numThreads, threadId, format, quiet)
    ---@type string[]
    local args = {}
    local skipNext = false
    for i = minIndex, #arg do
        local a = arg[i]
        -- --check needs to be transformed into --check_worker
        if a:lower():match('^%-%-check$') or a:lower():match('^%-%-check=') then
            args[#args + 1] = a:gsub('%-%-%w*', '--check_worker')
        -- --check_out_path needs to be removed if we have more than one thread
        elseif a:lower():match('%-%-check_out_path') and numThreads > 1 then
            if not a:match('%-%-[%w_]*=') then
                skipNext = true
            end
        else
            if skipNext then
                skipNext = false
            else
                args[#args + 1] = a
            end
        end
    end
    args[#args + 1] = '--thread_id'
    args[#args + 1] = tostring(threadId)
    if numThreads > 1 then
        if quiet then
            args[#args + 1] = '--quiet'
        end
        if format then
            args[#args + 1] = '--check_format=' .. format
        end
        args[#args + 1] = '--check_out_path'
        args[#args + 1] = logFileForThread(threadId)
    end
    return args
end

function export.runCLI()
    local numThreads = tonumber(NUM_THREADS or 1) or 1

    ---@type string
    local exe
    local minIndex = -1
    while arg[minIndex] do
        exe = arg[minIndex]
        minIndex = minIndex - 1
    end
    minIndex = minIndex + 1
    -- TODO: is this necessary? got it from the shell.lua helper in bee.lua tests
    if platform.os == 'windows' and not exe:match('%.[eE][xX][eE]$') then
        arg[minIndex] = exe..'.exe'
    end

    if not QUIET and numThreads > 1 then
        print(lang.script('CLI_CHECK_MULTIPLE_WORKERS', numThreads))
    end

    ---@type proc[]
    local procs = {}
    for i = 1, numThreads do
        local process, err = subprocess.spawn({buildArgs(minIndex, numThreads, i, CHECK_FORMAT, QUIET)})
        if err then
            print(err)
        end
        if process then
            procs[#procs + 1] = process
        end
    end

    local checkPassed = true
    for _, process in ipairs(procs) do
        checkPassed = process:wait() == 0 and checkPassed
    end

    if numThreads > 1 then
        ---@type table<string, table[]>
        local mergedResults = {}
        ---@type integer
        local count = 0
        for i = 1, numThreads do
            local result = json.decode(util.loadFile(logFileForThread(i)) or '[]') --[[@as table<string, table[]>]]
            for k, v in pairs(result) do
                local entries = mergedResults[k] or {}
                mergedResults[k] = entries
                for _, entry in ipairs(v) do
                    entries[#entries + 1] = entry
                    count = (count + 1) --[[@as integer]]
                end
            end
        end

        ---@type string?
        local outpath
        if CHECK_FORMAT == 'json' or CHECK_OUT_PATH then
            local resolvedPath = CHECK_OUT_PATH or (LOGPATH .. '/check.json')
            outpath = resolvedPath
            util.saveFile(resolvedPath, jsonBeautify(mergedResults))
        end

        if not QUIET then
            if count == 0 then
                print(lang.script('CLI_CHECK_SUCCESS'))
            elseif outpath then
                print(lang.script('CLI_CHECK_RESULTS_OUTPATH', count, outpath))
            else
                print(lang.script('CLI_CHECK_RESULTS_PRETTY', count))
            end
        end
    end
    return checkPassed and 0 or 1
end

return export
