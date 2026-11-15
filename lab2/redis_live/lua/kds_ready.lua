-- Позиція готова: статус, прибрати з черги станції, лічильник «на видачу», сповіщення офіціанту
-- KEYS: order:{oid}, order:{oid}:items     ARGV: oid, iid
local raw = redis.call('HGET', KEYS[2], ARGV[2])
if not raw then return redis.error_reply('ITEM_NOT_FOUND') end
local it = cjson.decode(raw)
if it.status ~= 'cooking' then return redis.error_reply('ITEM_NOT_COOKING') end
local t = redis.call('TIME')
it.status = 'ready'
it.ready_at = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
redis.call('HSET', KEYS[2], ARGV[2], cjson.encode(it))
redis.call('ZREM', 'kds:' .. it.station, ARGV[1] .. ':' .. ARGV[2])
redis.call('HINCRBY', KEYS[1], 'ready_cnt', 1)
local o = redis.call('HMGET', KEYS[1], 'waiter_id', 'table_number')
return redis.call('XADD', 'notify:' .. o[1], 'MAXLEN', '~', 1000, '*',
  'order', ARGV[1], 'item', ARGV[2], 'table', o[2], 'dish', it.name)
