-- =====================================================================
-- 04_live_service.sql : ЛР2 — SQL-реалізація модуля «Live Service»
--   (оперативне обслуговування залу: живий чек столу, черга кухні (KDS),
--    сповіщення офіціантів, мапа залу, кеш меню, рейтинг страв дня).
--   Той самий модуль реалізовано в Redis (redis_live/live_redis.py) —
--   саме ці дві реалізації порівнюються в бенчмарку.
-- Виконувати ПІСЛЯ 01_schema.sql, 02_logic.sql, 03_seed.sql
-- =====================================================================
SET search_path TO restaurant, public;

-- Функції ЛР1/ЛР2 використовують неуточнені імена таблиць, тому фіксуємо
-- search_path на рівні БД (інакше виклик з клієнта без SET search_path падає).
DO $$ BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path = restaurant, public', current_database());
END $$;

-- ---------------------------------------------------------------------
-- 1. Нові таблиці / колонки
-- ---------------------------------------------------------------------

-- Станції кухні: кожна страва готується на певній станції (свій екран KDS)
CREATE TABLE IF NOT EXISTS kitchen_stations (
    station_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        varchar(20) NOT NULL UNIQUE,
    name        varchar(60) NOT NULL
);
INSERT INTO kitchen_stations(code, name) VALUES
 ('hot', 'Гаряча кухня'), ('cold', 'Холодна кухня'), ('bar', 'Бар'), ('pastry', 'Кондитерська')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE dishes ADD COLUMN IF NOT EXISTS station_id integer REFERENCES kitchen_stations(station_id);

-- Прив'язка страв seed-даних до станцій (за категорією)
UPDATE dishes d SET station_id = s.station_id
FROM kitchen_stations s
WHERE d.station_id IS NULL
  AND s.code = CASE d.category_id WHEN 1 THEN 'cold' WHEN 2 THEN 'hot' WHEN 3 THEN 'pastry' ELSE 'bar' END;

-- Життєвий цикл позиції на кухні.
--   status='new' AND sent_at IS NULL      -> позиція ще в «кошику» столу
--   status='new' AND sent_at IS NOT NULL  -> у черзі станції
--   'cooking' -> 'ready' -> 'served'      (enum з ЛР1 не змінюємо)
ALTER TABLE order_items
    ADD COLUMN IF NOT EXISTS station_id integer REFERENCES kitchen_stations(station_id), -- знімок на момент відправки
    ADD COLUMN IF NOT EXISTS comment    varchar(200),
    ADD COLUMN IF NOT EXISTS added_at   timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS sent_at    timestamptz,
    ADD COLUMN IF NOT EXISTS started_at timestamptz,
    ADD COLUMN IF NOT EXISTS ready_at   timestamptz,
    ADD COLUMN IF NOT EXISTS cook_id    integer REFERENCES employees(employee_id);

-- Сповіщення офіціанту «страва готова» (аналог Redis Stream stream:ready)
CREATE TABLE IF NOT EXISTS item_ready_events (
    event_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_item_id  bigint  NOT NULL REFERENCES order_items(order_item_id) ON DELETE CASCADE,
    order_id       bigint  NOT NULL,
    table_id       integer NOT NULL,
    waiter_id      integer NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    acked_at       timestamptz
);

-- ---------------------------------------------------------------------
-- 2. Індекси під шаблони доступу модуля
-- ---------------------------------------------------------------------
-- черга станції: лише «живі» позиції (частковий індекс — кілька сотень записів
-- навіть при мільйонах рядків історії), порядок індексу = порядок екрана кухні,
-- тож LIMIT зупиняє сканування без сортування
DROP INDEX IF EXISTS ix_oi_kds_queue;
CREATE INDEX ix_oi_kds_queue ON order_items (station_id, sent_at, order_item_id)
    WHERE status IN ('new', 'cooking') AND sent_at IS NOT NULL;
-- рейтинг страв за день
CREATE INDEX IF NOT EXISTS ix_oi_sent_at ON order_items (sent_at);
-- відкрите замовлення столу (мапа залу)
CREATE INDEX IF NOT EXISTS ix_orders_open_by_table ON orders (table_id)
    WHERE status IN ('open', 'in_kitchen', 'served');
-- непрочитані сповіщення офіціанта
CREATE INDEX IF NOT EXISTS ix_ready_events_waiter ON item_ready_events (waiter_id, event_id)
    WHERE acked_at IS NULL;

-- ---------------------------------------------------------------------
-- 3. Оптимізація тригера ЛР1.
--    У ЛР1 trg_order_items_recalc спрацьовував на БУДЬ-ЯКИЙ UPDATE order_items,
--    тобто кожна зміна статусу на кухні (new->cooking->ready) перераховувала
--    суму замовлення й писала запис у audit_log. Сума залежить лише від
--    quantity, unit_price та факту скасування — обмежуємо спрацювання.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_order_items_recalc ON order_items;
DROP TRIGGER IF EXISTS trg_order_items_recalc_ins_del ON order_items;
DROP TRIGGER IF EXISTS trg_order_items_recalc_upd ON order_items;

CREATE TRIGGER trg_order_items_recalc_ins_del AFTER INSERT OR DELETE ON order_items
    FOR EACH ROW EXECUTE FUNCTION trg_fn_recalc_order();

CREATE TRIGGER trg_order_items_recalc_upd AFTER UPDATE ON order_items
    FOR EACH ROW
    WHEN (OLD.quantity   IS DISTINCT FROM NEW.quantity
       OR OLD.unit_price IS DISTINCT FROM NEW.unit_price
       OR (OLD.status = 'cancelled') IS DISTINCT FROM (NEW.status = 'cancelled'))
    EXECUTE FUNCTION trg_fn_recalc_order();

-- ---------------------------------------------------------------------
-- 3b. Оптимізація функції ЛР1 fn_dish_can_be_cooked.
--    У ЛР1 вона LANGUAGE sql. Скалярна SQL-функція з EXISTS не вбудовується
--    (inlining) у запит, що її викликає, а план її тіла НЕ кешується між
--    викликами — PostgreSQL планує запит щоразу (~170 мкс/виклик у наших
--    вимірах). plpgsql кешує план (~60 мкс). Семантику не змінено.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_dish_can_be_cooked(p_dish_id integer, p_qty integer)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM dishes d
                   WHERE d.dish_id = p_dish_id AND NOT d.is_deleted AND d.is_available)
       AND NOT EXISTS (SELECT 1
                       FROM dish_ingredients di
                       JOIN ingredients i ON i.ingredient_id = di.ingredient_id
                       WHERE di.dish_id = p_dish_id
                         AND (i.is_deleted OR i.stock_qty < di.quantity * p_qty));
END $$;

-- ---------------------------------------------------------------------
-- 4. Представлення: меню для гостя (QR-меню) з доступністю за залишками
--    Відповідає ключу Redis  menu:json  (+ menu:dish:{id})
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_menu AS
SELECT d.dish_id, c.category_id, c.name AS category_name, c.sort_order,
       d.name, d.description, d.price, d.cooking_time_min,
       s.code AS station,
       (d.is_available AND NOT EXISTS (
            SELECT 1 FROM dish_ingredients di
            JOIN ingredients i ON i.ingredient_id = di.ingredient_id
            WHERE di.dish_id = d.dish_id AND (i.is_deleted OR i.stock_qty < di.quantity))) AS available
FROM dishes d
JOIN menu_categories c       ON c.category_id = d.category_id
LEFT JOIN kitchen_stations s ON s.station_id  = d.station_id
WHERE NOT d.is_deleted;

-- ---------------------------------------------------------------------
-- 5. Операції модуля (API) — 1:1 з методами LiveRedis
-- ---------------------------------------------------------------------

-- 5.1 Додати страву в чек столу («кошик», ще не відправлено на кухню)
--     Доступність перевіряється за залишками (fn_dish_can_be_cooked з ЛР1),
--     ціну знімає тригер ЛР1 trg_order_items_price,
--     суму замовлення перераховує тригер, зміну orders фіксує audit_log.
CREATE OR REPLACE FUNCTION fn_live_add_item(
    p_order_id bigint, p_dish_id integer, p_qty integer, p_comment varchar DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_status order_status; v_id bigint;
BEGIN
    IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'BAD_QTY'; END IF;
    SELECT status INTO v_status FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND %', p_order_id; END IF;
    IF v_status IN ('paid', 'cancelled') THEN RAISE EXCEPTION 'ORDER_CLOSED %', p_order_id; END IF;
    -- та сама семантика, що й прапорець available у меню (v_menu / menu:dish:{id}):
    -- страва не видалена, увімкнена і є інгредієнти щонайменше на 1 порцію
    IF NOT fn_dish_can_be_cooked(p_dish_id, 1) THEN RAISE EXCEPTION 'DISH_UNAVAILABLE %', p_dish_id; END IF;

    INSERT INTO order_items(order_id, dish_id, quantity, comment)
    VALUES (p_order_id, p_dish_id, p_qty, NULLIF(p_comment, ''))
    RETURNING order_item_id INTO v_id;
    RETURN v_id;
END $$;

-- 5.2 Відправити «кошик» столу на кухню: позиції потрапляють у черги станцій
CREATE OR REPLACE FUNCTION fn_live_send_to_kitchen(p_order_id bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    UPDATE order_items oi
       SET sent_at = now(), station_id = d.station_id
      FROM dishes d
     WHERE d.dish_id = oi.dish_id
       AND oi.order_id = p_order_id AND oi.status = 'new' AND oi.sent_at IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN
        UPDATE orders SET status = 'in_kitchen' WHERE order_id = p_order_id AND status = 'open';
    END IF;
    RETURN n;
END $$;

-- 5.3 Екран станції кухні: найстаріші позиції в роботі/черзі
CREATE OR REPLACE FUNCTION fn_kds_queue(p_station varchar, p_limit integer DEFAULT 30)
RETURNS TABLE (order_item_id bigint, order_id bigint, table_number integer, hall_name varchar,
               dish_name varchar, quantity integer, comment varchar, status text,
               sent_at timestamptz, started_at timestamptz)
LANGUAGE sql STABLE AS $$
    SELECT oi.order_item_id, oi.order_id, t.table_number, h.name, d.name, oi.quantity,
           oi.comment, oi.status::text, oi.sent_at, oi.started_at
    FROM order_items oi
    JOIN dishes d            ON d.dish_id = oi.dish_id
    JOIN orders o            ON o.order_id = oi.order_id
    JOIN restaurant_tables t ON t.table_id = o.table_id
    JOIN halls h             ON h.hall_id = t.hall_id
    -- Станція як скалярний підзапит (InitPlan), а не JOIN по code:
    -- інакше в generic plan підготовленого запиту планувальник не знає станції
    -- і обирає повний прохід індексу ix_oi_sent_at (виявлено під час бенчмарку).
    WHERE oi.station_id = (SELECT station_id FROM kitchen_stations WHERE code = p_station)
      AND oi.status IN ('new', 'cooking') AND oi.sent_at IS NOT NULL
    ORDER BY oi.sent_at, oi.order_item_id
    LIMIT p_limit
$$;

-- 5.4 Кухар узяв позицію в роботу
CREATE OR REPLACE FUNCTION fn_kds_start(p_item_id bigint, p_cook_id integer)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE order_items SET status = 'cooking', started_at = now(), cook_id = p_cook_id
     WHERE order_item_id = p_item_id AND status = 'new' AND sent_at IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'ITEM_NOT_IN_QUEUE %', p_item_id; END IF;
END $$;

-- 5.5 Позиція готова: статус + сповіщення офіціанту
CREATE OR REPLACE FUNCTION fn_kds_ready(p_item_id bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_order bigint; v_event bigint;
BEGIN
    UPDATE order_items SET status = 'ready', ready_at = now()
     WHERE order_item_id = p_item_id AND status = 'cooking'
    RETURNING order_id INTO v_order;
    IF NOT FOUND THEN RAISE EXCEPTION 'ITEM_NOT_COOKING %', p_item_id; END IF;

    INSERT INTO item_ready_events(order_item_id, order_id, table_id, waiter_id)
    SELECT p_item_id, o.order_id, o.table_id, o.waiter_id FROM orders o WHERE o.order_id = v_order
    RETURNING event_id INTO v_event;
    RETURN v_event;
END $$;

-- 5.6 Офіціант виніс страву
CREATE OR REPLACE FUNCTION fn_live_mark_served(p_item_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE order_items SET status = 'served' WHERE order_item_id = p_item_id AND status = 'ready';
    IF NOT FOUND THEN RAISE EXCEPTION 'ITEM_NOT_READY %', p_item_id; END IF;
    UPDATE item_ready_events SET acked_at = now() WHERE order_item_id = p_item_id AND acked_at IS NULL;
END $$;

-- 5.7 Непрочитані сповіщення офіціанта
CREATE OR REPLACE FUNCTION fn_waiter_notifications(p_waiter_id integer, p_after bigint DEFAULT 0)
RETURNS TABLE (event_id bigint, order_id bigint, table_number integer, dish_name varchar, created_at timestamptz)
LANGUAGE sql STABLE AS $$
    SELECT e.event_id, e.order_id, t.table_number, d.name, e.created_at
    FROM item_ready_events e
    JOIN order_items oi      ON oi.order_item_id = e.order_item_id
    JOIN dishes d            ON d.dish_id = oi.dish_id
    JOIN restaurant_tables t ON t.table_id = e.table_id
    WHERE e.waiter_id = p_waiter_id AND e.acked_at IS NULL AND e.event_id > p_after
    ORDER BY e.event_id
$$;

-- 5.8 Живий чек столу (шапка + позиції). Аналог Redis: order:{id} + order:{id}:items
CREATE OR REPLACE FUNCTION fn_order_check(p_order_id bigint)
RETURNS TABLE (order_id bigint, status text, opened_at timestamptz, table_number integer, hall_name varchar,
               waiter_name text, subtotal numeric, order_item_id bigint, dish_id integer, dish_name varchar,
               quantity integer, unit_price numeric, item_status text, comment varchar,
               added_at timestamptz, sent_at timestamptz, ready_at timestamptz)
LANGUAGE sql STABLE AS $$
    SELECT o.order_id, o.status::text, o.opened_at, t.table_number, h.name,
           e.first_name || ' ' || e.last_name, o.subtotal,
           oi.order_item_id, oi.dish_id, d.name, oi.quantity, oi.unit_price, oi.status::text,
           oi.comment, oi.added_at, oi.sent_at, oi.ready_at
    FROM orders o
    JOIN restaurant_tables t ON t.table_id = o.table_id
    JOIN halls h             ON h.hall_id = t.hall_id
    JOIN employees e         ON e.employee_id = o.waiter_id
    LEFT JOIN order_items oi ON oi.order_id = o.order_id AND oi.status <> 'cancelled'
    LEFT JOIN dishes d       ON d.dish_id = oi.dish_id
    WHERE o.order_id = p_order_id
    ORDER BY oi.order_item_id
$$;

-- 5.9 Мапа залу: усі столи + відкрите замовлення + кількість готових страв «на видачу»
CREATE OR REPLACE FUNCTION fn_hall_map()
RETURNS TABLE (table_id integer, hall_name varchar, table_number integer, seats integer,
               order_id bigint, waiter_name text, opened_at timestamptz,
               subtotal numeric, ready_items bigint)
LANGUAGE sql STABLE AS $$
    SELECT t.table_id, h.name, t.table_number, t.seats,
           o.order_id, e.first_name || ' ' || e.last_name, o.opened_at, o.subtotal,
           (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.order_id AND oi.status = 'ready')
    FROM restaurant_tables t
    JOIN halls h          ON h.hall_id = t.hall_id
    LEFT JOIN orders o    ON o.table_id = t.table_id AND o.status IN ('open', 'in_kitchen', 'served')
    LEFT JOIN employees e ON e.employee_id = o.waiter_id
    WHERE NOT t.is_deleted
    ORDER BY h.hall_id, t.table_number
$$;

-- 5.10 ТОП-N страв за сьогодні (порції, відправлені на кухню, без скасованих)
CREATE OR REPLACE FUNCTION fn_top_dishes_today(p_limit integer DEFAULT 10)
RETURNS TABLE (dish_id integer, dish_name varchar, qty bigint)
LANGUAGE sql STABLE AS $$
    SELECT d.dish_id, d.name, sum(oi.quantity)::bigint AS qty
    FROM order_items oi
    JOIN dishes d ON d.dish_id = oi.dish_id
    WHERE oi.sent_at >= date_trunc('day', now()) AND oi.status <> 'cancelled'
    GROUP BY d.dish_id, d.name
    ORDER BY qty DESC, d.dish_id
    LIMIT p_limit
$$;
