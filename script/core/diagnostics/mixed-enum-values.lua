local files           = require 'files'
local guide           = require 'parser.guide'
local protoDiagnostic = require 'proto.diagnostic'

local MIXED       = 'The value of `%s` is a %s, the enum started with a %s.'
local UNSUPPORTED = 'The value of `%s` is a %s: an enum holds numbers or strings.'

protoDiagnostic.register {
    'mixed-enum-values',
} {
    group    = 'type-check',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for an `---@enum` whose values are not all numbers or all strings: a value of another kind than the first literal one is reported, and so is a value that is neither (a boolean, a table, a function).',
}

--- The kind of a literal value an enum can hold, or nil for anything else (a call, a variable: nothing is known).
---@type table<string, string>
local KIND = {
    ['string']  = 'string',
    ['integer'] = 'number',
    ['number']  = 'number',
}

--- A literal that an enum cannot hold at all, by what to call it in the message.
---@type table<string, string>
local UNSUPPORTED_KIND = {
    ['boolean']  = 'boolean',
    ['table']    = 'table',
    ['function'] = 'function',
}

--- The table an `---@enum` describes: the doc binds to the local that holds it, or to the table itself.
---@param doc parser.object
---@return parser.object?
local function enumTable(doc)
    local source = doc.bindSource
    if not source then
        return nil
    end
    if source.type == 'table' then
        return source
    end
    local value = source.value
    if value and value.type == 'table' then
        return value
    end
    return nil
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state or not state.ast.docs then
        return
    end

    guide.eachSourceType(state.ast.docs, 'doc.enum', function (doc)
        local tbl = enumTable(doc)
        if not tbl then
            return
        end
        ---@type string?
        local first
        for _, field in ipairs(tbl) do
            if (field.type == 'tablefield' or field.type == 'tableindex') and field.value then
                local kind = KIND[field.value.type]
                local unsupported = UNSUPPORTED_KIND[field.value.type]
                if unsupported then
                    callback {
                        start   = field.value.start,
                        finish  = field.value.finish,
                        message = UNSUPPORTED:format(tostring(guide.getKeyName(field)), unsupported),
                    }
                elseif kind then
                    if not first then
                        first = kind
                    elseif kind ~= first then
                        callback {
                            start   = field.value.start,
                            finish  = field.value.finish,
                            message = MIXED:format(tostring(guide.getKeyName(field)), kind, first),
                        }
                    end
                end
            end
        end
    end)
end
