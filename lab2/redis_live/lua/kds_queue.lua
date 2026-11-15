-- Екран станції: найстаріші позиції (у черзі та в роботі) з номером столу.
-- Redis однопотоковий, тому скрипт лише атомарно ЗБИРАЄ дані (без cjson),
-- а розбір JSON виконує клієнт.
-- KEYS: kds:{station}     ARGV: limit
-- Повертає плаский масив: oid, item_json, table_number, hall, oid, item_json, ...
local m = redis.call('ZRANGE', KEYS[1], 0, tonumber(ARGV[1]) - 1)
local out = {}
for _, mem in ipairs(m) do
  local sep = string.find(mem, ':', 1, true)
  local oid, iid = string.sub(mem, 1, sep - 1), string.sub(mem, sep + 1)
  local raw = redis.call('HGET', 'order:' .. oid .. ':items', iid)
  if raw then
    local o = redis.call('HMGET', 'order:' .. oid, 'table_number', 'hall')
    out[#out + 1] = oid; out[#out + 1] = raw; out[#out + 1] = o[1]; out[#out + 1] = o[2]
  end
end
return out
