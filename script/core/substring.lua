local guide = require 'parser.guide'

---@param state parser.state
---@return fun(pos1: parser.position, pos2: parser.position): string
return function (state)
    local lua = assert(state.lua)
    ---@param pos1 parser.position
    ---@param pos2 parser.position
    ---@return string
    return function (pos1, pos2)
        return lua:sub(
            guide.positionToOffset(state, pos1),
            guide.positionToOffset(state, pos2)
        )
    end
end
