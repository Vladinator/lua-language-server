local core   = require 'core.completion'
local files  = require 'files'
local catch  = require 'catch'
local vm     = require 'vm'

---@diagnostic disable: await-in-sync

-- `vm.registerSlotRefusal`: a plugin's rule that a parameter refuses a value. The completion of an argument puts the values that would be
-- refused after all the others (after the ones that merely do not fit the declared type too), and nothing is hidden. The rule here is a
-- fake that only the parameter named `zzrefuser` triggers, so it changes nothing for the rest of the suite (and for a build without plugins).
vm.registerSlotRefusal(function (param, value)
    if param[1] ~= 'zzrefuser' then
        return false
    end
    for object in value:eachObject() do
        if object.type == 'boolean' then
            return true
        end
    end
    return false
end)

--- The labels offered at the `<??>`, in order.
---@param script string
---@return string[]
local function labelsOf(script)
    local newScript, catched = catch(script, '?')
    files.setText(TESTURI, newScript)
    local result = core.completion(TESTURI, catched['?'][1][1], nil)
    files.remove(TESTURI)
    ---@type string[]
    local labels = {}
    for _, item in ipairs(result or {}) do
        labels[#labels+1] = item.label
    end
    return labels
end

---@param labels string[]
---@param label  string
---@return number
local function indexOf(labels, label)
    for i, name in ipairs(labels) do
        if name == label then
            return i
        end
    end
    return math.huge
end

-- the refused value is last, behind a value that does not fit either; the fitting one is first; nothing is hidden
do
    local labels = labelsOf [[
---@param zzrefuser string
local function takes(zzrefuser) end
local varflag = true
local varnum  = 1
local varstr  = 'x'
takes(var<??>)
]]
    assert(indexOf(labels, 'varstr') < indexOf(labels, 'varnum'), 'the fitting value is before the one that does not fit')
    assert(indexOf(labels, 'varnum') < indexOf(labels, 'varflag'), 'the refused value is after the one that does not fit')
    assert(indexOf(labels, 'varflag') ~= math.huge, 'the refused value is still offered')
end

-- negative: the same values at a parameter the rule does not refuse for keep the order of the declarations
do
    local labels = labelsOf [[
---@param other string
local function takes(other) end
local varflag = true
local varnum  = 1
local varstr  = 'x'
takes(var<??>)
]]
    assert(indexOf(labels, 'varstr') < indexOf(labels, 'varflag'), 'the fitting value is first')
    assert(indexOf(labels, 'varflag') < indexOf(labels, 'varnum'), 'without the rule the declaration order stays')
end

-- negative: a refused value is not refused when the rule says no for the value (a number at the refusing parameter is only "not fitting")
do
    local labels = labelsOf [[
---@param zzrefuser string
local function takes(zzrefuser) end
local varnum  = 1
local varstr  = 'x'
takes(var<??>)
]]
    assert(indexOf(labels, 'varstr') < indexOf(labels, 'varnum'), 'ranked as before')
end
