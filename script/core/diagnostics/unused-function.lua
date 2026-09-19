local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local define          = require 'proto.define'
local await           = require 'await'
local client          = require 'client'
local util            = require 'utility'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Unused functions.'

protoDiagnostic.register {
    'unused-function',
} {
    group    = 'unused',
    severity = 'Hint',
    status   = 'Opened',
    description = 'Enable unused function diagnostics.',
}

---@param source parser.object
---@return boolean
local function isToBeClosed(source)
    if not source.attrs then
        return false
    end
    for _, attr in ipairs(source.attrs) do
        if attr[1] == 'close' then
            return true
        end
    end
    return false
end

---@param source parser.object?
---@return boolean
local function isValidFunction(source)
    if not source then
        return false
    end
    if source.type == 'main' then
        return false
    end
    local parent = source.parent
    if not parent then
        return false
    end
    if  parent.type ~= 'local'
    and parent.type ~= 'setlocal' then
        return false
    end
    if isToBeClosed(parent) then
        return false
    end
    return true
end

-- Small reachability graph over local-function declarations: a function
-- starts "white" (candidate-unused) unless something outside the local
-- functions it's reachable from calls it; turnBlack below flood-fills
-- reachability from each root to clear white off everything it reaches.
---@alias unused-function.mark  table<parser.object, true>
---@alias unused-function.links table<parser.object, parser.object[]>

---@async
---@param ast   parser.object
---@param white unused-function.mark
---@param roots unused-function.mark
---@param links unused-function.links
---@return unused-function.mark white
---@return unused-function.mark roots
---@return unused-function.links links
local function collect(ast, white, roots, links)
    ---@async
    guide.eachSourceType(ast, 'function', function (src)
        await.delay()
        if not isValidFunction(src) then
            return
        end
        local loc = src.parent
        if loc.type == 'setlocal' then
            loc = loc.node
        end
        for _, ref in ipairs(loc.ref or {}) do
            if ref.type == 'getlocal' then
                local func = guide.getParentFunction(ref)
                if not func or not isValidFunction(func) or roots[func] then
                    roots[src] = true
                    return
                end
                if not links[func] then
                    links[func] = {}
                end
                links[func][#links[func]+1] = src
            end
        end
        white[src] = true
    end)

    return white, roots, links
end

---@param source parser.object
---@param black  unused-function.mark
---@param white  unused-function.mark
---@param links  unused-function.links
local function turnBlack(source, black, white, links)
    if black[source] then
        return
    end
    black[source] = true
    white[source] = nil
    for _, link in ipairs(links[source] or {}) do
        turnBlack(link, black, white, links)
    end
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    if vm.isMetaFile(uri) then
        return
    end

    ---@type unused-function.mark
    local black = {}
    ---@type unused-function.mark
    local white = {}
    ---@type unused-function.mark
    local roots = {}
    ---@type unused-function.links
    local links = {}

    collect(state.ast, white, roots, links)

    for source in pairs(roots) do
        turnBlack(source, black, white, links)
    end

    local tagSupports = client.getAbility('textDocument.completion.completionItem.tagSupport.valueSet')
    local supportUnnecessary = (tagSupports and util.arrayHas(tagSupports, define.DiagnosticTag.Unnecessary)) --[[@as boolean?]]

    for source in pairs(white) do
        if supportUnnecessary then
            callback {
                start   = source.start,
                finish  = source.finish,
                tags    = { define.DiagnosticTag.Unnecessary },
                message = MESSAGE,
            }
        else
            callback {
                start   = source.keyword[1],
                finish  = source.keyword[2],
                tags    = { define.DiagnosticTag.Unnecessary },
                message = MESSAGE,
            }
        end
    end
end
