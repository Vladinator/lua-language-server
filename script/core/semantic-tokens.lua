local files          = require 'files'
local await          = require 'await'
local define         = require 'proto.define'
local vm             = require 'vm'
local util           = require 'utility'
local guide          = require 'parser.guide'
local converter      = require 'proto.converter'
local config         = require 'config'
local linkedTable    = require 'linked-table'
local client         = require 'client'

---@class semantic.options
---@field uri uri
---@field state parser.state
---@field text string
---@field libGlobals table<string, boolean>
---@field variable boolean
---@field annotation boolean
---@field keyword boolean

--- Raw offsets, as produced across the big dispatch below and consumed
--- by solveMultilineAndOverlapping's sort/merge pass.
---@class semantic.token
---@field start integer
---@field finish integer
---@field type integer
---@field modifieres? integer

--- Positions, as solveMultilineAndOverlapping converts each
--- semantic.token into on its way out (see converter.packPosition
--- calls near its end) -- this is what buildTokens actually consumes.
---@class semantic.packedToken
---@field start position
---@field finish position
---@field type integer
---@field modifieres? integer

local Care = util.switch()
    : case 'getglobal'
    : case 'setglobal'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.variable then
            return
        end

        local name = source[1] --[[@as string]]
        if source.declare and name == '*' then
            return
        end
        local isLib = options.libGlobals[name]
        if isLib == nil then
            isLib = false
            local globalVar = vm.getGlobal('variable', name)
            if globalVar then
                local uri = guide.getUri(source)
                for _, set in ipairs(globalVar:getSets(uri)) do
                    if vm.isMetaFile(guide.getUri(set)) then
                        isLib = true
                        break
                    end
                end
            end
            options.libGlobals[name] = isLib
        end
        local isFunc = vm.getInfer(source):hasFunction(guide.getUri(source))

        local type = isFunc and define.TokenTypes['function'] or define.TokenTypes.variable
        local modifier = isLib and define.TokenModifiers.defaultLibrary or define.TokenModifiers['global']

        if source.declare then
            modifier = modifier | define.TokenModifiers.declaration --[[@as integer]]
        end

        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = type,
            modifieres = modifier,
        }
    end)
    : case 'getmethod'
    : case 'setmethod'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.variable then
            return
        end
        local method = source.method
        if method and method.type == 'method' then
            results[#results+1] = {
                start      = method.start,
                finish     = method.finish,
                type       = define.TokenTypes.method,
                modifieres = source.type == 'setmethod' and define.TokenModifiers.declaration or nil,
            }
        end
    end)
    : case 'field'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.variable then
            return
        end
        if source.parent then
            if source.parent.type == 'tablefield' then
                results[#results+1] = {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes.property,
                }
                return
            end
            local value = source.parent.value
            if value and value.type == 'function' then
                results[#results+1] = {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes.method,
                }
                return
            end
        end
        if vm.getInfer(source):hasFunction(guide.getUri(source)) then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes.method,
            }
            return
        end
        if source.parent.parent.type == 'call' then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes.method,
            }
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.property,
        }
    end)
    : case 'local'
    : case 'self'
    : case 'getlocal'
    : case 'setlocal'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if options.keyword then
            if source.locPos then
                results[#results+1] = {
                    start      = source.locPos,
                    finish     = source.locPos + #'local',
                    type       = define.TokenTypes.keyword,
                    modifieres = define.TokenModifiers.declaration,
                }
            end
            if source.attrs then
                for _, attr in ipairs(source.attrs) do
                    results[#results+1] = {
                        start      = attr.start,
                        finish     = attr.finish,
                        type       = define.TokenTypes.typeParameter,
                    }
                end
            end
        end
        if not options.variable then
            return
        end
        local loc = source.node or source
        local uri = guide.getUri(loc)
        -- 1. 值为函数的局部变量 | Local variable whose value is a function
        if vm.getInfer(source):hasFunction(uri) then
            if source.type == 'local' then
                results[#results+1] = {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes['function'],
                    modifieres = define.TokenModifiers.declaration,
                }
            else
                results[#results+1] = {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes['function'],
                }
            end
            return
        end
        -- 3. 特殊变量 | Special variableif source[1] == '_ENV' then
        if loc[1] == '_ENV' then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes.variable,
                modifieres = define.TokenModifiers.readonly,
            }
            return
        end
        if loc[1] == 'self' then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes.variable,
                modifieres = define.TokenModifiers.definition,
            }
            return
        end
        -- 4. 函数的参数 | Function parameters
        if loc.parent and loc.parent.type == 'funcargs' then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes.parameter,
                modifieres = loc == source and define.TokenModifiers.declaration or nil,
            }
            return
        end
        -- 5. Class declaration
            -- only search this local
        if loc.bindDocs then
            local isParam = source.parent.type == 'funcargs'
                         or source.parent.type == 'in'
            if not isParam then
                for _, doc in ipairs(loc.bindDocs) do
                    if doc.type == 'doc.class' then
                        results[#results+1] = {
                            start      = source.start,
                            finish     = source.finish,
                            type       = define.TokenTypes.class,
                        }
                        return
                    end
                end
            end
        end
        -- 6. References to other functions
        if vm.getInfer(loc):hasFunction(guide.getUri(source)) then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes['function'],
                modifieres = guide.isAssign(source) and define.TokenModifiers.declaration or nil,
            }
            return
        end
        -- 7. const 变量 | Const variable
        if loc.attrs then
            for _, attr in ipairs(loc.attrs) do
                local name = attr[1]
                if name == 'const' then
                    results[#results+1] = {
                        start      = source.start,
                        finish     = source.finish,
                        type       = define.TokenTypes.variable,
                        modifieres = define.TokenModifiers.readonly,
                    }
                    return
                elseif name == 'close' then
                    results[#results+1] = {
                        start      = source.start,
                        finish     = source.finish,
                        type       = define.TokenTypes.variable,
                        modifieres = define.TokenModifiers.abstract,
                    }
                    return
                end
            end
        end
        ---@type integer?
        local mod
        if source.type == 'local' then
            mod = define.TokenModifiers.declaration
        end
        -- 8. 其他 | Other
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.variable,
            modifieres = mod,
        }
    end)
    : case 'function'
    : case 'ifblock'
    : case 'elseifblock'
    : case 'elseblock'
    : case 'do'
    : case 'for'
    : case 'loop'
    : case 'in'
    : case 'while'
    : case 'repeat'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        local keyword = source.keyword
        if keyword then
            for i = 1, #keyword, 2 do
                results[#results+1] = {
                    start      = keyword[i],
                    finish     = keyword[i + 1],
                    type       = define.TokenTypes.keyword,
                }
            end
        end
    end)
    : case 'if'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        local offset = guide.positionToOffset(options.state, source.finish)
        if options.text:sub(offset - 2, offset) == 'end' then
            results[#results+1] = {
                start      = source.finish - #'end',
                finish     = source.finish,
                type       = define.TokenTypes.keyword,
            }
        end
    end)
    : case 'return'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.start + #'return',
            type       = define.TokenTypes.keyword,
        }
    end)
    : case 'break'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.start + #'break',
            type       = define.TokenTypes.keyword,
        }
    end)
    : case 'goto'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        -- always set on a 'goto' action (see parser/compile.lua)
        local keyStart = source.keyStart --[[@as integer]]
        results[#results+1] = {
            start      = keyStart,
            finish     = keyStart + #'goto',
            type       = define.TokenTypes.keyword,
        }
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.struct,
        }
    end)
    : case 'label'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.struct,
            modifieres = define.TokenModifiers.declaration,
        }
    end)
    : case 'binary'
    : case 'unary'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.op.start,
            finish     = source.op.finish,
            type       = define.TokenTypes.operator,
        }
    end)
    : case 'boolean'
    : case 'nil'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.keyword,
            modifieres = define.TokenModifiers.readonly,
        }
    end)
    : case 'string'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.string,
        }
        local escs = source.escs
        if escs then
            for i = 1, #escs, 3 do
                ---@type integer
                local mod
                if escs[i + 2] == 'err' then
                    mod = define.TokenModifiers.deprecated
                else
                    mod = define.TokenModifiers.modification
                end
                results[#results+1] = {
                    start      = escs[i] --[[@as integer]],
                    finish     = escs[i + 1] --[[@as integer]],
                    type       = define.TokenTypes.string,
                    modifieres = mod,
                }
            end
        end
    end)
    : case 'integer'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.number,
            modifieres = define.TokenModifiers.static,
        }
    end)
    : case 'number'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.keyword then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.number,
        }
    end)
    : case 'doc.class.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.class,
            modifieres = define.TokenModifiers.declaration,
        }
    end)
    : case 'doc.extends.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.class,
        }
    end)
    : case 'doc.type.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        if source.typeGeneric then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes.type,
                modifieres = define.TokenModifiers.modification,
            }
        elseif source[1] == 'self' then
            results[#results+1] = {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes.type,
                modifieres = define.TokenModifiers.readonly,
            }
        else
            results[#results+1] = {
                start  = source.start,
                finish = source.finish,
                type   = define.TokenTypes.type,
            }
        end
    end)
    : case 'doc.alias.name'
    : case 'doc.enum.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.macro,
        }
    end)
    : case 'doc.param.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.parameter,
        }
    end)
    : case 'doc.field'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        if source.visible then
            results[#results+1] = {
                start      = source.start,
                finish     = source.start + #source.visible,
                type       = define.TokenTypes.keyword,
            }
        end
    end)
    : case 'doc.field.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.property,
            modifieres = define.TokenModifiers.declaration,
        }
    end)
    : case 'doc.return.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start  = source.start,
            finish = source.finish,
            type   = define.TokenTypes.parameter,
        }
    end)
    : case 'doc.generic.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.type,
            modifieres = define.TokenModifiers.modification,
        }
    end)
    : case 'doc.type.string'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.string,
            modifieres = define.TokenModifiers.static,
        }
    end)
    : case 'doc.type.function'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.start + #'fun',
            type       = define.TokenTypes.keyword,
        }
        if source.async then
            -- always set together with `async` (see luadoc.lua)
            local asyncPos = source.asyncPos --[[@as integer]]
            results[#results+1] = {
                start      = asyncPos,
                finish     = asyncPos + #'async',
                type       = define.TokenTypes.keyword,
                modifieres = define.TokenModifiers.async,
            }
        end
    end)
    : case 'doc.type.table'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.start + #'table',
            type       = define.TokenTypes.type,
        }
    end)
    : case 'doc.type.arg.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.parameter,
            modifieres = define.TokenModifiers.declaration,
        }
    end)
    : case 'doc.version.unit'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.enumMember,
        }
    end)
    : case 'doc.see.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.class,
        }
    end)
    : case 'doc.diagnostic'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        -- always set on a 'doc.diagnostic' node (see parser/luadoc.lua)
        local mode = source.mode --[[@as string]]
        results[#results+1] = {
            start      = source.start,
            finish     = source.start + #mode,
            type       = define.TokenTypes.keyword,
        }
    end)
    : case 'doc.diagnostic.name'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.event,
            modifieres = define.TokenModifiers.static,
        }
    end)
    : case 'doc.module'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.string,
            modifieres = define.TokenModifiers.defaultLibrary,
        }
    end)
    : case 'doc.tailcomment'
    ---@param source parser.object
    ---@param options semantic.options
    ---@param results semantic.token[]
    : call(function (source, options, results)
        if not options.annotation then
            return
        end
        results[#results+1] = {
            start  = source.start,
            finish = source.finish,
            type   = define.TokenTypes.comment,
        }
    end)
    : case 'nonstandardSymbol.comment'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start  = source.start,
            finish = source.finish,
            type   = define.TokenTypes.comment,
        }
    end)
    : case 'nonstandardSymbol.continue'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start  = source.start,
            finish = source.finish,
            type   = define.TokenTypes.keyword,
        }
    end)
    : case 'doc.cast.block'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.keyword,
        }
    end)
    : case 'doc.cast.name'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.variable,
        }
    end)
    : case 'doc.type.code'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.string,
            modifieres = define.TokenModifiers.abstract,
        }
    end)
    : case 'doc.operator.name'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.operator,
        }
    end)
    : case 'doc.meta.name'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.namespace,
        }
    end)
    : case 'doc.attr'
    ---@param source parser.object
    ---@param _options semantic.options
    ---@param results semantic.token[]
    : call(function (source, _options, results)
        results[#results+1] = {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.decorator,
        }
    end)

---@param results semantic.packedToken[]
---@return integer[]
local function buildTokens(results)
    ---@type integer[]
    local tokens = {}
    local lastLine = 0
    local lastStartChar = 0
    local index = 0
    for i, source in ipairs(results) do
        local startPos  = source.start
        local finishPos = source.finish
        local line      = startPos.line
        local startChar = startPos.character
        local deltaLine = line - lastLine
        ---@type integer
        local deltaStartChar
        if deltaLine == 0 then
            deltaStartChar = startChar - lastStartChar
            if deltaStartChar == 0 and i > 1 then
                goto continue
            end
        else
            deltaStartChar = startChar
        end
        lastLine = line
        lastStartChar = startChar
        -- see https://microsoft.github.io/language-server-protocol/specifications/specification-3-16/#textDocument_semanticTokens
        index = index + 1 --[[@as integer]]
        local len = index * 5 - 5
        tokens[len + 1] = deltaLine
        tokens[len + 2] = deltaStartChar
        tokens[len + 3] = finishPos.character - startPos.character -- length
        tokens[len + 4] = source.type
        tokens[len + 5] = source.modifieres or 0
        ::continue::
    end
    return tokens
end

---@async
---@param state parser.state
---@param results semantic.token[]
---@return semantic.packedToken[]
local function solveMultilineAndOverlapping(state, results)
    table.sort(results, function (a, b)
        if a.start == b.start then
            return a.finish < b.finish
        else
            return a.start < b.start
        end
    end)

    await.delay()

    local tokens = linkedTable()

    ---@param pos integer
    ---@return semantic.token?
    local function findToken(pos)
        for token in tokens:pairs(nil ,true) do
            ---@cast token semantic.token
            if token.start <= pos and token.finish >= pos then
                return token
            end
            if token.finish < pos then
                break
            end
        end
        return nil
    end

    for _, current in ipairs(results) do
        local left = findToken(current.start)
        if not left then
            tokens:pushTail(current)
            goto CONTINUE
        end
        local right = findToken(current.finish)
        tokens:pushAfter(current, left)
        tokens:pop(left)
        if left.start < current.start then
            tokens:pushBefore({
                start      = left.start,
                finish     = current.start,
                type       = left.type,
                modifieres = left.modifieres
            }, current)
        end
        if right and right.finish > current.finish then
            tokens:pushAfter({
                start      = current.finish,
                finish     = right.finish,
                type       = right.type,
                modifieres = right.modifieres
            }, current)
        end
        ::CONTINUE::
    end

    await.delay()

    ---@type semantic.packedToken[]
    local new = {}
    for token in tokens:pairs() do
        ---@cast token semantic.token
        local startPos = converter.packPosition(state, token.start)
        local endPos   = converter.packPosition(state, token.finish)
        if  startPos.line == endPos.line
        and startPos.character == endPos.character then
            goto continue
        end
        if endPos.line == startPos.line
        or client.getAbility 'textDocument.semanticTokens.multilineTokenSupport' then
            new[#new+1] = {
                start      = startPos,
                finish     = endPos,
                type       = token.type,
                modifieres = token.modifieres,
            }
        else
            --LSP规范说客户端不支持token跨行的话，
            --token长度可以超出行的范围，客户端应该
            --将其视为在行的末尾结束。
            --正好可以测试（拷打）一下客户端的实现。
            new[#new+1] = {
                start      = startPos,
                finish     = converter.position(startPos.line, 9999),
                type       = token.type,
                modifieres = token.modifieres,
            }
            for i = startPos.line + 1, endPos.line - 1 do
                new[#new+1] = {
                    start      = converter.position(i, 0),
                    finish     = converter.position(i, 9999),
                    type       = token.type,
                    modifieres = token.modifieres,
                }
            end
            if endPos.character > 0 then
                new[#new+1] = {
                    start      = converter.position(endPos.line, 0),
                    finish     = converter.position(endPos.line, endPos.character),
                    type       = token.type,
                    modifieres = token.modifieres,
                }
            end
        end
        ::continue::
    end

    return new
end

---@async
---@return semantic.token[]|integer[]
return function (uri, start, finish)
    ---@type semantic.token[]
    local results = {}
    if not config.get(uri, 'Lua.semantic.enable') then
        return results
    end
    local state = files.getState(uri)
    if not state then
        return results
    end

    ---@type semantic.options
    local options = {
        uri        = uri,
        state      = state,
        -- non-nil: the file's text is loaded whenever its state is (just checked above)
        text       = files.getText(uri) --[[@as string]],
        libGlobals = {},
        variable   = config.get(uri, 'Lua.semantic.variable'),
        annotation = config.get(uri, 'Lua.semantic.annotation'),
        keyword    = config.get(uri, 'Lua.semantic.keyword'),
    }

    local n = 0
    guide.eachSourceBetween(state.ast, start, finish, function (source) ---@async
        -- skip virtual source
        if source.virtual then
            return
        end
        Care(source.type, source, options, results)
        n = n + 1
        if n % 100 == 0 then
            await.delay()
        end
    end)

    for _, comm in ipairs(state.comms) do
        -- skip virtual comment
        if not comm.virtual
        and start <= comm.start and comm.finish <= finish then
            -- the same logic as in buildLuaDoc
            local headPos = (comm.type == 'comment.short' and comm.text:match '^%-%s*[@|]()')
                         or (comm.type == 'comment.long'  and comm.text:match '^%s*@()')
            if headPos then
                -- absolute position of `@` symbol
                local startOffset = comm.start + (headPos --[[@as integer]])
                if comm.type == 'comment.long' then
                    assert(comm.mark)
                    startOffset = comm.start + (headPos --[[@as integer]]) + #comm.mark - 2
                end
                results[#results+1] = {
                    start  = comm.start,
                    finish = startOffset,
                    type   = define.TokenTypes.comment,
                }
                results[#results+1] = {
                    start      = startOffset,
                    finish     = startOffset + #comm.text:match('%S*', headPos) + 1,
                    type       = define.TokenTypes.keyword,
                    modifieres = define.TokenModifiers.documentation,
                }
            else
                results[#results+1] = {
                    start  = comm.start,
                    finish = comm.finish,
                    type   = define.TokenTypes.comment,
                }
            end
        end
    end

    if #results == 0 then
        return results
    end

    results = solveMultilineAndOverlapping(state, results)

    local tokens = buildTokens(results)

    return tokens
end
