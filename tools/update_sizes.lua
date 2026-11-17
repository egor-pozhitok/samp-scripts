-- Пересчитать размеры файлов в scripts.json по самим файлам репозитория, чтобы они не расходились.
--   luajit tools/update_sizes.lua          - записать новые размеры в scripts.json
--   luajit tools/update_sizes.lua --check  - только проверить (код выхода 1, если что-то не так)
-- Запускать из корня репозитория. Формат scripts.json: каждый файл - одна строка вида
--   { "path": "...", "size": 123, "src": "..." }
-- Инструмент меняет только число после "size" в таких строках и проверяет, что файлы "src" и "image" есть.
-- После строки "image" держит строку "image_size" с размером картинки (нет её - вставляет): по нему каталог
-- (samp-catalog 5+) скачивает заново картинку карточки, если в кэше игрока она другого размера.
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
local pendingImage = nil -- { path, indent } картинки из прошлой строки: ждёт строку image_size
for line in (text:gsub('\r', '') .. '\n'):gmatch('(.-)\n') do
	if pendingImage then
		local size = fileSize(pendingImage[1])
		local old = line:match('"image_size"%s*:%s*(%d+)')
		if not old then
			if size then
				print(('%s image_size of %s: none -> %d'):format(check and 'DRIFT' or 'ADD', pendingImage[1], size))
				changed = changed + 1
				out[#out + 1] = pendingImage[2] .. '"image_size": ' .. size .. ','
			end
		elseif size and tonumber(old) ~= size then
			print(('%s image_size of %s: %s -> %d'):format(check and 'DRIFT' or 'UPDATE', pendingImage[1], old, size))
			changed = changed + 1
			line = line:gsub('("image_size"%s*:%s*)%d+', '%1' .. size, 1)
		end
		pendingImage = nil
	end
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
	elseif image then
		pendingImage = { image, line:match('^(%s*)') }
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
