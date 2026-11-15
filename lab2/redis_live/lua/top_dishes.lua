-- ТОП-N страв дня з назвами з кешу меню
-- KEYS: stats:dishes:{YYYY-MM-DD}     ARGV: n
local z = redis.call('ZREVRANGE', KEYS[1], 0, tonumber(ARGV[1]) - 1, 'WITHSCORES')
local out = {}
for i = 1, #z, 2 do
  out[#out + 1] = { dish_id = tonumber(z[i]), qty = tonumber(z[i + 1]),
                    name = redis.call('HGET', 'menu:dish:' .. z[i], 'name') }
end
if #out == 0 then return '[]' end
return cjson.encode(out)
