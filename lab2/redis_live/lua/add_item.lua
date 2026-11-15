-- Додати страву в чек (атомарно: перевірки + позиція + сума + журнал аудиту)
-- KEYS: order:{oid}, order:{oid}:items, menu:dish:{dish_id}, audit:orders
-- ARGV: oid, dish_id, qty, comment
local st = redis.call('HGET', KEYS[1], 'status')
if not st then return redis.error_reply('ORDER_NOT_FOUND') end
if st == 'paid' or st == 'cancelled' then return redis.error_reply('ORDER_CLOSED') end
local qty = tonumber(ARGV[3])
if not qty or qty <= 0 or qty ~= math.floor(qty) then return redis.error_reply('BAD_QTY') end
local d = redis.call('HMGET', KEYS[3], 'name', 'price_minor', 'station', 'available')
if not d[1] then return redis.error_reply('DISH_NOT_FOUND') end
if d[4] ~= '1' then return redis.error_reply('DISH_UNAVAILABLE') end
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
local iid = redis.call('HINCRBY', KEYS[1], 'item_seq', 1)
local price = tonumber(d[2])
redis.call('HSET', KEYS[2], iid, cjson.encode({
  id = iid, dish_id = tonumber(ARGV[2]), name = d[1], qty = qty, price_minor = price,
  station = d[3], comment = ARGV[4], status = 'new', added_at = now }))
redis.call('HINCRBY', KEYS[1], 'subtotal_minor', price * qty)
redis.call('XADD', KEYS[4], 'MAXLEN', '~', 1000000, '*',
  'op', 'add_item', 'order', ARGV[1], 'item', iid, 'dish', ARGV[2], 'qty', qty)
return iid
