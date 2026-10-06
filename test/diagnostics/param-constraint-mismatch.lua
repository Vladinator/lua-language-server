-- A method marked `---@requires T: Constraint` may only be called on a receiver whose class type argument for `T` satisfies the
-- constraint. The method name of the call is reported.

TEST [[
---@class Frame
---@class Widget<T>
local Widget = {}

---@requires T: Frame
function Widget:Show() end

---@type Widget<number>
local bad
bad:<!Show!>()

---@type Widget<Frame>
local good
good:Show()
]]

-- the `extends` spelling, a subclass of the constraint, a union where one member does not fit, an optional argument
TEST [[
---@class Frame
---@class Button: Frame
---@class Widget<T>
local Widget = {}

---@requires T extends Frame
function Widget:Show() end

---@type Widget<Button>
local sub
sub:Show()

---@type Widget<Frame|number>
local mixed
mixed:<!Show!>()

---@type Widget<Frame?>
local optional
optional:Show()
]]

-- called as a field, with the receiver passed by hand
TEST [[
---@class Frame
---@class Widget<T>
local Widget = {}

---@requires T: Frame
function Widget:Show() end

---@type Widget<string>
local w
w.<!Show!>(w)
]]

-- the requirement names the parameter it is about: `B` is checked, `A` is not
TEST [[
---@class Pair<A, B>
local Pair = {}

---@requires B: string
function Pair:Label() end

---@type Pair<boolean, number>
local bad
bad:<!Label!>()

---@type Pair<boolean, string>
local good
good:Label()
]]

-- nothing to check: a method without `@requires`, a receiver without type arguments, a requirement that names no parameter of the
-- class, a malformed tag (no constraint)
TEST [[
---@class Frame
---@class Widget<T>
local Widget = {}

function Widget:Plain() end

---@requires T: Frame
function Widget:Show() end

---@requires U: Frame
function Widget:Other() end

---@requires T
function Widget:Bare() end

---@type Widget<number>
local w
w:Plain()
w:Other()
w:Bare()

---@type Widget
local noArgs
noArgs:Show()
]]

-- a class that inherits the method: the parent's type arguments are the ones that count
TEST [[
---@class Frame
---@class Widget<T>
local Widget = {}

---@requires T: Frame
function Widget:Show() end

---@class Numbers: Widget<number>

---@class Frames: Widget<Frame>

---@type Numbers
local n
n:<!Show!>()

---@type Frames
local f
f:Show()
]]

-- through a type parameter of the child (`Child<U>: Widget<U>`), and through two levels
TEST [[
---@class Frame
---@class Widget<T>
local Widget = {}

---@requires T: Frame
function Widget:Show() end

---@class Child<U>: Widget<U>

---@class Grand: Child<string>

---@type Child<number>
local bad
bad:<!Show!>()

---@type Child<Frame>
local good
good:Show()

---@type Grand
local deep
deep:<!Show!>()
]]

-- a child with a type parameter of the same name that is unrelated to the parent's: the parent's argument is checked
TEST [[
---@class Frame
---@class Widget<T>
local Widget = {}

---@requires T: Frame
function Widget:Show() end

---@class Other<T>: Widget<Frame>

---@type Other<number>
local o
o:Show()
]]

-- a hierarchy that loops back on itself is walked once
TEST [[
---@class Frame
---@class CycA<T>: CycB<T>
local CycA = {}

---@class CycB<T>: CycA<T>

---@requires T: Frame
function CycA:Show() end

---@type CycB<number>
local c
c:<!Show!>()
]]
