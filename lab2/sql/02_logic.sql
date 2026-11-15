-- =====================================================================
-- 02_logic.sql : функції, процедури, тригери, представлення (views)
-- =====================================================================
SET search_path TO restaurant, public;

-- =====================================================================
-- A. КОРИСТУВАЦЬКІ ФУНКЦІЇ
-- =====================================================================

-- A1. Поточний користувач застосунку (передається через set_config('app.current_user_id', ..., true))
CREATE OR REPLACE FUNCTION fn_current_user_id()
RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::integer
$$;

-- A2. Чи можна приготувати N порцій страви (достатньо інгредієнтів, страва доступна)
CREATE OR REPLACE FUNCTION fn_dish_can_be_cooked(p_dish_id integer, p_qty integer)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM dishes d
                   WHERE d.dish_id = p_dish_id AND NOT d.is_deleted AND d.is_available)
       AND NOT EXISTS (SELECT 1
                       FROM dish_ingredients di
                       JOIN ingredients i ON i.ingredient_id = di.ingredient_id
                       WHERE di.dish_id = p_dish_id
                         AND (i.is_deleted OR i.stock_qty < di.quantity * p_qty))
$$;

-- A3. Чи вільний стіл на вказаний проміжок часу
CREATE OR REPLACE FUNCTION fn_table_is_free(p_table_id integer, p_from timestamptz, p_to timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM reservations r
        WHERE r.table_id = p_table_id
          AND r.status IN ('pending', 'confirmed', 'seated')
          AND tstzrange(r.reserved_from, r.reserved_to) && tstzrange(p_from, p_to))
$$;

-- A4. Створення співробітника
CREATE OR REPLACE FUNCTION fn_create_employee(
    p_role_id integer, p_first_name varchar, p_last_name varchar,
    p_phone varchar, p_email varchar, p_salary numeric)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_id integer;
BEGIN
    INSERT INTO employees(role_id, first_name, last_name, phone, email, salary)
    VALUES (p_role_id, p_first_name, p_last_name, p_phone, p_email, p_salary)
    RETURNING employee_id INTO v_id;
    RETURN v_id;
END $$;

-- A5. Створення клієнта
CREATE OR REPLACE FUNCTION fn_create_customer(
    p_first_name varchar, p_last_name varchar, p_phone varchar,
    p_email varchar DEFAULT NULL, p_birth_date date DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_id integer;
BEGIN
    INSERT INTO customers(first_name, last_name, phone, email, birth_date)
    VALUES (p_first_name, p_last_name, p_phone, p_email, p_birth_date)
    RETURNING customer_id INTO v_id;
    RETURN v_id;
END $$;

-- A6. Створення страви
CREATE OR REPLACE FUNCTION fn_create_dish(
    p_category_id integer, p_name varchar, p_description varchar,
    p_price numeric, p_cooking_time_min integer DEFAULT 10)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_id integer;
BEGIN
    INSERT INTO dishes(category_id, name, description, price, cooking_time_min)
    VALUES (p_category_id, p_name, p_description, p_price, p_cooking_time_min)
    RETURNING dish_id INTO v_id;
    RETURN v_id;
END $$;

-- A7. Створення бронювання
CREATE OR REPLACE FUNCTION fn_create_reservation(
    p_customer_id integer, p_table_id integer,
    p_from timestamptz, p_to timestamptz, p_guests integer, p_comment varchar DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_seats integer; v_id integer;
BEGIN
    SELECT seats INTO v_seats FROM restaurant_tables WHERE table_id = p_table_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Стіл % не існує або видалений', p_table_id; END IF;
    IF p_guests > v_seats THEN
        RAISE EXCEPTION 'Стіл % розрахований на % місць, а гостей %', p_table_id, v_seats, p_guests;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Клієнт % не існує або видалений', p_customer_id;
    END IF;

    INSERT INTO reservations(customer_id, table_id, reserved_from, reserved_to, guests_count, comment, status)
    VALUES (p_customer_id, p_table_id, p_from, p_to, p_guests, p_comment, 'confirmed')
    RETURNING reservation_id INTO v_id;
    RETURN v_id;
END $$;

-- A8. Створення замовлення (займає стіл)
CREATE OR REPLACE FUNCTION fn_create_order(
    p_table_id integer, p_waiter_id integer, p_customer_id integer DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
    PERFORM 1 FROM restaurant_tables
     WHERE table_id = p_table_id AND NOT is_deleted AND is_available
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Стіл % недоступний або не існує', p_table_id; END IF;

    IF NOT EXISTS (SELECT 1 FROM employees WHERE employee_id = p_waiter_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Офіціант % не існує або звільнений', p_waiter_id;
    END IF;
    IF p_customer_id IS NOT NULL AND
       NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Клієнт % не існує або видалений', p_customer_id;
    END IF;

    INSERT INTO orders(table_id, waiter_id, customer_id)
    VALUES (p_table_id, p_waiter_id, p_customer_id)
    RETURNING order_id INTO v_id;

    UPDATE restaurant_tables SET is_available = false WHERE table_id = p_table_id;
    RETURN v_id;
END $$;

-- A9. Створення поставки
CREATE OR REPLACE FUNCTION fn_create_delivery(p_supplier_id integer, p_received_by integer)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM suppliers WHERE supplier_id = p_supplier_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Постачальник % не існує або видалений', p_supplier_id;
    END IF;
    INSERT INTO deliveries(supplier_id, received_by) VALUES (p_supplier_id, p_received_by)
    RETURNING delivery_id INTO v_id;
    RETURN v_id;
END $$;

-- =====================================================================
-- B. ЗБЕРЕЖЕНІ ПРОЦЕДУРИ
-- =====================================================================

-- B1. Перерахунок суми замовлення
CREATE OR REPLACE PROCEDURE sp_recalc_order(p_order_id bigint)
LANGUAGE plpgsql AS $$
DECLARE v_sub numeric(12,2); v_pct numeric(5,2); v_disc numeric(12,2);
BEGIN
    SELECT COALESCE(SUM(quantity * unit_price), 0) INTO v_sub
      FROM order_items WHERE order_id = p_order_id AND status <> 'cancelled';

    SELECT COALESCE(d.percent, 0) INTO v_pct
      FROM orders o LEFT JOIN discounts d ON d.discount_id = o.discount_id
     WHERE o.order_id = p_order_id;

    v_disc := round(v_sub * COALESCE(v_pct, 0) / 100, 2);

    UPDATE orders
       SET subtotal = v_sub, discount_amount = v_disc, total_amount = v_sub - v_disc
     WHERE order_id = p_order_id;
END $$;

-- B2. Додати позицію до замовлення
CREATE OR REPLACE PROCEDURE sp_add_order_item(p_order_id bigint, p_dish_id integer, p_quantity integer)
LANGUAGE plpgsql AS $$
DECLARE v_status order_status;
BEGIN
    SELECT status INTO v_status FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Замовлення % не знайдено', p_order_id; END IF;
    IF v_status IN ('paid', 'cancelled') THEN
        RAISE EXCEPTION 'Замовлення % закрите (статус %)', p_order_id, v_status;
    END IF;
    IF NOT fn_dish_can_be_cooked(p_dish_id, p_quantity) THEN
        RAISE EXCEPTION 'Страву % у кількості % приготувати неможливо (немає інгредієнтів або страва недоступна)',
            p_dish_id, p_quantity;
    END IF;

    INSERT INTO order_items(order_id, dish_id, quantity) VALUES (p_order_id, p_dish_id, p_quantity);
    -- ціну виставляє тригер, суму замовлення перераховує тригер
END $$;

-- B3. Застосувати промокод до замовлення
CREATE OR REPLACE PROCEDURE sp_apply_discount(p_order_id bigint, p_code varchar)
LANGUAGE plpgsql AS $$
DECLARE v_discount_id integer;
BEGIN
    SELECT discount_id INTO v_discount_id FROM discounts
     WHERE code = p_code AND is_active AND current_date BETWEEN valid_from AND valid_to;
    IF NOT FOUND THEN RAISE EXCEPTION 'Промокод % недійсний', p_code; END IF;

    UPDATE orders SET discount_id = v_discount_id
     WHERE order_id = p_order_id AND status NOT IN ('paid', 'cancelled');
    IF NOT FOUND THEN RAISE EXCEPTION 'Замовлення % не існує або вже закрите', p_order_id; END IF;

    CALL sp_recalc_order(p_order_id);
END $$;

-- B4. Оплата замовлення (списує інгредієнти, нараховує бали, звільняє стіл)
CREATE OR REPLACE PROCEDURE sp_pay_order(
    p_order_id bigint, p_amount numeric, p_method text, p_cashier_id integer)
LANGUAGE plpgsql AS $$
DECLARE v_order orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Замовлення % не знайдено', p_order_id; END IF;
    IF v_order.status IN ('paid', 'cancelled') THEN
        RAISE EXCEPTION 'Замовлення % уже закрите (статус %)', p_order_id, v_order.status;
    END IF;
    IF v_order.total_amount <= 0 THEN RAISE EXCEPTION 'Замовлення % порожнє', p_order_id; END IF;
    IF p_amount <> v_order.total_amount THEN
        RAISE EXCEPTION 'Сума оплати % не збігається із сумою замовлення %', p_amount, v_order.total_amount;
    END IF;

    INSERT INTO payments(order_id, cashier_id, amount, method)
    VALUES (p_order_id, p_cashier_id, p_amount, p_method::payment_method);

    -- списання інгредієнтів (CHECK stock_qty >= 0 відкотить транзакцію при нестачі)
    UPDATE ingredients i
       SET stock_qty = i.stock_qty - x.used
      FROM (SELECT di.ingredient_id, SUM(di.quantity * oi.quantity) AS used
              FROM order_items oi
              JOIN dish_ingredients di ON di.dish_id = oi.dish_id
             WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
             GROUP BY di.ingredient_id) x
     WHERE i.ingredient_id = x.ingredient_id;

    UPDATE order_items SET status = 'served' WHERE order_id = p_order_id AND status <> 'cancelled';
    UPDATE orders SET status = 'paid', closed_at = now() WHERE order_id = p_order_id;
    UPDATE restaurant_tables SET is_available = true WHERE table_id = v_order.table_id;

    IF v_order.customer_id IS NOT NULL THEN
        UPDATE customers SET loyalty_points = loyalty_points + floor(p_amount / 10)::integer
         WHERE customer_id = v_order.customer_id;
    END IF;
END $$;

-- B5. Скасування замовлення
CREATE OR REPLACE PROCEDURE sp_cancel_order(p_order_id bigint)
LANGUAGE plpgsql AS $$
DECLARE v_order orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Замовлення % не знайдено', p_order_id; END IF;
    IF v_order.status = 'paid' THEN RAISE EXCEPTION 'Оплачене замовлення % скасувати не можна', p_order_id; END IF;
    IF v_order.status = 'cancelled' THEN RETURN; END IF;

    UPDATE order_items SET status = 'cancelled' WHERE order_id = p_order_id;
    UPDATE orders SET status = 'cancelled', closed_at = now() WHERE order_id = p_order_id;
    UPDATE restaurant_tables SET is_available = true WHERE table_id = v_order.table_id;
END $$;

-- B6. Скасування бронювання
CREATE OR REPLACE PROCEDURE sp_cancel_reservation(p_reservation_id integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE reservations SET status = 'cancelled'
     WHERE reservation_id = p_reservation_id AND status IN ('pending', 'confirmed');
    IF NOT FOUND THEN RAISE EXCEPTION 'Бронювання % не знайдено або не може бути скасоване', p_reservation_id; END IF;
END $$;

-- B7. Додати позицію до поставки (залишки оновлює тригер)
CREATE OR REPLACE PROCEDURE sp_add_delivery_item(
    p_delivery_id bigint, p_ingredient_id integer, p_quantity numeric, p_unit_price numeric)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO delivery_items(delivery_id, ingredient_id, quantity, unit_price)
    VALUES (p_delivery_id, p_ingredient_id, p_quantity, p_unit_price);
END $$;

-- B8. Зміна ціни страви
CREATE OR REPLACE PROCEDURE sp_update_dish_price(p_dish_id integer, p_new_price numeric)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE dishes SET price = p_new_price WHERE dish_id = p_dish_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Страву % не знайдено', p_dish_id; END IF;
END $$;

-- B9. SOFT DELETE / RESTORE: співробітники
CREATE OR REPLACE PROCEDURE sp_soft_delete_employee(p_employee_id integer, p_deleted_by integer)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM orders WHERE waiter_id = p_employee_id AND status NOT IN ('paid', 'cancelled')) THEN
        RAISE EXCEPTION 'Співробітник % має незакриті замовлення', p_employee_id;
    END IF;

    UPDATE shifts SET ended_at = now() WHERE employee_id = p_employee_id AND ended_at IS NULL;

    UPDATE employees
       SET is_deleted = true, deleted_at = now(), deleted_by = p_deleted_by
     WHERE employee_id = p_employee_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Співробітника % не знайдено або вже видалено', p_employee_id; END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_restore_employee(p_employee_id integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE employees SET is_deleted = false, deleted_at = NULL, deleted_by = NULL
     WHERE employee_id = p_employee_id AND is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Видаленого співробітника % не знайдено', p_employee_id; END IF;
END $$;

-- B10. SOFT DELETE / RESTORE: страви
CREATE OR REPLACE PROCEDURE sp_soft_delete_dish(p_dish_id integer, p_deleted_by integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE dishes SET is_deleted = true, deleted_at = now(), deleted_by = p_deleted_by
     WHERE dish_id = p_dish_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Страву % не знайдено або вже видалено', p_dish_id; END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_restore_dish(p_dish_id integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE dishes SET is_deleted = false, deleted_at = NULL, deleted_by = NULL
     WHERE dish_id = p_dish_id AND is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Видаленої страви % не знайдено', p_dish_id; END IF;
END $$;

-- B11. SOFT DELETE: клієнти
CREATE OR REPLACE PROCEDURE sp_soft_delete_customer(p_customer_id integer, p_deleted_by integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE customers SET is_deleted = true, deleted_at = now(), deleted_by = p_deleted_by
     WHERE customer_id = p_customer_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Клієнта % не знайдено або вже видалено', p_customer_id; END IF;
END $$;

-- B12. Зміни співробітників
CREATE OR REPLACE PROCEDURE sp_start_shift(p_employee_id integer)
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM shifts WHERE employee_id = p_employee_id AND ended_at IS NULL) THEN
        RAISE EXCEPTION 'У співробітника % вже є відкрита зміна', p_employee_id;
    END IF;
    INSERT INTO shifts(employee_id) VALUES (p_employee_id);
END $$;

CREATE OR REPLACE PROCEDURE sp_end_shift(p_employee_id integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE shifts SET ended_at = now() WHERE employee_id = p_employee_id AND ended_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'У співробітника % немає відкритої зміни', p_employee_id; END IF;
END $$;

-- =====================================================================
-- C. ПРЕДСТАВЛЕННЯ (VIEW)
-- =====================================================================

CREATE OR REPLACE VIEW v_active_employees AS
SELECT e.employee_id, e.first_name, e.last_name, e.first_name || ' ' || e.last_name AS full_name,
       r.role_id, r.name AS role_name, e.phone, e.email, e.hire_date, e.salary,
       e.updated_at, e.updated_by
FROM employees e JOIN roles r ON r.role_id = e.role_id
WHERE NOT e.is_deleted;

CREATE OR REPLACE VIEW v_active_customers AS
SELECT customer_id, first_name, last_name, first_name || ' ' || last_name AS full_name,
       phone, email, birth_date, loyalty_points, updated_at, updated_by
FROM customers WHERE NOT is_deleted;

CREATE OR REPLACE VIEW v_active_dishes AS
SELECT d.dish_id, d.category_id, c.name AS category_name, d.name, d.description,
       d.price, d.cooking_time_min, d.is_available, d.updated_at, d.updated_by
FROM dishes d JOIN menu_categories c ON c.category_id = d.category_id
WHERE NOT d.is_deleted;

CREATE OR REPLACE VIEW v_free_tables AS
SELECT t.table_id, t.table_number, h.hall_id, h.name AS hall_name, t.seats
FROM restaurant_tables t JOIN halls h ON h.hall_id = t.hall_id
WHERE NOT t.is_deleted AND t.is_available;

CREATE OR REPLACE VIEW v_order_details AS
SELECT o.order_id, o.status::text AS status, o.opened_at, o.closed_at,
       t.table_id, t.table_number, h.name AS hall_name,
       e.employee_id AS waiter_id, e.first_name || ' ' || e.last_name AS waiter_name,
       c.customer_id, c.first_name || ' ' || c.last_name AS customer_name,
       d.code AS discount_code,
       o.subtotal, o.discount_amount, o.total_amount, o.updated_at, o.updated_by
FROM orders o
JOIN restaurant_tables t ON t.table_id = o.table_id
JOIN halls h             ON h.hall_id  = t.hall_id
JOIN employees e         ON e.employee_id = o.waiter_id
LEFT JOIN customers c    ON c.customer_id = o.customer_id
LEFT JOIN discounts d    ON d.discount_id = o.discount_id;

CREATE OR REPLACE VIEW v_order_items_detail AS
SELECT oi.order_item_id, oi.order_id, oi.dish_id, d.name AS dish_name,
       oi.quantity, oi.unit_price, oi.quantity * oi.unit_price AS line_total,
       oi.status::text AS status
FROM order_items oi JOIN dishes d ON d.dish_id = oi.dish_id;

CREATE OR REPLACE VIEW v_low_stock_ingredients AS
SELECT ingredient_id, name, unit, stock_qty, min_stock_qty, min_stock_qty - stock_qty AS shortage
FROM ingredients
WHERE NOT is_deleted AND stock_qty <= min_stock_qty;

CREATE OR REPLACE VIEW v_daily_revenue AS
SELECT p.paid_at::date AS day,
       count(*)                      AS payments_count,
       sum(p.amount)                 AS revenue,
       round(avg(p.amount), 2)       AS avg_check
FROM payments p
GROUP BY p.paid_at::date;

CREATE OR REPLACE VIEW v_popular_dishes AS
SELECT d.dish_id, d.name, sum(oi.quantity) AS sold_qty, sum(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN orders o ON o.order_id = oi.order_id AND o.status = 'paid'
JOIN dishes d ON d.dish_id = oi.dish_id
WHERE oi.status <> 'cancelled'
GROUP BY d.dish_id, d.name;

CREATE OR REPLACE VIEW v_upcoming_reservations AS
SELECT r.reservation_id, c.first_name || ' ' || c.last_name AS customer_name, c.phone,
       t.table_number, h.name AS hall_name, r.reserved_from, r.reserved_to,
       r.guests_count, r.status::text AS status
FROM reservations r
JOIN customers c         ON c.customer_id = r.customer_id
JOIN restaurant_tables t ON t.table_id = r.table_id
JOIN halls h             ON h.hall_id = t.hall_id
WHERE r.status IN ('pending', 'confirmed') AND r.reserved_to > now();

-- Табличні функції (залежать від view)
CREATE OR REPLACE FUNCTION fn_get_orders_by_period(p_from timestamptz, p_to timestamptz)
RETURNS SETOF v_order_details LANGUAGE sql STABLE AS $$
    SELECT * FROM v_order_details WHERE opened_at >= p_from AND opened_at < p_to ORDER BY opened_at
$$;

CREATE OR REPLACE FUNCTION fn_search_dishes(p_query text)
RETURNS SETOF v_active_dishes LANGUAGE sql STABLE AS $$
    SELECT * FROM v_active_dishes
    WHERE to_tsvector('simple', name || ' ' || coalesce(description, '')) @@ plainto_tsquery('simple', p_query)
$$;

CREATE OR REPLACE FUNCTION fn_employee_sales(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (employee_id integer, full_name text, orders_count bigint, total_sales numeric)
LANGUAGE sql STABLE AS $$
    SELECT e.employee_id, (e.first_name || ' ' || e.last_name)::text, count(o.order_id), COALESCE(sum(o.total_amount), 0)
    FROM employees e
    JOIN orders o ON o.waiter_id = e.employee_id AND o.status = 'paid'
                 AND o.closed_at >= p_from AND o.closed_at < p_to
    GROUP BY e.employee_id, e.first_name, e.last_name
    ORDER BY 4 DESC
$$;

-- =====================================================================
-- D. ТРИГЕРИ
-- =====================================================================

-- D1. Аудит: дата останньої зміни + користувач, що змінив
CREATE OR REPLACE FUNCTION trg_fn_set_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    NEW.updated_by := COALESCE(fn_current_user_id(), NEW.updated_by);
    RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['employees','restaurant_tables','customers','dishes',
                             'ingredients','suppliers','orders','reservations'] LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_audit BEFORE INSERT OR UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_fn_set_audit()', t, t);
    END LOOP;
END $$;

-- D2. SOFT DELETE: фізичний DELETE перетворюється на позначку is_deleted
CREATE OR REPLACE FUNCTION trg_fn_soft_delete() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_pk text := TG_ARGV[0];
    v_id bigint := (to_jsonb(OLD) ->> v_pk)::bigint;
BEGIN
    IF OLD.is_deleted THEN
        RETURN OLD;   -- вже "м'яко" видалений запис можна остаточно очистити
    END IF;
    EXECUTE format('UPDATE %I.%I SET is_deleted = true, deleted_at = now(), deleted_by = $2
                    WHERE %I = $1', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_pk)
       USING v_id, fn_current_user_id();
    RETURN NULL;      -- скасовуємо фізичне видалення
END $$;

CREATE TRIGGER trg_employees_softdel  BEFORE DELETE ON employees
    FOR EACH ROW EXECUTE FUNCTION trg_fn_soft_delete('employee_id');
CREATE TRIGGER trg_tables_softdel     BEFORE DELETE ON restaurant_tables
    FOR EACH ROW EXECUTE FUNCTION trg_fn_soft_delete('table_id');
CREATE TRIGGER trg_customers_softdel  BEFORE DELETE ON customers
    FOR EACH ROW EXECUTE FUNCTION trg_fn_soft_delete('customer_id');
CREATE TRIGGER trg_dishes_softdel     BEFORE DELETE ON dishes
    FOR EACH ROW EXECUTE FUNCTION trg_fn_soft_delete('dish_id');
CREATE TRIGGER trg_ingredients_softdel BEFORE DELETE ON ingredients
    FOR EACH ROW EXECUTE FUNCTION trg_fn_soft_delete('ingredient_id');
CREATE TRIGGER trg_suppliers_softdel  BEFORE DELETE ON suppliers
    FOR EACH ROW EXECUTE FUNCTION trg_fn_soft_delete('supplier_id');

-- D3. Журнал змін у audit_log (jsonb: старе/нове значення)
CREATE OR REPLACE FUNCTION trg_fn_audit_log() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_pk text := TG_ARGV[0]; v_row jsonb;
BEGIN
    v_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    INSERT INTO audit_log(table_name, record_id, operation, old_data, new_data, changed_by)
    VALUES (TG_TABLE_NAME, v_row ->> v_pk, TG_OP,
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END,
            fn_current_user_id());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_employees_log AFTER INSERT OR UPDATE ON employees
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('employee_id');
CREATE TRIGGER trg_dishes_log    AFTER INSERT OR UPDATE ON dishes
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('dish_id');
CREATE TRIGGER trg_customers_log AFTER INSERT OR UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('customer_id');
CREATE TRIGGER trg_orders_log    AFTER INSERT OR UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_log('order_id');

-- D4. Ціна позиції береться з меню на момент замовлення + перевірка доступності страви
CREATE OR REPLACE FUNCTION trg_fn_order_item_price() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_price numeric(10,2);
BEGIN
    SELECT price INTO v_price FROM dishes
     WHERE dish_id = NEW.dish_id AND NOT is_deleted AND is_available;
    IF NOT FOUND THEN RAISE EXCEPTION 'Страва % недоступна для замовлення', NEW.dish_id; END IF;
    IF NEW.unit_price IS NULL THEN NEW.unit_price := v_price; END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_order_items_price BEFORE INSERT ON order_items
    FOR EACH ROW EXECUTE FUNCTION trg_fn_order_item_price();

-- D5. Автоматичний перерахунок суми замовлення
CREATE OR REPLACE FUNCTION trg_fn_recalc_order() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    CALL sp_recalc_order(COALESCE(NEW.order_id, OLD.order_id));
    RETURN NULL;
END $$;

CREATE TRIGGER trg_order_items_recalc AFTER INSERT OR UPDATE OR DELETE ON order_items
    FOR EACH ROW EXECUTE FUNCTION trg_fn_recalc_order();

-- D6. Поповнення складу та сума поставки
CREATE OR REPLACE FUNCTION trg_fn_delivery_item() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE ingredients SET stock_qty = stock_qty + NEW.quantity
     WHERE ingredient_id = NEW.ingredient_id;
    UPDATE deliveries SET total_amount = total_amount + round(NEW.quantity * NEW.unit_price, 2)
     WHERE delivery_id = NEW.delivery_id;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_delivery_items_stock AFTER INSERT ON delivery_items
    FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_item();

-- D7. Заборона перетину бронювань одного столу
CREATE OR REPLACE FUNCTION trg_fn_reservation_overlap() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('pending', 'confirmed', 'seated') AND EXISTS (
        SELECT 1 FROM reservations r
        WHERE r.table_id = NEW.table_id
          AND r.reservation_id <> NEW.reservation_id
          AND r.status IN ('pending', 'confirmed', 'seated')
          AND tstzrange(r.reserved_from, r.reserved_to) && tstzrange(NEW.reserved_from, NEW.reserved_to)) THEN
        RAISE EXCEPTION 'Стіл % уже заброньовано на цей час', NEW.table_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_reservations_overlap BEFORE INSERT OR UPDATE ON reservations
    FOR EACH ROW EXECUTE FUNCTION trg_fn_reservation_overlap();
