-- Закрити живий чек ПІСЛЯ успішного запису в PostgreSQL (ідемпотентно)
-- KEYS: order:{oid}, order:{oid}:items, hall:occupied, orders:open     ARGV: oid
local tid = redis.call('HGET', KEYS[1], 'table_id')
local all = redis.call('HGETALL', KEYS[2])
for i = 1, #all, 2 do
  local it = cjson.decode(all[i + 1])
  if it.station then redis.call('ZREM', 'kds:' .. it.station, ARGV[1] .. ':' .. all[i]) end
end
redis.call('DEL', KEYS[1], KEYS[2])
if tid and redis.call('HGET', KEYS[3], tid) == ARGV[1] then redis.call('HDEL', KEYS[3], tid) end
redis.call('SREM', KEYS[4], ARGV[1])
return 1
