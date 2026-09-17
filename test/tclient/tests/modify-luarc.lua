local lclient  = require 'lclient'
local util     = require 'utility'
local ws       = require 'workspace'
local jsonc    = require 'jsonc'
local jsonb    = require 'json-beautify'
local client   = require 'client'
local provider = require 'provider'
local json     = require 'json'
local config   = require 'config'

local configPath = LOGPATH .. '/modify-luarc.json'

--- `require 'json-beautify'` sets `json.beautify` as a side effect, so the
--- field is genuinely optional in `json`'s declared type until then; this
--- module already required it above, so narrow it once here.
--- `require 'jsonc'` sets `json.decode_jsonc` as a side effect, so the
--- field is genuinely optional in `json`'s declared type until then; this
--- module already required it above, so narrow it once here.
local decode_jsonc = assert(jsonc.decode_jsonc)
local beautify = assert(jsonb.beautify)

--- `configPath` is always written by `util.saveFile` immediately before
--- each read below, so a failed load here would mean the write itself
--- failed; assert rather than thread an optional string through every
--- `jsonc.decode_jsonc` call site.
---@return string
local function loadConfigFile()
    return assert(util.loadFile(configPath))
end

---@async
lclient():start(function (languageClient)
    languageClient:registerFakers()

    CONFIGPATH = configPath

    languageClient:initialize()

    ws.awaitReady()

    -------------------------------

    util.saveFile(configPath, beautify(json.createEmptyObject()))

    provider.updateConfig()

    client.setConfig({
        {
            action = 'set',
            key    = 'Lua.runtime.version',
            value  = 'LuaJIT',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['runtime.version'] = 'LuaJIT',
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        ['Lua.runtime.version'] = json.null,
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'set',
            key    = 'Lua.runtime.version',
            value  = 'LuaJIT',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['Lua.runtime.version'] = 'LuaJIT',
    }))

    -------------------------------

    util.saveFile(configPath, beautify(json.createEmptyObject()))

    provider.updateConfig()

    client.setConfig({
        {
            action = 'add',
            key    = 'Lua.diagnostics.disable',
            value  = 'undefined-global',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['diagnostics.disable'] = {
            'undefined-global',
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        ['Lua.diagnostics.disable'] = {}
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'add',
            key    = 'Lua.diagnostics.disable',
            value  = 'undefined-global',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['Lua.diagnostics.disable'] = {
            'undefined-global',
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        ['Lua.diagnostics.disable'] = {
            'unused-local'
        }
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'add',
            key    = 'Lua.diagnostics.disable',
            value  = 'undefined-global',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['Lua.diagnostics.disable'] = {
            'unused-local',
            'undefined-global',
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify(json.createEmptyObject()))

    provider.updateConfig()

    client.setConfig({
        {
            action = 'prop',
            key    = 'Lua.runtime.special',
            prop   = 'include',
            value  = 'require',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['runtime.special'] = {
            ['include'] = 'require',
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        ['Lua.runtime.special'] = json.createEmptyObject()
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'prop',
            key    = 'Lua.runtime.special',
            prop   = 'include',
            value  = 'require',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['Lua.runtime.special'] = {
            ['include'] = 'require',
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        ['Lua.runtime.special'] = {
            ['import'] = 'require',
        }
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'prop',
            key    = 'Lua.runtime.special',
            prop   = 'include',
            value  = 'require',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['Lua.runtime.special'] = {
            ['import']  = 'require',
            ['include'] = 'require',
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        ['runtime.version'] = json.null,
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'set',
            key    = 'Lua.runtime.version',
            value  = 'LuaJIT',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['runtime.version'] = 'LuaJIT',
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        Lua = {
            runtime = {
                version = json.null,
            }
        }
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'set',
            key    = 'Lua.runtime.version',
            value  = 'LuaJIT',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        Lua = {
            runtime = {
                version = 'LuaJIT',
            }
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        runtime = {
            version = json.null,
        }
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'set',
            key    = 'Lua.runtime.version',
            value  = 'LuaJIT',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        runtime = {
            version = 'LuaJIT',
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        diagnostics = {
            disable = {
                'unused-local',
            }
        }
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'add',
            key    = 'Lua.diagnostics.disable',
            value  = 'undefined-global',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        diagnostics = {
            disable = {
                'unused-local',
                'undefined-global',
            }
        }
    }))

    -------------------------------

    util.saveFile(configPath, beautify {
        runtime = {
            special = {
                import = 'require',
            }
        }
    })

    provider.updateConfig()

    client.setConfig({
        {
            action = 'prop',
            key    = 'Lua.runtime.special',
            prop   = 'include',
            value  = 'require',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        runtime = {
            special = {
                import  = 'require',
                include = 'require',
            }
        }
    }))

    -------------------------------
    -- merrge other configs --
    -------------------------------

    util.saveFile(configPath, beautify(json.createEmptyObject()))

    provider.updateConfig()

    config.add(nil, 'Lua.diagnostics.globals', 'x')
    config.add(nil, 'Lua.diagnostics.globals', 'y')

    client.setConfig({
        {
            action = 'add',
            key    = 'Lua.diagnostics.globals',
            value  = 'z',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['diagnostics.globals'] = { 'x', 'y', 'z' }
    }))

    -------------------------------

    util.saveFile(configPath, beautify(json.createEmptyObject()))

    provider.updateConfig()

    config.prop(nil, 'Lua.runtime.special', 'kx', 'require')
    config.prop(nil, 'Lua.runtime.special', 'ky', 'require')

    client.setConfig({
        {
            action = 'prop',
            key    = 'Lua.runtime.special',
            prop   = 'kz',
            value  = 'require',
        }
    })

    assert(util.equal(decode_jsonc(loadConfigFile()), {
        ['runtime.special'] = {
            ['kx'] = 'require',
            ['ky'] = 'require',
            ['kz'] = 'require',
        }
    }))
end)
