-- samp-catalog: общий каталог скриптов GORYCH (репозиторий samp-scripts) для всех скриптов автора.
-- Лежит в moonloader/lib/samp-catalog.lua, подключается так: local SC = require 'samp-catalog'.
-- Каждый скрипт получает файл через свой загрузчик (в его списке DEPS с размером) и запускается и без
-- него: тогда вместо каталога он показывает, что файла нет.
--
-- Две части:
--   1. Чистая логика (без API MoonLoader, с тестами): безопасные пути, разбор scripts.json, что скачать,
--      что удалить, файл состояния, действие на карточке, в том числе на карточке самого скрипта.
--   2. SC.new(opts) - каталог внутри скрипта: загрузка списка и картинок, установка, обновление (и самого
--      скрипта), удаление, отрисовка раздела. Внешний вид - через функции темы скрипта (opts.ui).
--
-- Общие файлы в папке игры (их ведут все скрипты с каталогом, формат менять нельзя):
--   config/SNHelper/catalog.state - установленные версии, строки «id=version_num». Перед каждой записью
--     файл перечитывается и меняется только своя строка: скрипты могут писать в него одновременно.
--   resource/SNHelper/catalog/<id>.png - картинки карточек: скачанную одним скриптом другой не качает.
--
-- Файл собирается в CP1251, как скрипты: тексты для уведомлений и чата здесь в CP1251, для ImGui они
-- проходят через opts.u8 (encoding.UTF8 скрипта). Тексты каталога (scripts.json) - в UTF-8.
--
-- Совместимость: VERSION растёт с каждым выпуском; новые версии только добавляют. Скрипт требует
-- VERSION не ниже нужной ему; более новая библиотека, скачанная другим скриптом, ему подходит.

local M = {}

M.VERSION = 1
M.REPO = 'https://raw.githubusercontent.com/egor-pozhitok/samp-scripts/main/'
M.STATE_FILE = 'config/SNHelper/catalog.state'
M.IMAGE_DIR = 'resource/SNHelper/catalog'
-- Файлы, которые ни один скрипт каталога не может заменить или удалить: SNHelper обновляется сам.
M.ALWAYS_PROTECTED = { 'SNHelper.lua', 'SNHelper.luac' }
M.MAX_SIZE = 50 * 1024 * 1024
M.MAX_FILES = 64

------------------------------------------------------------------------------------------------------
-- 1. Чистая логика. Пути в каталоге - относительно папки moonloader игры (path) и относительно корня
-- репозитория samp-scripts (src, image).

-- Путь безопасен: латиница, цифры, '-', '_', '.', '/' между частями; без '..', '.', пустых частей,
-- ведущего '/', обратной косой, двоеточия (диск, потоки NTFS), точки в конце части и имён устройств Windows.
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

-- Путь для сравнения: строчные буквы, прямые косые.
function M.normPath(path)
	return (tostring(path):gsub('\\', '/'):lower())
end

-- Множества для parse/plan/removeList. protect - пути, которые нельзя трогать никогда (кроме SNHelper,
-- он там всегда), deps - общие файлы скрипта (его DEPS: строки или таблицы с полем path).
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

-- Одна запись каталога или nil, если в ней ошибка.
-- ownKey - файл самого скрипта с каталогом: его могут менять только файлы его же записи.
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
	-- Свои файлы скрипта не могут заменить ни защищённые файлы, ни общие файлы скрипта с каталогом,
	-- ни сам скрипт с каталогом (кроме его собственной записи).
	local files = fileList(e.files, function(key) return not selfSet[key] and not shared[key] and key ~= foreign end)
	if not files then return nil end
	local own, hasMain = {}, false
	for _, f in ipairs(files) do
		local key = M.normPath(f.path)
		own[key] = true
		if key == mainKey then hasMain = true end
	end
	if not hasMain then return nil end
	-- Общие файлы (deps) могут совпадать с общими файлами скрипта (тогда их только докачивают),
	-- но не с защищёнными и не со своими файлами.
	local deps = fileList(e.deps, function(key) return not selfSet[key] and not own[key] and key ~= foreign end)
	if not deps then return nil end
	return {
		id = e.id, name = e.name, description = e.description or '', version = e.version, version_num = num,
		image = e.image, main = e.main, files = files, deps = deps,
	}
end

-- Разобрать каталог (таблица из decodeJson). ownKey (необязательно) - нормализованное имя файла скрипта,
-- который читает каталог. Возвращает список скриптов и число пропущенных записей
-- с ошибкой либо nil и причину (CP1251), если сам каталог не того формата.
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

-- Действие для карточки: installed - номер установленной версии или nil, если скрипта нет.
function M.action(entry, installed)
	if installed == nil then return 'install' end
	if entry.version_num > installed then return 'update' end
	return 'remove'
end

-- Действие для карточки самого скрипта: «Обновить», если в каталоге версия новее запущенной, иначе
-- только пометка «этот скрипт» (удалять себя из своего же окна нельзя).
function M.selfAction(entry, runningNum)
	if entry.version_num > (tonumber(runningNum) or 0) then return 'update' end
	return 'self'
end

-- Файл состояния установленных скриптов: строки «id=version_num».
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

-- Новый текст файла состояния: запись id меняется (num = nil - удаляется), чужие строки остаются.
-- text - то, что лежит в файле прямо сейчас (его перечитывают перед каждой записью).
function M.stateUpdate(text, id, num)
	local state = M.stateParse(text)
	state[id] = num
	return M.stateText(state)
end

-- Что скачать при установке или обновлении: все свои файлы; общие - если их нет (или пустые) или другой
-- размер, но общий файл скрипта с каталогом (shared) с другим размером не трогаем: это рабочая версия
-- для других скриптов. sizeOf(path) - размер файла на диске или nil.
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

-- Что удалить: главный файл и свои файлы скрипта; общие файлы (deps), защищённые и общие файлы
-- скрипта с каталогом - никогда.
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

-- Состояние списка: idle (не открывали), loading, ready, empty, error.
-- События: open (первое открытие раздела), refresh (кнопка), loaded (count скриптов), failed.
function M.nextStatus(status, event, count)
	if event == 'open' then return status == 'idle' and 'loading' or status end
	if event == 'refresh' then return 'loading' end
	if status ~= 'loading' then return status end
	if event == 'loaded' then return (tonumber(count) or 0) > 0 and 'ready' or 'empty' end
	if event == 'failed' then return 'error' end
	return status
end

-- Скачанная картинка - PNG (а не страница ошибки).
function M.isPng(head)
	return type(head) == 'string' and head:sub(1, 8) == '\137PNG\r\n\26\n'
end

-- Справка раздела (CP1251). selfName - как назвать сам скрипт («плеер»); nil - карточки себя нет.
-- extra - строки скрипта после общих. Номера ставятся здесь.
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

------------------------------------------------------------------------------------------------------
-- 2. Каталог внутри скрипта. Всё ниже вызывает API MoonLoader только во время работы, поэтому файл
-- подключается и в тестах без игры.
--
-- opts:
--   u8          encoding.UTF8 скрипта (обязательно): u8(s) и u8:decode(s)
--   ui          тема скрипта (обязательно):
--                 colors = { card, control, muted, white, accent, danger, panel }
--                 label(text, color), button(label, kind, size) -> bool, dangerButton(id, label, size) -> bool
--                   (удаление с подтверждением: true на втором нажатии), buttonWidth(label),
--                 dangerButtonWidth(label), frameHeight(), alignRight(width), fitText(text, width),
--                 notify(text1251, seconds, kind) (kind: 'success' | 'error' | nil),
--                 help(linesU8) - необязательно: справка над списком
--   deps        общие файлы скрипта (его DEPS): каталог их не перезаписывает и не удаляет
--   protect     ещё пути, которые каталог не трогает никогда (SNHelper передаёт своё имя файла)
--   selfName    как назвать сам скрипт в текстах (винительный падеж: «плеер»); nil - своей карточки нет
--   chatPrefix  начало строки чата при обновлении себя («Audio Player»)
--   tag         начало строк лога ('[AudioPlayer]')
--   dataDir     папка для временного файла списка ('config/samp-audio-player')
--   idPrefix    префикс id элементов ImGui ('apCat'); imageSize, cardPad - размеры карточки
--   helpExtra   строки справки после общих (CP1251)
--   selfFile, runningVersion, repo, timeout, imgui, fa, download - для тестов и особых случаев

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

-- Скачать url в path, ждать не дольше timeout секунд без прогресса. Вызывать из lua_thread.
local function download(url, path, timeout)
	local done = false
	local deadline = os.time() + timeout
	os.remove(path)
	downloadUrlToFile(url, path, function(_, status)
		if status == 58 then -- STATUSEX_ENDDOWNLOAD
			done = true
		else
			deadline = os.time() + timeout -- любой прогресс продлевает ожидание
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

-- Записать версию id (nil - убрать запись), не трогая чужие строки: файл перечитывается прямо перед записью.
function Catalog:setState(id, num)
	ensureDir(statePath())
	local text = M.stateUpdate(readFile(statePath()) or '', id, num)
	local f = io.open(statePath(), 'w')
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

-- Установлен ли скрипт, решает наличие его главного файла; номер версии - из файла состояния (нет - 0).
function Catalog:refreshInstalled()
	local state = self:readState()
	local installed = {}
	for _, entry in ipairs(self.list) do
		if doesFileExist(full(entry.main)) then installed[entry.id] = state[entry.id] or 0 end
	end
	self.installed = installed
	self.checkedAt = os.clock()
end

-- Картинка скачивается один раз в общий кэш; не PNG - не сохраняется (на карточке заглушка).
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
	-- Ответ вида «404: Not Found» не передаём в decodeJson: он пишет исключение в лог.
	if not text:match('^%s*{') then return nil, 'каталог не найден' end
	local okJson, info = pcall(decodeJson, text)
	if not okJson or type(info) ~= 'table' then return nil, 'каталог повреждён' end
	local selfSet, shared = self:sets()
	return M.parse(info, selfSet, shared, self:ownName())
end

-- event: 'open' (первое открытие раздела) или 'refresh' (кнопка).
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

-- Скачать файлы записи: всё во временные файлы со сверкой размера, заменить только после этого.
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

-- Обновление самого скрипта: файлы заменены - перезагрузка. Строка пишется в чат: окно старой версии
-- закроется вместе с ней.
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

-- kind: 'install' (и обновление), 'self' (обновление самого скрипта) или 'remove'.
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
			-- При успехе скрипт уже перезагружается; сообщение - только если обновить не вышло.
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

------------------------------------------------------------------------------------------------------
-- Отрисовка. Каждый Push здесь закрыт своим Pop в той же функции.

function Catalog:libs()
	local imgui = self.opts.imgui or require('imgui')
	local fa = self.opts.fa or require('fAwesome5')
	return imgui, fa
end

-- Текстура картинки создаётся в кадре ImGui один раз; ошибка - заглушка до перезагрузки скрипта.
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

-- Карточка: картинка слева; справа колонка от верха картинки. Первая строка (высоты кнопки) - название,
-- версия и действие у правого края; под ней описание по всей ширине колонки.
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
	local showVersion = nameWidth >= 40 -- узко: версия уступает место названию
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
			-- Без вертикального промежутка после первой строки: описание сразу под ней.
			imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, V2(gap, 0))
				local nameText = ui.fitText(entry.name, math.max(20, nameWidth))
				local usedWidth = imgui.CalcTextSize(nameText).x
				ui.label(nameText, C.white)
				if showVersion then
					imgui.SameLine()
					ui.label(version, C.muted)
					usedWidth = usedWidth + gap + versionWidth
				end
				-- Внутри группы SameLine(x) считает x от начала группы: действие ставится промежутком.
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

-- Раздел целиком. С height - панель width x height цвета colors.panel со своей прокруткой; без height -
-- прямо в текущем окне скрипта (ширина - доступная).
function Catalog:draw(width, height)
	local imgui = self:libs()
	local V2 = imgui.ImVec2
	if self.status == 'idle' then self:fetch('open') end
	-- Файлы могли удалить руками или из другого скрипта: установленные пересчитываются не чаще раза в 2 с.
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
