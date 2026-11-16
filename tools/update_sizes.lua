-- Пересчитать размеры файлов в scripts.json по самим файлам репозитория, чтобы они не расходились.
--   luajit tools/update_sizes.lua          - записать новые размеры в scripts.json
--   luajit tools/update_sizes.lua --check  - только проверить (код выхода 1, если что-то не так)
-- Запускать из корня репозитория. Формат scripts.json: каждый файл - одна строка вида
--   { "path": "...", "size": 123, "src": "..." }
-- Инструмент меняет только число после "size" в таких строках и проверяет, что файлы "src" и "image" есть.
local check = arg[1] == '--check'

local function fileSize(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local size = f:seek('end')
	f:close()
	return size
end

local f = assert(io.open('scripts.json', 'rb'), 'scripts.json not found: run from the repository root')
local text = f:read('*a')
f:close()

local problems, changed, files = 0, 0, 0
local out = {}
for line in (text:gsub('\r', '') .. '\n'):gmatch('(.-)\n') do
	local src = line:match('"src"%s*:%s*"([^"]+)"')
	if src then
		files = files + 1
		local size = fileSize(src)
		if not size then
			print('MISSING ' .. src)
			problems = problems + 1
		else
			local old = tonumber(line:match('"size"%s*:%s*(%d+)'))
			if not old then
				print('NO SIZE on the line of ' .. src .. ' (put path, size and src on one line)')
				problems = problems + 1
			elseif old ~= size then
				print(('%s %s: %d -> %d'):format(check and 'DRIFT' or 'UPDATE', src, old, size))
				changed = changed + 1
				line = line:gsub('("size"%s*:%s*)%d+', '%1' .. size, 1)
			end
		end
	end
	local image = line:match('"image"%s*:%s*"([^"]+)"')
	if image and not fileSize(image) then
		print('MISSING image ' .. image)
		problems = problems + 1
	end
	out[#out + 1] = line
end
-- Файлы из deps/, которых нет ни в одной записи, не ошибка: их берут загрузчики скриптов напрямую.
if not check and changed > 0 then
	while out[#out] == '' do out[#out] = nil end
	local w = assert(io.open('scripts.json', 'wb'))
	w:write(table.concat(out, '\n') .. '\n')
	w:close()
end
if problems > 0 or (check and changed > 0) then
	print(('FAIL: %d problems, %d sizes differ'):format(problems, changed))
	os.exit(1)
end
print(('sizes OK: %d files%s'):format(files, changed > 0 and (', updated ' .. changed) or ''))
