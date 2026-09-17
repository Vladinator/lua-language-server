local lang   = require 'language'
local parser = require 'parser'
local guide  = require 'parser.guide'
local util   = require 'utility'

---@param node parser.object
---@return string
local function nodeId(node)
	return node.type .. ':' .. node.start .. ':' .. node.finish
end

---@param str any
---@return any
local function shorten(str)
	if type(str) ~= 'string' then
		return str
	end
	str = str:gsub('\n', '\\\\n') --[[@as string]]
	if #str <= 20 then
		return str
	else
		return str:sub(1, 17) .. '...'
	end
end

---@param k any
---@param v any
---@return string
local function getTooltipLine(k, v)
	if type(v) == 'table' then
		if v.type then
			v = '<node ' .. v.type .. '>' --[[@as string]]
		else
			v = '<table>'
		end
	end
	v = tostring(v) --[[@as string]]
	v = v:gsub('"', '\\"')
	return k .. ': ' .. shorten(v) .. '\\n'
end

---@param node parser.object
---@return string
local function getTooltip(node)
	---@type string[]
	local parts = {}
	local skipNodes = {parent = true, start = true, finish = true, type = true}
	parts[#parts+1] = getTooltipLine('start', node.start)
	parts[#parts+1] = getTooltipLine('finish', node.finish)
	for k, v in util.sortPairs(node --[[@as table<any, any>]], function (a, b)
		return tostring(a) < tostring(b)
	end) do
		if type(k) ~= 'number' and not skipNodes[k] then
			parts[#parts+1] = getTooltipLine(k, v)
		end
	end
	for i = 1, math.min(#node, 15) do
		parts[#parts+1] = getTooltipLine(i, node[i])
	end
	if #node > 15 then
		parts[#parts+1] = getTooltipLine('15..' .. #node, '(...)')
	end
	return table.concat(parts)
end

local nodeEntry = '\t"%s" [\n\t\tlabel="%s\\l%s\\l"\n\t\ttooltip="%s"\n\t]'
---@param node parser.object
---@return string
local function getNodeLabel(node)
	local keyName = guide.getKeyName(node)
	if node.type == 'binary' or node.type == 'unary' then
		keyName = node.op.type
	elseif node.type == 'label' or node.type == 'goto' then
		keyName = node[1]
	end
	return nodeEntry:format(nodeId(node), node.type, shorten(keyName) or '', getTooltip(node))
end

---@param writer file*
---@return fun(node: parser.object?, parent?: parser.object)
local function getVisualizeVisitor(writer)
	---@param node   parser.object?
	---@param parent parser.object?
	local function visitNode(node, parent)
		if node == nil then return end
		writer:write(getNodeLabel(node))
		writer:write('\n')
		if parent then
			writer:write(('\t"%s" -> "%s"'):format(nodeId(parent), nodeId(node)))
			writer:write('\n')
		end
		guide.eachChild(node, function(child)
			visitNode(child, node)
		end)
	end
	return visitNode
end


local export = {}

---@param code   string
---@param writer file*
function export.visualizeAst(code, writer)
	local state = parser.compile(code, 'Lua', _G['LUA_VER'] or 'Lua 5.4')
	writer:write('digraph AST {\n')
	writer:write('\tnode [shape = rect]\n')
	getVisualizeVisitor(writer)(state.ast)
	writer:write('}\n')
end

---@return integer
function export.runCLI()
	lang(LOCALE)
	local file = _G['VISUALIZE'] --[[@as string]]
	local code, err = io.open(file)
	if not code then
		io.stderr:write('failed to open ' .. file .. ': ' .. (err or '?'))
		return 1
	end
	local content = code:read('a')
	export.visualizeAst(content, io.stdout)
	return 0
end

return export
