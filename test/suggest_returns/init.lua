-- Dev tool, not part of the default suite: run with
--     SUGGEST_FILES=script/vm/tracer.lua,script/vm/infer.lua bin/lua-language-server test.lua -n=suggest_returns
-- For every function in those files that has `---@param` / `---@return` documentation but is
-- missing a `---@return` for an index it returns (what `incomplete-signature-doc` reports), prints
-- the inferred type of that index as a line
--     SUGGEST<TAB>{"file":..., "after":<0-based line to insert after>, "indent":..., "types":[...], "name":...}
-- for tools/apply_returns.py to turn into `---@return <type>` lines. Functions whose return type
-- cannot be inferred (unknown / any / too long) are printed as `SKIP<TAB>...` for a manual look.
local target = TARGET_TEST_NAME --[[@as string?]]
if not target or not ('suggest_returns'):match(target) then
    return
end

local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm'
local furi  = require 'file-uri'
local await = require 'await'
local json  = require 'json'

-- the same setup as editor_sim: the repository itself is the workspace
SIM_KEEPALIVE = true

---@type string[]
local wanted = {}
for fragment in (os.getenv('SUGGEST_FILES') or ''):gmatch('[^,]+') do
    wanted[#wanted+1] = fragment
end

---@param tbl table<any, any>
---@return string
local function encode(tbl)
    return json.encode(tbl)
end

--- Whether every path of the block ends in a `return` (or an exit): what the
--- `missing-return` diagnostic asks (same logic as core/diagnostics/missing-return.lua).
---@param block parser.object
---@return boolean
local function hasReturn(block)
    if block.hasReturn or block.hasExit then
        return true
    end
    if block.type == 'if' then
        ---@type boolean?
        local hasElse
        for _, subBlock in ipairs(block) do
            if not hasReturn(subBlock) then
                return false
            end
            if subBlock.type == 'elseblock' then
                hasElse = true
            end
        end
        return hasElse == true
    end
    if block.type == 'while' and vm.testCondition(block.filter) then
        return true
    end
    for _, action in ipairs(block) do
        if guide.isBlockType(action) and hasReturn(action) then
            return true
        end
    end
    return false
end

--- The type of one returned expression as text, split into its members; `nilable` when it can be nil.
---@param expr parser.object
---@param uri  uri
---@return string[] members
---@return boolean nilable
local function viewMembers(expr, uri)
    local view = vm.getInfer(vm.compileNode(expr)):view(uri)
    local nilable = false
    if view:sub(-1) == '?' then
        nilable = true
        view = view:sub(1, -2)
    end
    -- `(vm.node)?` is a nilable `vm.node`: drop parentheses that wrap the whole text
    while view:sub(1, 1) == '(' and view:sub(-1) == ')' and not view:sub(2, -2):find('[()]') do
        view = view:sub(2, -2)
    end
    ---@type string[]
    local members = {}
    for member in (view .. '|'):gmatch('([^|]*)|') do
        if member == 'nil' then
            nilable = true
        elseif member ~= '' then
            members[#members+1] = member
        end
    end
    return members, nilable
end

---@async
await.call(function ()
    for uri in files.eachFile() do
        local path = furi.decode(uri):gsub('[\\]', '/')
        ---@type string?
        local rel = path:match('/lua%-language%-server/(.*)')
        local hit = false
        for _, fragment in ipairs(wanted) do
            if rel and rel == fragment then
                hit = true
            end
        end
        if not hit or not rel then
            goto CONTINUE
        end
        do
            local state = files.getState(uri)
            if not state or not state.ast then
                goto CONTINUE
            end
            ---@type string[]
            local lines = {}
            for line in (state.lua or ''):gmatch('([^\n]*)\n?') do
                lines[#lines+1] = line
            end
            guide.eachSourceType(state.ast, 'function', function (func)
                if not func.bindDocs or not func.returns then
                    return
                end
                local hasSignatureDoc = false
                ---@type table<integer, true>
                local documented = {}
                ---@type parser.object?
                local lastDoc
                for _, doc in ipairs(func.bindDocs) do
                    if doc.type == 'doc.param' or doc.type == 'doc.return' then
                        hasSignatureDoc = true
                        if not lastDoc or doc.finish > lastDoc.finish then
                            lastDoc = doc
                        end
                    end
                    if doc.type == 'doc.return' then
                        for _, ret in ipairs(doc.returns) do
                            documented[ret.returnIndex] = true
                        end
                    end
                end
                if not hasSignatureDoc or not lastDoc then
                    return
                end
                -- the indexes some return statement provides, and the expressions for each
                ---@type table<integer, parser.object[]>
                local exprs = {}
                local maxIndex = 0
                for _, ret in ipairs(func.returns) do
                    for index, expr in ipairs(ret) do
                        exprs[index] = exprs[index] or {}
                        exprs[index][#exprs[index]+1] = expr
                        if index > maxIndex then
                            maxIndex = index
                        end
                    end
                end
                ---@type integer[]
                local missing = {}
                for index = 1, maxIndex do
                    if not documented[index] then
                        missing[#missing+1] = index
                    end
                end
                if #missing == 0 then
                    return
                end
                -- 0-based line of the last signature doc
                local line = guide.rowColOf(lastDoc.finish)
                local text = lines[line + 1] or ''
                local indent = text:match('^(%s*)') or ''
                local nameNode = func.parent and func.parent.type ~= 'main' and func.parent.node and func.parent.node[1]
                local name = type(nameNode) == 'string' and nameNode or nil
                local funcLine = guide.rowColOf(func.start)
                ---@type string[]
                local types = {}
                local ok = true
                local why = ''
                -- an existing @return for a later index would have to be moved: leave that to a human
                for index in pairs(documented) do
                    if index > missing[1] then
                        ok = false
                        why = 'a later index is documented'
                    end
                end
                local fallsThrough = not hasReturn(func)
                for _, index in ipairs(missing) do
                    -- every return statement, and the end of the function, must provide the index
                    local nilable = fallsThrough
                    local expands = false
                    for _, ret in ipairs(func.returns) do
                        if #ret < index then
                            local last = ret[#ret]
                            -- `return f()` / `return ...` may provide this index; what it is cannot be read off here
                            if last and (last.type == 'call' or last.type == 'varargs') then
                                expands = true
                            else
                                nilable = true
                            end
                        end
                    end
                    ---@type string[]
                    local members = {}
                    ---@type table<string, true>
                    local seen = {}
                    for _, expr in ipairs(exprs[index]) do
                        local exprMembers, exprNilable = viewMembers(expr, uri)
                        nilable = nilable or exprNilable
                        for _, member in ipairs(exprMembers) do
                            if not seen[member] then
                                seen[member] = true
                                members[#members+1] = member
                            end
                        end
                    end
                    local view = #members > 0 and table.concat(members, '|') or 'nil'
                    if seen['any'] then
                        view = 'any'   -- `any` absorbs everything else: nothing useful to write
                    end
                    if nilable and view ~= 'nil' then
                        view = view .. '|nil'
                    end
                    if expands then
                        ok = false
                        why = ('index %d comes from a call or `...`'):format(index)
                    elseif view == 'unknown' or view == 'any' or view == 'nil' or view == '' then
                        ok = false
                        why = ('index %d is %s'):format(index, view)
                    elseif #view > 90 or view:find('\n', 1, true) then
                        ok = false
                        why = ('index %d is too long: %s'):format(index, view:sub(1, 60))
                    end
                    types[#types+1] = view
                end
                local record = {
                    file   = rel,
                    after  = line,
                    indent = indent,
                    types  = types,
                    name   = name,
                    line   = funcLine + 1,
                    why    = why,
                }
                print((ok and 'SUGGEST' or 'SKIP') .. '\t' .. encode(record))
            end)
        end
        ::CONTINUE::
    end
    os.exit(0)
end)
