---@type { ZoneBeginN: fun(info: any), ZoneEnd: fun() }?
local originTracy

local function enable()
    if not originTracy then
        local suc = pcall(require, 'luatracy')
        if suc then
            originTracy = tracy --[[@as { ZoneBeginN: fun(info: any), ZoneEnd: fun() }]]
        else
            originTracy = {
                ZoneBeginN = function (_info) end,
                ZoneEnd    = function () end,
            }
        end
    end
---@diagnostic expect-next-line: lowercase-global
    tracy = originTracy
end

local function disable()
---@diagnostic expect-next-line: lowercase-global
    tracy = {
        ZoneBeginN = function (_info) end,
        ZoneEnd    = function () end,
    }
end

disable()

return {
    enable  = enable,
    disable = disable,
}
