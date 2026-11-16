-- samp-notifier: общие уведомления скриптов GORYCH для MoonLoader
local STLogic = {}

STLogic.API = 1
STLogic.MAX_QUEUE = 12
STLogic.MAX_VISIBLE = 3
STLogic.KINDS = { success = true, error = true }

function STLogic.sanitize(text, seconds, kind, key, sender)
	if type(text) ~= 'string' then return nil end
	text = text:gsub('%s+$', '')
	if text == '' then return nil end
	if #text > 600 then text = text:sub(1, 600) end
	seconds = tonumber(seconds) or 4
	if seconds ~= seconds then seconds = 4 end
	seconds = math.max(1, math.min(30, seconds))
	if not STLogic.KINDS[kind] then kind = nil end
	if type(key) ~= 'string' or key == '' or #key > 60 then key = nil end
	if type(sender) ~= 'string' then sender = '' end
	sender = sender:gsub('[%c]', ''):sub(1, 32)
	return { text = text, seconds = seconds, kind = kind, key = key, sender = sender }
end

function STLogic.toastUpdate(queue, now, maxVisible)
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

function STLogic.toastPush(queue, item, now, maxQueue)
	for _, old in ipairs(queue) do
		if old.sender == item.sender and ((item.key and old.key == item.key) or (not item.key and old.text == item.text)) then
			old.text, old.kind, old.seconds = item.text, item.kind, item.seconds
			if old.startAt then old.startAt = now - math.min(now - old.startAt, 0.2) end
			return old
		end
	end
	if #queue >= maxQueue then table.remove(queue, 1) end
	queue[#queue + 1] = item
	return item
end

if STLOGIC_TEST then return STLogic end

script_name('samp-notifier')
script_author('GORYCH')
script_description('Shared notifications for GORYCH scripts')
script_version_number(1)
script_version('1.0')

local okImgui, imgui = pcall(require, 'imgui')
local okEncoding, encoding = pcall(require, 'encoding')
local u8 = nil
if okEncoding then
	encoding.default = 'CP1251'
	u8 = encoding.UTF8
end
local ready = okImgui and okEncoding
local queue = {}
local fontBase = nil
local fontsLoaded = false

function EXPORTS.api()
	return STLogic.API
end

function EXPORTS.push(text, seconds, kind, key, sender)
	if not ready then return false end
	local item = STLogic.sanitize(text, seconds, kind, key, sender)
	if not item then return false end
	STLogic.toastPush(queue, item, os.clock(), STLogic.MAX_QUEUE)
	return true
end

if not ready then
	print('samp-notifier: imgui or encoding is missing, notifications stay in the scripts')
	return
end

local V2, V4 = imgui.ImVec2, imgui.ImVec4
local function hex(rgb, alpha)
	return V4(math.floor(rgb / 65536) % 256 / 255, math.floor(rgb / 256) % 256 / 255, rgb % 256 / 255, alpha or 1)
end
local C = {
	window = hex(0x17161D, 0.94), text = hex(0xEAE8F2), muted = hex(0x9D99B0),
	accent = hex(0x8B6CF6), success = hex(0x5FD08A), danger = hex(0xFF6B7A),
}

function imgui.BeforeDrawFrame()
	if fontsLoaded then return end
	fontsLoaded = true
	local dir = getFolderPath(0x14) .. '\\'
	for _, name in ipairs({ 'segoeui.ttf', 'trebuc.ttf', 'arial.ttf' }) do
		if doesFileExist(dir .. name) then
			local fonts = imgui.GetIO().Fonts
			fontBase = fonts:AddFontFromFileTTF(dir .. name, 15.0, nil, fonts:GetGlyphRangesCyrillic())
			break
		end
	end
end

local function drawToasts()
	local shown = STLogic.toastUpdate(queue, os.clock(), STLogic.MAX_VISIBLE)
	if #shown == 0 then return end
	local resX, resY = getScreenResolution()
	local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
		+ imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoFocusOnAppearing
		+ imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoMove
	local padX, padY, gap, margin, bar = 12, 9, 6, 16, 3
	imgui.PushStyleVar(imgui.StyleVar.WindowRounding, 8)
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, V2(padX, padY))
	imgui.PushStyleColor(imgui.Col.WindowBg, C.window)
	if fontBase then imgui.PushFont(fontBase) end
	local fontSize = imgui.GetFontSize()
	local width = math.floor(fontSize * 17)
	local textX = padX + bar + 6
	local wrap = width - textX - padX
	local y = resY - margin
	for i, entry in ipairs(shown) do
		local item = entry.item
		local text = u8(item.text)
		local sender = item.sender ~= '' and u8(item.sender) or nil
		local textH = imgui.GetFont():CalcTextSizeA(fontSize, 10000, wrap, text).y
		local senderH = sender and (fontSize + 2) or 0
		local h = math.floor(senderH + textH + padY * 2)
		y = y - h
		imgui.SetNextWindowPos(V2(resX - margin - width, y), imgui.Cond.Always)
		imgui.SetNextWindowSize(V2(width, h), imgui.Cond.Always)
		imgui.PushStyleVar(imgui.StyleVar.Alpha, entry.alpha)
		imgui.Begin('##samptoast' .. i, nil, flags)
			local pos = imgui.GetWindowPos()
			local barColor = item.kind == 'success' and C.success or item.kind == 'error' and C.danger or C.accent
			imgui.GetWindowDrawList():AddRectFilled(V2(pos.x + padX, pos.y + padY), V2(pos.x + padX + bar, pos.y + h - padY), imgui.GetColorU32(barColor), 1)
			if sender then
				imgui.SetCursorPosX(textX)
				imgui.TextColored(C.muted, sender)
				imgui.SetCursorPosY(padY + senderH)
			end
			imgui.SetCursorPosX(textX)
			imgui.PushTextWrapPos(width - padX)
				imgui.TextColored(C.text, text)
			imgui.PopTextWrapPos()
		imgui.End()
		imgui.PopStyleVar()
		y = y - gap
	end
	if fontBase then imgui.PopFont() end
	imgui.PopStyleColor()
	imgui.PopStyleVar(2)
end

function imgui.OnDrawFrame()
	drawToasts()
end

function main()
	imgui.ShowCursor = false
	while true do
		wait(0)
		imgui.Process = #queue > 0
	end
end
