-- Мапа залу: атомарний знімок усіх столів + даних відкритих чеків (без cjson, розбір — на клієнті)
-- KEYS: hall:tables, hall:occupied
-- Повертає: { HGETALL hall:tables, {tid, oid, waiter_name, opened_at, subtotal_minor, ready_cnt, ...} }
local tabs = redis.call('HGETALL', KEYS[1])
local occ = redis.call('HGETALL', KEYS[2])
local busy = {}
for i = 1, #occ, 2 do
  local o = redis.call('HMGET', 'order:' .. occ[i + 1], 'waiter_name', 'opened_at', 'subtotal_minor', 'ready_cnt')
  busy[#busy + 1] = occ[i]; busy[#busy + 1] = occ[i + 1]
  busy[#busy + 1] = o[1]; busy[#busy + 1] = o[2]; busy[#busy + 1] = o[3]; busy[#busy + 1] = o[4]
end
return { tabs, busy }
