-- Відправити «кошик» на кухню: позиції -> черги станцій kds:{station}, + рейтинг дня
-- KEYS: order:{oid}, order:{oid}:items, stats:dishes:{YYYY-MM-DD}
-- ARGV: oid
local st = redis.call('HGET', KEYS[1], 'status')
if not st then return redis.error_reply('ORDER_NOT_FOUND') end
if st == 'paid' or st == 'cancelled' then return redis.error_reply('ORDER_CLOSED') end
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
local all = redis.call('HGETALL', KEYS[2])
local n = 0
for i = 1, #all, 2 do
  local it = cjson.decode(all[i + 1])
  if it.status == 'new' and not it.sent_at then
    it.sent_at = now
    redis.call('HSET', KEYS[2], all[i], cjson.encode(it))
    redis.call('ZADD', 'kds:' .. it.station, now, ARGV[1] .. ':' .. all[i])
    redis.call('ZINCRBY', KEYS[3], it.qty, it.dish_id)
    n = n + 1
  end
end
if n > 0 then
  if st == 'open' then redis.call('HSET', KEYS[1], 'status', 'in_kitchen') end
  redis.call('EXPIRE', KEYS[3], 259200)   -- рейтинг дня живе 3 доби
end
return n
