-- Загрузчик недостающих файлов: если нет библиотек (imgui, шрифт значков и др.), скрипт до запуска
-- скачивает их из общего репозитория samp-scripts (папка deps) и перезапускается.
-- Это сокращённая копия загрузчика SNHelper (SNBoot): без самообновления и необязательных файлов.
local APBoot = {}

APBoot.DEPS_REPO = 'https://raw.githubusercontent.com/egor-pozhitok/samp-scripts/main/'
-- Не больше MAX_ATTEMPTS загрузок за ATTEMPT_WINDOW секунд: при постоянной ошибке файлы не качаются
-- на каждом запуске игры.
APBoot.MAX_ATTEMPTS = 2
APBoot.ATTEMPT_WINDOW = 600
APBoot.TIMEOUT_SEC = 30

-- Файлы зависимостей и их размеры; tools/check_deps.lua сверяет их с папкой deps репозитория samp-scripts.
APBoot.DEPS = {
	{ path = 'lib/imgui.lua', size = 114068, module = 'imgui' },
	{ path = 'lib/MoonImGui.dll', size = 3346432, module = 'imgui' },
	{ path = 'lib/bitex.lua', size = 557, module = 'imgui' },
	{ path = 'lib/windows/init.lua', size = 184, module = 'imgui' },
	{ path = 'lib/windows/message.lua', size = 26909, module = 'imgui' },
	{ path = 'lib/fAwesome5.lua', size = 41642, module = 'fAwesome5' },
	{ path = 'lib/encoding.lua', size = 2636, module = 'encoding' },
	{ path = 'lib/iconv.dll', size = 1000960, module = 'encoding' },
	{ path = 'lib/lfs.dll', size = 126976, module = 'lfs' },
	{ path = 'lib/samp/events.lua', size = 26829, module = 'lib.samp.events' },
	{ path = 'lib/samp/raknet.lua', size = 12181, module = 'lib.samp.events' },
	{ path = 'lib/samp/synchronization.lua', size = 4296, module = 'lib.samp.events' },
	{ path = 'lib/samp/events/bitstream_io.lua', size = 7155, module = 'lib.samp.events' },
	{ path = 'lib/samp/events/core.lua', size = 3880, module = 'lib.samp.events' },
	{ path = 'lib/samp/events/extra_types.lua', size = 1573, module = 'lib.samp.events' },
	{ path = 'lib/samp/events/handlers.lua', size = 17405, module = 'lib.samp.events' },
	{ path = 'lib/samp/events/utils.lua', size = 1385, module = 'lib.samp.events' },
	{ path = 'resource/fonts/fa-solid-900.ttf', size = 202744 },
}

-- Адрес файла зависимости в samp-scripts/deps.
function APBoot.depUrl(dep)
	return APBoot.DEPS_REPO .. 'deps/' .. dep.path
end

function APBoot.fileSize(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local size = f:seek('end')
	f:close()
	return size
end

-- Проблемный файл: отсутствует, пустой, либо все файлы модуля на месте, но модуль не подключается.
-- Существующие файлы другого размера не трогаем: это может быть рабочая версия для других скриптов.
function APBoot.findProblems(deps, root, tryRequire)
	local missing, groupHasMissing = {}, {}
	for i, dep in ipairs(deps) do
		local size = APBoot.fileSize(root .. '/' .. dep.path)
		if size == nil or size == 0 then
			missing[i] = true
			if dep.module then groupHasMissing[dep.module] = true end
		end
	end
	local broken, problems = {}, {}
	for i, dep in ipairs(deps) do
		local m = dep.module
		if missing[i] then
			table.insert(problems, dep)
		elseif m and not groupHasMissing[m] then
			if broken[m] == nil then broken[m] = not tryRequire(m) end
			if broken[m] then table.insert(problems, dep) end
		end
	end
	return problems
end

function APBoot.readState(path)
	local f = io.open(path, 'r')
	if not f then return { attempts = 0, time = 0 } end
	local attempts, time = f:read('*a'):match('^(%d+) (%d+)')
	f:close()
	return { attempts = tonumber(attempts) or 0, time = tonumber(time) or 0 }
end

function APBoot.writeState(path, attempts, time)
	local f = io.open(path, 'w')
	if not f then return false end
	f:write(string.format('%d %d', attempts, time))
	f:close()
	return true
end

function APBoot.attemptsUsed(state, now)
	if now - state.time > APBoot.ATTEMPT_WINDOW then return 0 end
	return state.attempts
end

function APBoot.acceptDownload(tmp, final, size)
	if APBoot.fileSize(tmp) ~= size then
		os.remove(tmp)
		return false
	end
	os.remove(final)
	return os.rename(tmp, final) == true
end

-- Тесты загружают файл только до этой строки: дальше нужен API MoonLoader.
if APBOOT_TEST then return APBoot end

script_name('samp-audio-player')
script_author('GORYCH')
script_description('Music player: radio stations and tracks from a folder')
script_version_number(2)
script_version('1.1')

function APBoot.ensureDir(filePath)
	local dir = filePath:match('^(.*)[/\\][^/\\]+$')
	if not dir then return end
	local cur = ''
	for part in dir:gmatch('[^/\\]+') do
		cur = (cur == '' and part) or (cur .. '\\' .. part)
		if not doesDirectoryExist(cur) then createDirectory(cur) end
	end
end

function APBoot.download(url, path, label, font, timeoutSec)
	local timeout = timeoutSec or APBoot.TIMEOUT_SEC
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
	local _, resY = getScreenResolution()
	while not done and os.time() <= deadline do
		if label and font then renderFontDrawText(font, label, 20, resY / 2, 0xFFFFFFFF) end
		wait(0)
	end
	return done
end

function APBoot.reportFailure(list)
	sampAddChatMessage('Audio Player | {FFFFFF}Не удалось загрузить файлы:', 0xFF5555)
	for i = 1, math.min(#list, 5) do
		sampAddChatMessage('Audio Player | {FFFFFF}moonloader/' .. list[i].path, 0xFF5555)
	end
	if #list > 5 then
		sampAddChatMessage(('Audio Player | {FFFFFF}... и ещё %d'):format(#list - 5), 0xFF5555)
	end
	sampAddChatMessage('Audio Player | {FFFFFF}Возьмите их вручную: github.com/egor-pozhitok/samp-scripts (папка deps)', 0xFF5555)
end

function APBoot.run(problems)
	while not isSampAvailable() do wait(100) end
	local root = getWorkingDirectory()
	local statePath = root .. '\\config\\samp-audio-player\\bootstrap.state'
	APBoot.ensureDir(statePath)
	local used = APBoot.attemptsUsed(APBoot.readState(statePath), os.time())
	if used >= APBoot.MAX_ATTEMPTS then
		APBoot.reportFailure(problems)
		return
	end
	if not APBoot.writeState(statePath, used + 1, os.time()) then
		APBoot.reportFailure(problems)
		return
	end
	sampAddChatMessage(('Audio Player | {FFFFFF}Не хватает файлов: %d. Загружаю...'):format(#problems), 0xC0C0C0)
	local font = renderCreateFont('Arial', 10, 5)
	local failed = {}
	for i, dep in ipairs(problems) do
		local final = root .. '\\' .. (dep.path:gsub('/', '\\'))
		local tmp = final .. '.tmp'
		APBoot.ensureDir(final)
		local label = ('Audio Player: загрузка %d из %d'):format(i, #problems)
		local ok = APBoot.download(APBoot.depUrl(dep), tmp, label, font)
		if not (ok and APBoot.acceptDownload(tmp, final, dep.size)) then
			os.remove(tmp)
			table.insert(failed, dep)
		end
	end
	if #failed > 0 then
		APBoot.reportFailure(failed)
		return
	end
	sampAddChatMessage('Audio Player | {FFFFFF}Файлы загружены, перезапускаю скрипт.', 0xC0C0C0)
	thisScript():reload()
end

do
	local root = getWorkingDirectory()
	local problems = APBoot.findProblems(APBoot.DEPS, root, function(m)
		return (pcall(require, m))
	end)
	-- Не хватает файлов: main заменяется загрузчиком, а return выходит из всей склейки,
	-- чтобы остальной код с его require не выполнялся.
	if #problems > 0 then
		function main() APBoot.run(problems) end
		return
	end
	os.remove(root .. '\\config\\samp-audio-player\\bootstrap.state')
	script_dependencies('imgui', 'inicfg', 'fAwesome5', 'encoding', 'lfs')
end
-- Чистая логика плеера (без API MoonLoader): её проверяют tests/logic_test.lua.
-- Функции перенесены из SNHelper без изменений, кроме имени таблицы.
local APLogic = {}

function APLogic.clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Экспоненциальное приближение к цели: одинаково выглядит при любом FPS.
function APLogic.approach(current, target, dt, speed)
	if dt <= 0 then return current end
	local nextValue = current + (target - current) * (1 - math.exp(-speed * dt))
	if math.abs(target - nextValue) < 0.001 then return target end
	return nextValue
end

-- Клавиши, которые нельзя назначить на открытие окна: модификаторы, Enter, пробел, Tab, Esc, T и F6 (чат).
APLogic.UNBINDABLE_KEYS = { [0x0D] = true, [0x20] = true, [0x09] = true, [0x1B] = true, [0x54] = true, [0x75] = true }
function APLogic.isBindableKey(vk)
	if type(vk) ~= 'number' or vk <= 0 then return false end
	if vk >= 0x10 and vk <= 0x12 then return false end
	if vk >= 0xA0 and vk <= 0xA5 then return false end
	return not APLogic.UNBINDABLE_KEYS[vk]
end

-- Радио: что делать с заданием открытия потока (оно идёт в отдельном системном потоке).
-- job.done - поток открылся или BASS вернул ошибку; job.current - это задание ещё ждёт игрок.
function APLogic.radioJobStep(job, now, timeout)
	if not job.done then
		if job.current and now - (job.startedAt or now) >= timeout then return 'timeout' end
		return 'wait'
	end
	local ok = (job.handle or 0) ~= 0
	if job.current then return ok and 'play' or 'fail' end
	return ok and 'free' or 'drop'
end

-- BASS_ChannelIsActive -> состояние как у getAudioStreamState: 1 играет, 2 пауза, -1 остановлен.
function APLogic.bassState(active)
	if active == 1 or active == 2 then return 1 end
	if active == 3 then return 2 end
	return -1
end

APLogic.BASS_ERRORS = {
	[2] = 'не удалось подключиться',
	[8] = 'звук не инициализирован',
	[32] = 'нет подключения к интернету',
	[40] = 'сервер не ответил',
	[41] = 'формат потока не поддерживается',
	[44] = 'нет кодека для этого формата (AAC)',
}

function APLogic.bassErrorText(code)
	return APLogic.BASS_ERRORS[code] or ('ошибка BASS '..tostring(code))
end

-- Уведомления: очередь { text, seconds, startAt }. Одновременно видно не больше maxVisible,
-- остальные ждут. Показ начинается, когда освободилось место; появление 0.2 с, исчезание 0.5 с.
-- Возвращает видимые { item, alpha } в порядке очереди; истёкшие удаляет из очереди.
function APLogic.toastUpdate(queue, now, maxVisible)
	for i = #queue, 1, -1 do
		local item = queue[i]
		if item.startAt and now - item.startAt >= item.seconds then table.remove(queue, i) end
	end
	local shown = {}
	for _, item in ipairs(queue) do
		if #shown >= maxVisible then break end
		item.startAt = item.startAt or now
		local elapsed = now - item.startAt
		local alpha = math.min(1, elapsed / 0.2, (item.seconds - elapsed) / 0.5)
		shown[#shown + 1] = { item = item, alpha = math.max(0, alpha) }
	end
	return shown
end

-- Окно плеера (src/view.lua)

-- Время «м:сс» или «ч:мм:сс».
function APLogic.formatTime(sec)
	sec = math.floor(tonumber(sec) or 0)
	if sec < 0 then sec = 0 end
	local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
	if h > 0 then return ('%d:%02d:%02d'):format(h, m, s) end
	return ('%d:%02d'):format(m, s)
end

-- Нижний регистр строки UTF-8: латиница и кириллица (А-Я, Ё). Нужен для поиска по спискам ImGui.
function APLogic.utf8Lower(text)
	return (text:gsub('[%z\1-\127\194-\244][\128-\191]*', function(ch)
		if #ch == 1 then return ch:lower() end
		if #ch ~= 2 then return ch end
		local a, b = ch:byte(1, 2)
		if a == 0xD0 and b >= 0x90 and b <= 0x9F then return string.char(0xD0, b + 0x20) end -- А-П
		if a == 0xD0 and b >= 0xA0 and b <= 0xAF then return string.char(0xD1, b - 0x20) end -- Р-Я
		if a == 0xD0 and b == 0x81 then return string.char(0xD1, 0x91) end -- Ё
		return ch
	end))
end

-- Порядок строк списка: только подходящие под запрос (подстрока без учёта регистра, пробелы по краям
-- не считаются), сначала избранные (fav[индекс] = true), в остальном - исходный порядок.
function APLogic.listOrder(names, query, fav)
	local q = APLogic.utf8Lower(tostring(query or '')):match('^%s*(.-)%s*$')
	local first, rest = {}, {}
	for i, name in ipairs(names) do
		if q == '' or APLogic.utf8Lower(name):find(q, 1, true) then
			table.insert((fav and fav[i]) and first or rest, i)
		end
	end
	for _, i in ipairs(rest) do first[#first + 1] = i end
	return first
end

-- Избранные станции в ini: адреса потоков через «|».
function APLogic.favParse(text)
	local set = {}
	for part in tostring(text or ''):gmatch('[^|]+') do set[part] = true end
	return set
end

function APLogic.favText(set)
	local list = {}
	for url in pairs(set) do list[#list + 1] = url end
	table.sort(list)
	return table.concat(list, '|')
end

-- Высоты столбиков индикатора (0.15..1) в момент t: сумма синусов с разной частотой и фазой у каждого
-- столбика. Это имитация: настоящий спектр звука не читается.
function APLogic.eqBars(t, n)
	local bars = {}
	for i = 1, n do
		local v = 0.5 + 0.28 * math.sin(t * (5.1 + i * 1.7) + i * 1.3) + 0.22 * math.sin(t * (2.3 + i * 0.9) + i * 2.7)
		bars[i] = math.max(0.15, math.min(1, v))
	end
	return bars
end

-- Сколько секунд трек уже играл: st = { key, elapsed, last }. key - текущий поток (новый поток - отсчёт
-- с нуля), playing - играет ли сейчас; время на паузе не считается.
function APLogic.elapsedStep(st, key, playing, now)
	if st.key ~= key then
		st.key, st.elapsed = key, 0
	elseif playing and st.last then
		st.elapsed = (st.elapsed or 0) + (now - st.last)
	end
	st.elapsed = st.elapsed or 0
	st.last = playing and now or nil
	return st.elapsed
end

-- Доля прослушанного трека 0..1 или nil, если длина неизвестна.
function APLogic.progress(elapsed, length)
	length = tonumber(length)
	if not length or length <= 0 then return nil end
	return math.max(0, math.min(1, (tonumber(elapsed) or 0) / length))
end

-- Состояние для строки «Сейчас играет»: info = { loading = секунды подключения, error = текст,
-- state = 1 играет / 2 пауза / -1 остановлен }. Возвращает вид и текст (CP1251).
function APLogic.playerStatus(info)
	if info.loading then return 'loading', 'Подключение... ' .. info.loading .. ' с' end
	if info.error then return 'error', info.error end
	if info.state == 1 then return 'playing', 'Играет' end
	if info.state == 2 then return 'paused', 'Пауза' end
	return 'stopped', 'Остановлено'
end

function APLogic.trackTitle(file)
	return (tostring(file):gsub('%.[mM][pP]3$', ''))
end

-- Значок громкости: 'off' (0), 'down' (до половины), 'up'.
function APLogic.volumeIcon(v)
	if v <= 0.001 then return 'off' end
	if v < 0.5 then return 'down' end
	return 'up'
end

-- Громкость по положению мыши на дорожке ползунка (x0 - левый край, w - ширина).
function APLogic.volumeFromX(mx, x0, w)
	if w <= 0 then return 0 end
	return math.max(0, math.min(1, (mx - x0) / w))
end

-- Предыдущий / следующий по кругу: i + step в пределах 1..n.
function APLogic.wrapIndex(i, step, n)
	if n <= 0 then return 1 end
	return (i - 1 + step) % n + 1
end

if APLOGIC_TEST then return APLogic end
-- Тема и элементы интерфейса - часть ui.lua из SNHelper (те же цвета и кнопки), без лишних элементов.
local APUI = { animations = true, fontBase = nil, fontLarge = nil }
do
	local imgui = require 'imgui'
	local u8 = require('encoding').UTF8
	local V2, V4 = imgui.ImVec2, imgui.ImVec4

	local function hex(rgb, alpha)
		local r = math.floor(rgb / 65536) % 256
		local g = math.floor(rgb / 256) % 256
		local b = rgb % 256
		return V4(r / 255, g / 255, b / 255, alpha or 1)
	end

	local C = {
		window = hex(0x17161D), nav = hex(0x121117), field = hex(0x121117), card = hex(0x1E1C28),
		control = hex(0x2A2738), controlHover = hex(0x353148), navActive = hex(0x231F33),
		border = hex(0x2A2836), text = hex(0xEAE8F2), muted = hex(0x9D99B0), faint = hex(0x5F5B72),
		accent = hex(0x8B6CF6), accentSoft = hex(0xA78BFA), danger = hex(0xFF6B7A), dangerBg = hex(0x5A2230),
		switchOff = hex(0x3D3A4D), white = hex(0xFFFFFF), clear = hex(0x000000, 0),
	}
	APUI.colors = C

	function APUI.mix(a, b, t)
		return V4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t)
	end

	local function u32(color)
		return imgui.GetColorU32(color)
	end

	local animated = {}
	function APUI.animate(id, target, speed)
		local current = animated[id]
		if current == nil or not APUI.animations then
			animated[id] = target
			return target
		end
		current = APLogic.approach(current, target, imgui.GetIO().DeltaTime, speed or 14)
		animated[id] = current
		return current
	end

	function APUI.applyStyle()
		local style = imgui.GetStyle()
		style.WindowRounding = 12
		style.ChildWindowRounding = 10
		style.FrameRounding = 8
		style.ScrollbarRounding = 8
		style.GrabRounding = 8
		style.ScrollbarSize = 8
		style.GrabMinSize = 10
		style.WindowPadding = V2(12, 12)
		style.FramePadding = V2(10, 7)
		style.ItemSpacing = V2(8, 8)
		style.ItemInnerSpacing = V2(6, 6)
		style.ButtonTextAlign = V2(0.5, 0.5)
		local palette = {
			Text = C.text, TextDisabled = C.muted, WindowBg = C.window, ChildWindowBg = C.clear,
			PopupBg = C.card, Border = C.border, BorderShadow = C.clear,
			FrameBg = C.field, FrameBgHovered = C.control, FrameBgActive = C.control,
			TitleBg = C.nav, TitleBgActive = C.nav, TitleBgCollapsed = C.nav,
			ScrollbarBg = C.clear, ScrollbarGrab = C.control, ScrollbarGrabHovered = C.controlHover, ScrollbarGrabActive = C.accent,
			ComboBg = C.card, CheckMark = C.accent, SliderGrab = C.accent, SliderGrabActive = C.accentSoft,
			Button = C.control, ButtonHovered = C.controlHover, ButtonActive = C.accent,
			Header = C.navActive, HeaderHovered = C.controlHover, HeaderActive = C.accent,
			Separator = C.border, SeparatorHovered = C.border, SeparatorActive = C.border,
			TextSelectedBg = hex(0x8B6CF6, 0.35), ModalWindowDarkening = hex(0x000000, 0.5),
		}
		for name, color in pairs(palette) do
			local index = imgui.Col[name]
			if index then style.Colors[index] = color end
		end
	end

	-- Кнопка собственной отрисовки с плавным наведением.
	-- kind: nil | 'primary' | 'danger' (фон подтверждения) | 'dangerText' (обычный фон, красный текст).
	-- animKey: необязательный ключ анимации наведения; по умолчанию полная подпись кнопки.
	function APUI.button(label, kind, size, animKey)
		local text = label:match('^(.-)##') or label
		local textSize = imgui.CalcTextSize(text)
		local pad = imgui.GetStyle().FramePadding
		local w = textSize.x + pad.x * 2
		if size and size.x > 0 then w = size.x end
		if size and size.x < 0 then w = math.max(1, imgui.GetContentRegionAvail().x + size.x + 1) end
		local h = textSize.y + pad.y * 2
		if size and size.y > 0 then h = size.y end
		local pos = imgui.GetCursorScreenPos()
		local pressed = imgui.InvisibleButton(label, V2(w, h))
		local hover = APUI.animate('button:' .. (animKey or label), imgui.IsItemHovered() and 1 or 0, 16)
		local base, over, textColor = C.control, C.controlHover, C.text
		if kind == 'primary' then
			base, over, textColor = C.accent, C.accentSoft, C.white
		elseif kind == 'danger' then
			base, over, textColor = C.dangerBg, APUI.mix(C.dangerBg, C.danger, 0.35), C.white
		elseif kind == 'dangerText' then
			textColor = C.danger
		end
		local corner = V2(pos.x + w, pos.y + h)
		local drawList = imgui.GetWindowDrawList()
		drawList:AddRectFilled(pos, corner, u32(APUI.mix(base, over, hover)), imgui.GetStyle().FrameRounding)
		drawList:PushClipRect(pos, corner, true)
		drawList:AddText(V2(pos.x + (w - textSize.x) / 2, pos.y + (h - textSize.y) / 2), u32(textColor), text)
		drawList:PopClipRect()
		return pressed
	end

	function APUI.selectable(label, active, size)
		return APUI.button(label, active and 'primary' or nil, size)
	end

	function APUI.tabs(id, labels, current)
		local spacing = imgui.GetStyle().ItemSpacing.x
		local width = (imgui.GetWindowContentRegionWidth() - spacing * (#labels - 1)) / #labels
		for i, label in ipairs(labels) do
			if i > 1 then imgui.SameLine() end
			if APUI.selectable(label .. '##' .. id .. i, current == i, V2(width, 0)) then
				current = i
			end
		end
		return current
	end

	-- Раскладка строки. Все элементы строки (кнопка, поле, переключатель, подпись) имеют одну высоту,
	-- высоту рамки, и центрируются в ней по вертикали, как элементы flex-строки с align-items: center.

	-- Высота кнопки и поля ввода при текущем шрифте.
	function APUI.frameHeight()
		return imgui.GetFontSize() + imgui.GetStyle().FramePadding.y * 2
	end

	-- Ширина, которую займёт APUI.button с такой подписью.
	function APUI.buttonWidth(label)
		local text = label:match('^(.-)##') or label
		return imgui.CalcTextSize(text).x + imgui.GetStyle().FramePadding.x * 2
	end

	-- Текст в строке с кнопками и полями: встаёт по центру их высоты. color необязателен.
	function APUI.label(text, color)
		imgui.AlignTextToFramePadding()
		if color then
			imgui.TextColored(color, text)
		else
			imgui.Text(text)
		end
	end

	-- Продолжает строку у правого края: следующий элемент шириной width встанет вплотную к нему.
	function APUI.alignRight(width)
		imgui.SameLine(math.max(0, imgui.GetWindowContentRegionWidth() - width))
	end

	function APUI.header(text)
		if APUI.fontLarge then imgui.PushFont(APUI.fontLarge) end
		imgui.TextColored(C.white, text)
		if APUI.fontLarge then imgui.PopFont() end
	end

	-- Уведомления в правом нижнем углу.
	-- text в CP1251, как в чате; рисует APUI.drawToasts() из imgui.OnDrawFrame.
	APUI.toasts = {}
	function APUI.notify(text, seconds)
		local queue = APUI.toasts
		if #queue >= 8 then table.remove(queue, 1) end
		queue[#queue + 1] = { text = tostring(text), seconds = tonumber(seconds) or 4 }
	end

	-- Для imgui.Process: кадры ImGui нужны, пока есть уведомления.
	function APUI.toastsActive()
		return #APUI.toasts > 0
	end

	function APUI.drawToasts()
		if #APUI.toasts == 0 then return end
		local shown = APLogic.toastUpdate(APUI.toasts, os.clock(), 3)
		if #shown == 0 then return end
		local resX, resY = getScreenResolution()
		local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
			+ imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoFocusOnAppearing
			+ imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoMove
		local padX, padY, gap, margin, bar = 12, 9, 6, 16, 3
		-- Общее оформление всех уведомлений: ставится до цикла и снимается после него, на одном уровне.
		imgui.PushStyleVar(imgui.StyleVar.WindowRounding, 8)
		imgui.PushStyleVar(imgui.StyleVar.WindowPadding, V2(padX, padY))
		imgui.PushStyleColor(imgui.Col.WindowBg, V4(C.window.x, C.window.y, C.window.z, 0.94))
		if APUI.fontBase then imgui.PushFont(APUI.fontBase) end
		local fontSize = imgui.GetFontSize()
		local width = math.floor(fontSize * 17)
		local textX = padX + bar + 6
		local wrap = width - textX - padX
		local y = resY - margin
		for i, entry in ipairs(shown) do
			local text = u8(entry.item.text)
			local size = imgui.GetFont():CalcTextSizeA(fontSize, 10000, wrap, text)
			local h = math.floor(size.y + padY * 2)
			y = y - h
			imgui.SetNextWindowPos(V2(resX - margin - width, y), imgui.Cond.Always)
			imgui.SetNextWindowSize(V2(width, h), imgui.Cond.Always)
			imgui.PushStyleVar(imgui.StyleVar.Alpha, entry.alpha)
			imgui.Begin('##aptoast' .. i, nil, flags)
				local pos = imgui.GetWindowPos()
				imgui.GetWindowDrawList():AddRectFilled(V2(pos.x + padX, pos.y + padY), V2(pos.x + padX + bar, pos.y + h - padY), u32(C.accent), 1)
				imgui.SetCursorPosX(textX)
				imgui.PushTextWrapPos(width - padX)
					imgui.TextColored(C.text, text)
				imgui.PopTextWrapPos()
			imgui.End()
			imgui.PopStyleVar()
			y = y - gap
		end
		if APUI.fontBase then imgui.PopFont() end
		imgui.PopStyleColor()
		imgui.PopStyleVar(2)
	end
end
-- Аудиоплеер для MoonLoader: радиостанции и треки (mp3) из папки на компьютере.
-- Воспроизведение перенесено из SNHelper без изменений: те же станции, фоновое подключение к станции,
-- повтор трека, громкость. Свои окно (src/view.lua), команда (/aplayer), клавиша (по умолчанию F12)
-- и настройки (moonloader/config/samp-audio-player.ini).
local hook = require 'lib.samp.events'
require 'lib.moonloader'

local imgui = require 'imgui'
local inicfg = require 'inicfg'
local fa = require 'fAwesome5'
local encoding = require 'encoding'
local as_action = require('moonloader').audiostream_state
local lfs = require 'lfs'

-- Скрипт собирается в CP1251, как чат игры, а ImGui ждёт UTF-8: строки для imgui.* оборачиваются в u8(...).
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local fa_glyph_ranges = imgui.ImGlyphRanges({ fa.min_range, fa.max_range })
-- Шрифты добавляются один раз перед первым кадром. В шрифте интерфейса только кириллица и латиница:
-- в строках интерфейса нельзя использовать длинное тире и символ многоточия.
function imgui.BeforeDrawFrame()
	if apFontsLoaded then return end
	apFontsLoaded = true
	local fonts = imgui.GetIO().Fonts
	local iconFont = 'moonloader/resource/fonts/fa-solid-900.ttf'
	if doesFileExist(iconFont) then
		local merge = imgui.ImFontConfig()
		merge.MergeMode = true
		fonts:AddFontFromFileTTF(iconFont, 13.0, merge, fa_glyph_ranges)
	end
	local dir = getFolderPath(0x14) .. '\\'
	local file
	for _, name in ipairs({ 'segoeui.ttf', 'trebuc.ttf', 'arial.ttf' }) do
		if doesFileExist(dir .. name) then
			file = dir .. name
			break
		end
	end
	if file then
		local cyrillic = fonts:GetGlyphRangesCyrillic()
		APUI.fontBase = fonts:AddFontFromFileTTF(file, 15.0, nil, cyrillic)
		if doesFileExist(iconFont) then
			local merge = imgui.ImFontConfig()
			merge.MergeMode = true
			fonts:AddFontFromFileTTF(iconFont, 13.0, merge, fa_glyph_ranges)
		end
		APUI.fontLarge = fonts:AddFontFromFileTTF(file, 21.0, nil, cyrillic)
		-- Значки и в крупном шрифте: ими рисуются большая кнопка «Играть» и обложка в «Сейчас играет».
		if doesFileExist(iconFont) then
			local merge = imgui.ImFontConfig()
			merge.MergeMode = true
			fonts:AddFontFromFileTTF(iconFont, 18.0, merge, fa_glyph_ranges)
		end
	end
end

local resX, resY = getScreenResolution()
local cfgpath = 'samp-audio-player' -- moonloader/config/samp-audio-player.ini
local data = nil
local DEFAULT_KEY = 0x7B -- F12
local apWindow = imgui.ImBool(false)
local apKeyCapture = false
local apWindowPos = nil

-- Плеер и радио

local 	musics				= {}
local 	current_music 		= 1
local 	icon_play_pause		= fa.ICON_FA_PLAY
local results = ''

local current_radio				= imgui.ImInt(0)
local volume_player				= imgui.ImFloat(1)
local music_repeat = imgui.ImBool(false)
local musicpath = imgui.ImBuffer('', 256)

-- Станции: { название, адрес потока }. Только обычный HTTP: на HTTPS-потоках игра под CrossOver зависала. Проверены 16.11.2026.
local radio_stations = {
	{ 'Europa Plus', 'http://ep256.hostingradio.ru:8052/europaplus256.mp3' },
	{ 'DFM', 'http://dfm.hostingradio.ru/dfm128.mp3' },
	{ 'Новое Радио RU', 'http://icecast.newradio.cdnvideo.ru/newradio3' },
	{ 'Zaycev FM', 'http://abs.zaycev.fm/pop128k' },
	{ 'KISS FM Russian Beats', 'http://topradio-de-hz-fal-stream03-cluster01.radiohost.de/kissfm-russian-beats_mp3-128' },
	{ 'Dance', 'http://topradio-de-hz-fal-stream03-cluster01.radiohost.de/kissfm-dance_mp3-128' },
	{ 'Hiphop', 'http://topradio-de-hz-fal-stream03-cluster01.radiohost.de/kissfm-hiphop_mp3-128' },
	{ 'ХИТ FM', 'http://hitfm.hostingradio.ru/hitfm96.aacp' },
	{ 'Radio Record', 'http://radiorecord.hostingradio.ru/rr_main96.aacp' },
	{ 'Rap Classics', 'http://radiorecord.hostingradio.ru/rapclassics96.aacp' },
	{ 'Pirate Station', 'http://radiorecord.hostingradio.ru/ps96.aacp' },
	{ 'Vip Mix', 'http://radiorecord.hostingradio.ru/vip96.aacp' },
	{ 'Hardstyle', 'http://radiorecord.hostingradio.ru/teo96.aacp' },
	{ 'DanceCore', 'http://radiorecord.hostingradio.ru/dc96.aacp' },
	{ 'Chill-Out', 'http://radiorecord.hostingradio.ru/chil96.aacp' },
	{ 'Dubstep', 'http://radiorecord.hostingradio.ru/dub96.aacp' },
	{ '90-e', 'http://radiorecord.hostingradio.ru/sd9096.aacp' },
	{ 'Club Radio', 'http://radiorecord.hostingradio.ru/club96.aacp' },
	{ 'Medlyak FM', 'http://radiorecord.hostingradio.ru/mdl96.aacp' },
	{ 'Russian Mix', 'http://radiorecord.hostingradio.ru/rus96.aacp' },
	{ 'Deep', 'http://radiorecord.hostingradio.ru/deep96.aacp' },
	{ 'Rock Radio', 'http://radiorecord.hostingradio.ru/rock96.aacp' },
	{ 'Trancemission', 'http://radiorecord.hostingradio.ru/tm96.aacp' },
	{ 'Trap', 'http://radiorecord.hostingradio.ru/trap96.aacp' },
	{ 'Future House', 'http://radiorecord.hostingradio.ru/fut96.aacp' },
	{ 'Minimal/Tech', 'http://radiorecord.hostingradio.ru/mini96.aacp' },
	{ 'Techno', 'http://radiorecord.hostingradio.ru/techno96.aacp' },
	{ 'Black', 'http://radiorecord.hostingradio.ru/yo96.aacp' },
	{ 'Megamix', 'http://radiorecord.hostingradio.ru/mix96.aacp' },
}
local radiolist = {}
local radio_items = {}
for _, station in ipairs(radio_stations) do
	local name = u8(station[1])
	table.insert(radiolist, name)
	radio_items[name] = station[2]
end

-- Текст, обрезанный многоточием по ширине (UTF-8).
local function apFitText(text, maxWidth)
	if imgui.CalcTextSize(text).x <= maxWidth then return text end
	local chars = {}
	for ch in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = ch end
	local function candidate(count)
		return (table.concat(chars, '', 1, count):gsub('%s+$', '')) .. '...'
	end
	local low, high = 0, #chars - 1
	while low < high do
		local mid = math.ceil((low + high) / 2)
		if imgui.CalcTextSize(candidate(mid)).x <= maxWidth then low = mid else high = mid - 1 end
	end
	if low > 0 and imgui.CalcTextSize(candidate(low)).x <= maxWidth then return candidate(low) end
	return '...'
end

-- Подсказка при наведении на предыдущий элемент.
local apHintAt = nil
function imgui.Hint(text, delay)
	if imgui.IsItemHovered() then
		if apHintAt == nil then apHintAt = os.clock() + (delay and delay or 0.0) end
		local alpha = (os.clock() - apHintAt) * 6 -- скорость появления
		if os.clock() >= apHintAt then
			imgui.PushStyleVar(imgui.StyleVar.Alpha, (alpha <= 1.0 and alpha or 1.0))
				imgui.PushStyleColor(imgui.Col.PopupBg, imgui.GetStyle().Colors[imgui.Col.ButtonHovered])
					imgui.BeginTooltip()
					imgui.PushTextWrapPos(450)
					imgui.TextUnformatted(text)
					if not imgui.IsItemVisible() and imgui.GetStyle().Alpha == 1.0 then apHintAt = nil end
					imgui.PopTextWrapPos()
					imgui.EndTooltip()
				imgui.PopStyleColor()
			imgui.PopStyleVar()
		end
	end
end

local currentPage = 1
local audioStream = nil

-- Станции открываются через BASS в отдельном системном потоке. BASS_StreamCreateURL держит
-- вызвавший поток, пока не подключится и не разберёт формат; на AAC под Wine это может длиться
-- бесконечно, а loadAudioStream вызывается в главном потоке игры, и игра замирала.
-- Поэтому игра не ждёт: apRadioPoll() каждый кадр смотрит, готово ли задание.
-- Задание (структура apRadioJob) живёт в памяти вне сборщика мусора: поток может закончить
-- работу когда угодно, даже после выгрузки скрипта. Треки из папки открываются через loadAudioStream:
-- локальный файл открывается сразу.
apRadio = { jobs = {}, handle = nil, job = nil, ready = nil, TIMEOUT = 15, MAX_HUNG = 4 }

do
	local ffi = require 'ffi'
	local bass, kernel, thunk

	-- x86, stdcall ThreadProc(job): BASS_SetDevice(job.device);
	-- job.handle = BASS_StreamCreateURL(job.url, 0, job.flags, NULL, NULL);
	-- job.err = BASS_ErrorGetCode(); job.done = 1; return 0. Lua в этом потоке не выполняется.
	-- Смещения полей: create 0, url 4, flags 8, handle 12, errorCode 16, err 20, setDevice 24, device 28, done 32.
	local THUNK_HEX = '8B44240453' .. '89C3' .. 'FF731C' .. 'FF5318' .. '6A00' .. '6A00' .. 'FF7308' .. '6A00'
		.. 'FF7304' .. 'FF13' .. '89430C' .. 'FF5310' .. '894314' .. 'C7432001000000' .. '5B' .. '31C0' .. 'C20400'

	local DECLS = {
		'typedef struct { void *create; const char *url; uint32_t flags; uint32_t handle; void *errorCode; int32_t err; void *setDevice; uint32_t device; volatile int32_t done; } apRadioJob;',
		'uint32_t __stdcall BASS_StreamCreateURL(const char *url, uint32_t offset, uint32_t flags, void *proc, void *user);',
		'int __stdcall BASS_ErrorGetCode();',
		'int __stdcall BASS_SetDevice(uint32_t device);',
		'uint32_t __stdcall BASS_GetDevice();',
		'int __stdcall BASS_ChannelPlay(uint32_t handle, int restart);',
		'int __stdcall BASS_ChannelPause(uint32_t handle);',
		'int __stdcall BASS_ChannelStop(uint32_t handle);',
		'uint32_t __stdcall BASS_ChannelIsActive(uint32_t handle);',
		'int __stdcall BASS_ChannelSetAttribute(uint32_t handle, uint32_t attrib, float value);',
		'int __stdcall BASS_StreamFree(uint32_t handle);',
		'void* __stdcall VirtualAlloc(void *addr, size_t size, uint32_t type, uint32_t protect);',
		'void* __stdcall LocalAlloc(uint32_t flags, size_t bytes);',
		'void* __stdcall LocalFree(void *mem);',
		'void* __stdcall CreateThread(void *attr, size_t stack, void *start, void *param, uint32_t flags, uint32_t *id);',
		'int __stdcall CloseHandle(void *handle);',
	}

	-- Подготовить FFI и машинный код один раз; false - фоновое открытие недоступно.
	function apRadioInit()
		if apRadio.ready ~= nil then return apRadio.ready end
		apRadio.ready = false
		local ok, err = pcall(function()
			assert(ffi.os == 'Windows' and ffi.abi('32bit'), 'нужна 32-битная Windows')
			for _, decl in ipairs(DECLS) do pcall(ffi.cdef, decl) end
			assert(ffi.sizeof('apRadioJob') == 36 and ffi.offsetof('apRadioJob', 'device') == 28
				and ffi.offsetof('apRadioJob', 'done') == 32, 'раскладка apRadioJob')
			bass = ffi.load('bass')
			kernel = ffi.load('kernel32')
			local code = (THUNK_HEX:gsub('%x%x', function(h) return string.char(tonumber(h, 16)) end))
			assert(#code == 49, 'длина кода')
			thunk = kernel.VirtualAlloc(nil, #code, 0x3000, 0x40) -- MEM_COMMIT|MEM_RESERVE, PAGE_EXECUTE_READWRITE
			assert(thunk ~= nil, 'VirtualAlloc')
			ffi.copy(thunk, code, #code)
		end)
		apRadio.ready = ok
		if not ok then print('[AudioPlayer] радио: фоновое открытие недоступно: '..tostring(err)) end
		return ok
	end

	-- Начать открытие потока. Возвращает true или false и причину.
	function apRadioOpen(url, name)
		apRadioCancel()
		local hung = 0
		for _, job in ipairs(apRadio.jobs) do
			if job.c.done == 0 then hung = hung + 1 end
		end
		if hung >= apRadio.MAX_HUNG then return false, 'уже '..hung..' станции не отвечают, подождите' end
		local mem = kernel.LocalAlloc(0x40, ffi.sizeof('apRadioJob') + #url + 1) -- LPTR: обнулённая память
		if mem == nil then return false, 'нет памяти' end
		local c = ffi.cast('apRadioJob*', mem)
		local urlMem = ffi.cast('char*', mem) + ffi.sizeof('apRadioJob')
		ffi.copy(urlMem, url)
		c.create = ffi.cast('void*', bass.BASS_StreamCreateURL)
		c.url = urlMem
		c.flags = 0
		c.errorCode = ffi.cast('void*', bass.BASS_ErrorGetCode)
		c.setDevice = ffi.cast('void*', bass.BASS_SetDevice)
		c.device = bass.BASS_GetDevice()
		local thread = kernel.CreateThread(nil, 0, thunk, mem, 0, nil)
		if thread == nil then
			kernel.LocalFree(mem)
			return false, 'не удалось запустить поток'
		end
		kernel.CloseHandle(thread)
		local job = { mem = mem, c = c, name = name, startedAt = os.clock(), current = true }
		table.insert(apRadio.jobs, job)
		apRadio.job = job
		return true
	end

	-- Игрок больше не ждёт текущее открытие (выбрал другое, Stop, трек); поток доработает сам.
	function apRadioCancel()
		if apRadio.job then
			apRadio.job.current = false
			apRadio.job = nil
		end
	end

	-- Секунды с начала текущего открытия или nil, если ничего не открывается.
	function apRadioLoadingSeconds()
		if not apRadio.job then return nil end
		return math.floor(os.clock() - apRadio.job.startedAt)
	end

	function apRadioState()
		if not apRadio.handle then return -1 end
		return APLogic.bassState(tonumber(bass.BASS_ChannelIsActive(apRadio.handle)))
	end
	function apRadioPause()
		if apRadio.handle then bass.BASS_ChannelPause(apRadio.handle) end
	end
	function apRadioResume()
		if apRadio.handle then bass.BASS_ChannelPlay(apRadio.handle, 0) end
	end
	function apRadioVolume(value)
		if apRadio.handle then bass.BASS_ChannelSetAttribute(apRadio.handle, 2, value) end -- BASS_ATTRIB_VOL
	end
	function apRadioFree()
		apRadioCancel()
		if apRadio.handle then
			bass.BASS_ChannelStop(apRadio.handle)
			bass.BASS_StreamFree(apRadio.handle)
			apRadio.handle = nil
		end
	end

	local function failed(job, reason)
		icon_play_pause = fa.ICON_FA_PLAY
		apStoppedByUser = true
		APUI.notify('Станция '..job.name..' не открылась:\n'..reason..'.\nВыберите другую.', 6)
	end

	-- Каждый кадр: забрать готовые задания. Повторных попыток нет - только по клику игрока.
	function apRadioPoll()
		if #apRadio.jobs == 0 then return end
		local now = os.clock()
		for i = #apRadio.jobs, 1, -1 do
			local job = apRadio.jobs[i]
			job.done = job.c.done ~= 0
			if job.done then
				job.handle = tonumber(job.c.handle)
				job.err = tonumber(job.c.err)
			end
			local step = APLogic.radioJobStep(job, now, apRadio.TIMEOUT)
			if step == 'timeout' then
				apRadioCancel()
				failed(job, 'сервер не ответил за '..apRadio.TIMEOUT..' с')
			elseif step ~= 'wait' then
				table.remove(apRadio.jobs, i)
				kernel.LocalFree(job.mem)
				if step == 'play' then
					apRadio.job = nil
					apRadio.handle = job.handle
					bass.BASS_ChannelSetAttribute(job.handle, 2, volume_player.v)
					bass.BASS_ChannelPlay(job.handle, 0)
					icon_play_pause = fa.ICON_FA_PAUSE
					APUI.notify('Станция: '..job.name)
				elseif step == 'fail' then
					apRadio.job = nil
					failed(job, APLogic.bassErrorText(job.err))
				elseif step == 'free' then
					bass.BASS_StreamFree(job.handle)
				end
			end
		end
	end
end

-- Остановить и освободить текущий поток (станции или трека) и забыть открытие станции.
function apReleaseStream()
	apRadioFree()
	if audioStream then
		setAudioStreamState(audioStream, as_action.STOP)
		releaseAudioStream(audioStream)
		audioStream = nil
	end
end

-- Загрузить и запустить текущий трек списка (старый поток освобождается).
function apPlayTrack()
	apReleaseStream()
	apLastRestart = os.clock()
	audioStream = loadAudioStream(u8:decode(musicpath.v).."\\"..musics[current_music])
	apStreamIsTrack = true
	if audioStream then
		setAudioStreamVolume(audioStream, volume_player.v)
		setAudioStreamState(audioStream, as_action.PLAY)
		apStoppedByUser = false
		icon_play_pause = fa.ICON_FA_PAUSE
	else
		apStoppedByUser = true
		icon_play_pause = fa.ICON_FA_PLAY
		APUI.notify('Не удалось загрузить трек.')
	end
end

-- Загрузить и запустить выбранную станцию (старый поток освобождается).
function apPlayStation()
	apReleaseStream()
	apStreamIsTrack = false
	apStoppedByUser = false
	local stationName = radiolist[current_radio.v + 1]
	local stationUrl = stationName and radio_items[stationName]
	if not stationUrl then return end
	if apRadioInit() then
		-- Фоново: игра не ждёт, результат заберёт apRadioPoll().
		icon_play_pause = fa.ICON_FA_PLAY
		local ok, reason = apRadioOpen(stationUrl, u8:decode(stationName))
		if not ok then
			apStoppedByUser = true
			APUI.notify('Станция '..u8:decode(stationName)..' не открылась:\n'..reason..'.', 5)
		end
		return
	end
	-- Запасной путь, если фоновое открытие недоступно: игра ждёт подключения в главном потоке.
	audioStream = loadAudioStream(stationUrl)
	if audioStream then
		setAudioStreamVolume(audioStream, volume_player.v)
		setAudioStreamState(audioStream, as_action.PLAY)
		icon_play_pause = fa.ICON_FA_PAUSE
		APUI.notify('Станция: '..u8:decode(stationName))
	else
		icon_play_pause = fa.ICON_FA_PLAY
		APUI.notify('Не удалось открыть поток станции.\nВыберите другую.', 5)
	end
end

-- Действия плеера. Тела перенесены без изменений из прежней панели (кнопки «Выбор», играть/пауза,
-- стоп, повтор, предыдущий и следующий трек, ползунок громкости); окно (src/view.lua) только вызывает их.

-- «Выбор» папки: найти mp3, запомнить папку; играющий поток останавливается.
function apScanFolder()
	if doesDirectoryExist(u8:decode(musicpath.v)) then
		local found = {}
		results = ''
		for v in lfs.dir(u8:decode(musicpath.v)) do
			if string.find(v,"mp3") then
				found[#found+1] = v
			end
		end
		if #found < 1 then
			results = "Музыка не найдена"
		else
			musics = found
			current_music = 1
			data.music.path = u8:decode(musicpath.v)
			inicfg.save(data, cfgpath)
			apReleaseStream()
			apStreamIsTrack = true
			apStoppedByUser = true
			icon_play_pause = fa.ICON_FA_PLAY
		end
	else
		results = "Неправильный путь"
	end
end

-- Список треков сохранённой папки при запуске скрипта: без сообщений и без остановки звука (он ещё не играет).
function apLoadFolderQuiet()
	local path = u8:decode(musicpath.v)
	if not doesDirectoryExist(path) then return end
	local ok, found = pcall(function()
		local list = {}
		for v in lfs.dir(path) do
			if string.find(v,"mp3") then list[#list+1] = v end
		end
		return list
	end)
	if ok and #found > 0 then
		musics = found
		current_music = 1
	end
end

function apTogglePlay()
	if apRadio.job then
		-- Идёт подключение к станции: второй раз не открываем.
	elseif apRadio.handle then
		local state = apRadioState()
		if state == 1 then
			icon_play_pause = fa.ICON_FA_PLAY
			apRadioPause()
		elseif state == 2 then
			icon_play_pause = fa.ICON_FA_PAUSE
			apRadioResume()
		else
			apPlayStation()
		end
	elseif not audioStream then
		if currentPage == 2 and #musics > 0 then
			apPlayTrack()
		elseif currentPage == 1 then
			apPlayStation()
		end
	else
		local state = getAudioStreamState(audioStream)
		if state == 2 then
			icon_play_pause = fa.ICON_FA_PAUSE
			setAudioStreamState(audioStream, as_action.RESUME)
		elseif state == -1 then
			icon_play_pause = fa.ICON_FA_PAUSE
			setAudioStreamState(audioStream, as_action.PLAY)
			apStoppedByUser = false
		elseif state == 1 then
			icon_play_pause = fa.ICON_FA_PLAY
			setAudioStreamState(audioStream, as_action.PAUSE)
		end
	end
end

function apStop()
	apStoppedByUser = true
	apReleaseStream()
	icon_play_pause = fa.ICON_FA_PLAY
end

function apToggleRepeat()
	music_repeat.v = not music_repeat.v
	data.music.rep = music_repeat.v
	inicfg.save(data, cfgpath)
end

function apPrevTrack()
	if musics[current_music-1] then
		current_music = current_music - 1
	else
		current_music = #musics
	end
	apPlayTrack()
end

function apNextTrack()
	if musics[current_music+1] then
		current_music = current_music + 1
	else
		current_music = 1
	end
	apPlayTrack()
end

-- Громкость 0..1: сразу в играющий поток; в ini сохраняется, когда отпущена кнопка мыши (см. src/view.lua).
function apSetVolume(value)
	volume_player.v = value
	if audioStream then
		setAudioStreamVolume(audioStream, volume_player.v)
	end
	apRadioVolume(volume_player.v)
	data.music.volume = math.floor(volume_player.v * 100 + 0.5)
	apVolumeDirty = true
end

-- Что сейчас источник: треки (играет или выбран трек из папки) или радио.
function apSourceIsTracks()
	return #musics > 0 and (apStreamIsTrack or (currentPage == 2 and not apRadio.job and not apRadio.handle))
end

-- Предыдущий / следующий: для треков - как раньше, для радио - соседняя станция списка.
function apStep(step)
	if apSourceIsTracks() then
		if step < 0 then apPrevTrack() else apNextTrack() end
	else
		current_radio.v = APLogic.wrapIndex(current_radio.v + 1, step, #radiolist) - 1
		apPlayStation()
	end
end

-- Строка списка: станция i (как выбор в прежнем выпадающем списке) или трек i.
function apPlayStationAt(i)
	current_radio.v = i - 1
	apPlayStation()
end

function apPlayTrackAt(i)
	current_music = i
	apPlayTrack()
end

-- Избранные станции: адреса потоков в data.music.favorites.
local apFavorites = {}
function apIsFavorite(i)
	local station = radio_stations[i]
	return station and apFavorites[station[2]] or false
end

function apToggleFavorite(i)
	local station = radio_stations[i]
	if not station then return end
	apFavorites[station[2]] = not apFavorites[station[2]] or nil
	data.music.favorites = APLogic.favText(apFavorites)
	inicfg.save(data, cfgpath)
end

function apLoadFavorites()
	apFavorites = APLogic.favParse(data.music.favorites)
end

local function apKeyName(code)
	if code == 0 then return 'не задана' end
	return require('vkeys').id_to_name(code) or tostring(code)
end

-- Строка настройки клавиши окна: текущая клавиша, «Назначить» и «Сбросить» (к F12).
local function apDrawKeyRow()
	local key = tonumber(data.window.key) or 0
	local spacing = imgui.GetStyle().ItemSpacing.x
	APUI.label(u8'Клавиша окна')
	imgui.SameLine()
	if apKeyCapture then
		APUI.label(u8'Нажмите клавишу (Esc - отмена)', APUI.colors.muted)
		return
	end
	APUI.label(u8(apKeyName(key)), APUI.colors.muted)
	local setLabel = u8'Назначить'
	local resetLabel = u8'Сбросить'
	local buttonsWidth = APUI.buttonWidth(setLabel)
	if key ~= DEFAULT_KEY then buttonsWidth = buttonsWidth + spacing + APUI.buttonWidth(resetLabel) end
	APUI.alignRight(buttonsWidth)
	if APUI.button(setLabel..'##apkey') then apKeyCapture = true end
	if key ~= DEFAULT_KEY then
		imgui.SameLine()
		if APUI.button(resetLabel..'##apkeyreset') then
			data.window.key = DEFAULT_KEY
			inicfg.save(data, cfgpath)
		end
	end
end

APUI.applyStyle()

-- Мини-режим может висеть на экране без курсора, пока игрок ездит и играет: тогда окно не ловит мышь,
-- а кнопки «Полное окно» и «Закрыть» спрятаны. apMiniCursor - курсор, включённый клавишей окна.
apMiniCursor = true
local apPinnedHintShown = false

function apIsMini()
	return data ~= nil and (data.window.mini == true or data.window.mini == 'true')
end

-- Можно ли сейчас нажимать кнопки мини-плеера: свой курсор или курсор SA-MP (диалог, другой скрипт).
function apCursorOn()
	if not apIsMini() or apMiniCursor then return true end
	local ok, active = pcall(sampIsCursorActive)
	return ok and active == true
end

local function apPinCursorOff()
	apMiniCursor = false
	if not apPinnedHintShown then
		apPinnedHintShown = true
		local key = tonumber(data.window.key) or 0
		APUI.notify('Плеер остаётся на экране.\nКнопки: ' .. (key ~= 0 and (apKeyName(key) .. ' или ') or '') .. '/aplayer.', 5)
	end
end

-- Клавиша окна и /aplayer: открыть или закрыть окно; у открытого мини-плеера - включить или убрать курсор.
function apHotkey()
	if apWindow.v and apIsMini() then
		if apMiniCursor then apPinCursorOff() else apMiniCursor = true end
	else
		apWindow.v = not apWindow.v
		apMiniCursor = true
	end
end

function onWindowMessage(msg, wparam, lparam)
	if msg ~= 0x100 then return end -- WM_KEYDOWN
	if apKeyCapture then
		if not apWindow.v or not data then
			apKeyCapture = false
		else
			consumeWindowMessage(true, false)
			if wparam == VK_ESCAPE then
				apKeyCapture = false
			elseif APLogic.isBindableKey(wparam) then
				data.window.key = wparam
				inicfg.save(data, cfgpath)
				apKeyCapture = false
			else
				APUI.notify('Эту клавишу назначить нельзя.\nВыберите другую или нажмите Esc.', 4)
			end
			return
		end
	end
	-- Esc закрывает окно; у мини-плеера только убирает курсор (полоска остаётся). Без курсора Esc - игре.
	if wparam == VK_ESCAPE and apWindow.v and (not apIsMini() or apMiniCursor)
		and not isPauseMenuActive() and not sampIsChatInputActive() and not sampIsDialogActive() then
		consumeWindowMessage(true, false)
		if apIsMini() then apPinCursorOff() else apWindow.v = false end
		return
	end
	local key = tonumber(data and data.window and data.window.key) or 0
	local repeated = math.floor(lparam / 0x40000000) % 2 == 1 -- бит 30: клавиша уже была нажата (автоповтор)
	if key ~= 0 and wparam == key and not repeated and not (apWindow.v and imgui.GetIO().WantTextInput)
		and not sampIsChatInputActive() and not sampIsDialogActive() and not isPauseMenuActive() then
		apHotkey()
	end
end

-- Пока играет музыка плеера, звук, который включает сервер, не запускается (как в SNHelper).
function hook.onPlayAudioStream()
	if (audioStream and getAudioStreamState(audioStream) == 1) or apRadioState() == 1 then
		return false
	end
end

-- Ключи положения окна в ini: у полного окна posX/posY, у мини-плеера свои miniX/miniY.
function apPosKeys(mini)
	if mini then return 'miniX', 'miniY' end
	return 'posX', 'posY'
end

-- Запомнить положение окна для текущего режима.
local function apSaveWindowPos()
	if not data or not apWindowPos then return end
	local kx, ky = apPosKeys(apIsMini())
	if apWindowPos.x ~= tonumber(data.window[kx]) or apWindowPos.y ~= tonumber(data.window[ky]) then
		data.window[kx], data.window[ky] = apWindowPos.x, apWindowPos.y
		inicfg.save(data, cfgpath)
	end
end

-- Переключить мини-режим: положение уходящего режима запоминается, курсор остаётся.
function apSetMini(on)
	apSaveWindowPos()
	data.window.mini = on
	apMiniCursor = true
	inicfg.save(data, cfgpath)
end

function onScriptTerminate(script, quitGame)
	if script ~= thisScript() then return end
	apRadioFree() -- поток станции открыт не через MoonLoader, сам он его не освободит
	apSaveWindowPos()
end

function main()
	while not isSampAvailable() do wait(100) end
	data = inicfg.load({
		music = {
			path = 'C:\\Users\\User\\Music',
			rep = false,
			volume = 100,
			favorites = '', -- избранные станции: адреса потоков через «|»
		},
		window = {
			key = DEFAULT_KEY,
			posX = -1, -- левый верхний угол окна; -1 - по центру экрана
			posY = -1,
			miniX = -1, -- то же для мини-плеера; -1 - там, где было полное окно
			miniY = -1,
			mini = false, -- мини-режим: узкая полоска с названием и кнопками
		},
	}, cfgpath)
	music_repeat.v = data.music.rep == true or data.music.rep == 'true'
	volume_player.v = (tonumber(data.music.volume) or 100) / 100
	apStoppedByUser = false
	apStreamIsTrack = false
	apLastRestart = 0
	musicpath.v = u8(tostring(data.music.path))
	apLoadFavorites()
	apLoadFolderQuiet()
	sampRegisterChatCommand('aplayer', function()
		apHotkey()
	end)
	local key = tonumber(data.window.key) or 0
	sampAddChatMessage('Audio Player | {FFFFFF}Аудиоплеер загружен. Окно: /aplayer' .. (key ~= 0 and (' или клавиша ' .. apKeyName(key)) or '') .. '.', 0xC0C0C0)
	local wasOpen = false
	while true do
		wait(0)
		apRadioPoll()
		apViewTick()
		-- Повтор трека: поток есть, повтор включён, пользователь не нажимал Stop, не чаще раза в секунду.
		if audioStream and apStreamIsTrack and not apStoppedByUser and musics[current_music] then
			local state = getAudioStreamState(audioStream)
			if state == -1 or state == as_action.STOP then
				if music_repeat.v then
					if os.clock() - (apLastRestart or 0) >= 1 then
						apPlayTrack()
					end
				else
					apReleaseStream()
					icon_play_pause = fa.ICON_FA_PLAY
					apStoppedByUser = true
				end
			end
		end
		imgui.Process = apWindow.v or APUI.toastsActive()
		imgui.ShowCursor = apWindow.v and (not apIsMini() or apMiniCursor)
		if wasOpen and not apWindow.v then
			apKeyCapture = false
			apSaveWindowPos()
		end
		wasOpen = apWindow.v
	end
end
-- Окно плеера. Файл идёт в склейке после main.lua: состояние (musics, current_radio, audioStream...) и
-- действия (apTogglePlay, apStep, apSetVolume...) берутся оттуда. Здесь только отрисовка и то, что
-- окно показывает: название, состояние, время трека.
--
-- Окно (сверху вниз): заголовок с кнопками (клавиша, мини-режим, закрыть); строка настройки клавиши
-- (по кнопке); карточка «Сейчас играет» (обложка-значок, название, состояние, индикатор-эквалайзер);
-- время трека или метка «Прямой эфир»; ряд управления (повтор, предыдущий, играть/пауза, следующий,
-- стоп) и громкость; вкладки «Радио» / «Мои треки»; папка с музыкой (на вкладке треков); поиск; список.
-- Мини-режим: одна полоска с обложкой, названием, кнопками и возвратом к полному окну.
--
-- Пары ImGui: каждый Push* снимается в той же функции и том же окне; ранних выходов между ними нет.

local V2, V4 = imgui.ImVec2, imgui.ImVec4
local FULL_W, MINI_W = 440, 380
local LIST_ROWS = 6
local apView = {
	openT = nil, settings = false, eqT = 0, eqBars = nil,
	search = { imgui.ImBuffer('', 64), imgui.ImBuffer('', 64) },
}
-- Что показывает окно: ошибка подключения, время трека, длина трека (см. apViewTick).
local apNow = { wasLoading = false, error = nil, track = {}, lengthKey = nil, length = nil }

local function u32(color)
	return imgui.GetColorU32(color)
end

local function withAlpha(color, alpha)
	return V4(color.x, color.y, color.z, color.w * alpha)
end

-- Каждый кадр из main(): заметить, что станция не подключилась, посчитать время трека, узнать его длину.
function apViewTick()
	if apRadio.job then
		apNow.wasLoading = true
		apNow.error = nil
	elseif apNow.wasLoading then
		apNow.wasLoading = false
		if not apRadio.handle and not audioStream then apNow.error = 'Станция не подключилась' end
	end
	if apRadio.handle or audioStream then apNow.error = nil end
	local key = (apStreamIsTrack and audioStream) or nil
	local playing = key ~= nil and getAudioStreamState(audioStream) == 1
	APLogic.elapsedStep(apNow.track, key, playing, os.clock())
	if key ~= apNow.lengthKey then
		apNow.lengthKey, apNow.length = key, nil
		if key then
			-- Длина в секундах; странное значение (0, больше 10 часов) - длина неизвестна.
			local ok, length = pcall(getAudioStreamLength, audioStream)
			length = ok and tonumber(length) or nil
			if length and length > 0 and length < 36000 then apNow.length = length end
		end
	end
end

-- Что играет: название (UTF-8), состояние для APLogic.playerStatus, радио ли это.
local function apNowPlaying()
	local loading = apRadioLoadingSeconds()
	local state = -1
	if apRadio.handle then
		state = apRadioState()
	elseif audioStream then
		state = getAudioStreamState(audioStream)
	end
	local title, isRadio
	if apRadio.job then
		title, isRadio = u8(apRadio.job.name), true
	elseif apStreamIsTrack and musics[current_music] then
		title, isRadio = u8(APLogic.trackTitle(musics[current_music])), false
	elseif apRadio.handle or audioStream then
		title, isRadio = radiolist[current_radio.v + 1] or '', true
	end
	local kind, text = APLogic.playerStatus({ loading = loading, error = apNow.error, state = state })
	if not title then
		title = u8'Ничего не играет'
		if kind == 'stopped' then text = 'Выберите станцию или трек' end
		isRadio = currentPage == 1
	end
	return title, kind, u8(text), isRadio
end

-- Круглая кнопка со значком в ячейке diameter x boxH (круг по центру высоты: кнопки разного размера
-- в одном ряду стоят по одной средней линии). kind: nil, 'primary' (акцент, значок крупным шрифтом),
-- 'on' / 'off' (переключатель: значок акцентный или погашенный).
local function apRoundButton(id, icon, diameter, kind, boxH)
	local C = APUI.colors
	boxH = boxH or diameter
	local pos = imgui.GetCursorScreenPos()
	local pressed = imgui.InvisibleButton('##round' .. id, V2(diameter, boxH))
	pos = V2(pos.x, pos.y + (boxH - diameter) / 2)
	local hover = APUI.animate('round:' .. id, imgui.IsItemHovered() and 1 or 0, 16)
	local base, over, textColor = C.control, C.controlHover, C.text
	if kind == 'primary' then
		base, over, textColor = C.accent, C.accentSoft, C.white
	elseif kind == 'on' then
		textColor = C.accentSoft
	elseif kind == 'off' then
		base, over, textColor = C.clear, C.control, C.faint
	end
	local center = V2(pos.x + diameter / 2, pos.y + diameter / 2)
	local drawList = imgui.GetWindowDrawList()
	drawList:AddCircleFilled(center, diameter / 2, u32(APUI.mix(base, over, hover)), 32)
	local large = kind == 'primary' and APUI.fontLarge
	if large then imgui.PushFont(APUI.fontLarge) end
	local size = imgui.CalcTextSize(icon)
	-- Значок «играть» визуально левее центра: сдвиг на 1/12 диаметра.
	local nudge = (icon == fa.ICON_FA_PLAY) and diameter / 12 or 0
	drawList:AddText(V2(center.x - size.x / 2 + nudge, center.y - size.y / 2), u32(textColor), icon)
	if large then imgui.PopFont() end
	return pressed
end

-- Индикатор-эквалайзер: count столбиков в прямоугольнике (x, y, w, h). Пока звук идёт, столбики
-- двигаются; на паузе замирают; без звука лежат внизу и гаснут.
local function apDrawEq(drawList, x, y, w, h, kind, count)
	local C = APUI.colors
	local dt = imgui.GetIO().DeltaTime
	if kind == 'playing' then apView.eqT = apView.eqT + dt end
	local target = APLogic.eqBars(apView.eqT, count)
	local alive = (kind == 'playing' or kind == 'paused') and 1 or 0
	local glow = APUI.animate('eq:alive', alive, 6)
	local gap = 3
	local barW = (w - gap * (count - 1)) / count
	for i = 1, count do
		local value = APUI.animate('eq:' .. i, alive == 1 and target[i] or 0.15, 18)
		local barH = math.max(3, h * value)
		local left = x + (i - 1) * (barW + gap)
		drawList:AddRectFilled(V2(left, y + h - barH), V2(left + barW, y + h),
			u32(APUI.mix(C.faint, C.accentSoft, glow)), 2)
	end
end

-- Карточка «Сейчас играет».
local function apDrawNowCard(width)
	local C = APUI.colors
	local title, kind, status, isRadio = apNowPlaying()
	local pad, art = 12, 56
	local eqW, eqH = 46, 28
	local height = art + pad * 2
	imgui.PushStyleColor(imgui.Col.ChildWindowBg, C.card)
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, V2(pad, pad))
	imgui.BeginChild('apnow', V2(width, height), false, imgui.WindowFlags.AlwaysUseWindowPadding + imgui.WindowFlags.NoScrollbar)
		local drawList = imgui.GetWindowDrawList()
		local pos = imgui.GetCursorScreenPos()
		-- Обложка: акцентный квадрат со значком станции или трека.
		imgui.Dummy(V2(art, art))
		drawList:AddRectFilled(pos, V2(pos.x + art, pos.y + art), u32(C.navActive), 10)
		drawList:AddRectFilled(V2(pos.x + 4, pos.y + 4), V2(pos.x + art - 4, pos.y + art - 4), u32(withAlpha(C.accent, 0.85)), 8)
		if APUI.fontLarge then imgui.PushFont(APUI.fontLarge) end
		local icon = isRadio and fa.ICON_FA_BROADCAST_TOWER or fa.ICON_FA_MUSIC
		local iconSize = imgui.CalcTextSize(icon)
		drawList:AddText(V2(pos.x + (art - iconSize.x) / 2, pos.y + (art - iconSize.y) / 2), u32(C.white), icon)
		if APUI.fontLarge then imgui.PopFont() end
		-- Название (крупно) и строка состояния справа от обложки, вместе по центру её высоты.
		local textX = pos.x + art + 14
		local textW = width - pad * 2 - art - 14 - eqW - 10
		local largeH = APUI.fontLarge and 21 or imgui.GetTextLineHeight()
		local lineH = imgui.GetTextLineHeight()
		local top = pos.y + (art - largeH - 4 - lineH) / 2
		local titleColor = (kind == 'stopped' and not apRadio.handle and not audioStream) and C.muted or C.white
		if APUI.fontLarge then imgui.PushFont(APUI.fontLarge) end
		drawList:AddText(V2(textX, top), u32(titleColor), apFitText(title, textW))
		if APUI.fontLarge then imgui.PopFont() end
		local statusColor = C.muted
		if kind == 'playing' then statusColor = C.accentSoft elseif kind == 'error' then statusColor = C.danger end
		local dot = kind == 'error' and fa.ICON_FA_EXCLAMATION_CIRCLE or (kind == 'loading' and fa.ICON_FA_CIRCLE_NOTCH or fa.ICON_FA_CIRCLE)
		drawList:AddText(V2(textX, top + largeH + 4), u32(statusColor), apFitText(dot .. ' ' .. status, textW))
		-- Эквалайзер у правого края, по центру высоты обложки.
		local eqX = pos.x + width - pad * 2 - eqW
		apDrawEq(drawList, eqX, pos.y + (art - eqH) / 2, eqW, eqH, kind, 6)
	imgui.EndChild()
	imgui.PopStyleVar()
	imgui.PopStyleColor()
end

-- Время трека: «прошло», полоса, «всего». Для радио - метка «Прямой эфир». Перемотки нет: MoonLoader
-- не даёт ни узнать, ни поменять позицию в потоке трека.
local function apDrawTimeline(width)
	local C = APUI.colors
	local h = imgui.GetTextLineHeight()
	local pos = imgui.GetCursorScreenPos()
	imgui.Dummy(V2(width, h))
	local drawList = imgui.GetWindowDrawList()
	if apStreamIsTrack and audioStream then
		local elapsed = apNow.track.elapsed or 0
		local left = APLogic.formatTime(elapsed)
		local right = apNow.length and APLogic.formatTime(apNow.length) or '--:--'
		local leftW, rightW = imgui.CalcTextSize(left).x, imgui.CalcTextSize(right).x
		local barX0, barX1 = pos.x + leftW + 10, pos.x + width - rightW - 10
		local barY = pos.y + h / 2
		drawList:AddText(pos, u32(C.muted), left)
		drawList:AddText(V2(pos.x + width - rightW, pos.y), u32(C.muted), right)
		drawList:AddRectFilled(V2(barX0, barY - 2), V2(barX1, barY + 2), u32(C.switchOff), 2)
		local fraction = APLogic.progress(elapsed, apNow.length)
		if fraction then
			local fillX = barX0 + (barX1 - barX0) * APUI.animate('ap:progress', fraction, 10)
			drawList:AddRectFilled(V2(barX0, barY - 2), V2(fillX, barY + 2), u32(C.accent), 2)
			drawList:AddCircleFilled(V2(fillX, barY), 5, u32(C.white), 16)
		end
	elseif apRadio.handle or apRadio.job or audioStream then
		local live = fa.ICON_FA_CIRCLE .. u8'  Прямой эфир'
		local liveW = imgui.CalcTextSize(live).x
		local playing = apRadio.handle and apRadioState() == 1
		drawList:AddText(V2(pos.x + (width - liveW) / 2, pos.y), u32(playing and C.danger or C.muted), live)
	end
end

-- Громкость своей отрисовки: значок, дорожка, заливка, ручка в ячейке width x h. Тянуть можно, если
-- нажатие началось на дорожке (не на значке).
local function apVolume(width, h)
	local C = APUI.colors
	local knob = 6
	local level = APLogic.volumeIcon(volume_player.v)
	local icon = level == 'off' and fa.ICON_FA_VOLUME_OFF or (level == 'down' and fa.ICON_FA_VOLUME_DOWN or fa.ICON_FA_VOLUME_UP)
	local iconW = imgui.CalcTextSize(fa.ICON_FA_VOLUME_UP).x
	local pos = imgui.GetCursorScreenPos()
	imgui.InvisibleButton('##apvolume', V2(width, h))
	local active, hovered = imgui.IsItemActive(), imgui.IsItemHovered()
	local x0, x1 = pos.x + iconW + 8 + knob, pos.x + width - knob
	local mouseX = imgui.GetMousePos().x
	if not active then
		apView.volDrag = false
	elseif not apView.volDrag and mouseX >= x0 - knob then
		apView.volDrag = true
	end
	if apView.volDrag then
		local value = APLogic.volumeFromX(mouseX, x0, x1 - x0)
		if math.abs(value - volume_player.v) > 0.0005 then apSetVolume(value) end
	end
	if apVolumeDirty and not imgui.IsMouseDown(0) then
		apVolumeDirty = false
		inicfg.save(data, cfgpath)
	end
	if hovered then imgui.Hint(u8('Громкость ' .. math.floor(volume_player.v * 100 + 0.5) .. ' %')) end
	local grow = APUI.animate('ap:volume', (apView.volDrag or hovered) and 1 or 0, 16)
	local drawList = imgui.GetWindowDrawList()
	local y = pos.y + h / 2
	drawList:AddText(V2(pos.x, y - imgui.GetTextLineHeight() / 2), u32(APUI.mix(C.muted, C.text, grow)), icon)
	local x = x0 + (x1 - x0) * volume_player.v
	drawList:AddRectFilled(V2(x0, y - 2), V2(x1, y + 2), u32(C.switchOff), 2)
	drawList:AddRectFilled(V2(x0, y - 2), V2(x, y + 2), u32(APUI.mix(C.accent, C.accentSoft, grow)), 2)
	drawList:AddCircleFilled(V2(x, y), knob + grow, u32(C.white), 16)
end

-- Ряд управления: кнопки по центру своей части, громкость справа. Все элементы ряда - одной высоты big.
local function apDrawControls(width)
	local gap = imgui.GetStyle().ItemSpacing.x
	local small, big = APUI.frameHeight() + 4, math.floor(APUI.frameHeight() * 1.6)
	local volumeW = 140
	local buttonsW = small * 4 + big + gap * 4
	local areaW = width - volumeW - gap
	local rowX = imgui.GetCursorPosX()
	local tracks = apSourceIsTracks()
	imgui.SetCursorPosX(rowX + math.max(0, (areaW - buttonsW) / 2))
	if apRoundButton('repeat', fa.ICON_FA_REDO, small, music_repeat.v and 'on' or 'off', big) then apToggleRepeat() end
	imgui.Hint(u8(music_repeat.v and 'Повтор трека: включён' or 'Повтор трека: выключен'))
	imgui.SameLine()
	if apRoundButton('prev', fa.ICON_FA_STEP_BACKWARD, small, nil, big) then apStep(-1) end
	imgui.Hint(u8(tracks and 'Предыдущий трек' or 'Предыдущая станция'))
	imgui.SameLine()
	if apRoundButton('play', icon_play_pause, big, 'primary') then apTogglePlay() end
	imgui.Hint(u8'Играть / Пауза')
	imgui.SameLine()
	if apRoundButton('next', fa.ICON_FA_STEP_FORWARD, small, nil, big) then apStep(1) end
	imgui.Hint(u8(tracks and 'Следующий трек' or 'Следующая станция'))
	imgui.SameLine()
	if apRoundButton('stop', fa.ICON_FA_STOP, small, nil, big) then
		apNow.error = nil
		apStop()
	end
	imgui.Hint(u8'Стоп')
	imgui.SameLine(rowX + width - volumeW)
	apVolume(volumeW, big)
end

-- Строка списка: номер или значок играющей, название, звёздочка (для станций). Возвращает нажатие по
-- строке и по звёздочке.
local function apListRow(id, i, text, width, active, playing, star)
	local C = APUI.colors
	local h = APUI.frameHeight()
	local pos = imgui.GetCursorScreenPos()
	local starW = star ~= nil and h or 0
	local pressed = imgui.InvisibleButton('##' .. id .. i, V2(math.max(1, width - starW), h))
	local hovered = imgui.IsItemHovered()
	if hovered then imgui.Hint(text, 0.6) end
	local starPressed, starHover = false, false
	if star ~= nil then
		imgui.SameLine(0, 0)
		starPressed = imgui.InvisibleButton('##star' .. id .. i, V2(starW, h))
		starHover = imgui.IsItemHovered()
		if starHover then imgui.Hint(u8(star and 'Убрать из избранного' or 'В избранное')) end
	end
	local glow = APUI.animate('row:' .. id .. i, (hovered or starHover) and 1 or 0, 16)
	local drawList = imgui.GetWindowDrawList()
	local corner = V2(pos.x + width, pos.y + h)
	if active then
		drawList:AddRectFilled(pos, corner, u32(APUI.mix(C.navActive, C.controlHover, glow * 0.5)), 6)
		drawList:AddRectFilled(V2(pos.x, pos.y + 6), V2(pos.x + 3, pos.y + h - 6), u32(C.accent), 2)
	elseif glow > 0.01 then
		drawList:AddRectFilled(pos, corner, u32(withAlpha(C.control, glow)), 6)
	end
	local lineY = pos.y + (h - imgui.GetTextLineHeight()) / 2
	local mark = active and (playing and fa.ICON_FA_VOLUME_UP or fa.ICON_FA_PAUSE) or tostring(i)
	local markColor = active and C.accentSoft or C.faint
	drawList:AddText(V2(pos.x + 10, lineY), u32(markColor), mark)
	local textX = pos.x + 40
	local textW = width - 40 - starW - 8
	drawList:AddText(V2(textX, lineY), u32(active and C.white or APUI.mix(C.text, C.white, glow)), apFitText(text, textW))
	if star ~= nil then
		local starIcon = fa.ICON_FA_STAR
		local starSize = imgui.CalcTextSize(starIcon)
		local starColor = star and C.accentSoft or (starHover and C.muted or withAlpha(C.faint, 0.6 + 0.4 * glow))
		drawList:AddText(V2(pos.x + width - starW + (starW - starSize.x) / 2, lineY), u32(starColor), starIcon)
	end
	return pressed, starPressed
end

-- Поле поиска: подсказка «Поиск» внутри пустого поля.
local function apSearchField(buffer, width)
	local C = APUI.colors
	local pos = imgui.GetCursorScreenPos()
	imgui.PushItemWidth(width)
		imgui.InputText('##apsearch' .. currentPage, buffer)
	imgui.PopItemWidth()
	if buffer.v == '' and not imgui.IsItemActive() then
		local pad = imgui.GetStyle().FramePadding
		imgui.GetWindowDrawList():AddText(V2(pos.x + pad.x, pos.y + pad.y), u32(C.faint), fa.ICON_FA_SEARCH .. u8'  Поиск по названию')
	end
end

-- Пустой список: приглушённая строка.
local function apEmpty(text)
	imgui.Dummy(V2(0, 4))
	imgui.TextDisabled(text)
end

-- Список станций или треков в панели высотой height.
local function apDrawList(width, height)
	local C = APUI.colors
	local query = apView.search[currentPage].v
	imgui.PushStyleColor(imgui.Col.ChildWindowBg, C.field)
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, V2(6, 6))
	imgui.BeginChild('aplist' .. currentPage, V2(width, height), false, imgui.WindowFlags.AlwaysUseWindowPadding)
		imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, V2(0, 2))
		local rowW = imgui.GetWindowContentRegionWidth()
		if currentPage == 1 then
			local fav = {}
			for i = 1, #radio_stations do fav[i] = apIsFavorite(i) end
			local order = APLogic.listOrder(radiolist, query, fav)
			local stationOn = apRadio.job or apRadio.handle or (audioStream and not apStreamIsTrack)
			for _, i in ipairs(order) do
				local active = stationOn and current_radio.v + 1 == i
				local playing = active and (apRadio.job ~= nil or (apRadio.handle and apRadioState() == 1)
					or (audioStream ~= nil and getAudioStreamState(audioStream) == 1))
				local pressed, starPressed = apListRow('st', i, radiolist[i], rowW, active, playing, fav[i])
				if starPressed then
					apToggleFavorite(i)
				elseif pressed then
					apNow.error = nil
					apPlayStationAt(i)
				end
			end
			if #order == 0 then apEmpty(u8'Ничего не найдено.') end
		else
			if results and results ~= '' then
				imgui.PushTextWrapPos(0)
				imgui.TextColored(C.danger, u8(results))
				imgui.PopTextWrapPos()
			end
			if #musics == 0 then
				imgui.Dummy(V2(0, 4))
				imgui.TextColored(C.text, u8'В папке нет треков')
				imgui.PushTextWrapPos(0)
				imgui.TextColored(C.muted, musicpath.v ~= '' and musicpath.v or u8'Папка не выбрана')
				imgui.TextColored(C.faint, u8'Укажите папку с файлами mp3 выше и нажмите «Выбор».')
				imgui.PopTextWrapPos()
				if APUI.button(fa.ICON_FA_SYNC_ALT .. u8' Обновить список##aprescan') then apScanFolder() end
			else
				local names = {}
				for i, file in ipairs(musics) do names[i] = u8(APLogic.trackTitle(file)) end
				local order = APLogic.listOrder(names, query)
				for _, i in ipairs(order) do
					local active = apStreamIsTrack and audioStream ~= nil and current_music == i
					local playing = active and getAudioStreamState(audioStream) == 1
					if apListRow('tr', i, names[i], rowW, active, playing, nil) then apPlayTrackAt(i) end
				end
				if #order == 0 then apEmpty(u8'Ничего не найдено.') end
			end
		end
		imgui.PopStyleVar()
	imgui.EndChild()
	imgui.PopStyleVar()
	imgui.PopStyleColor()
end

-- Строка папки с музыкой: поле и «Выбор» (как раньше).
local function apDrawFolderRow(width)
	local spacing = imgui.GetStyle().ItemSpacing.x
	local selectLabel = fa.ICON_FA_FOLDER_OPEN .. u8' Выбор'
	imgui.PushItemWidth(width - spacing - APUI.buttonWidth(selectLabel))
		imgui.InputText('##musicpath', musicpath)
	imgui.PopItemWidth()
	imgui.Hint(u8'Папка с музыкой (mp3)')
	imgui.SameLine()
	if APUI.button(selectLabel .. '##musicpathselect') then apScanFolder() end
end

-- Кнопки-значки заголовка справа: клавиша, мини-режим, закрыть. x0 - левый край содержимого.
local function apHeaderButtons(x0, width, mini)
	local gap = imgui.GetStyle().ItemSpacing.x
	local keyIcon, modeIcon, closeIcon = fa.ICON_FA_KEYBOARD, mini and fa.ICON_FA_EXPAND or fa.ICON_FA_COMPRESS, fa.ICON_FA_TIMES
	local total = APUI.buttonWidth(modeIcon) + APUI.buttonWidth(closeIcon) + gap
	if not mini then total = total + APUI.buttonWidth(keyIcon) + gap end
	imgui.SameLine(x0 + width - total)
	if not mini then
		if APUI.button(keyIcon .. '##apsettings', apView.settings and 'primary' or nil) then apView.settings = not apView.settings end
		imgui.Hint(u8'Клавиша окна')
		imgui.SameLine()
	end
	if APUI.button(modeIcon .. '##apmode') then apSetMini(not mini) end
	imgui.Hint(u8(mini and 'Полное окно' or 'Мини-режим'))
	imgui.SameLine()
	if APUI.button(closeIcon .. '##apclose') then apWindow.v = false end
	imgui.Hint(u8'Закрыть (Esc)')
end

local function apDrawFull(x0, width)
	local C = APUI.colors
	APUI.label(fa.ICON_FA_HEADPHONES, C.accentSoft)
	imgui.SameLine()
	APUI.label(u8'Аудиоплеер', C.white)
	apHeaderButtons(x0, width, false)
	if apView.settings then apDrawKeyRow() end
	apDrawNowCard(width)
	apDrawTimeline(width)
	apDrawControls(width)
	imgui.Dummy(V2(0, 2))
	currentPage = APUI.tabs('apsrc', { fa.ICON_FA_BROADCAST_TOWER .. u8' Радио', fa.ICON_FA_FOLDER_OPEN .. u8' Мои треки' }, currentPage)
	local rowStep = APUI.frameHeight() + imgui.GetStyle().ItemSpacing.y
	local listH = LIST_ROWS * (APUI.frameHeight() + 2) + 12
	if currentPage == 2 then
		apDrawFolderRow(width)
	else
		listH = listH + rowStep -- без строки папки список выше: окно не меняет высоту при смене вкладки
	end
	apSearchField(apView.search[currentPage], width)
	apDrawList(width, listH)
end

-- Квадратная кнопка-значок высоты кнопки темы по центру ячейки width x boxH (для ряда мини-режима).
local function apBoxButton(id, icon, boxH)
	local C = APUI.colors
	local h = APUI.frameHeight()
	local w = APUI.buttonWidth(icon)
	local pos = imgui.GetCursorScreenPos()
	local pressed = imgui.InvisibleButton('##box' .. id, V2(w, boxH))
	local hover = APUI.animate('box:' .. id, imgui.IsItemHovered() and 1 or 0, 16)
	local top = pos.y + (boxH - h) / 2
	local drawList = imgui.GetWindowDrawList()
	drawList:AddRectFilled(V2(pos.x, top), V2(pos.x + w, top + h), u32(APUI.mix(C.control, C.controlHover, hover)), imgui.GetStyle().FrameRounding)
	local size = imgui.CalcTextSize(icon)
	drawList:AddText(V2(pos.x + (w - size.x) / 2, top + (h - size.y) / 2), u32(C.text), icon)
	return pressed
end

-- Мини-режим: один ряд высоты rowH. Обложка, текст (две строки блоком), круглые и квадратные кнопки -
-- каждый элемент занимает ячейку высоты rowH и рисуется по её вертикальной середине, поэтому поля окна
-- сверху и снизу одинаковые.
local function apDrawMini(x0, width)
	local C = APUI.colors
	local title, kind, status, isRadio = apNowPlaying()
	local gap = imgui.GetStyle().ItemSpacing.x
	local small = APUI.frameHeight() + 4
	local lineH = imgui.GetTextLineHeight()
	local textH = lineH * 2 + 4
	local rowH = math.max(small, textH)
	local art = small
	local expandIcon, closeIcon = fa.ICON_FA_EXPAND, fa.ICON_FA_TIMES
	-- Без курсора кнопки «Полное окно» и «Закрыть» не нужны: их место отдаётся названию.
	local withBox = apCursorOn()
	local buttonsW = small * 3 + gap * 2
	if withBox then buttonsW = buttonsW + APUI.buttonWidth(expandIcon) + APUI.buttonWidth(closeIcon) + gap * 2 end
	local textW = width - art - gap - buttonsW - gap
	local drawList = imgui.GetWindowDrawList()
	-- Обложка.
	local pos = imgui.GetCursorScreenPos()
	imgui.Dummy(V2(art, rowH))
	local top = pos.y + (rowH - art) / 2
	drawList:AddRectFilled(V2(pos.x, top), V2(pos.x + art, top + art), u32(withAlpha(C.accent, 0.85)), 8)
	local icon = isRadio and fa.ICON_FA_BROADCAST_TOWER or fa.ICON_FA_MUSIC
	local iconSize = imgui.CalcTextSize(icon)
	drawList:AddText(V2(pos.x + (art - iconSize.x) / 2, top + (art - iconSize.y) / 2), u32(C.white), icon)
	-- Название и состояние блоком по середине ряда.
	imgui.SameLine()
	pos = imgui.GetCursorScreenPos()
	imgui.Dummy(V2(math.max(1, textW), rowH))
	local textTop = pos.y + (rowH - textH) / 2
	local statusColor = kind == 'playing' and C.accentSoft or (kind == 'error' and C.danger or C.muted)
	drawList:AddText(V2(pos.x, textTop), u32(C.white), apFitText(title, textW))
	drawList:AddText(V2(pos.x, textTop + lineH + 4), u32(statusColor), apFitText(status, textW))
	-- Кнопки у правого края.
	imgui.SameLine(x0 + width - buttonsW)
	local tracks = apSourceIsTracks()
	if apRoundButton('mprev', fa.ICON_FA_STEP_BACKWARD, small, nil, rowH) then apStep(-1) end
	imgui.Hint(u8(tracks and 'Предыдущий трек' or 'Предыдущая станция'))
	imgui.SameLine()
	if apRoundButton('mplay', icon_play_pause, small, 'primary', rowH) then apTogglePlay() end
	imgui.Hint(u8'Играть / Пауза')
	imgui.SameLine()
	if apRoundButton('mnext', fa.ICON_FA_STEP_FORWARD, small, nil, rowH) then apStep(1) end
	imgui.Hint(u8(tracks and 'Следующий трек' or 'Следующая станция'))
	if not withBox then return end
	imgui.SameLine()
	if apBoxButton('mexpand', expandIcon, rowH) then apSetMini(false) end
	imgui.Hint(u8'Полное окно')
	imgui.SameLine()
	if apBoxButton('mclose', closeIcon, rowH) then apWindow.v = false end
	imgui.Hint(u8'Закрыть')
end

function imgui.OnDrawFrame()
	APUI.drawToasts()
	if not apWindow.v or not data then
		apView.openT = nil
		apView.placed = nil
		return
	end
	local mini = data.window.mini == true or data.window.mini == 'true'
	local width = mini and MINI_W or FULL_W
	-- Поля окна одинаковые со всех сторон.
	local padX, padY = 16, 16
	if mini then padX, padY = 12, 12 end
	-- У полного окна и мини-плеера свои положения. Окно ставится на место при открытии и при смене
	-- режима, дальше его двигает игрок. Мини-плеер в первый раз появляется там, где было полное окно.
	local mode = mini and 'mini' or 'full'
	if apView.placed ~= mode then
		local kx, ky = apPosKeys(mini)
		local x, y = tonumber(data.window[kx]) or -1, tonumber(data.window[ky]) or -1
		if mini and (x < 0 or y < 0) and apWindowPos then x, y = apWindowPos.x, apWindowPos.y end
		if x < 0 or y < 0 or x > resX - 60 or y > resY - 60 then x, y = math.floor((resX - width) / 2), math.floor(resY / 5) end
		imgui.SetNextWindowPos(imgui.ImVec2(x, y), imgui.Cond.Always)
		apView.placed = mode
	end
	-- Появление окна: прозрачность от 0 до 1 за 0.18 с (как у окна SNHelper).
	apView.openT = math.min(1, (apView.openT or 0) + imgui.GetIO().DeltaTime / 0.18)
	local t = 1 - apView.openT
	if APUI.fontBase then imgui.PushFont(APUI.fontBase) end
	imgui.PushStyleVar(imgui.StyleVar.Alpha, math.max(0.02, 1 - t * t * t))
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(padX, padY))
	local flags = imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
		+ imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.AlwaysAutoResize
	-- Мини-плеер без курсора висит поверх игры: мышь и фокус не забирает, перетащить нельзя.
	if mini and not apCursorOn() then
		flags = flags + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoFocusOnAppearing
	end
	imgui.Begin('##sampaudioplayer', apWindow, flags)
		-- Внутри окна обычный отступ, чтобы отступ окна не достался подсказкам и панелям.
		imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(12, 12))
		local pos = imgui.GetWindowPos()
		apWindowPos = { x = math.floor(pos.x), y = math.floor(pos.y) }
		if mini then apDrawMini(padX, width) else apDrawFull(padX, width) end
		imgui.PopStyleVar()
	imgui.End()
	imgui.PopStyleVar(2)
	if APUI.fontBase then imgui.PopFont() end
end
