-- =====================================================================
-- 05_bench_data.sql : генерація великого обсягу даних для бенчмарку
--   psql -v hist_orders=1000000 -f 05_bench_data.sql
--   hist_orders  — кількість історичних (оплачених) замовлень за 2 роки
--   today_orders — кількість уже оплачених замовлень за сьогодні
-- Виконувати після 01..04. Потрібні права суперкористувача
-- (session_replication_role вимикає тригери на час масової вставки:
--  дані генеруються узгодженими, суми рахуються окремим UPDATE).
-- =====================================================================
\set ON_ERROR_STOP on
\if :{?hist_orders}
\else
  \set hist_orders 100000
\endif
\if :{?today_orders}
\else
  \set today_orders 800
\endif

SET search_path TO restaurant, public;
SELECT setseed(0.42);
SET session_replication_role = replica;

-- Довідники ---------------------------------------------------------
INSERT INTO menu_categories(name, sort_order)
SELECT 'Категорія ' || g, 4 + g FROM generate_series(1, 8) g;                 -- разом 12

INSERT INTO ingredients(name, unit, stock_qty, min_stock_qty)
SELECT 'Інгредієнт ' || g, 'кг', round((500 + random() * 1000)::numeric, 3), 5
FROM generate_series(1, 72) g;                                                 -- разом 80
-- кілька інгредієнтів закінчились -> частина страв недоступна в меню
UPDATE ingredients SET stock_qty = 0.001 WHERE name IN ('Інгредієнт 7', 'Інгредієнт 33', 'Інгредієнт 61');

INSERT INTO dishes(category_id, name, description, price, cooking_time_min, station_id)
SELECT 1 + (g % 12), 'Страва ' || g, 'Опис страви ' || g || ' — сезонні інгредієнти',
       round((60 + random() * 540)::numeric, 0), 3 + (g % 30), 1 + (g % 4)
FROM generate_series(1, 195) g;                                                -- разом 200

INSERT INTO dish_ingredients(dish_id, ingredient_id, quantity)
SELECT d.dish_id, i.ingredient_id, round((0.01 + random() * 0.3)::numeric, 3)
FROM dishes d
CROSS JOIN LATERAL (SELECT ingredient_id FROM ingredients
                    WHERE ingredient_id <> -d.dish_id          -- корелюємо підзапит із d
                    ORDER BY random() LIMIT 3 + (d.dish_id % 4)) i
WHERE d.dish_id > 5;

INSERT INTO halls(name, description)
SELECT 'Зал ' || g, 'Згенерований зал' FROM generate_series(3, 5) g;            -- разом 5

INSERT INTO restaurant_tables(hall_id, table_number, seats)
SELECT h, n, (ARRAY[2, 4, 4, 6, 8])[1 + (n % 5)]
FROM generate_series(1, 5) h, generate_series(1, 20) n
ON CONFLICT (hall_id, table_number) DO NOTHING;                                -- разом 100

INSERT INTO employees(role_id, first_name, last_name, phone, email, salary)
SELECT r, 'Співробітник', 'N' || g, '+38050' || lpad(g::text, 7, '0'), 'emp' || g || '@resto.ua', 15000 + g * 100
FROM generate_series(1, 45) g,
     LATERAL (SELECT CASE WHEN g <= 30 THEN 2 WHEN g <= 40 THEN 4 ELSE 3 END AS r) x;

INSERT INTO customers(first_name, last_name, phone, email)
SELECT 'Гість', 'N' || g, '+38090' || lpad(g::text, 7, '0'), 'guest' || g || '@example.com'
FROM generate_series(1, 50000) g;

-- Історія замовлень ----------------------------------------------------
CREATE TEMP TABLE _ids AS
SELECT (SELECT array_agg(employee_id) FROM employees WHERE role_id = 2) AS waiters,
       (SELECT array_agg(employee_id) FROM employees WHERE role_id = 3) AS cashiers,
       (SELECT max(customer_id) FROM customers) AS max_customer;

-- минулі дні (2 роки) + уже оплачені сьогодні
INSERT INTO orders(table_id, waiter_id, customer_id, status, opened_at, closed_at)
SELECT 1 + floor(random() * 100)::int,
       w.waiters[1 + floor(random() * array_length(w.waiters, 1))::int],
       CASE WHEN random() < 0.4 THEN 1 + floor(random() * w.max_customer)::int END,
       'paid', ts, least(ts + interval '50 min', now())
FROM _ids w,
     LATERAL (SELECT date_trunc('day', now()) - interval '1 second' - random() * interval '730 days' AS ts
              FROM generate_series(1, :hist_orders)
              UNION ALL
              SELECT date_trunc('day', now()) + random() * (now() - date_trunc('day', now()))
              FROM generate_series(1, :today_orders)) t;

-- 1..8 позицій на замовлення; популярність страв нерівномірна (random()^2)
INSERT INTO order_items(order_id, dish_id, quantity, unit_price, status, station_id,
                        added_at, sent_at, started_at, ready_at)
SELECT x.order_id, d.dish_id, x.qty, d.price, 'served', d.station_id,
       x.opened_at + interval '2 min', x.opened_at + interval '4 min',
       x.opened_at + interval '6 min', x.opened_at + interval '20 min'
FROM (SELECT o.order_id, o.opened_at,
             1 + floor(200 * random() ^ 2)::int AS dish_no,
             CASE WHEN random() < 0.2 THEN 2 ELSE 1 END AS qty
      FROM orders o,
           LATERAL generate_series(1, 1 + floor(random() * 8)::int + (o.order_id * 0)::int) k
      WHERE o.status = 'paid') x
JOIN dishes d ON d.dish_id = x.dish_no;

UPDATE orders o SET subtotal = s.amt, total_amount = s.amt
FROM (SELECT order_id, sum(quantity * unit_price) AS amt FROM order_items GROUP BY order_id) s
WHERE s.order_id = o.order_id;

INSERT INTO payments(order_id, cashier_id, amount, method, paid_at)
SELECT o.order_id, w.cashiers[1 + floor(random() * array_length(w.cashiers, 1))::int],
       o.total_amount, (ARRAY['cash', 'card', 'card', 'online'])[1 + floor(random() * 4)::int]::payment_method,
       o.closed_at
FROM orders o, _ids w
WHERE o.status = 'paid' AND o.total_amount > 0;

SET session_replication_role = origin;
VACUUM ANALYZE;

SELECT 'orders' AS t, count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'payments', count(*) FROM payments
UNION ALL SELECT 'dishes', count(*) FROM dishes
UNION ALL SELECT 'customers', count(*) FROM customers;
