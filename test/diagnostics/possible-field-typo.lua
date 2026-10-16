-- a field a method of a class declares by assigning it (`self.totl = 1`) whose name is one letter away from a field the class declares: a hint, not a ban
TEST [[
---@class TypoCounter
---@field total integer
---@field count integer
local TypoCounter = {}

function TypoCounter:add(n)
    self.<!totl!> = self.total + n
    self.<!cuont!> = 0
end
]]

-- ... a transposition (two letters swapped), a different case and a typo on the class table itself count too
TEST [[
---@class TypoTransposed
---@field value integer
---@field Name string
local TypoTransposed = {}

function TypoTransposed:set()
    self.<!vaule!> = 1
    self.<!name!> = "x"
end
TypoTransposed.<!valeu!> = 0
]]

-- ... a letter too many and a letter missing
TEST [[
---@class TypoLength
---@field total integer
local TypoLength = {}

function TypoLength:set()
    self.<!totall!> = 1
    self.<!tota!> = 1
end
]]

-- ... a name that is far from every declared field, one that is declared, one that is short, and a method written for the name are not typos
TEST [[
---@class TypoFar
---@field total integer
---@field id integer
local TypoFar = {}

function TypoFar:set()
    self.total = 1
    self.history = {}
    self.ix = 0
    self.totally = 1
end
function TypoFar:tota() end
]]

-- ... a public name next to a private one (`client` and `_client`) is on purpose
TEST [[
---@class TypoPrivate
---@field _client integer
local TypoPrivate = {}

function TypoPrivate:set()
    self.client = 1
end
]]

-- ... and so is a plural
TEST [[
---@class TypoPlural
---@field event integer
---@field items integer
local TypoPlural = {}

function TypoPlural:set()
    self.events = {}
    self.item = 1
end
]]

-- ... a field of a parent class is declared too
TEST [[
---@class TypoBase
---@field position integer

---@class TypoChild : TypoBase
local TypoChild = {}

function TypoChild:move()
    self.<!postion!> = 1
end
]]

-- ... an `(exact)` class reports the undeclared field as an error already, and a `@type` reference is `inject-field`'s
TEST [[
---@class (exact) TypoExact
---@field total integer
local TypoExact = {}

function TypoExact:set()
    self.<!totl!> = 1
end
]]
