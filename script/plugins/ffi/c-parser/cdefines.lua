
local cdefines = {}

local c99 = require("plugins.ffi.c-parser.c99")
local cpp = require("plugins.ffi.c-parser.cpp")
local typed = require("plugins.ffi.c-parser.typed")

---@param lst ctypes.TypeList
---@param name any
---@param typ any
local function add_type(lst, name, typ)
    lst[name] = typ
    table.insert(lst, { name = name, type = typ })
end

local base_c_types = {
    CONST_CHAR_PTR = { "const", "char", "*" },
    CONST_CHAR = { "const", "char" },
    LONG_LONG = { "long", "long" },
    LONG = { "long" },
    DOUBLE = { "double" },
    INT = { "int" },
}

local function get_binop_type(e1, e2)
    if e1[1] == "double" or e2[1] == "double" then
        return base_c_types.DOUBLE
    end
    if e1[2] == "long" or e2[2] == "long" then
        return base_c_types.LONG_LONG
    end
    if e1[1] == "long" or e2[1] == "long" then
        return base_c_types.LONG
    end
    return base_c_types.INT
end

local binop_set = {
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
}

local relop_set = {
    ["<"] = true,
    [">"] = true,
    [">="] = true,
    ["<="] = true,
    ["=="] = true,
    ["!="] = true,
}

local bitop_set = {
    ["<<"] = true,
    [">>"] = true,
    ["&"] = true,
    ["^"] = true,
    ["|"] = true,
}

-- Best-effort assessment of the type of a #define
---@type fun(exp: Exp, lst: ctypes.TypeList): string[]?
local get_type_of_exp
get_type_of_exp = typed("Exp, TypeList -> {string}?",
    ---@param exp Exp
    ---@param lst ctypes.TypeList
    ---@return table|string[]|nil
    function(exp, lst)
    if type(exp[1]) == "string" and exp[2] == nil then
        local val = exp[1] --[[@as string]]
        if val:sub(1,1) == '"' or val:sub(1,2) == 'L"' then
            return base_c_types.CONST_CHAR_PTR
        elseif val:sub(1,1) == "'" or val:sub(1,2) == "L'" then
            return base_c_types.CONST_CHAR
        elseif val:match("^[0-9]*LL$") then
            return base_c_types.LONG_LONG
        elseif val:match("^[0-9]*L$") then
            return base_c_types.LONG
        elseif val:match("%.") then
            return base_c_types.DOUBLE
        else
            return base_c_types.INT
        end
    end

    if type(exp[1]) == "string" and exp[2] and exp[2].args then
        local fn = lst[exp[1]] --[[@as any]]
        if not fn or not fn.ret then
            return nil -- unknown function, or not a function
        end
        local r = fn.ret.type --[[@as any]]
        return table.move(r, 1, #r, 1, {}) -- shallow_copy(r)
    end

    if exp.unop == "*" then
        local etype = get_type_of_exp(exp[1], lst)
        if not etype then
            return nil
        end
        local rem = table.remove(etype)
        assert(rem == "*")
        return etype
    elseif exp.unop == "-" then
        return get_type_of_exp(exp[1], lst)
    elseif exp.op == "?" then
        return get_type_of_exp(exp[2], lst)
    elseif exp.op == "," then
        return get_type_of_exp(exp[#exp], lst)
    elseif binop_set[exp.op] then
        local e1 = get_type_of_exp(exp[1], lst)
        if not e1 then
            return nil
        end
        -- some binops are also unops (e.g. - and *)
        if exp[2] then
            local e2 = get_type_of_exp(exp[2], lst)
            if not e2 then
                return nil
            end
            return get_binop_type(e1, e2)
        else
            return e1
        end
    elseif relop_set[exp.op] then
        return base_c_types.INT
    elseif bitop_set[exp.op] then
        return get_type_of_exp(exp[1], lst) -- ...or should it be int?
    elseif exp.op then
        print("FIXME unsupported op", exp.op)
    end
    return nil
end)

---@param lst ctypes.TypeList
---@param name string
---@param text string
function cdefines.register_define(lst, name, text)
    local exp = c99.match_language_expression_grammar(text .. " ")
    if not exp then
        -- failed parsing expression
        -- print(("failed parsing: %d:%d: %s\n"):format(line, col, text))
        return
    end
    local typ = get_type_of_exp(exp, lst)
    if typ then
        add_type(lst, name, { type = typ })
    end
end

---@param lst ctypes.TypeList
---@param define_set table<string, Token?>
function cdefines.register_defines(lst, define_set)
    for name, def0 in pairs(define_set) do
        local def = def0
        if #def == 0 then
            goto continue
        end
        local text = cpp.expand_macro(name, define_set)
        cdefines.register_define(lst, name, text)
        ::continue::
    end
end

return cdefines
