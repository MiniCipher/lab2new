-- Кухар узяв позицію в роботу
-- KEYS: order:{oid}:items     ARGV: iid, cook_id
local raw = redis.call('HGET', KEYS[1], ARGV[1])
if not raw then return redis.error_reply('ITEM_NOT_FOUND') end
local it = cjson.decode(raw)
if it.status ~= 'new' or not it.sent_at then return redis.error_reply('ITEM_NOT_IN_QUEUE') end
local t = redis.call('TIME')
it.status = 'cooking'
it.started_at = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
it.cook_id = tonumber(ARGV[2])
redis.call('HSET', KEYS[1], ARGV[1], cjson.encode(it))
return 1
