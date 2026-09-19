local visualize = require 'cli.visualize'

local testDataDir = 'test/cli/visualize/testdata/'

---@param fileName string
local function TestVisualize(fileName)
	local inputFile = testDataDir .. fileName .. '.txt'
	local outputFile = testDataDir .. fileName .. '-expected.txt'
	local output = ''
	---@type { write: fun(self: table, text: string) }
	local writer = {}
	---@param text string
	function writer:write(text)
		output = (output .. text)
	end
	visualize.visualizeAst(io.open(inputFile):read('a'), writer)
	local expectedOutput = io.open(outputFile):read('a')
	if expectedOutput ~= output then
		-- uncomment this to update reference output
		io.open(outputFile, "w+"):write(output):close()
		error('output mismatch for test file ' .. inputFile)
	end
end

TestVisualize('all-types')
TestVisualize('shorten-names')
