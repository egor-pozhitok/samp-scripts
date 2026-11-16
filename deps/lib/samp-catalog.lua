-- samp-catalog: каталог скриптов GORYCH для MoonLoader
local M = {}

M.VERSION = 1
M.REPO = 'https://raw.githubusercontent.com/egor-pozhitok/samp-scripts/main/'
M.STATE_FILE = 'config/SNHelper/catalog.state'
M.IMAGE_DIR = 'resource/SNHelper/catalog'
M.ALWAYS_PROTECTED = { 'SNHelper.lua', 'SNHelper.luac' }
M.MAX_SIZE = 50 * 1024 * 1024
M.MAX_FILES = 64

local DEVICES = { con = true, prn = true, aux = true, nul = true }
function M.safePath(path)
	if type(path) ~= 'string' or #path == 0 or #path > 200 then return false end
	if not path:match('^[%w%-%._/]+$') or path:sub(1, 1) == '/' then return false end
	for part in (path .. '/'):gmatch('(.-)/') do
		if part == '' or part == '.' or part == '..' or part:sub(-1) == '.' then return false end
		local base = part:match('^[^.]*'):lower()
		if DEVICES[base] or base:match('^com%d$') or base:match('^lpt%d$') then return false end
	end
	return true
end

function M.normPath(path)
	return (tostring(path):gsub('\\', '/'):lower())
end

function M.protectSets(protect, deps)
	local selfSet, shared = {}, {}
	for _, p in ipairs(M.ALWAYS_PROTECTED) do selfSet[M.normPath(p)] = true end
	for _, p in ipairs(protect or {}) do selfSet[M.normPath(p)] = true end
	for _, d in ipairs(deps or {}) do
		local p = type(d) == 'table' and d.path or d
		if type(p) == 'string' then shared[M.normPath(p)] = true end
	end
	return selfSet, shared
end

local function fileList(list, check)
	if list == nil then return {} end
	if type(list) ~= 'table' or #list > M.MAX_FILES then return nil end
	local out, seen = {}, {}
	for i, f in ipairs(list) do
		if type(f) ~= 'table' or not M.safePath(f.path) or not M.safePath(f.src) then return nil end
		local size = tonumber(f.size)
		if not size or size <= 0 or size > M.MAX_SIZE or size ~= math.floor(size) then return nil end
		local key = M.normPath(f.path)
		if seen[key] or not check(key) then return nil end
		seen[key] = true
		out[i] = { path = f.path, size = size, src = f.src }
	end
	return out
end

local function parseEntry(e, selfSet, shared, ownKey)
	if type(e) ~= 'table' then return nil end
	if type(e.id) ~= 'string' or #e.id > 40 or not e.id:match('^[a-z0-9][a-z0-9_%-]*$') then return nil end
	if type(e.name) ~= 'string' or e.name:match('^%s*$') or #e.name > 100 then return nil end
	if e.description ~= nil and type(e.description) ~= 'string' then return nil end
	if type(e.version) ~= 'string' or e.version == '' or #e.version > 20 then return nil end
	local num = tonumber(e.version_num)
	if not num or num < 0 or num ~= math.floor(num) then return nil end
	if e.image ~= nil and (not M.safePath(e.image) or not e.image:lower():match('%.png$')) then return nil end
	if not M.safePath(e.main) or e.main:find('/', 1, true) or not (e.main:lower():match('%.lua$') or e.main:lower():match('%.luac$')) then return nil end
	local mainKey = M.normPath(e.main)
	if selfSet[mainKey] or shared[mainKey] then return nil end
	local foreign = ownKey and mainKey ~= ownKey and ownKey or nil
	local files = fileList(e.files, function(key) return not selfSet[key] and not shared[key] and key ~= foreign end)
	if not files then return nil end
	local own, hasMain = {}, false
	for _, f in ipairs(files) do
		local key = M.normPath(f.path)
		own[key] = true
		if key == mainKey then hasMain = true end
	end
	if not hasMain then return nil end
	local deps = fileList(e.deps, function(key) return not selfSet[key] and not own[key] and key ~= foreign end)
	if not deps then return nil end
	return {
		id = e.id, name = e.name, description = e.description or '', version = e.version, version_num = num,
		image = e.image, main = e.main, files = files, deps = deps,
	}
end

function M.parse(info, selfSet, shared, ownKey)
	if type(info) ~= 'table' then return nil, 'не каталог' end
	if tonumber(info.format) ~= 1 then return nil, 'формат каталога не поддерживается' end
	if type(info.scripts) ~= 'table' then return nil, 'в каталоге нет списка скриптов' end
	local list, seen, skipped = {}, {}, 0
	for _, e in ipairs(info.scripts) do
		local entry = parseEntry(e, selfSet, shared, ownKey)
		if entry and not seen[entry.id] then
			seen[entry.id] = true
			list[#list + 1] = entry
		else
			skipped = skipped + 1
		end
	end
	return list, skipped
end

function M.action(entry, installed)
	if installed == nil then return 'install' end
	if entry.version_num > installed then return 'update' end
	return 'remove'
end

function M.selfAction(entry, runningNum)
	if entry.version_num > (tonumber(runningNum) or 0) then return 'update' end
	return 'self'
end

function M.stateParse(text)
	local state = {}
	for line in (tostring(text or '') .. '\n'):gmatch('(.-)\n') do
		local id, num = line:gsub('\r', ''):match('^([%w_%-]+)=(%d+)$')
		if id then state[id] = tonumber(num) end
	end
	return state
end

function M.stateText(state)
	local ids = {}
	for id in pairs(state) do ids[#ids + 1] = id end
	table.sort(ids)
	local out = {}
	for i, id in ipairs(ids) do out[i] = id .. '=' .. state[id] .. '\n' end
	return table.concat(out)
end

function M.stateUpdate(text, id, num)
	local state = M.stateParse(text)
	state[id] = num
	return M.stateText(state)
end

function M.plan(entry, sizeOf, shared)
	local plan = {}
	for _, f in ipairs(entry.files) do plan[#plan + 1] = f end
	for _, d in ipairs(entry.deps) do
		local size = sizeOf(d.path)
		if size == nil or size == 0 or (size ~= d.size and not shared[M.normPath(d.path)]) then
			plan[#plan + 1] = d
		end
	end
	return plan
end

function M.removeList(entry, selfSet, shared)
	local deps, seen, out = {}, {}, {}
	for _, d in ipairs(entry.deps) do deps[M.normPath(d.path)] = true end
	local function add(path)
		local key = M.normPath(path)
		if seen[key] or deps[key] or selfSet[key] or shared[key] then return end
		seen[key] = true
		out[#out + 1] = path
	end
	add(entry.main)
	for _, f in ipairs(entry.files) do add(f.path) end
	return out
end

function M.nextStatus(status, event, count)
	if event == 'open' then return status == 'idle' and 'loading' or status end
	if event == 'refresh' then return 'loading' end
	if status ~= 'loading' then return status end
	if event == 'loaded' then return (tonumber(count) or 0) > 0 and 'ready' or 'empty' end
	if event == 'failed' then return 'error' end
	return status
end

function M.isPng(head)
	return type(head) == 'string' and head:sub(1, 8) == '\137PNG\r\n\26\n'
end

function M.helpLines(selfName, extra)
	local lines = {
		'Здесь скрипты от GORYCH. Список загружается из интернета при первом открытии раздела, «Обновить список» загружает его заново.',
		'«Установить» скачивает файлы скрипта в папку moonloader и сразу запускает его. Общие библиотеки (imgui, шрифт значков и другие), которых нет, скачиваются вместе с ним.',
		'«Обновить» появляется, когда вышла новая версия: файлы заменяются, скрипт перезапускается.'
			.. (selfName and (' Так же обновляется и сам ' .. selfName .. ' (карточка «этот скрипт»).') or ''),
		'«Удалить» (нажмите два раза) останавливает скрипт и удаляет его файлы. Общие библиотеки остаются: ими пользуются другие скрипты.',
	}
	for _, line in ipairs(extra or {}) do lines[#lines + 1] = line end
	for i, line in ipairs(lines) do lines[i] = i .. '. ' .. line end
	return lines
end

local Catalog = {}
Catalog.__index = Catalog

function M.new(opts)
	assert(type(opts) == 'table' and opts.u8 and type(opts.ui) == 'table', 'samp-catalog: opts.u8 and opts.ui are required')
	local self = setmetatable({}, Catalog)
	self.opts = opts
	self.repo = opts.repo or M.REPO
	self.timeout = opts.timeout or 15
	self.tag = opts.tag or '[catalog]'
	self.idPrefix = opts.idPrefix or 'sc'
	self.status, self.list, self.skipped, self.err = 'idle', {}, 0, nil
	self.busy, self.busyKind, self.progress = nil, nil, nil
	self.installed, self.images, self.textures = {}, {}, {}
	self.checkedAt = 0
	return self
end

local function full(path)
	return getWorkingDirectory() .. '\\' .. (path:gsub('/', '\\'))
end

local function readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local text = f:read('*a')
	f:close()
	return text
end

local function fileSize(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local size = f:seek('end')
	f:close()
	return size
end

local function ensureDir(filePath)
	local dir = filePath:match('^(.*)[/\\][^/\\]+$')
	if not dir then return end
	local cur = ''
	for part in dir:gmatch('[^/\\]+') do
		cur = (cur == '' and part) or (cur .. '\\' .. part)
		if not doesDirectoryExist(cur) then createDirectory(cur) end
	end
end

local function download(url, path, timeout)
	local done = false
	local deadline = os.time() + timeout
	os.remove(path)
	downloadUrlToFile(url, path, function(_, status)
		if status == 58 then
			done = true
		else
			deadline = os.time() + timeout
		end
	end)
	while not done and os.time() <= deadline do wait(0) end
	return done
end

function Catalog:log(text)
	print(self.tag .. ' catalog: ' .. tostring(text))
end

function Catalog:fetchUrl(src, path)
	local url = self.repo .. src .. '?t=' .. os.time()
	if self.opts.download then return self.opts.download(url, path, self.timeout) end
	return download(url, path, self.timeout)
end

function Catalog:sets()
	return M.protectSets(self.opts.protect, self.opts.deps)
end

function Catalog:ownName()
	local file = self.opts.selfFile or tostring(thisScript().path):match('[^\\/]+$') or ''
	return M.normPath(file)
end

function Catalog:isSelf(entry)
	return self.opts.selfName and M.normPath(entry.main) == self:ownName() or false
end

function Catalog:runningVersion()
	if self.opts.runningVersion then return self.opts.runningVersion end
	return thisScript().version_num
end

local function statePath()
	return full(M.STATE_FILE)
end

function Catalog:readState()
	return M.stateParse(readFile(statePath()) or '')
end

function Catalog:setState(id, num)
	ensureDir(statePath())
	local text = M.stateUpdate(readFile(statePath()) or '', id, num)
	local f = io.open(statePath(), 'w')
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

function Catalog:refreshInstalled()
	local state = self:readState()
	local installed = {}
	for _, entry in ipairs(self.list) do
		if doesFileExist(full(entry.main)) then installed[entry.id] = state[entry.id] or 0 end
	end
	self.installed = installed
	self.checkedAt = os.clock()
end

function Catalog:fetchImages()
	for _, entry in ipairs(self.list) do
		if entry.image then
			local final = full(M.IMAGE_DIR .. '/' .. entry.id .. '.png')
			if not doesFileExist(final) then
				local tmp = final .. '.tmp'
				ensureDir(final)
				if self:fetchUrl(entry.image, tmp) and M.isPng((readFile(tmp) or ''):sub(1, 8)) then
					os.remove(final)
					os.rename(tmp, final)
				end
				os.remove(tmp)
			end
			if doesFileExist(final) then self.images[entry.id] = final end
		end
	end
end

function Catalog:fetchList()
	local tmp = full((self.opts.dataDir or 'config/samp-catalog') .. '/catalog.json.tmp')
	ensureDir(tmp)
	local ok = self:fetchUrl('scripts.json', tmp)
	local text = readFile(tmp)
	os.remove(tmp)
	if not ok or not text then return nil, 'сервер не ответил' end
	text = text:gsub('^\239\187\191', '')
	if not text:match('^%s*{') then return nil, 'каталог не найден' end
	local okJson, info = pcall(decodeJson, text)
	if not okJson or type(info) ~= 'table' then return nil, 'каталог повреждён' end
	local selfSet, shared = self:sets()
	return M.parse(info, selfSet, shared, self:ownName())
end

function Catalog:fetch(event)
	if self.busy then return end
	local status = M.nextStatus(self.status, event)
	if status ~= 'loading' or self.status == 'loading' then return end
	self.status = status
	self.busy = 'list'
	lua_thread.create(function()
		local ok, list, extra = pcall(self.fetchList, self)
		if ok and list then
			self.list, self.skipped, self.err = list, extra or 0, nil
			self.status = M.nextStatus(self.status, 'loaded', #list)
			self:refreshInstalled()
			local okImg, errImg = pcall(self.fetchImages, self)
			if not okImg then self:log(errImg) end
		else
			if not ok then self:log(list) end
			self.err = ok and extra or 'ошибка скрипта'
			self.status = M.nextStatus(self.status, 'failed')
		end
		self.busy = nil
	end)
end

local function findRunning(path)
	local key = M.normPath(path)
	for _, s in ipairs(script.list()) do
		if M.normPath(s.path) == key then return s end
	end
	return nil
end

function Catalog:fetchFiles(entry)
	local _, shared = self:sets()
	local plan = M.plan(entry, function(p) return fileSize(full(p)) end, shared)
	self.progress = { done = 0, total = #plan }
	local ready = {}
	for i, f in ipairs(plan) do
		local final = full(f.path)
		local tmp = final .. '.tmp'
		ensureDir(final)
		if not self:fetchUrl(f.src, tmp) or fileSize(tmp) ~= f.size then
			os.remove(tmp)
			for _, r in ipairs(ready) do os.remove(r.tmp) end
			return false, 'не скачался файл ' .. f.path
		end
		ready[#ready + 1] = { tmp = tmp, final = final }
		self.progress.done = i
	end
	for _, r in ipairs(ready) do
		os.remove(r.final)
		if os.rename(r.tmp, r.final) ~= true then
			os.remove(r.tmp)
			return false, 'не удалось записать ' .. r.final
		end
	end
	return true
end

function Catalog:install(entry)
	local ok, err = self:fetchFiles(entry)
	if not ok then return false, err end
	self:setState(entry.id, entry.version_num)
	local path = full(entry.main)
	local running = findRunning(path)
	local started
	if running then
		started = pcall(running.reload, running)
	else
		local okLoad, s = pcall(script.load, path)
		started = okLoad and s ~= nil
	end
	return true, started
end

function Catalog:updateSelf(entry)
	local ok, err = self:fetchFiles(entry)
	if not ok then return false, err end
	self:setState(entry.id, entry.version_num)
	sampAddChatMessage((self.opts.chatPrefix or 'Script') .. ' | {FFFFFF}Обновление ' .. entry.version .. ' установлено, перезапускаю ' .. self.opts.selfName .. '.', 0xC0C0C0)
	thisScript():reload()
	return true
end

function Catalog:remove(entry)
	local running = findRunning(full(entry.main))
	if running then
		pcall(running.unload, running)
		wait(200)
	end
	for _, path in ipairs(M.removeList(entry, self:sets())) do
		os.remove(full(path))
	end
	self:setState(entry.id, nil)
	return not doesFileExist(full(entry.main))
end

function Catalog:run(entry, kind)
	local notify = self.opts.ui.notify
	if self.busy then
		notify('Подождите: идёт загрузка.', 3)
		return
	end
	self.busy, self.busyKind = entry.id, kind
	local name = self.opts.u8:decode(entry.name)
	lua_thread.create(function()
		if kind == 'remove' then
			local ok, removed = pcall(self.remove, self, entry)
			if not ok then self:log(removed) end
			if ok and removed then
				notify('Скрипт ' .. name .. ' удалён.', 4, 'success')
			else
				notify('Не удалось удалить скрипт ' .. name .. '.\nУдалите файл moonloader/' .. entry.main .. ' вручную.', 6, 'error')
			end
		elseif kind == 'self' then
			local ok, done, extra = pcall(self.updateSelf, self, entry)
			if not ok then self:log(done) end
			if not (ok and done) then
				notify('Не удалось обновить ' .. self.opts.selfName .. ':\n' .. tostring(ok and extra or 'ошибка скрипта') .. '.\nПопробуйте позже.', 6, 'error')
			end
		else
			local ok, done, extra = pcall(self.install, self, entry)
			if not ok then self:log(done) end
			if ok and done then
				if extra then
					notify('Скрипт ' .. name .. ' ' .. entry.version .. ' установлен и запущен.', 5, 'success')
				else
					notify('Скрипт ' .. name .. ' установлен, но не запустился.\nПерезапустите игру.', 6, 'error')
				end
			else
				notify('Не удалось установить ' .. name .. ':\n' .. tostring(ok and extra or 'ошибка скрипта') .. '.\nПопробуйте позже.', 6, 'error')
			end
		end
		self:refreshInstalled()
		self.busy, self.busyKind, self.progress = nil, nil, nil
	end)
end

function Catalog:libs()
	local imgui = self.opts.imgui or require('imgui')
	local fa = self.opts.fa or require('fAwesome5')
	return imgui, fa
end

function Catalog:texture(entry)
	local imgui = self:libs()
	local path = self.images[entry.id]
	if not path then return nil end
	if self.textures[entry.id] == nil then
		local ok, tex = pcall(imgui.CreateTextureFromFile, path)
		self.textures[entry.id] = (ok and tex) or false
	end
	return self.textures[entry.id] or nil
end

function Catalog:drawImage(entry, size)
	local imgui, fa = self:libs()
	local V2 = imgui.ImVec2
	local C = self.opts.ui.colors
	local tex = self:texture(entry)
	if tex then
		imgui.Image(tex, V2(size, size))
		return
	end
	local pos = imgui.GetCursorScreenPos()
	imgui.Dummy(V2(size, size))
	local drawList = imgui.GetWindowDrawList()
	drawList:AddRectFilled(pos, V2(pos.x + size, pos.y + size), imgui.GetColorU32(C.control), imgui.GetStyle().FrameRounding)
	local icon = fa.ICON_FA_PUZZLE_PIECE
	local iconSize = imgui.CalcTextSize(icon)
	drawList:AddText(V2(pos.x + (size - iconSize.x) / 2, pos.y + (size - iconSize.y) / 2), imgui.GetColorU32(C.muted), icon)
end

function Catalog:drawCard(entry, width)
	local imgui, fa = self:libs()
	local V2 = imgui.ImVec2
	local ui, u8 = self.opts.ui, self.opts.u8
	local C = ui.colors
	local id = self.idPrefix
	local gap = imgui.GetStyle().ItemSpacing.x
	local pad = self.opts.cardPad or 10
	local imgSize = math.floor((self.opts.imageSize or 44) * imgui.GetIO().FontGlobalScale)
	local own = self:isSelf(entry)
	local action
	if own then
		action = M.selfAction(entry, self:runningVersion())
	else
		action = M.action(entry, self.installed[entry.id])
	end
	local mine = self.busy == entry.id
	local label
	if mine then
		local p = self.progress
		label = self.busyKind == 'remove' and u8('Удаление...') or (p and p.total > 0 and u8('Загрузка ' .. p.done .. ' из ' .. p.total)) or u8('Загрузка...')
	elseif action == 'self' then
		label = u8('этот скрипт')
	elseif action == 'install' then
		label = fa.ICON_FA_DOWNLOAD .. u8(' Установить')
	elseif action == 'update' then
		label = fa.ICON_FA_SYNC .. u8(' Обновить')
	else
		label = fa.ICON_FA_TRASH .. u8(' Удалить')
	end
	local buttonWidth
	if action == 'self' and not mine then
		buttonWidth = imgui.CalcTextSize(label).x
	elseif action == 'remove' and not mine then
		buttonWidth = ui.dangerButtonWidth(label)
	else
		buttonWidth = ui.buttonWidth(label)
	end
	local textWidth = math.max(40, width - pad * 2 - imgSize - gap)
	local version = u8('версия ') .. entry.version
	local versionWidth = imgui.CalcTextSize(version).x
	local nameWidth = textWidth - buttonWidth - gap * 2 - versionWidth
	local showVersion = nameWidth >= 40
	if not showVersion then nameWidth = textWidth - buttonWidth - gap end
	local descHeight = 0
	if entry.description ~= '' then
		descHeight = imgui.GetFont():CalcTextSizeA(imgui.GetFontSize(), 10000, textWidth, entry.description).y
	end
	local height = math.floor(math.max(imgSize, ui.frameHeight() + descHeight) + pad * 2)
	imgui.PushStyleColor(imgui.Col.ChildWindowBg, C.card)
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, V2(pad, pad))
	imgui.BeginChild(id .. 'Card' .. entry.id, V2(width, height), false, imgui.WindowFlags.AlwaysUseWindowPadding + imgui.WindowFlags.NoScrollbar)
		self:drawImage(entry, imgSize)
		imgui.SameLine()
		imgui.BeginGroup()
			imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, V2(gap, 0))
				local nameText = ui.fitText(entry.name, math.max(20, nameWidth))
				local usedWidth = imgui.CalcTextSize(nameText).x
				ui.label(nameText, C.white)
				if showVersion then
					imgui.SameLine()
					ui.label(version, C.muted)
					usedWidth = usedWidth + gap + versionWidth
				end
				imgui.SameLine(0, math.max(gap, textWidth - usedWidth - buttonWidth))
				if mine then
					ui.button(label .. '##' .. id .. 'Busy' .. entry.id, nil, V2(buttonWidth, 0))
				elseif action == 'self' then
					ui.label(label, C.accent)
				elseif action == 'remove' then
					if ui.dangerButton(id .. entry.id, label, V2(buttonWidth, 0)) then self:run(entry, 'remove') end
				elseif ui.button(label .. '##' .. id .. entry.id, 'primary', V2(buttonWidth, 0)) then
					self:run(entry, own and 'self' or 'install')
				end
			imgui.PopStyleVar()
			if entry.description ~= '' then
				imgui.PushTextWrapPos(0)
				imgui.TextColored(C.muted, entry.description)
				imgui.PopTextWrapPos()
			end
		imgui.EndGroup()
	imgui.EndChild()
	imgui.PopStyleVar()
	imgui.PopStyleColor()
end

function Catalog:drawBody(inner)
	local imgui, fa = self:libs()
	local ui, u8 = self.opts.ui, self.opts.u8
	local C = ui.colors
	local id = self.idPrefix
	local status = self.status
	local refreshLabel = fa.ICON_FA_SYNC .. u8(' Обновить список')
	if status == 'loading' then
		ui.label(u8('Загрузка списка...'), C.muted)
	elseif status == 'ready' then
		ui.label(u8('Скриптов: ' .. #self.list), C.muted)
	else
		ui.label(u8('Скрипты от GORYCH'), C.muted)
	end
	ui.alignRight(ui.buttonWidth(refreshLabel))
	if ui.button(refreshLabel .. '##' .. id .. 'Refresh') then
		if self.busy then
			ui.notify('Подождите: идёт загрузка.', 3)
		else
			self:fetch('refresh')
		end
	end
	if ui.help then
		if not self.helpU8 then
			self.helpU8 = {}
			for i, line in ipairs(M.helpLines(self.opts.selfName, self.opts.helpExtra)) do self.helpU8[i] = u8(line) end
		end
		ui.help(self.helpU8)
	end
	if status == 'error' then
		imgui.PushTextWrapPos(0)
		imgui.TextColored(C.danger, u8('Не удалось загрузить список: ' .. tostring(self.err) .. '.'))
		imgui.PopTextWrapPos()
		if ui.button(fa.ICON_FA_REDO .. u8(' Повторить') .. '##' .. id .. 'Retry', 'primary') then self:fetch('refresh') end
	elseif status == 'empty' then
		imgui.TextDisabled(u8('В каталоге пока нет скриптов.'))
	elseif status == 'ready' then
		for _, entry in ipairs(self.list) do self:drawCard(entry, inner) end
	end
	if (status == 'ready' or status == 'empty') and self.skipped > 0 then
		imgui.PushTextWrapPos(0)
		imgui.TextDisabled(u8('Пропущено записей с ошибкой: ' .. self.skipped .. '. Обновите ' .. (self.opts.selfName or 'скрипт') .. '.'))
		imgui.PopTextWrapPos()
	end
end

function Catalog:draw(width, height)
	local imgui = self:libs()
	local V2 = imgui.ImVec2
	if self.status == 'idle' then self:fetch('open') end
	if self.status == 'ready' and not self.busy and os.clock() - self.checkedAt > 2 then self:refreshInstalled() end
	if not height then
		self:drawBody(width or imgui.GetContentRegionAvailWidth())
		return
	end
	imgui.PushStyleColor(imgui.Col.ChildWindowBg, self.opts.ui.colors.panel)
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, V2(8, 8))
	imgui.BeginChild(self.idPrefix .. 'Panel', V2(width, height), false, imgui.WindowFlags.AlwaysUseWindowPadding)
		self:drawBody(imgui.GetWindowContentRegionWidth())
	imgui.EndChild()
	imgui.PopStyleVar()
	imgui.PopStyleColor()
end

return M
