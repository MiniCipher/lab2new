-- Відкрити живий чек столу (order_id видає PostgreSQL — система запису)
-- KEYS: hall:tables, hall:occupied, order:{oid}, orders:open
-- ARGV: oid, table_id, waiter_id, waiter_name, customer_id|'' , opened_at_ms
if redis.call('HEXISTS', KEYS[2], ARGV[2]) == 1 then return redis.error_reply('TABLE_OCCUPIED') end
local raw = redis.call('HGET', KEYS[1], ARGV[2])
if not raw then return redis.error_reply('TABLE_NOT_FOUND') end
if redis.call('EXISTS', KEYS[3]) == 1 then return redis.error_reply('ORDER_EXISTS') end
local t = cjson.decode(raw)
redis.call('HSET', KEYS[3],
  'order_id', ARGV[1], 'table_id', ARGV[2], 'table_number', t.table_number, 'hall', t.hall,
  'waiter_id', ARGV[3], 'waiter_name', ARGV[4], 'customer_id', ARGV[5],
  'status', 'open', 'opened_at', ARGV[6], 'subtotal_minor', 0, 'ready_cnt', 0, 'item_seq', 0)
redis.call('HSET', KEYS[2], ARGV[2], ARGV[1])
redis.call('SADD', KEYS[4], ARGV[1])
return 1
