---@meta lpeglabel

-- Type declarations for the lpeglabel C binding (3rd/lpeglabel). Covers the
-- combinator surface this repo actually uses; it is not a full API reference.

---@alias lpeglabel.value lpeglabel.pattern|string|integer|boolean|table|function

---@class lpeglabel.pattern
---@operator mul(lpeglabel.value): lpeglabel.pattern
---@operator add(lpeglabel.value): lpeglabel.pattern
---@operator sub(lpeglabel.value): lpeglabel.pattern
---@operator div(any): lpeglabel.pattern
---@operator pow(integer): lpeglabel.pattern
---@operator unm: lpeglabel.pattern
---@operator len: lpeglabel.pattern
local pattern = {}

---@param subject string
---@param init? integer
---@param ... any
---@return any? result First capture (or the match end position), or nil on failure.
---@return any ...   Remaining captures, or the failure label/position.
function pattern:match(subject, init, ...) end

---@class lpeglabel
---@field P      fun(value: lpeglabel.value): lpeglabel.pattern
---@field S      fun(set: string): lpeglabel.pattern
---@field R      fun(...: string): lpeglabel.pattern
---@field V      fun(name: string|integer): lpeglabel.pattern
---@field C      fun(patt: lpeglabel.value): lpeglabel.pattern
---@field Cc     fun(...: any): lpeglabel.pattern
---@field Cg     fun(patt: lpeglabel.value, name?: any): lpeglabel.pattern
---@field Cs     fun(patt: lpeglabel.value): lpeglabel.pattern
---@field Ct     fun(patt: lpeglabel.value): lpeglabel.pattern
---@field Cp     fun(): lpeglabel.pattern
---@field Cf     fun(patt: lpeglabel.value, func: function): lpeglabel.pattern
---@field Cb     fun(name: any): lpeglabel.pattern
---@field Cmt    fun(patt: lpeglabel.value, func: function): lpeglabel.pattern
---@field Carg   fun(n: integer): lpeglabel.pattern
---@field B      fun(patt: lpeglabel.value): lpeglabel.pattern
---@field T      fun(label: string|integer): lpeglabel.pattern
---@field Rec    fun(patt: lpeglabel.value, recovery: lpeglabel.value, ...: string|integer): lpeglabel.pattern
---@field RecT   fun(...: any): lpeglabel.pattern
---@field type   fun(value: any): string?
---@field locale fun(t?: table): table
---@field match  fun(patt: lpeglabel.value, subject: string, init?: integer, ...: any): any
local lpeglabel = {}

return lpeglabel
