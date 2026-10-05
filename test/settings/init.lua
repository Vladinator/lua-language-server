-- What each `Lua.*` setting does, with a positive and a negative case for every value. One file per area.
-- (The settings that already have tests elsewhere keep them: this group is for the ones nothing covered, and
-- for the boundaries of the ones that are easy to break while changing the checker.)
rawset(_G, 'TEST', true)

require 'settings.type'
require 'settings.hover'
require 'settings.completion'
require 'settings.hint'
require 'settings.semantic'
require 'settings.locale-texts'
