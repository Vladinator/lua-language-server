-- A class cannot extend a primitive type: the parent is reported (a class describes a table). `table`, `userdata`, other classes
-- and `any` are fine.

TEST [[
---@class A : <!string!>
---@class B : <!number!>
---@class C : <!integer!>
---@class D : <!boolean!>
---@class E : <!function!>
---@class F : <!thread!>
]]

-- one primitive among several parents
TEST [[
---@class Base
---@class Both : Base, <!string!>
]]

-- allowed parents
TEST [[
---@class Base
---@class Child : Base
---@class FromTable : table
---@class FromUserdata : userdata
---@class FromAny : any
]]

-- generic parents and a class that is only named like a primitive are other classes
TEST [[
---@class Box<T>
---@class IntBox : Box<integer>
---@class Stringy
---@class Derived : Stringy
]]

-- a parent that does not exist is another diagnostic (undefined-doc-class), not this one
TEST [[
---@class Orphan : Missing
]]
