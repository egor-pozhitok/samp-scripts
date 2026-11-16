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
script_version_number(1)
script_version('1.0')

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
-- Плеер перенесён из SNHelper без изменений в поведении: те же станции, фоновое подключение к станции,
-- повтор трека, громкость. Свои окно, команда (/aplayer), клавиша (по умолчанию F12) и настройки
-- (moonloader/config/samp-audio-player.ini).
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

-- Панель плеера (вкладки «Станции» и «Плеер», кнопки, громкость) размером width x height.
function apDrawPlayer(width, height)
	imgui.BeginChild('player', imgui.ImVec2(width, height), false)
		local contentWidth = imgui.GetWindowContentRegionWidth()
		local spacing = imgui.GetStyle().ItemSpacing.x

		currentPage = APUI.tabs('player', { fa.ICON_FA_BROADCAST_TOWER..u8' Станции', fa.ICON_FA_HEADPHONES..u8' Плеер' }, currentPage)

		imgui.Dummy(imgui.ImVec2(0, 5))

		if currentPage == 1 then
			imgui.TextDisabled(u8'Станция')
			imgui.PushItemWidth(contentWidth)
				if imgui.Combo("##stations", current_radio, radiolist, #radiolist) then
					apPlayStation()
				end
			imgui.PopItemWidth()
			local loading = apRadioLoadingSeconds()
			if loading then
				imgui.TextDisabled(u8('Подключение... '..loading..' с'))
			end
		else
			local selectLabel = u8'Выбор'
			imgui.TextDisabled(u8'Папка с музыкой')
			imgui.PushItemWidth(contentWidth - spacing - APUI.buttonWidth(selectLabel))
				imgui.InputText("##musicpath", musicpath)
			imgui.PopItemWidth()
			imgui.SameLine()
			if APUI.button(selectLabel.."##musicpathselect") then
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

			if #musics > 0 then
				imgui.TextDisabled(apFitText(u8(musics[current_music]), contentWidth))
			end
			if results and results ~= '' then
				imgui.TextColored(APUI.colors.danger, apFitText(u8(results), contentWidth))
			end
		end

		imgui.Dummy(imgui.ImVec2(0, 5))

		-- Кнопки управления
			local withTracks = currentPage == 2 and #musics > 0
			local transportSize = imgui.ImVec2(APUI.frameHeight() * 1.4, 0)
			local transportCount = withTracks and 5 or 3
			local transportTotal = transportCount * transportSize.x + (transportCount - 1) * spacing
			imgui.SetCursorPosX(math.max(0, (contentWidth - transportTotal) / 2))
			if withTracks then
				if APUI.button(fa.ICON_FA_BACKWARD.."##backward", nil, transportSize) then
					if musics[current_music-1] then
						current_music = current_music - 1
					else
						current_music = #musics
					end
					apPlayTrack()
				end
				imgui.Hint(u8'Предыдущий трек')
				imgui.SameLine()
			end
			if APUI.button(icon_play_pause.."##stoppause", nil, transportSize) then
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
			imgui.Hint(u8'Играть / Пауза')
			imgui.SameLine()
			if APUI.button(fa.ICON_FA_STOP..'##stop', nil, transportSize) then
				apStoppedByUser = true
				apReleaseStream()
				icon_play_pause = fa.ICON_FA_PLAY
			end
			imgui.Hint(u8'Стоп')
			imgui.SameLine()
			if APUI.button(fa.ICON_FA_REDO..'##repeat', music_repeat.v and 'primary' or nil, transportSize) then
				music_repeat.v = not music_repeat.v
				data.music.rep = music_repeat.v
				inicfg.save(data, cfgpath)
			end
			imgui.Hint(u8'Повтор трека')
			if withTracks then
				imgui.SameLine()
				if APUI.button(fa.ICON_FA_FORWARD.."##forward", nil, transportSize) then
					if musics[current_music+1] then
						current_music = current_music + 1
					else
						current_music = 1
					end
					apPlayTrack()
				end
				imgui.Hint(u8'Следующий трек')
			end

		imgui.Dummy(imgui.ImVec2(0, 5))

		-- Громкость
			local volumeLabel = fa.ICON_FA_VOLUME_DOWN..u8' Громкость'
			APUI.label(volumeLabel)
			imgui.SameLine()
			imgui.PushItemWidth(contentWidth - imgui.CalcTextSize(volumeLabel).x - spacing)
				if imgui.SliderFloat(u8'##volume_player', volume_player, 0, 1) then
					if audioStream then
						setAudioStreamVolume(audioStream, volume_player.v)
					end
					apRadioVolume(volume_player.v)
					data.music.volume = math.floor(volume_player.v * 100 + 0.5)
					apVolumeDirty = true
				end
				if apVolumeDirty and not imgui.IsMouseDown(0) then
					apVolumeDirty = false
					inicfg.save(data, cfgpath)
				end
			imgui.PopItemWidth()

	imgui.EndChild()
end

-- Высота панели плеера: самая высокая вкладка («Плеер» с подписью ошибки), чтобы окно не прыгало.
local function apPlayerHeight()
	local frame, line, gap = APUI.frameHeight(), imgui.GetTextLineHeight(), imgui.GetStyle().ItemSpacing.y
	return math.ceil(frame * 4 + line * 3 + 5 * 3 + gap * 9 + 2)
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

function imgui.OnDrawFrame()
	APUI.drawToasts()
	if not apWindow.v or not data then return end
	local width = 400
	local x, y = tonumber(data.window.posX) or -1, tonumber(data.window.posY) or -1
	if x < 0 or y < 0 or x > resX - 60 or y > resY - 60 then x, y = math.floor((resX - width) / 2), math.floor(resY / 4) end
	imgui.SetNextWindowPos(imgui.ImVec2(x, y), imgui.Cond.FirstUseEver)
	if APUI.fontBase then imgui.PushFont(APUI.fontBase) end
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(20, 18))
	imgui.Begin('##sampaudioplayer', apWindow, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
		+ imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.AlwaysAutoResize)
		-- Внутри окна возвращаем обычный отступ, чтобы 20x18 не достался подсказкам и списку станций.
		imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(12, 12))
		local pos = imgui.GetWindowPos()
		apWindowPos = { x = math.floor(pos.x), y = math.floor(pos.y) }
		APUI.header(fa.ICON_FA_MUSIC..u8' Аудиоплеер')
		local closeWidth = APUI.buttonWidth(fa.ICON_FA_TIMES)
		imgui.SameLine(20 + width - closeWidth)
		if APUI.button(fa.ICON_FA_TIMES..'##apclose') then apWindow.v = false end
		apDrawPlayer(width, apPlayerHeight())
		imgui.Dummy(imgui.ImVec2(0, 2))
		apDrawKeyRow()
		imgui.PopStyleVar()
	imgui.End()
	imgui.PopStyleVar()
	if APUI.fontBase then imgui.PopFont() end
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
	if wparam == VK_ESCAPE and apWindow.v and not isPauseMenuActive() and not sampIsChatInputActive() and not sampIsDialogActive() then
		consumeWindowMessage(true, false)
		apWindow.v = false
		return
	end
	local key = tonumber(data and data.window and data.window.key) or 0
	local repeated = math.floor(lparam / 0x40000000) % 2 == 1 -- бит 30: клавиша уже была нажата (автоповтор)
	if key ~= 0 and wparam == key and not repeated and not (apWindow.v and imgui.GetIO().WantTextInput)
		and not sampIsChatInputActive() and not sampIsDialogActive() and not isPauseMenuActive() then
		apWindow.v = not apWindow.v
	end
end

-- Пока играет музыка плеера, звук, который включает сервер, не запускается (как в SNHelper).
function hook.onPlayAudioStream()
	if (audioStream and getAudioStreamState(audioStream) == 1) or apRadioState() == 1 then
		return false
	end
end

local function apSaveWindowPos()
	if not data or not apWindowPos then return end
	if apWindowPos.x ~= tonumber(data.window.posX) or apWindowPos.y ~= tonumber(data.window.posY) then
		data.window.posX, data.window.posY = apWindowPos.x, apWindowPos.y
		inicfg.save(data, cfgpath)
	end
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
		},
		window = {
			key = DEFAULT_KEY,
			posX = -1, -- левый верхний угол окна; -1 - по центру экрана
			posY = -1,
		},
	}, cfgpath)
	music_repeat.v = data.music.rep == true or data.music.rep == 'true'
	volume_player.v = (tonumber(data.music.volume) or 100) / 100
	apStoppedByUser = false
	apStreamIsTrack = false
	apLastRestart = 0
	musicpath.v = u8(tostring(data.music.path))
	sampRegisterChatCommand('aplayer', function()
		apWindow.v = not apWindow.v
	end)
	local key = tonumber(data.window.key) or 0
	sampAddChatMessage('Audio Player | {FFFFFF}Аудиоплеер загружен. Окно: /aplayer' .. (key ~= 0 and (' или клавиша ' .. apKeyName(key)) or '') .. '.', 0xC0C0C0)
	local wasOpen = false
	while true do
		wait(0)
		apRadioPoll()
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
		imgui.ShowCursor = apWindow.v
		if wasOpen and not apWindow.v then
			apKeyCapture = false
			apSaveWindowPos()
		end
		wasOpen = apWindow.v
	end
end
