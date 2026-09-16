local type = type
local next = next
local error = error
local tonumber = tonumber
local table_concat = table.concat
local table_move = table.move
local string_char = string.char
local string_byte = string.byte
local string_find = string.find
local string_match = string.match
local string_gsub = string.gsub
local string_sub = string.sub
local string_rep = string.rep
local string_format = string.format

---@type fun(c: integer): string
local utf8_char
---@type fun(v: number): "integer"|"float"
local math_type

if _VERSION == "Lua 5.1" or _VERSION == "Lua 5.2" then
    local math_floor = math.floor
    function utf8_char(c)
        if c <= 0x7f then
            return string_char(c)
        elseif c <= 0x7ff then
            return string_char(math_floor(c / 64) + 192, c % 64 + 128)
        elseif c <= 0xffff then
            return string_char(
                math_floor(c / 4096) + 224,
                math_floor(c % 4096 / 64) + 128,
                c % 64 + 128
            )
        elseif c <= 0x10ffff then
            return string_char(
                math_floor(c / 262144) + 240,
                math_floor(c % 262144 / 4096) + 128,
                math_floor(c % 4096 / 64) + 128,
                c % 64 + 128
            )
        end
        error(string_format("invalid UTF-8 code '%x'", c))
    end
    function math_type(v)
        if v >= -2147483648 and v <= 2147483647 and math_floor(v) == v then
            return "integer"
        end
        return "float"
    end
    ---@param a1  table
    ---@param f   integer
    ---@param e   integer
    ---@param t   integer
    ---@param a2? table
    ---@return table a2
    function table_move(a1, f, e, t, a2)
        local dst = (a2 or a1) --[[@as table<any, any>]]
        for i = f, e do
           dst[t+(i-f)] = a1[i]
        end
       return dst
    end
else
    utf8_char = utf8.char
    math_type = math.type
end

local json = require "json-beautify"

-- json-beautify.lua (required above) always sets these; narrow past the
-- optionality that `---@class json` must declare them with generically,
-- since plain `require "json"` (without json-beautify.lua) leaves them unset
---@type fun(v: any, option?: json-beautify.option): string
local beautify = json.beautify --[[@as any]]
---@type fun(builder: string[], v: any, option?: json-beautify.option)
local beautify_builder = json._beautify_builder --[[@as any]]
---@type fun(option?: json-beautify.option): json-beautify.option
---@diagnostic disable-next-line: invisible
local beautify_option = json._beautify_option --[[@as any]]

local encode_escape_map = {
    [ "\"" ] = "\\\"",
    [ "\\" ] = "\\\\",
    [ "/" ]  = "\\/",
    [ "\b" ] = "\\b",
    [ "\f" ] = "\\f",
    [ "\n" ] = "\\n",
    [ "\r" ] = "\\r",
    [ "\t" ] = "\\t",
}

---@type table<integer, boolean>
local decode_escape_set = {}
---@type table<string, string>
local decode_escape_map = {}
for k, v in next, encode_escape_map do
    decode_escape_map[v] = k
    decode_escape_set[string_byte(v, 2)] = true
end

---@class json-edit.ast
---@field s     integer -- start offset (of the value, or -- for object members -- of the value, with key_s/key_f covering the key separately)
---@field d     integer -- nesting depth at decode time
---@field f     integer -- finish offset
---@field v     any -- decoded value; nested ast nodes for object/array contents, else the primitive value
---@field key_s? integer -- for an object member's ast node: start offset of the key
---@field key_f? integer -- for an object member's ast node: finish offset of the key

---@type string
local statusBuf
---@type integer
local statusPos
---@type integer
local statusTop
---@type table<integer, boolean>
local statusAry = {}
---@type table<integer, table<any, json-edit.ast>>
local statusRef = {}
---@type table<integer, json-edit.ast>
local statusAst = {}

---@return integer line
---@return integer col
local function find_line()
    local line = 1
    local pos = 1
    while true do
        local f, _, nl1, nl2 = string_find(statusBuf, '([\n\r])([\n\r]?)', pos)
        if not f then
            return line, statusPos - pos + 1
        end
        local newpos = f + ((nl1 == nl2 or nl2 == '') and 1 or 2)
        if newpos > statusPos then
            return line, statusPos - pos + 1
        end
        pos = newpos
        line = line + 1
    end
end

---@param msg string
local function decode_error(msg)
    error(string_format("ERROR: %s at line %d col %d", msg, find_line()), 2)
end

---@return string?
local function get_word()
    return string_match(statusBuf, "^[^ \t\r\n%]},]*", statusPos)
end

---@param b integer
---@return true?
local function skip_comment(b)
    if b ~= 47 --[[ '/' ]] then
        return
    end
    local c = string_byte(statusBuf, statusPos+1)
    if c == 42 --[[ '*' ]] then
        -- block comment
        local pos = string_find(statusBuf, "*/", statusPos)
        if pos then
            statusPos = pos + 2
        else
            statusPos = #statusBuf + 1
        end
        return true
    elseif c == 47 --[[ '/' ]] then
        -- line comment
        local pos = string_find(statusBuf, "[\r\n]", statusPos)
        if pos then
            statusPos = pos
        else
            statusPos = #statusBuf + 1
        end
        return true
    end
end

---@return integer
local function next_byte()
    local pos = string_find(statusBuf, "[^ \t\r\n]", statusPos)
    if pos then
        statusPos = pos
        local b = string_byte(statusBuf, pos)
        if not skip_comment(b) then
            return b
        end
        return next_byte()
    end
    return -1
end

---@param s1 string
---@param s2 string
---@return string
local function decode_unicode_surrogate(s1, s2)
    return utf8_char(0x10000 + (tonumber(s1, 16) - 0xd800) * 0x400 + (tonumber(s2, 16) - 0xdc00))
end

---@param s string
---@return string
local function decode_unicode_escape(s)
    return utf8_char(tonumber(s, 16))
end

---@return string
local function decode_string()
    local has_unicode_escape = false
    local has_escape = false
    ---@type integer?
    local i = statusPos + 1
    while true do
        i = string_find(statusBuf, '[%z\1-\31\\"]', i)
        if not i then
            decode_error "expected closing quote for string"
        end
        assert(i)
        local x = string_byte(statusBuf, i)
        if x < 32 then
            statusPos = i
            decode_error "control character in string"
        end
        if x == 34 --[[ '"' ]] then
            local s = string_sub(statusBuf, statusPos + 1, i - 1)
            if has_unicode_escape then
                s = string_gsub(string_gsub(s
                    , "\\u([dD][89aAbB]%x%x)\\u([dD][c-fC-F]%x%x)", decode_unicode_surrogate)
                    , "\\u(%x%x%x%x)", decode_unicode_escape)
            end
            if has_escape then
                s = string_gsub(s, "\\.", decode_escape_map)
            end
            statusPos = i + 1
            return s
        end
        --assert(x == 92 --[[ "\\" ]])
        local nx = string_byte(statusBuf, i+1)
        if nx == 117 --[[ "u" ]] then
            if not string_match(statusBuf, "^%x%x%x%x", i+2) then
                statusPos = i
                decode_error "invalid unicode escape in string"
            end
            has_unicode_escape = true
            i = i + 6
        else
            if not decode_escape_set[nx] then
                statusPos = i
                decode_error("invalid escape char '" .. (nx and string_char(nx) or "<eol>") .. "' in string")
            end
            has_escape = true
            i = i + 2
        end
    end
end

---@return number
local function decode_number()
    local num, c = string_match(statusBuf, '^([0-9]+%.?[0-9]*)([eE]?)', statusPos)
    if not num or string_byte(num, -1) == 0x2E --[[ "." ]] then
        decode_error("invalid number '" .. get_word() .. "'")
    end
    if c ~= '' then
        num = string_match(statusBuf, '^([^eE]*[eE][-+]?[0-9]+)[ \t\r\n%]},/]', statusPos)
        if not num then
            decode_error("invalid number '" .. get_word() .. "'")
        end
    end
    statusPos = statusPos + #num
    return tonumber(num) --[[@as number]]
end

---@return number
local function decode_number_zero()
    local num, c = string_match(statusBuf, '^(.%.?[0-9]*)([eE]?)', statusPos)
    if not num or string_byte(num, -1) == 0x2E --[[ "." ]] or string_match(statusBuf, '^.[0-9]+', statusPos) then
        decode_error("invalid number '" .. get_word() .. "'")
    end
    if c ~= '' then
        num = string_match(statusBuf, '^([^eE]*[eE][-+]?[0-9]+)[ \t\r\n%]},/]', statusPos)
        if not num then
            decode_error("invalid number '" .. get_word() .. "'")
        end
    end
    statusPos = statusPos + #num
    return tonumber(num) --[[@as number]]
end

---@return number?
local function decode_number_negative()
    statusPos = statusPos + 1
    local c = string_byte(statusBuf, statusPos)
    if c then
        if c == 0x30 then
            return -decode_number_zero()
        elseif c > 0x30 and c < 0x3A then
            return -decode_number()
        end
    end
    decode_error("invalid number '" .. get_word() .. "'")
end

---@return boolean
local function decode_true()
    if string_sub(statusBuf, statusPos, statusPos+3) ~= "true" then
        decode_error("invalid literal '" .. get_word() .. "'")
    end
    statusPos = statusPos + 4
    return true
end

---@return boolean
local function decode_false()
    if string_sub(statusBuf, statusPos, statusPos+4) ~= "false" then
        decode_error("invalid literal '" .. get_word() .. "'")
    end
    statusPos = statusPos + 5
    return false
end

---@return any
local function decode_null()
    if string_sub(statusBuf, statusPos, statusPos+3) ~= "null" then
        decode_error("invalid literal '" .. get_word() .. "'")
    end
    statusPos = statusPos + 4
    return json.null
end

---@param ast json-edit.ast
---@return table
local function decode_array(ast)
    statusPos = statusPos + 1
    ---@type table<any, json-edit.ast>
    local res = {}
    local chr = next_byte()
    if chr == 93 --[[ ']' ]] then
        statusPos = statusPos + 1
        return res
    end
    statusTop = statusTop + 1
    statusAry[statusTop] = true
    statusRef[statusTop] = res
    statusAst[statusTop] = ast
    return res
end

---@param ast json-edit.ast
---@return table
local function decode_object(ast)
    statusPos = statusPos + 1
    ---@type table<any, json-edit.ast>
    local res = {}
    local chr = next_byte()
    if chr == 125 --[[ ']' ]] then
        statusPos = statusPos + 1
        return json.createEmptyObject()
    end
    statusTop = statusTop + 1
    statusAry[statusTop] = false
    statusRef[statusTop] = res
    statusAst[statusTop] = ast
    return res
end

---@alias json-edit.decoder fun(ast?: json-edit.ast): any

---@type table<integer, json-edit.decoder>
local decode_uncompleted_map = {
    [ string_byte '"' ] = decode_string,
    [ string_byte "0" ] = decode_number_zero,
    [ string_byte "1" ] = decode_number,
    [ string_byte "2" ] = decode_number,
    [ string_byte "3" ] = decode_number,
    [ string_byte "4" ] = decode_number,
    [ string_byte "5" ] = decode_number,
    [ string_byte "6" ] = decode_number,
    [ string_byte "7" ] = decode_number,
    [ string_byte "8" ] = decode_number,
    [ string_byte "9" ] = decode_number,
    [ string_byte "-" ] = decode_number_negative,
    [ string_byte "t" ] = decode_true,
    [ string_byte "f" ] = decode_false,
    [ string_byte "n" ] = decode_null,
    [ string_byte "[" ] = decode_array,
    [ string_byte "{" ] = decode_object,
}
local function unexpected_character()
    decode_error("unexpected character '" .. string_sub(statusBuf, statusPos, statusPos) .. "'")
end
local function unexpected_eol()
    decode_error("unexpected character '<eol>'")
end

---@type table<integer, json-edit.decoder>
local decode_map = {}
for i = 0, 255 do
    decode_map[i] = decode_uncompleted_map[i] or unexpected_character
end
decode_map[-1] = unexpected_eol

---@return json-edit.ast
local function decode()
    local chr = next_byte()
    ---@type json-edit.ast
    ---@diagnostic disable-next-line: missing-fields
    local ast = {s = statusPos, d = statusTop}
    ast.v = decode_map[chr](ast)
    ast.f = statusPos
    return ast
end

local function decode_item()
    local top = statusTop
    local ref = statusRef[top]
    if statusAry[top] then
        ref[#ref+1] = decode()
    else
        local start = statusPos
        local key = decode_string()
        local finish = statusPos
        if next_byte() ~= 58 --[[ ':' ]] then
            decode_error "expected ':'"
        end
        statusPos = statusPos + 1
        local val = decode()
        val.key_s = start
        val.key_f = finish
        ref[key] = val
    end
    if top == statusTop then
        repeat
            local chr = next_byte(); statusPos = statusPos + 1
            if chr == 44 --[[ "," ]] then
                local c = next_byte()
                if statusAry[statusTop] then
                    if c ~= 93 --[[ "]" ]] then return end
                else
                    if c ~= 125 --[[ "}" ]] then return end
                end
                statusPos = statusPos + 1
            else
                if statusAry[statusTop] then
                    if chr ~= 93 --[[ "]" ]] then decode_error "expected ']' or ','" end
                else
                    if chr ~= 125 --[[ "}" ]] then decode_error "expected '}' or ','" end
                end
            end
            local ast = statusAst[statusTop]
            ast.f = statusPos
            statusTop = statusTop - 1
        until statusTop == 0
    end
end

local JsonEmpty = function () end

---@param str string
---@return json-edit.ast
local function decode_ast(str)
    if type(str) ~= "string" then
        error("expected argument of type string, got " .. type(str))
    end
    statusBuf = str
    statusPos = 1
    statusTop = 0
    if next_byte() == -1 then
        return {s = statusPos, d = statusTop, f = statusPos, v = JsonEmpty}
    end
    local res = decode()
    while statusTop > 0 do
        decode_item()
    end
    if string_find(statusBuf, "[^ \t\r\n]", statusPos) then
        decode_error "trailing garbage"
    end
    return res
end

---@param s string
---@return string[]
local function split(s)
    ---@type string[]
    local r = {}
    s:gsub('[^/]+', function (w)
        r[#r+1] = w:gsub("~1", "/"):gsub("~0", "~")
    end)
    return r
end

---@param ast     json-edit.ast
---@param pathlst string[]
---@param n       integer
---@return json-edit.ast? ast
---@return (string|integer)? key_or_error
---@return boolean? isarray
---@return string[]? remaining
local function query_(ast, pathlst, n)
    local data = ast.v
    if type(data) ~= "table" then
        return nil, string_format("path `%s` does not point to object or array", "/"..table_concat(pathlst, "/", 1, n-1))
    end
    ---@cast data table
    local k = pathlst[n]
    ---@type string|integer
    local key = k
    local isarray = not json.isObject(data)
    if isarray then
        if k == "-" then
            key = (#data + 1) --[[@as integer]]
        else
            if k:match "^0%d+" then
                return nil, string_format("path `%s` point to array, but invalid", "/"..table_concat(pathlst, "/", 1, n))
            end
            local nk = tonumber(k)
            if nk == nil or math_type(nk) ~= "integer" or nk <= 0 or nk > #data + 1 then
                return nil, string_format("path `%s` point to array, but invalid", "/"..table_concat(pathlst, "/", 1, n))
            end
            key = nk --[[@as integer]]
        end
    end
    if n == #pathlst then
        return ast, key, isarray
    end
    local v = data[key] --[[@as any]]
    if v == nil then
        return ast, key, isarray, table_move(pathlst, n + 1, #pathlst, 1, {}) --[[@as string[] ]]
    end
    return query_(v, pathlst, n + 1)
end

---@param path any
---@return string[]? pathlst
---@return string? err
local function split_path(path)
    if type(path) ~= "string" then
        return nil, "path is not a string"
    end
    if path:sub(1,1) ~= "/" then
        return nil, "path must start with `/`"
    end
    return split(path:sub(2))
end

---@param ast  json-edit.ast
---@param path any
local function query(ast, path)
    local pathlst, err = split_path(path)
    if not pathlst then
        return nil, err
    end
    return query_(ast, pathlst, 1)
end

---@param str string
---@return integer?
local function del_first_empty_line(str)
    local pos = str:match("()[ \t]*$")
    if pos then
        local nl1 = str:sub(pos-1, pos-1)
        if nl1:match "[\r\n]" then
            return pos-1
        end
    end
end

---@param str string
---@return integer?
local function del_last_empty_line(str)
    local pos = str:match("^[ \t]*()")
    if pos then
        local nl1 = str:sub(pos, pos)
        if nl1:match "[\r\n]" then
            local nl2 = str:sub(pos+1, pos+1)
            if nl2:match "[\r\n]" and nl1 ~= nl2 then
                return pos+2
            else
                return pos+1
            end
        end
    end
end

---@param t table<any, json-edit.ast>
---@return json-edit.ast?
local function find_max_node(t)
    ---@type json-edit.ast?
    local max
    for _, n in pairs(t) do
        if not max or max.f < n.f then
            max = n
        end
    end
    return max
end

---@param option json-beautify.option
---@return string
local function encode_newline(option)
    return option.newline..string_rep(option.indent, option.depth)
end

---@param str    string
---@param option json-beautify.option
---@param value  any
---@param node   json-edit.ast
---@return string
local function apply_array_insert_before(str, option, value, node)
    local start_text = str:sub(1, node.s-1)
    local finish_text = str:sub(node.s)
    option.depth = option.depth + node.d
    ---@type string[]
    local bd = {}
    bd[#bd+1] = start_text
    beautify_builder(bd, value, option)
    bd[#bd+1] = ","
    bd[#bd+1] = encode_newline(option)
    bd[#bd+1] = finish_text
    return table_concat(bd)
end

---@param str    string
---@param option json-beautify.option
---@param value  any
---@param node   json-edit.ast
---@return string
local function apply_array_insert_after(str, option, value, node)
    local start_text = str:sub(1, node.f-1)
    local finish_text = str:sub(node.f)
    option.depth = option.depth + node.d
    ---@type string[]
    local bd = {}
    bd[#bd+1] = start_text
    bd[#bd+1] = ","
    bd[#bd+1] = encode_newline(option)
    beautify_builder(bd, value, option)
    bd[#bd+1] = finish_text
    return table_concat(bd)
end

---@param str    string
---@param option json-beautify.option
---@param value  any
---@param node   json-edit.ast
---@return string
local function apply_array_insert_empty(str, option, value, node)
    local start_text = str:sub(1, node.s)
    local finish_text = str:sub(node.f-1)
    option.depth = option.depth + node.d + 1
    ---@type string[]
    local bd = {}
    bd[#bd+1] = start_text
    bd[#bd+1] = encode_newline(option)
    beautify_builder(bd, value, option)
    option.depth = option.depth - 1
    bd[#bd+1] = encode_newline(option)
    bd[#bd+1] = finish_text
    return table_concat(bd)
end

---@param str    string
---@param option json-beautify.option
---@param value  any
---@param node   json-edit.ast
---@return string
local function apply_replace(str, option, value, node)
    local start_text = str:sub(1, node.s-1)
    local finish_text = str:sub(node.f)
    option.depth = option.depth + node.d
    ---@type string[]
    local bd = {}
    bd[#bd+1] = start_text
    beautify_builder(bd, value, option)
    bd[#bd+1] = finish_text
    return table_concat(bd)
end

---@param str    string
---@param option json-beautify.option
---@param value  any
---@param t      json-edit.ast
---@param k      string|integer
---@return string
local function apply_object_insert(str, option, value, t, k)
    local node = find_max_node(t.v)
    if node then
        local start_text = str:sub(1, node.f-1)
        local finish_text = str:sub(node.f)
        option.depth = option.depth + node.d
        ---@type string[]
        local bd = {}
        bd[#bd+1] = start_text
        bd[#bd+1] = ","
        bd[#bd+1] = encode_newline(option)
        bd[#bd+1] = '"'
        ---@diagnostic disable-next-line: invisible
        bd[#bd+1] = json._encode_string(k --[[@as string]])
        bd[#bd+1] = '": '
        beautify_builder(bd, value, option)
        bd[#bd+1] = finish_text
        return table_concat(bd)
    else
        local start_text = str:sub(1, t.s)
        local finish_text = str:sub(t.f-1)
        option.depth = option.depth + t.d + 1
        ---@type string[]
        local bd = {}
        bd[#bd+1] = start_text
        bd[#bd+1] = encode_newline(option)
        bd[#bd+1] = '"'
        ---@diagnostic disable-next-line: invisible
        bd[#bd+1] = json._encode_string(k --[[@as string]])
        bd[#bd+1] = '": '
        beautify_builder(bd, value, option)
        option.depth = option.depth - 1
        bd[#bd+1] = encode_newline(option)
        bd[#bd+1] = finish_text
        return table_concat(bd)
    end
end

---@param str string
---@param s   integer
---@param f   integer
---@return string
local function apply_remove(str, s, f)
    local start_text = str:sub(1, s-1)
    local finish_text = str:sub(f+1)
    local start_pos = del_first_empty_line(start_text)
    local finish_pos = del_last_empty_line(finish_text)
    if start_pos and finish_pos then
        return start_text:sub(1,start_pos) .. finish_text:sub(finish_pos)
    else
        return start_text .. finish_text
    end
end

---@param v any
---@param pathlst string[]
---@return any
local function add_prefix(v, pathlst)
    for i = #pathlst, 1, -1 do
        v = { [pathlst[i]] = v }
    end
    return v
end

---@alias json-edit.op fun(str: string, option: json-beautify.option, path: any, value: any): string?

---@type table<string, json-edit.op>
local OP = {}

---@param str    string
---@param option json-beautify.option
---@param path   any
---@param value  any
function OP.add(str, option, path, value)
    if path == '/' then
        return beautify(value, option)
    end
    local ast = decode_ast(str)
    if ast.v == JsonEmpty then
        local pathlst, err = split_path(path)
        if not pathlst then
            error(err)
            return
        end
        value = add_prefix(value, pathlst)
        return beautify(value, option)
    end
    local t, k, isarray, lastpath = query(ast, path)
    if not t then
        error(k)
        return
    end
    if lastpath then
        value = add_prefix(value, lastpath)
    end
    if isarray then
        k = k --[[@as integer]]
        if t.v[k] then
            return apply_array_insert_before(str, option, value, t.v[k])
        elseif k == 1 then
            return apply_array_insert_empty(str, option, value, t)
        else
            return apply_array_insert_after(str, option, value, t.v[k-1])
        end
    else
        if t.v[k] then
            return apply_replace(str, option, value, t.v[k])
        else
            return apply_object_insert(str, option, value, t, k)
        end
    end
end

---@param str  string
---@param _    json-beautify.option
---@param path any
function OP.remove(str, _, path)
    if path == '/' then
        return ''
    end
    local ast = decode_ast(str)
    if ast.v == JsonEmpty then
        return ''
    end
    local t, k, isarray, lastpath = query(ast, path)
    if not t then
        error(k)
        return
    end
    if lastpath then
        --warning: path does not exist
        return str
    end
    if isarray then
        k = k --[[@as integer]]
        if k > #t.v then
            --warning: path does not exist
            return str
        end
        return apply_remove(str, t.v[k].s, t.v[k].f)
    else
        if t.v[k] == nil then
            --warning: path does not exist
            return str
        end
        return apply_remove(str, t.v[k].key_s, t.v[k].f)
    end
end

---@param str    string
---@param option json-beautify.option
---@param path   any
---@param value  any
function OP.replace(str, option, path, value)
    if path == '/' then
        return beautify(value, option)
    end
    local ast = decode_ast(str)
    if ast.v == JsonEmpty then
        local pathlst, err = split_path(path)
        if not pathlst then
            error(err)
            return
        end
        value = add_prefix(value, pathlst)
        return beautify(value, option)
    end
    local t, k, isarray, lastpath = query(ast, path)
    if not t then
        error(k)
        return
    end
    if lastpath then
        value = add_prefix(value, lastpath)
    end
    if t.v[k] then
        return apply_replace(str, option, value, t.v[k])
    else
        if isarray then
            k = k --[[@as integer]]
            if k == 1 then
                return apply_array_insert_empty(str, option, value, t)
            else
                return apply_array_insert_after(str, option, value, t.v[k-1])
            end
        else
            return apply_object_insert(str, option, value, t, k)
        end
    end
end

---@class json-edit.patch
---@field op    string
---@field path  any
---@field value any

---@param str    string
---@param patch  json-edit.patch
---@param option json-beautify.option?
---@return string?
local function edit(str, patch, option)
    local f = OP[patch.op]
    if not f then
        error(string_format("invalid op: %s", patch.op))
        return
    end
    option = beautify_option(option)
    return f(str, option, patch.path, patch.value)
end

json.edit = edit

return json
