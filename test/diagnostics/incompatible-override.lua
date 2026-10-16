-- a method that overrides one of a parent class: what it needs, takes and gives has to fit the parent's (TypeScript's "class incorrectly extends")
TEST [[
---@class OvBase
local OvBase = {}
---@param dt number
---@return boolean
function OvBase:update(dt) return true end

---@class OvChild : OvBase
local OvChild = {}
---@param dt string
---@return boolean
function OvChild:<!update!>(dt) return true end
]]

-- ... the same parameter type, a narrower one or a wider one (bivariant), and an unannotated override are overrides
TEST [[
---@class OvBase2
local OvBase2 = {}
---@param dt number
---@return boolean
function OvBase2:update(dt) return true end

---@class OvSame : OvBase2
local OvSame = {}
---@param dt number
---@return boolean
function OvSame:update(dt) return true end

---@class OvWide : OvBase2
local OvWide = {}
---@param dt number|string
---@return boolean
function OvWide:update(dt) return true end

---@class OvNone : OvBase2
local OvNone = {}
function OvNone:update(dt) return true end
]]

-- ... a return that does not fit, written or inferred, and an override that needs more arguments
TEST [[
---@class OvBase3
local OvBase3 = {}
---@return boolean
function OvBase3:ready() return true end
---@param scale number
function OvBase3:grow(scale) end

---@class OvWrongReturn : OvBase3
local OvWrongReturn = {}
---@return string
function OvWrongReturn:<!ready!>() return "yes" end

---@class OvInferred : OvBase3
local OvInferred = {}
function OvInferred:<!ready!>() return "yes" end

---@class OvMore : OvBase3
local OvMore = {}
---@param scale number
---@param extra number
function OvMore:<!grow!>(scale, extra) end

---@class OvFewer : OvBase3
local OvFewer = {}
function OvFewer:grow() end

---@class OvOptional : OvBase3
local OvOptional = {}
---@param scale number
---@param extra? number
function OvOptional:grow(scale, extra) end
]]

-- ... only a method a parent class declares is compared, and only with a class it inherits from
TEST [[
---@class OvBase4
local OvBase4 = {}
---@param n number
function OvBase4:take(n) end

---@class OvUnrelated
local OvUnrelated = {}
---@param n string
function OvUnrelated:take(n) end

---@class OvChild4 : OvBase4
local OvChild4 = {}
---@param n string
function OvChild4:own(n) end
]]

-- ... two levels down, the nearest declaration counts
TEST [[
---@class OvA
local OvA = {}
---@param n number
function OvA:go(n) end

---@class OvB : OvA
local OvB = {}
---@param n number
function OvB:go(n) end

---@class OvC : OvB
local OvC = {}
---@param n string
function OvC:<!go!>(n) end
]]

-- ... a colon method and a function written with a dot are not compared with each other
TEST [[
---@class OvBase5
local OvBase5 = {}
---@param n number
function OvBase5:go(n) end

---@class OvChild5 : OvBase5
local OvChild5 = {}
---@param self OvChild5
---@param a string
---@param b string
function OvChild5.go(self, a, b) end
]]

-- ... an overloaded or generic parent method says nothing
TEST [[
---@class OvBase6
local OvBase6 = {}
---@overload fun(self: OvBase6, n: string)
---@param n number
function OvBase6:go(n) end
---@generic T
---@param v T
function OvBase6:wrap(v) end

---@class OvChild6 : OvBase6
local OvChild6 = {}
---@param n boolean
function OvChild6:go(n) end
---@param a number
---@param b number
function OvChild6:wrap(a, b) end
]]

-- a field a class redeclares: the same type, a narrower one (an override) and an unrelated or wider one (a collision)
TEST [[
---@class FieldBase
---@field name string
---@field size number|string
---@field mode "a"|"b"

---@class FieldSame : FieldBase
---@field name string

---@class FieldNarrow : FieldBase
---@field size number
---@field mode "a"

---@class FieldWrong : FieldBase
---@field <!name!> number
---@field <!size!> boolean
---@field <!mode!> "c"
]]

-- ... a function field is compared like a method, a field the parent does not have is new, a grandparent's counts
TEST [[
---@class FnFieldBase
---@field handler fun(n: number): string
---@field other number

---@class FnFieldChild : FnFieldBase
---@field <!handler!> fun(n: number, extra: number): string
---@field extra string

---@class FnFieldOk : FnFieldBase
---@field handler fun(n: number): string

---@class FnFieldGrand : FnFieldChild
---@field <!other!> string
]]

-- ... `T?` over `T` is the usual way to make a field optional, `nil` takes an inherited member away: neither is a collision
TEST [[
---@class OptBase
---@field name string
---@field run fun(self: OptBase)

---@class OptChild : OptBase
---@field name string?
---@field run nil

---@class OptWrong : OptBase
---@field <!name!> number?
]]

-- ... a field `fun(self: X, ...)` that redeclares a method has the method's `self` as its first parameter
TEST [[
---@class MethodBase
local MethodBase = {}
function MethodBase:show() end
---@param text string
function MethodBase:setText(text) end

---@class MethodField : MethodBase
---@field show fun(self: MethodField)
---@field setText fun(self: MethodField, text: string)

---@class MethodFieldWrong : MethodBase
---@field <!show!> fun(self: MethodFieldWrong, extra: number)
---@field <!setText!> fun(self: MethodFieldWrong, text: number)
]]

-- ... a base that is only `function` is not compared
TEST [[
---@class LooseBase
---@field handler function

---@class LooseChild : LooseBase
---@field handler fun(self: LooseChild, a: number, b: number)
]]

-- ... two functions written with a dot are compared
TEST [[
---@class OvBase7
local OvBase7 = {}
---@param n number
function OvBase7.make(n) end

---@class OvChild7 : OvBase7
local OvChild7 = {}
---@param n string
function OvChild7.<!make!>(n) end
]]

-- ... a field redeclared as `fun(self: T, ...)` over a dot function keeps its `self` as a parameter
TEST [[
---@class OvBase8
local OvBase8 = {}
---@param n number
function OvBase8.run(n) end

---@class OvChild8 : OvBase8
---@field <!run!> fun(self: OvChild8, n: number)
]]

-- ... a member set to something that is not a function is not compared as one
TEST [[
---@class OvBase9
local OvBase9 = {}
---@param n number
function OvBase9:go(n) end

---@class OvChild9 : OvBase9
local OvChild9 = {}
OvChild9.go = 1
]]
