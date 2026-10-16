TEST [[
---@class A : <!B!>
]]

-- a parent given with type arguments is checked like a plain one: a typo is reported, a real class and `table<K, V>` are not
TEST [[
---@class Dict : table<string, number>
---@class GenericBase<T>
---@class GenericChild<T> : GenericBase<T>
---@class TypoDict : <!tabel<string, number>!>
---@class BadChild : <!Tabel<string>!>
]]
