-- Lives next to invalid-secret-context.lua on purpose: this test only runs if its plugin does too (see the checkPluginDir scan in
-- test/diagnostics/init.lua). It uses a made-up API library written with the tags, the way the real stubs are, and checks that the code
-- behaves as wowlua-ls's documentation says: a secret result is ordinary where a guard proves the restriction away, and nowhere else.

DIAG_CARE = {
    ['secret-arithmetic']     = true,
    ['secret-comparison']     = true,
    ['secret-condition']      = true,
    ['secret-table-key']      = true,
    ['secret-access']         = true,
    ['need-check-nil']        = true,
    ['invalid-secret-context'] = true,
}

local API = [[
Enum = {
    AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
    SecrecyLevel = { NeverSecret = 0, Always = 1 },
}

C_Secrets = {}

---@secret-clears SecretWhenAurasRestricted
---@return boolean
function C_Secrets.ShouldAurasBeSecret() return false end

---@secret-clears SecretWhenCooldownsRestricted
---@return boolean
function C_Secrets.ShouldCooldownsBeSecret() return false end

---@secret-clears SecretWhenUnitHealthMax unit
---@param unit string
---@return boolean
function C_Secrets.ShouldUnitHealthMaxBeSecret(unit) return false end

---@secret-clears SecretWhenUnitPower unit=unit,unitToken powerType
---@param unit string
---@param powerType number
---@return boolean
function C_Secrets.ShouldUnitPowerBeSecret(unit, powerType) return false end

---@secret-clears SecretWhenSpellAura spell == Enum.SecrecyLevel.NeverSecret
---@param spell number
---@return number
function C_Secrets.GetSpellAuraSecrecy(spell) return 0 end

---@secret-clears *
---@return boolean
function C_Secrets.HasSecretRestrictions() return false end

---@secret-satisfies CanCompare a b
---@param a string
---@param b string
---@return boolean
function C_Secrets.CanCompareUnitTokens(a, b) return true end

---@secret-restriction-guard Combat
---@return boolean
function InCombatLockdown() return false end

C_RestrictedActions = {}

---@secret-restriction-guard type
---@param type number
---@return boolean
function C_RestrictedActions.IsAddOnRestrictionActive(type) return false end

---@secret-when SecretWhenAurasRestricted
---@return secret number
function GetAuraDuration() return 0 end

---@secret-when SecretWhenUnitHealthMax
---@param unit string
---@return secret number
function UnitHealthMax(unit) return 0 end

---@secret-when SecretWhenUnitPower
---@param unit string
---@param powerType number
---@return secret number
function UnitPower(unit, powerType) return 0 end

---@secret-when SecretWhenUnitPower
---@param unitToken string
---@param powerType number
---@return secret number
function UnitPowerByToken(unitToken, powerType) return 0 end

---@secret-when SecretWhenInCombat
---@return secret number
function GetCombatValue() return 0 end

---@secret-when SecretWhenSpellAura
---@param spell number
---@return secret number
function GetSpellAuraValue(spell) return 0 end

---@secret-when SecretWhenUnitIdentity
---@secret-unless unit player pet
---@param unit string
---@return secret string
function UnitName(unit) return '' end

---@secret-when SecretWhenAurasRestricted
---@secret-when SecretWhenCooldownsRestricted
---@return secret number
function GetTwoPredicates() return 0 end

---@return secret number
function GetAlwaysSecret() return 0 end

---@secret-when SecretWhenAurasRestricted
---@class AuraData
---@field name string
---@field duration secret number

---@return AuraData
function GetAura() return {} end

---@secret-when SecretWhenCooldownsRestricted
---@class CooldownData
---@field left secret number

---@return CooldownData
function GetCooldown() return {} end

---@class SecretInfo
---@field name string

---@secret-precondition CanCompare ReturnNothing the units must be comparable
---@param a string
---@param b string
---@return SecretInfo?
function CompareUnits(a, b) return nil end
]]

--- the script with the made-up API in front: the marks of the test come after it
---@param script string
---@return string
local function WITH_API(script)
    return API .. script
end

-- unguarded: secret (the control of every test below)
TEST(WITH_API [[
local d = GetAuraDuration()
print(<!d!> + 1)
]])

-- a guard clears the predicate where its result is falsy: `if not`, the else branch, an early exit
TEST(WITH_API [[
if not C_Secrets.ShouldAurasBeSecret() then
    local d = GetAuraDuration()
    print(d + 1)
end
]])

TEST(WITH_API [[
if C_Secrets.ShouldAurasBeSecret() then
    local d = GetAuraDuration()
    print(<!d!> + 1)
else
    local d = GetAuraDuration()
    print(d + 1)
end
]])

TEST(WITH_API [[
local function f()
    if C_Secrets.ShouldAurasBeSecret() then return end
    local d = GetAuraDuration()
    return d + 1
end
]])

-- ... and not before the guard, not when the guard is for something else, not past the end of the guarded block
TEST(WITH_API [[
local function f()
    local early = GetAuraDuration()
    if C_Secrets.ShouldAurasBeSecret() then return end
    return <!early!> + 1
end
]])

TEST(WITH_API [[
if not C_Secrets.ShouldUnitHealthMaxBeSecret('player') then
    local d = GetAuraDuration()
    print(<!d!> + 1)
end
]])

TEST(WITH_API [[
if not C_Secrets.ShouldAurasBeSecret() then
    print(1)
end
local d = GetAuraDuration()
print(<!d!> + 1)
]])

-- the early exit has to leave: a branch that falls through guards nothing
TEST(WITH_API [[
local function f(flag)
    if C_Secrets.ShouldAurasBeSecret() then print(flag) end
    local d = GetAuraDuration()
    return <!d!> + 1
end
]])

-- an `if` / `elseif` chain: the guard of an earlier branch holds in the later ones
TEST(WITH_API [[
local function f(flag)
    if C_Secrets.ShouldAurasBeSecret() then
        return 0
    elseif flag then
        local d = GetAuraDuration()
        return d + 1
    end
end
]])

-- `and` / `or` / `not` / `assert` / `while`
TEST(WITH_API [[
local a = not C_Secrets.ShouldAurasBeSecret() and GetAuraDuration() + 1
local b = C_Secrets.ShouldAurasBeSecret() or GetAuraDuration() + 1
local c = C_Secrets.ShouldAurasBeSecret() and <!GetAuraDuration()!> + 1
]])

TEST(WITH_API [[
local function f()
    assert(not C_Secrets.ShouldAurasBeSecret())
    local d = GetAuraDuration()
    return d + 1
end
]])

TEST(WITH_API [[
while not C_Secrets.ShouldAurasBeSecret() do
    local d = GetAuraDuration()
    print(d + 1)
    break
end
]])

-- the older clients' existence check
TEST(WITH_API [[
if C_Secrets and not C_Secrets.ShouldAurasBeSecret() then
    local d = GetAuraDuration()
    print(d + 1)
end
local ok = C_Secrets and C_Secrets.ShouldAurasBeSecret()
if not ok then
    local d = GetAuraDuration()
    print(d + 1)
end
]])

-- a boolean holding the result: until it is written again
TEST(WITH_API [[
local restricted = C_Secrets.ShouldAurasBeSecret()
if not restricted then
    local d = GetAuraDuration()
    print(d + 1)
end
restricted = true
if not restricted then
    local d = GetAuraDuration()
    print(<!d!> + 1)
end
]])

-- a function written inside the guarded code runs later: it starts again with nothing
TEST(WITH_API [[
if not C_Secrets.ShouldAurasBeSecret() then
    local later = function ()
        local d = GetAuraDuration()
        return <!d!> + 1
    end
end
]])

-- an API with two predicates needs both cleared
TEST(WITH_API [[
if not C_Secrets.ShouldAurasBeSecret() then
    local d = GetTwoPredicates()
    print(<!d!> + 1)
end
]])

-- an API without a predicate is secret everywhere, only `*` clears it
TEST(WITH_API [[
if not C_Secrets.ShouldAurasBeSecret() then
    local d = GetAlwaysSecret()
    print(<!d!> + 1)
end
if not C_Secrets.HasSecretRestrictions() then
    local d = GetAlwaysSecret()
    print(d + 1)
    local e = GetAuraDuration()
    print(e + 1)
end
]])

-- a guard about a unit clears the calls for the same unit only: the same local, field or literal
TEST(WITH_API [[
local function f(unit, other)
    if not C_Secrets.ShouldUnitHealthMaxBeSecret(unit) then
        local same = UnitHealthMax(unit)
        local different = UnitHealthMax(other)
        local literal = UnitHealthMax('player')
        print(same + 1)
        print(<!different!> + 1)
        print(<!literal!> + 1)
    end
end
]])

TEST(WITH_API [[
local frame = { unit = 'target' }
if not C_Secrets.ShouldUnitHealthMaxBeSecret(frame.unit) then
    local same = UnitHealthMax(frame.unit)
    local other = UnitHealthMax('target')
    print(same + 1)
    print(<!other!> + 1)
end
if not C_Secrets.ShouldUnitHealthMaxBeSecret('player') then
    local same = UnitHealthMax('player')
    local other = UnitHealthMax('pet')
    print(same + 1)
    print(<!other!> + 1)
end
]])

-- two bindings: both have to match, and a binding can name the parameter differently in the cleared API
TEST(WITH_API [[
local function f(unit, power)
    if not C_Secrets.ShouldUnitPowerBeSecret(unit, power) then
        local same = UnitPower(unit, power)
        local otherPower = UnitPower(unit, 3)
        print(same + 1)
        print(<!otherPower!> + 1)
    end
end
]])

-- the cleared API may call the same value by another name
TEST(WITH_API [[
local function f(unit, power)
    if not C_Secrets.ShouldUnitPowerBeSecret(unit, power) then
        local same = UnitPowerByToken(unit, power)
        local other = UnitPowerByToken('x', power)
        print(same + 1)
        print(<!other!> + 1)
    end
end
]])

-- a way out of the condition that holds on one side only proves nothing: `a and b` falsy, `a or b` truthy
TEST(WITH_API [[
local function f(unit)
    if C_Secrets.ShouldAurasBeSecret() and C_Secrets.ShouldUnitHealthMaxBeSecret(unit) then return end
    local d = GetAuraDuration()
    local h = UnitHealthMax(unit)
    print(<!d!> + 1)
    print(<!h!> + 1)
end

local function g(a, b, flag)
    if C_Secrets.CanCompareUnitTokens(a, b) or flag then
        local r = CompareUnits(a, b)
        print(<!r!>.name)
    end
    if C_Secrets.CanCompareUnitTokens(a, b) and flag then
        local r = CompareUnits(a, b)
        print(r.name)
    end
end
]])

-- a guard that is clear when its result equals a value
TEST(WITH_API [[
local function f(spell)
    if C_Secrets.GetSpellAuraSecrecy(spell) == Enum.SecrecyLevel.NeverSecret then
        local v = GetSpellAuraValue(spell)
        print(v + 1)
    else
        local v = GetSpellAuraValue(spell)
        print(<!v!> + 1)
    end
    if C_Secrets.GetSpellAuraSecrecy(spell) ~= Enum.SecrecyLevel.NeverSecret then return end
    local v = GetSpellAuraValue(spell)
    print(v + 1)
end
]])

-- a restriction proven inactive clears the predicates that depend on it alone ...
TEST(WITH_API [[
if not InCombatLockdown() then
    local v = GetCombatValue()
    print(v + 1)
end
local after = GetCombatValue()
print(<!after!> + 1)
]])

-- ... and a predicate that depends on several, once all of them are inactive
TEST(WITH_API [[
local Restriction = Enum.AddOnRestrictionType
local function f()
    if C_RestrictedActions.IsAddOnRestrictionActive(Restriction.Combat) then return end
    if C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Encounter) then return end
    local partial = GetAuraDuration()
    print(<!partial!> + 1)
    if C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.ChallengeMode) then return end
    if C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.PvPMatch) then return end
    local all = GetAuraDuration()
    print(all + 1)
end
]])

-- a class that declares the predicate: its secret fields are ordinary wherever the facts clear it, however the structure was obtained
TEST(WITH_API [[
local aura = GetAura()
print(<!aura.duration!> + 1)
print(#aura.name)
if not C_Secrets.ShouldAurasBeSecret() then
    print(aura.duration + 1)
    local again = GetAura()
    print(again.duration + 1)
end
if not C_Secrets.ShouldCooldownsBeSecret() then
    print(<!aura.duration!> + 1)
end
if not InCombatLockdown() then
    print(<!aura.duration!> + 1)
end
if not C_Secrets.HasSecretRestrictions() then
    print(aura.duration + 1)
end
local cooldown = GetCooldown()
if not C_Secrets.ShouldAurasBeSecret() then
    print(<!cooldown.left!> + 1)
end
if not C_Secrets.ShouldCooldownsBeSecret() then
    print(cooldown.left + 1)
end
]])

-- an exemption for a literal argument
TEST(WITH_API [[
local function f(unit)
    local me = UnitName('player')
    local pet = UnitName('pet')
    local target = UnitName('target')
    local anyone = UnitName(unit)
    print(me .. 'x', #me)
    print(#pet)
    print(#<!target!>)
    print(#<!anyone!>)
end
]])

-- the nil of a call that returns nothing when its precondition fails goes where a guard proves the precondition
TEST(WITH_API [[
local function f(a, b)
    local unproven = CompareUnits(a, b)
    print(<!unproven!>.name)
    if C_Secrets.CanCompareUnitTokens(a, b) then
        local proven = CompareUnits(a, b)
        print(proven.name)
        local otherPair = CompareUnits(a, 'x')
        print(<!otherPair!>.name)
    end
end
]])

-- the tags are checked
TEST [[
---@<!secret-when!>
local function A() end

---@secret-unless <!unit!>
local function B(unit) end

---@secret-unless <!unit player pet!>
local function C(unit2) end

---@<!secret-clears!>
local function D() end

---@secret-clears <!* extra!>
local function E() end

---@secret-clears <!Pred nope=a!>
local function F(unit) end

---@<!secret-restriction-guard!>
local function G() end

---@secret-restriction-guard <!Combat Encounter!>
local function H() end

---@<!secret-precondition!>
local function I() end

---@<!secret-satisfies!>
local function J() end

---@secret-clears <!Predicate unit ==!>
local function K(unit) end

---@<!secret-when!> Predicate
local notAFunction = 1

---@secret-when Predicate
local function Fine() end

---@secret-clears Predicate unit=unit,unitToken == false
---@secret-restriction-guard Combat
---@secret-restriction-guard unit
---@secret-unless unit player
---@secret-satisfies Name unit
---@secret-precondition Name ReturnNothing text
local function AlsoFine(unit) end
]]
