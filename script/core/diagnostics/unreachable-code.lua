local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local define          = require 'proto.define'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'Unreachable code.'

protoDiagnostic.register {
    'unreachable-code',
} {
    group    = 'unused',
    severity = 'Hint',
    status   = 'Opened',
    description = 'Enable diagnostics for unreachable code.',
}

---@param source parser.object
---@return boolean
local function allLiteral(source)
    local result = true
    guide.eachSource(source, function (src)
        if  src.type ~= 'unary'
        and src.type ~= 'binary'
        and not guide.isLiteral(src) then
            result = false
            return false
        end
    end)
    return result
end

--- A statement after which nothing of the block runs: a call of a function that never returns (`error(...)`, `os.exit()`, a `---@return never`).
---@param action parser.object
---@return boolean
local function neverReturns(action)
    return action.type == 'call' and vm.isNeverCall(action)
end

--- A `do ... end` that ends with a `return` or a call that never returns directly in it (`do return end`, the debugging idiom): it runs once, so what
--- follows it in the same block never runs. Only judged for the statements of a function or the main chunk: inside a loop a `goto continue` can skip it.
---@param action parser.object
---@return boolean
local function doEnds(action)
    if action.type ~= 'do' then
        return false
    end
    for _, inner in ipairs(action) do
        if inner.type == 'return' or neverReturns(inner) then
            return true
        end
    end
    return false
end

---@param block parser.object
---@return boolean
local function hasReturn(block)
    if block.hasReturn or vm.blockExits(block) then
        return true
    end
    if block.type == 'if' then
        ---@type boolean?
        local hasElse
        for _, subBlock in ipairs(block) do
            if not hasReturn(subBlock) then
                return false
            end
            if subBlock.type == 'elseblock' then
                hasElse = true
            end
        end
        return hasElse == true
    else
        if block.type == 'while' then
            if  vm.testCondition(block.filter)
            and not block.breaks
            and allLiteral(block.filter) then
                return true
            end
        end
        for _, action in ipairs(block) do
            if guide.isBlockType(action) then
                if hasReturn(action) then
                    return true
                end
            end
        end
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceTypes(state.ast, {'main', 'function', 'do', 'while', 'loop', 'in', 'repeat', 'ifblock', 'elseifblock', 'elseblock'}, function (source)
        await.delay()
        for i, action in ipairs(source) do
            if action.type == 'goto' then
                -- a `goto` leaves the block: what follows it up to the next label can never run (a label can be a target of another `goto`)
                local last = #source
                for j = i + 1, #source do
                    if source[j].type == 'label' then
                        last = j - 1
                        break
                    end
                end
                if i < last then
                    callback {
                        start   = source[i+1].start,
                        finish  = source[last].range or source[last].finish,
                        tags    = { define.DiagnosticTag.Unnecessary },
                        message = MESSAGE,
                    }
                end
                return
            end
            if  (guide.isBlockType(action) and hasReturn(action))
            or  neverReturns(action)
            or  doEnds(action) then
                -- (a label after it can be reached by a `goto`: what follows is not judged)
                local labelAfter = false
                for j = i + 1, #source do
                    if source[j].type == 'label' then
                        labelAfter = true
                    end
                end
                if i < #source and not labelAfter then
                    callback {
                        start   = source[i+1].start,
                        finish  = source[#source].range or source[#source].finish,
                        tags    = { define.DiagnosticTag.Unnecessary },
                        message = MESSAGE,
                    }
                end
                return
            end
        end
    end)
end
