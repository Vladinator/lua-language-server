-- workspace.diagnostic-affected: a safe, structural narrowing of "which files could a change to
-- this file affect" (provider/diagnostic.lua's workspace-wide re-diagnosis on save). Every case
-- here is a case where under-including would be a real bug (a file that should have been
-- re-diagnosed, silently wasn't); over-including is always allowed and not asserted against.
local files    = require 'files'
local furi     = require 'file-uri'
local affected = require 'workspace.diagnostic-affected'

local uriA = furi.encode(TESTROOT .. 'diagnostic-affected-a.lua')
local uriB = furi.encode(TESTROOT .. 'diagnostic-affected-b.lua')
local uriC = furi.encode(TESTROOT .. 'diagnostic-affected-c.lua')
local uriD = furi.encode(TESTROOT .. 'diagnostic-affected-d.lua')
local uriE = furi.encode(TESTROOT .. 'diagnostic-affected-e.lua')

local function cleanup()
    for _, uri in ipairs { uriA, uriB, uriC, uriD, uriE } do
        files.remove(uri)
    end
    affected.lastDeclares[uriA] = nil
end

-- A declares a global, B references it by name, C shares nothing with either.
files.setText(uriA, 'Foo = 1\n')
files.setText(uriB, 'print(Foo)\n')
files.setText(uriC, 'local x = 1\n')

local result = affected.getAffectedUris(uriA, { uriA })
assert(result, 'expected a narrowed set, not a full-scope fallback')
assert(result[uriA], 'the changed file itself must always be affected')
assert(result[uriB], 'a file referencing the changed file\'s declared global must be affected')
assert(not result[uriC], 'an unrelated file must not be pulled in by name reachability alone')

-- Rename hazard: A stops declaring Foo (declares Bar instead). B still only references Foo (the
-- OLD name). One more pass after the rename must still catch B through the last-seen snapshot;
-- only the pass after THAT is allowed to drop it.
files.setText(uriA, 'Bar = 1\n')
local afterRename = affected.getAffectedUris(uriA, { uriA })
assert(afterRename, 'expected a narrowed set after the rename')
assert(afterRename[uriB], 'a file referencing the OLD name must still be caught for one more pass after a rename')

local secondPass = affected.getAffectedUris(uriA, { uriA })
assert(secondPass, 'expected a narrowed set on the second pass')
assert(not secondPass[uriB], 'once the old name has aged out of the snapshot, an unrelated file must not stay pinned forever')

cleanup()

-- Require graph: D requires E; a change to E must re-diagnose D too, at file granularity,
-- without D referencing any name E declares.
files.setText(uriE, 'local M = {}\nreturn M\n')
files.setText(uriD, ('local dep = require %q\n'):format('diagnostic-affected-e'))

local reqResult = affected.getAffectedUris(uriD, { uriE })
assert(reqResult, 'expected a narrowed set for the require case')
assert(reqResult[uriE], 'the changed file itself must always be affected')
assert(reqResult[uriD], 'a requirer of the changed file must be affected even with no shared global name')

cleanup()

-- A dynamic (non-literal) require makes its own file unconditionally affected: its true target
-- is unknown, so it can never be proven unrelated to some other change.
files.setText(uriD, 'local name = "diagnostic-affected-e"\nlocal dep = require(name)\n')
files.setText(uriB, 'print(1)\n')

local dynResult = affected.getAffectedUris(uriB, { uriB })
assert(dynResult, 'expected a narrowed set even with a dynamic require present elsewhere')
assert(dynResult[uriD], 'a file with an unresolvable require must always be included, regardless of what actually changed')

cleanup()

-- Types: a class declared in the changed file reaches the files that name it (a `---@type`, a `---@param`, an
-- `extends`), an alias and an enum too; a file that merely declares the same class is reached as well (the fields of
-- a class are the union of its declarations); a file that names another type is not.
do
    local function lines(...)
        return table.concat({ ... }, string.char(10)) .. string.char(10)
    end
    local uriClass   = furi.encode(TESTROOT .. 'diagnostic-affected-class.lua')
    local uriUser    = furi.encode(TESTROOT .. 'diagnostic-affected-class-user.lua')
    local uriParam   = furi.encode(TESTROOT .. 'diagnostic-affected-class-param.lua')
    local uriChild   = furi.encode(TESTROOT .. 'diagnostic-affected-class-child.lua')
    local uriSame    = furi.encode(TESTROOT .. 'diagnostic-affected-class-same.lua')
    local uriOther   = furi.encode(TESTROOT .. 'diagnostic-affected-class-other.lua')
    local uriAlias   = furi.encode(TESTROOT .. 'diagnostic-affected-alias.lua')
    local uriAliasUse = furi.encode(TESTROOT .. 'diagnostic-affected-alias-user.lua')
    local uriEnum    = furi.encode(TESTROOT .. 'diagnostic-affected-enum.lua')
    local uriEnumUse = furi.encode(TESTROOT .. 'diagnostic-affected-enum-user.lua')
    local all = { uriClass, uriUser, uriParam, uriChild, uriSame, uriOther, uriAlias, uriAliasUse, uriEnum, uriEnumUse }
    for _, uri in ipairs(all) do
        affected.lastTypes[uri] = nil
    end

    files.setText(uriClass,  lines('---@class AffectedShape', '---@field size number', 'local M = {}', 'return M'))
    files.setText(uriUser,   lines('---@type AffectedShape', 'local shape'))
    files.setText(uriParam,  lines('---@param s AffectedShape', 'local function f(s) end'))
    files.setText(uriChild,  lines('---@class AffectedChild : AffectedShape', 'local C = {}', 'return C'))
    files.setText(uriSame,   lines('---@class AffectedShape', '---@field color string', 'local S = {}', 'return S'))
    files.setText(uriOther,  lines('---@type NothingToDoWithIt', 'local other'))
    local result = affected.getAffectedUris(uriClass, { uriClass })
    assert(result, 'expected a narrowed set for the class case')
    assert(result[uriClass], 'the changed file itself must always be affected')
    assert(result[uriUser],  'a file with `---@type C` of the changed file\'s class must be affected')
    assert(result[uriParam], 'a file with `---@param x C` of the changed file\'s class must be affected')
    assert(result[uriChild], 'a file whose class extends the changed file\'s class must be affected')
    assert(result[uriSame],  'a file that declares the same class (more fields of it) must be affected')
    assert(not result[uriOther], 'a file that names an unrelated type must not be pulled in')

    -- the class is renamed: the files that still name the old one are reached for one more pass
    files.setText(uriClass, lines('---@class AffectedRenamed', 'local M = {}', 'return M'))
    local renamed = affected.getAffectedUris(uriClass, { uriClass })
    assert(renamed and renamed[uriUser], 'a file naming the OLD class must still be caught once after a rename')
    local settled = affected.getAffectedUris(uriClass, { uriClass })
    assert(settled and not settled[uriUser], 'and not pinned for ever')

    files.setText(uriAlias,    lines('---@alias AffectedMode "a"|"b"'))
    files.setText(uriAliasUse, lines('---@param m AffectedMode', 'local function f(m) end'))
    local aliasResult = affected.getAffectedUris(uriAlias, { uriAlias })
    assert(aliasResult and aliasResult[uriAliasUse], 'a file naming the changed file\'s alias must be affected')
    assert(aliasResult and not aliasResult[uriOther], 'an unrelated file is not affected by an alias')

    files.setText(uriEnum,    lines('---@enum AffectedKind', 'local K = { A = 1 }', 'return K'))
    files.setText(uriEnumUse, lines('---@param k AffectedKind', 'local function f(k) end'))
    local enumResult = affected.getAffectedUris(uriEnum, { uriEnum })
    assert(enumResult and enumResult[uriEnumUse], 'a file naming the changed file\'s enum must be affected')

    for _, uri in ipairs(all) do
        files.remove(uri)
        affected.lastTypes[uri] = nil
    end
end

-- Members of a global: `Foo.bar = 1` / `function Foo:run() end` in the changed file declare nothing by name (no
-- `Foo = ...`), but the files that use `Foo.bar` / `Foo:run()` see the change through the global `Foo`.
do
    local function lines(...)
        return table.concat({ ... }, string.char(10)) .. string.char(10)
    end
    local uriDef   = furi.encode(TESTROOT .. 'diagnostic-affected-members.lua')
    local uriUse   = furi.encode(TESTROOT .. 'diagnostic-affected-members-user.lua')
    local uriAway  = furi.encode(TESTROOT .. 'diagnostic-affected-members-away.lua')
    local uriBase  = furi.encode(TESTROOT .. 'diagnostic-affected-members-base.lua')
    for _, uri in ipairs { uriDef, uriUse, uriAway, uriBase } do
        affected.lastDeclares[uri] = nil
    end
    files.setText(uriBase, lines('AffectedGlobalTable = {}'))
    files.setText(uriDef,  lines('function AffectedGlobalTable:run() return 1 end', 'AffectedGlobalTable.size = 2', 'AffectedGlobalTable[3] = 4'))
    files.setText(uriUse,  lines('local n = AffectedGlobalTable:run()'))
    files.setText(uriAway, lines('local m = SomethingElse:run()'))
    local result = affected.getAffectedUris(uriDef, { uriDef })
    assert(result and result[uriUse], 'a file using the members of a global must be affected by the file that sets them')
    assert(result and not result[uriAway], 'a file using another global is not affected')
    for _, uri in ipairs { uriDef, uriUse, uriAway, uriBase } do
        files.remove(uri)
        affected.lastDeclares[uri] = nil
    end
end

print('diagnostic-affected: OK')
