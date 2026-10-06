local files           = require 'files'
local guide           = require 'parser.guide'
local vm              = require 'vm'
local await           = require 'await'
local protoDiagnostic = require 'proto.diagnostic'

local MESSAGE = 'The method redeclares the type parameter `%s` of the class `%s`: remove it from this `@generic`.'

protoDiagnostic.register {
    'redundant-class-generic',
} {
    group    = 'luadoc',
    severity = 'Warning',
    status   = 'Opened',
    description = 'Enable diagnostics for a method whose `---@generic` names a type parameter its class already declares (`---@class Box<T>`): the class-level one is the one in scope. The wowlua-ls diagnostic of the same name.',
}

--- The type parameters the class a method belongs to declares (`---@class Box<T>`), with the name of the class.
---@async
---@param holder parser.object the table the method is stored in (`Box` of `function Box:get()`)
---@return table<string, string> declared type parameter name -> class name
local function classGenericsOf(holder)
    ---@type table<string, string>
    local declared = {}
    for obj in vm.compileNode(holder):eachObject() do
        if obj.type == 'global' and obj.cate == 'type' then
            ---@cast obj vm.global
            for _, set in ipairs(obj:getSets(guide.getUri(holder))) do
                if set.type == 'doc.class' then
                    for _, sign in ipairs(set.signs or {}) do
                        declared[sign[1] --[[@as string]]] = obj.name
                    end
                end
            end
        end
    end
    return declared
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local delayer = await.newThrottledDelayer(500)
    ---@async
    guide.eachSourceType(state.ast, 'function', function (func)
        delayer:delay()
        -- (the cheap exits come first: this runs on every function, and a type is compiled only for a method that has a `@generic`)
        ---@type parser.object[]
        local generics = {}
        for _, doc in ipairs(func.bindDocs or {}) do
            if doc.type == 'doc.generic' then
                generics[#generics+1] = doc
            end
        end
        local holder = func.parent and (func.parent.type == 'setmethod' or func.parent.type == 'setfield') and func.parent.node
        if #generics == 0 or not holder then
            return
        end
        local declared = classGenericsOf(holder)
        if next(declared) == nil then
            return
        end
        for _, doc in ipairs(generics) do
            for _, object in ipairs(doc.generics) do
                local name = object.generic and object.generic[1] --[[@as string?]]
                if name and declared[name] then
                    callback {
                        start   = object.generic.start,
                        finish  = object.generic.finish,
                        message = MESSAGE:format(name, declared[name]),
                    }
                end
            end
        end
    end)
end
