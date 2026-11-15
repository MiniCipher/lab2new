-- Офіціант виніс страву
-- KEYS: order:{oid}, order:{oid}:items     ARGV: iid
local raw = redis.call('HGET', KEYS[2], ARGV[1])
if not raw then return redis.error_reply('ITEM_NOT_FOUND') end
local it = cjson.decode(raw)
if it.status ~= 'ready' then return redis.error_reply('ITEM_NOT_READY') end
it.status = 'served'
redis.call('HSET', KEYS[2], ARGV[1], cjson.encode(it))
redis.call('HINCRBY', KEYS[1], 'ready_cnt', -1)
return 1
