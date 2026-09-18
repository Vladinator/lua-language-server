local fs      = require 'bee.filesystem'
local util    = require 'utility'
local version = require 'version'

require 'config.env'

---@param value string?
---@return boolean|number|string?
local function getValue(value)
    ---@type boolean|number|string?
    local result = value
    if     value == 'true' or value == nil then
        result = true
    elseif value == 'false' then
        result = false
    elseif tonumber(value) then
        result = tonumber(value)
    elseif value:sub(1, 1) == '"' and value:sub(-1, -1) == '"' then
        result = value:sub(2, -2)
    end
    return result
end

local function loadArgs()
    ---@type string?
    local lastKey
    for _, v in ipairs(arg) do
        ---@type string?, string?
        local key, tail = v:match '^%-%-([%w_]+)(.*)$'
        ---@type string?
        local value
        if key then
            value   = (tail --[[@as string]]):match '=(.+)'
            lastKey = nil
            if not value then
                lastKey = key
            end
        else
            if lastKey then
                key     = lastKey
                value   = v
                lastKey = nil
            end
        end
        if key then
            local globalKey = key:upper():gsub('-', '_')
            ;(_G --[[@as table<string, any>]])[globalKey] = getValue(value)
        end
    end
end

loadArgs()

local currentPath = debug.getinfo(1, 'S').source:sub(2)
local rootPath    = currentPath:gsub('[/\\]*[^/\\]-$', '')

rootPath = (rootPath == '' and '.' or rootPath)
ROOT     = fs.path(util.expandPath(rootPath))
LOGPATH  = (LOGPATH  and util.expandPath(LOGPATH)  or (ROOT:string() .. '/log')) --[[@as string]]
METAPATH = (METAPATH and util.expandPath(METAPATH) or (ROOT:string() .. '/meta')) --[[@as string]]

util.enableCloseFunction()
util.enableFormatString()

--collectgarbage('generational', 10, 50)
--collectgarbage('incremental', 120, 120, 0)
collectgarbage('param', 'minormul', 10)
collectgarbage('param', 'minormajor', 50)

---@diagnostic disable-next-line: lowercase-global
log = require 'log'
log.init(ROOT, fs.path(LOGPATH) / 'service.log')
if LOGLEVEL then
    log.level = tostring(LOGLEVEL):lower()
end

log.info('Lua Lsp startup, root: ', ROOT)
log.info('ROOT:', ROOT:string())
log.info('LOGPATH:', LOGPATH)
log.info('METAPATH:', METAPATH)
log.info('VERSION:', version.getVersion())

require 'tracy'

xpcall(dofile, log.debug, (ROOT / 'debugger.lua'):string())

require 'cli'

local _, service = xpcall(require, log.error, 'service')

service.start()
