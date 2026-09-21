---@type { ZoneBeginN: fun(info: any), ZoneEnd: fun() }?
local originTracy

local function enable()
    if not originTracy then
        local suc = pcall(require, 'luatracy')
        if suc then
            originTracy = tracy
        else
            originTracy = {
                ZoneBeginN = function (_info) end,
                ZoneEnd    = function () end,
            }
        end
    end
    -- (cast: the type of `originTracy` here depends on which of the reads that feed each other
    -- (`originTracy = tracy`, `tracy = originTracy`) the editor compiles first, and so did the type
    -- of the global, which made `need-check-nil` appear on every `tracy.ZoneBeginN` in some orders)
---@diagnostic expect-next-line: lowercase-global
    tracy = originTracy --[[@as { ZoneBeginN: fun(info: any), ZoneEnd: fun() }]]
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
