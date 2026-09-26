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

print('diagnostic-affected: OK')
