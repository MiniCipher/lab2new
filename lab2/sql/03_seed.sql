-- =====================================================================
-- 03_seed.sql : тестові дані (виконувати після 01 та 02)
-- =====================================================================
SET search_path TO restaurant, public;

-- Очищення даних і скидання лічильників id (щоб скрипт можна було запускати повторно)
TRUNCATE TABLE audit_log, payments, order_items, orders, shifts, discounts,
               delivery_items, deliveries, suppliers, dish_ingredients, ingredients,
               dishes, menu_categories, reservations, customers, restaurant_tables,
               halls, employees, roles
    RESTART IDENTITY CASCADE;

INSERT INTO roles(name, description) VALUES
 ('Адміністратор', 'Керування рестораном'),
 ('Офіціант',      'Обслуговування гостей'),
 ('Касир',         'Прийом оплат'),
 ('Кухар',         'Приготування страв');

-- Перший співробітник (id = 1) — адміністратор; використовується як поточний користувач
INSERT INTO employees(role_id, first_name, last_name, phone, email, salary) VALUES
 (1, 'Олена',  'Коваленко', '+380501110001', 'admin@resto.ua',  30000),
 (2, 'Андрій', 'Мельник',   '+380501110002', 'waiter@resto.ua', 18000),
 (3, 'Ірина',  'Шевченко',  '+380501110003', 'cashier@resto.ua',17000),
 (4, 'Максим', 'Бондар',    '+380501110004', 'chef@resto.ua',   25000);

INSERT INTO halls(name, description) VALUES
 ('Основний зал', 'Класичний зал'),
 ('Тераса',       'Літня тераса');

INSERT INTO restaurant_tables(hall_id, table_number, seats) VALUES
 (1, 1, 2), (1, 2, 4), (1, 3, 6), (2, 1, 4), (2, 2, 8);

INSERT INTO customers(first_name, last_name, phone, email) VALUES
 ('Петро', 'Іваненко', '+380671230001', 'petro@example.com'),
 ('Марія', 'Ткачук',   '+380671230002', 'maria@example.com');

INSERT INTO menu_categories(name, sort_order) VALUES
 ('Закуски', 1), ('Основні страви', 2), ('Десерти', 3), ('Напої', 4);

INSERT INTO ingredients(name, unit, min_stock_qty) VALUES
 ('Картопля', 'кг', 5), ('Куряче філе', 'кг', 5), ('Сир', 'кг', 2),
 ('Борошно', 'кг', 5), ('Томати', 'кг', 3), ('Цукор', 'кг', 2),
 ('Кава в зернах', 'кг', 1), ('Яйця', 'шт', 30);

INSERT INTO dishes(category_id, name, description, price, cooking_time_min) VALUES
 (1, 'Брускета з томатами', 'Хліб, томати, базилік',         120.00,  7),
 (2, 'Курча по-київськи',   'Куряче філе з вершковим маслом', 280.00, 25),
 (2, 'Піца Маргарита',      'Томати, сир моцарела',           220.00, 15),
 (3, 'Тірамісу',            'Класичний італійський десерт',   150.00,  5),
 (4, 'Еспресо',             'Міцна кава',                      60.00,  3);

INSERT INTO dish_ingredients(dish_id, ingredient_id, quantity)
SELECT d.dish_id, i.ingredient_id, v.qty
FROM (VALUES
  ('Брускета з томатами', 'Томати',        0.100),
  ('Брускета з томатами', 'Борошно',       0.050),
  ('Курча по-київськи',   'Куряче філе',   0.250),
  ('Курча по-київськи',   'Яйця',          1.000),
  ('Піца Маргарита',      'Борошно',       0.300),
  ('Піца Маргарита',      'Сир',           0.150),
  ('Піца Маргарита',      'Томати',        0.100),
  ('Тірамісу',            'Сир',           0.100),
  ('Тірамісу',            'Цукор',         0.030),
  ('Тірамісу',            'Яйця',          2.000),
  ('Еспресо',             'Кава в зернах', 0.010)
) AS v(dish, ingr, qty)
JOIN dishes d      ON d.name = v.dish
JOIN ingredients i ON i.name = v.ingr;

INSERT INTO suppliers(name, contact_person, phone, email, address) VALUES
 ('ТОВ "Свіжі продукти"', 'Олег Петренко', '+380441110000', 'sales@fresh.ua', 'м. Київ, вул. Складська, 1');

INSERT INTO discounts(code, description, percent, valid_from, valid_to) VALUES
 ('WELCOME10', 'Знижка 10% для нових гостей', 10, current_date - 30, current_date + 365);

-- Поставка продуктів (через функції/процедури; тригер поповнить склад)
DO $$
DECLARE
    v_delivery bigint;
    r record;
BEGIN
    PERFORM set_config('app.current_user_id', '1', true);
    v_delivery := fn_create_delivery(1, 1);

    FOR r IN
        SELECT i.ingredient_id, v.qty, v.price
        FROM (VALUES
            ('Картопля',      50, 15),
            ('Куряче філе',   30, 140),
            ('Сир',           20, 300),
            ('Борошно',       40, 25),
            ('Томати',        20, 60),
            ('Цукор',         10, 30),
            ('Кава в зернах',  5, 500),
            ('Яйця',         200, 6)
        ) AS v(ingr, qty, price)
        JOIN ingredients i ON i.name = v.ingr
    LOOP
        CALL sp_add_delivery_item(v_delivery, r.ingredient_id, r.qty::numeric, r.price::numeric);
    END LOOP;
END $$;
