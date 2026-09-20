---@param key? string
---@param k any
---@return string
local function mergeKey(key, k)
    if not key then
        return k
    end
    k = tostring(k)
    if k:sub(1, 1):match '%w' then
        return key .. '.' .. k
    else
        return key .. k
    end
end

---@param results table<string, any>
---@param key? string
---@return table
local function proxy(results, key)
    return setmetatable({}, {
        __index = function (_, k)
            return proxy(results, mergeKey(key, k))
        end,
        __newindex = function (_, k, v)
            results[mergeKey(key, k)] = v
        end
    })
end

---@param text string
---@param path string
---@param results? table<string, any>
---@return table<string, any>
return function (text, path, results)
    results = results or {}
    assert(load(text, '@' .. path, "t", proxy(results)))()
    return results
end
