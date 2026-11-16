-- samp-toast: клиент общих уведомлений скриптов GORYCH
local T = {}

T.VERSION = 1
T.API = 1
T.FILE = 'samp-notifier.lua'
T.NAME = 'samp-notifier'

function T.find()
	if type(script) ~= 'table' or type(script.list) ~= 'function' then return nil end
	for _, s in ipairs(script.list()) do
		local ok, match = pcall(function()
			if s.dead then return false end
			local file = tostring(s.filename or s.path or ''):match('[^\\/]*$'):lower()
			return s.name == T.NAME or file == T.FILE
		end)
		if ok and match then return s end
	end
	return nil
end

local function send(text, opts)
	local s = T.find()
	if not s then return false end
	local exports = s.exports
	if exports == nil then return false end
	local api = exports.api and exports.api()
	if type(api) ~= 'number' or api < T.API then return false end
	return exports.push(tostring(text), tonumber(opts.seconds) or 4, opts.kind, opts.key, opts.sender, tonumber(opts.scale) or 1) == true
end

function T.notify(text, opts)
	if text == nil then return false end
	local ok, accepted = pcall(send, text, type(opts) == 'table' and opts or {})
	return ok and accepted == true
end

function T.available()
	local ok, res = pcall(function()
		local s = T.find()
		if not s or s.exports == nil or not s.exports.api then return false end
		local api = s.exports.api()
		return type(api) == 'number' and api >= T.API
	end)
	return ok and res == true
end

return T
