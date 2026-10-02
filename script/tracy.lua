---@class tracy.api
---@field ZoneBeginN fun(info: any)
---@field ZoneEnd fun()

---@type tracy.api?
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
    -- of the global, which made `need-check-nil` appear on every `tracy.ZoneBeginN` in some orders.
    -- `audit_casts.py` flags it as removable -- it is not: it removed it once (c1944d9bb), restored
    -- (16df2e5cf), removed again (172d5030e) and `editor_sim` in the *forward* order showed nothing
    -- both times; only the reverse / shuffled orders do. Check those before removing it.
    -- audit_casts: keep)
---@diagnostic expect-next-line: lowercase-global
    tracy = originTracy --[[@as tracy.api]]
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
