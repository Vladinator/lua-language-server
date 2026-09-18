local parser = require 'parser'
local fs = require 'bee.filesystem'
local utility = require 'utility'

EXISTS = {}

---@type {[string]: integer, [integer]: string}
local sortList = {
    'specials',
    'type', 'start', 'vstart', 'bstart', 'finish', 'effect', 'range', 'tindex',
    'tag', 'special', 'keyword',
    'parent', 'extParent', 'child',
    'filter',
    'vararg',
    'node', 'locPos',
    'op', 'args',
    'loc', 'init', 'max', 'step', 'keys', 'exps', 'call', 'func',
    'dot', 'colon',
    'field', 'index', 'method',
    'exp', 'value', 'vref',
    'attrs', 'escs',
    'locals', 'ref', 'returns', 'breaks',
}
for i, v in ipairs(sortList) do
    sortList[v] = i
end
local ignoreList = {
    'specials', 'locals', 'ref', 'node', 'parent', 'extParent', 'returns', 'state', 'mirror', 'next', 'vararg', 'originalComment', 'typeCache', 'eachCache', 'bindSource'
}
---@type table<string, boolean>
local ignoreMap = {}
for i, v in ipairs(ignoreList) do
    ignoreMap[v] = true
end

IGNORE_MAP = ignoreMap

local myOption = {
    alignment = true,
    ---@param keys any[]
    ---@param keymap any
    sorter = function (keys, keymap)
        table.sort(keys, function (a, b)
            local tp1 = type(a)
            local tp2 = type(b)
            if tp1 == 'number' and tp2 ~= 'number' then
                return false
            end
            if tp1 ~= 'number' and tp2 == 'number' then
                return true
            end
            if tp1 == 'number' and tp2 == 'number' then
                return a < b
            end
            local s1 = sortList[a] or 9999
            local s2 = sortList[b] or 9999
            if s1 == s2 then
                return a < b
            else
                return s1 < s2
            end
        end)
    end,
    loop = ('%q'):format('<LOOP>'),
    number = function (n)
        return ('%q'):format(n)
    end,
    format = setmetatable({}, { __index = function (_, key)
        return function (value, _, _, _)
            if ignoreMap[key] then
                return '<IGNORE>'
            end
            if type(key) == 'string' and key:sub(1, 1) == '_' then
                return nil
            end
            return value
        end
    end}),
}

local targetOption = {
    alignment = true,
    ---@param keys any[]
    ---@param keymap any
    sorter = function (keys, keymap)
        table.sort(keys, function (a, b)
            local tp1 = type(a)
            local tp2 = type(b)
            if tp1 == 'number' and tp2 ~= 'number' then
                return false
            end
            if tp1 ~= 'number' and tp2 == 'number' then
                return true
            end
            if tp1 == 'number' and tp2 == 'number' then
                return a < b
            end
            local s1 = sortList[a] or 9999
            local s2 = sortList[b] or 9999
            if s1 == s2 then
                return a < b
            else
                return s1 < s2
            end
        end)
    end,
    loop = ('%q'):format('<LOOP>'),
    number = function (n)
        return ('%q'):format(n)
    end,
}

---@param myBuf string
---@param targetBuf string
local function autoFix(myBuf, targetBuf)
    local info = debug.getinfo(3, 'Sl')
    local filename = info.source:sub(2)
    local fileBuf = utility.loadFile(filename)
    assert(fileBuf)
    local pos = fileBuf:find(targetBuf, 1, true)
    assert(pos)
    local newFileBuf = fileBuf:sub(1, pos-1) .. myBuf .. fileBuf:sub(pos + #targetBuf)
    utility.saveFile(filename, newFileBuf)
end

local function test(type)
    local mode = type
    if mode == 'Dirty' then
        mode = 'Lua'
    end
    CHECK = function (buf, opt)
        return function (target_ast)
            local state, err = parser.compile(buf, mode, 'Lua 5.4', opt)
            if not state then
                error(('语法树生成失败：%s'):format(err))
            end
            state.ast.state = nil
            local result = utility.dump(state.ast, myOption)
            local expect = utility.dump(target_ast, targetOption)
            if result ~= expect then
                fs.create_directories(ROOT / 'test' / 'log')
                utility.saveFile((ROOT / 'test' / 'log' / 'my_ast.ast'):string(), result)
                utility.saveFile((ROOT / 'test' / 'log' / 'target_ast.ast'):string(), expect)
                autoFix(result, expect)
                error(('语法树不相等：%s\n%s'):format(type, buf))
            end
        end
    end
    LuaDoc = function (buf)
        return function (target_doc)
            local state, err = parser.compile(buf, 'Lua', 'Lua 5.4')
            if not state then
                error(('语法树生成失败：%s'):format(err))
            end
            parser.luadoc(state)
            local ast = assert(state.ast)
            local docs = assert(ast.docs)
            for _, doc in ipairs(docs) do
                doc.bindGroup = nil
                ---@diagnostic disable-next-line: inject-field, no-unknown -- test-only: clears a legacy field that no longer exists on the type
                doc.bindSources = nil
            end
            docs.groups = nil
            local result = utility.dump(docs, myOption)
            local expect = utility.dump(target_doc, targetOption)
            if result ~= expect then
                fs.create_directories(ROOT / 'test' / 'log')
                utility.saveFile((ROOT / 'test' / 'log' / 'my_doc.ast'):string(), result)
                utility.saveFile((ROOT / 'test' / 'log' / 'target_doc.ast'):string(), expect)
                autoFix(result, expect)
                error(('语法树不相等：%s\n%s'):format(type, buf))
            end
        end
    end
    Comment = function (buf)
        return function (target_comment)
            local state, err = parser.compile(buf, mode, 'Lua 5.4', {
                ['nonstandardSymbol'] = {
                    ['//'] = true,
                },
            })
            if not state then
                error(('语法树生成失败：%s'):format(err))
            end
            state.ast.state = nil
            local result = utility.dump(state.comms, myOption)
            local expect = utility.dump(target_comment, targetOption)
            if result ~= expect then
                fs.create_directories(ROOT / 'test' / 'log')
                utility.saveFile((ROOT / 'test' / 'log' / 'my_ast.ast'):string(), result)
                utility.saveFile((ROOT / 'test' / 'log' / 'target_ast.ast'):string(), expect)
                --autoFix(result, expect)
                error(('语法树不相等：%s\n%s'):format(type, buf))
            end
        end
    end
    require('parser_test.ast.' .. type)
end

test 'Nil'
test 'Boolean'
test 'String'
test 'Number'
test 'Exp'
test 'Action'
test 'Lua'
test 'Dirty'
test 'LuaDoc'
test 'Comment'
