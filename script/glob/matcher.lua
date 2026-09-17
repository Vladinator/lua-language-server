---@type glob.lpegM
local m = require 'lpeglabel'

local Slash  = m.S('/\\')^1
local Symbol = m.S',{}[]*?/\\'
local Char   = 1 - Symbol
local Path   = (1 - m.S[[\/*?"<>|]])^1 * Slash
local NoWord = #(m.P(-1) + Symbol)

---@alias glob.exp.type
---| '"word"'
---| '"char"'
---| '"**"'
---| '"*"'
---| '"?"'
---| '"[]"'
---| '"/"'

---@class glob.exp
---@field type  glob.exp.type
---@field value any

---@class glob.state
---@field [integer] glob.exp
---@field neg?  boolean
---@field root? boolean

---@class glob.matcher
---@field needDirectory? boolean
---@field matcher any
---@field state glob.state
---@field options any
---@overload fun(path: string): any
local mt = {}
mt.__index = mt
mt.__name = 'matcher'

---@param state glob.state
---@param index integer
---@return any
function mt:exp(state, index)
    local exp = state[index]
    if not exp then
        return
    end
    if exp.type == 'word' then
        return self:word(exp, state, index + 1)
    elseif exp.type == 'char' then
        return self:char(exp, state, index + 1)
    elseif exp.type == '**' then
        return self:anyPath(exp, state, index + 1)
    elseif exp.type == '*' then
        return self:anyChar(exp, state, index + 1)
    elseif exp.type == '?' then
        return self:oneChar(exp, state, index + 1)
    elseif exp.type == '[]' then
        return self:range(exp, state, index + 1)
    elseif exp.type == '/' then
        return self:slash(exp, state, index + 1)
    end
end

---@param exp   glob.exp
---@param state glob.state
---@param index integer
---@return any
function mt:word(exp, state, index)
    local current = self:exp(exp.value, 1)
    assert(current)
    local after = self:exp(state, index)
    if after then
        return current * Slash * after
    else
        return current
    end
end

---@param exp   glob.exp
---@param state glob.state
---@param index integer
---@return any
function mt:char(exp, state, index)
    local current = m.P(exp.value)
    local after = self:exp(state, index)
    if after then
        return current * after * NoWord
    else
        return current * NoWord
    end
end

---@param exp   glob.exp?
---@param state glob.state
---@param index integer
---@return any
function mt:anyPath(exp, state, index)
    local after = self:exp(state, index)
    if after then
        return m.P {
            'Main',
            Main    = after
                    + Path * m.V'Main'
        }
    else
        return Path^0
    end
end

---@param exp   glob.exp?
---@param state glob.state
---@param index integer
---@return any
function mt:anyChar(exp, state, index)
    local after = self:exp(state, index)
    if after then
        return m.P {
            'Main',
            Main    = after
                    + Char * m.V'Main'
        }
    else
        return Char^0
    end
end

---@param exp   glob.exp?
---@param state glob.state
---@param index integer
---@return any
function mt:oneChar(exp, state, index)
    local after = self:exp(state, index)
    if after then
        return Char * after
    else
        return Char
    end
end

---@param exp   glob.exp
---@param state glob.state
---@param index integer
---@return any
function mt:range(exp, state, index)
    local after = self:exp(state, index)
    ---@type string[]
    local ranges = {}
    ---@type string[]
    local selects = {}
    for _, range in ipairs(exp.value --[[@as string[][] ]]) do
        if #range == 1 then
            selects[#selects+1] = range[1]
        elseif #range == 2 then
            ranges[#ranges+1] = range[1] .. range[2]
        end
    end
    local current = m.S(table.concat(selects)) + m.R(table.unpack(ranges))
    if after then
        return current * after
    else
        return current
    end
end

---@param exp   glob.exp?
---@param state glob.state
---@param index integer
---@return any
function mt:slash(exp, state, index)
    local after = self:exp(state, index)
    if after then
        return after
    else
        self.needDirectory = true
        return nil
    end
end

---@param state glob.state
---@return any
function mt:pattern(state)
    if state.root then
        local after = self:exp(state, 1)
        if after then
            return m.C(after)
        else
            return nil
        end
    else
        return m.C(self:anyPath(nil, state, 1))
    end
end

---@return boolean
function mt:isNeedDirectory()
    return self.needDirectory == true
end

---@return boolean
function mt:isNegative()
    return self.state.neg == true
end

---@param path string
---@return any
function mt:__call(path)
    return self.matcher:match(path)
end

---@param state   glob.state
---@param options any
---@return glob.matcher?
return function (state, options)
    local self = setmetatable({
        options = options,
        state   = state,
    }, mt --[[@as metatable]]) --[[@as glob.matcher]]
    self.matcher = self:pattern(state)
    if not self.matcher then
        return nil
    end
    return self
end
