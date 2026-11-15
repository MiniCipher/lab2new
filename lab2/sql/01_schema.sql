-- =====================================================================
-- Система управління ресторанним бізнесом (PostgreSQL 14+)
-- 01_schema.sql : схема, типи, таблиці, обмеження, індекси
-- =====================================================================
DROP SCHEMA IF EXISTS restaurant CASCADE;
CREATE SCHEMA restaurant;
SET search_path TO restaurant, public;

-- ---------------------------------------------------------------------
-- Перелічувані типи
-- ---------------------------------------------------------------------
CREATE TYPE order_status        AS ENUM ('open', 'in_kitchen', 'served', 'paid', 'cancelled');
CREATE TYPE order_item_status   AS ENUM ('new', 'cooking', 'ready', 'served', 'cancelled');
CREATE TYPE reservation_status  AS ENUM ('pending', 'confirmed', 'seated', 'completed', 'cancelled', 'no_show');
CREATE TYPE payment_method      AS ENUM ('cash', 'card', 'online');

-- ---------------------------------------------------------------------
-- 1. roles — посади / ролі співробітників
-- ---------------------------------------------------------------------
CREATE TABLE roles (
    role_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         varchar(50) NOT NULL UNIQUE,
    description  varchar(255)
);

-- ---------------------------------------------------------------------
-- 2. employees — співробітники (SOFT DELETE + AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_id      integer       NOT NULL REFERENCES roles(role_id),
    first_name   varchar(60)   NOT NULL,
    last_name    varchar(60)   NOT NULL,
    phone        varchar(20)   NOT NULL,
    email        varchar(120),
    hire_date    date          NOT NULL DEFAULT current_date,
    salary       numeric(10,2) NOT NULL CHECK (salary >= 0),
    -- audit
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now(),
    updated_by   integer       REFERENCES employees(employee_id),
    -- soft delete
    is_deleted   boolean       NOT NULL DEFAULT false,
    deleted_at   timestamptz,
    deleted_by   integer       REFERENCES employees(employee_id),
    CONSTRAINT ck_employees_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 3. halls — зали
-- ---------------------------------------------------------------------
CREATE TABLE halls (
    hall_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         varchar(80) NOT NULL UNIQUE,
    description  varchar(255)
);

-- ---------------------------------------------------------------------
-- 4. restaurant_tables — столи (SOFT DELETE + AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE restaurant_tables (
    table_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hall_id       integer  NOT NULL REFERENCES halls(hall_id),
    table_number  integer  NOT NULL CHECK (table_number > 0),
    seats         integer  NOT NULL CHECK (seats > 0),
    is_available  boolean  NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    integer  REFERENCES employees(employee_id),
    is_deleted    boolean  NOT NULL DEFAULT false,
    deleted_at    timestamptz,
    deleted_by    integer  REFERENCES employees(employee_id),
    CONSTRAINT uq_table_in_hall UNIQUE (hall_id, table_number),
    CONSTRAINT ck_tables_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 5. customers — клієнти (SOFT DELETE + AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name      varchar(60) NOT NULL,
    last_name       varchar(60) NOT NULL,
    phone           varchar(20) NOT NULL,
    email           varchar(120),
    birth_date      date CHECK (birth_date < current_date),
    loyalty_points  integer NOT NULL DEFAULT 0 CHECK (loyalty_points >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      integer REFERENCES employees(employee_id),
    is_deleted      boolean NOT NULL DEFAULT false,
    deleted_at      timestamptz,
    deleted_by      integer REFERENCES employees(employee_id),
    CONSTRAINT ck_customers_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 6. reservations — бронювання (AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE reservations (
    reservation_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     integer NOT NULL REFERENCES customers(customer_id),
    table_id        integer NOT NULL REFERENCES restaurant_tables(table_id),
    reserved_from   timestamptz NOT NULL,
    reserved_to     timestamptz NOT NULL,
    guests_count    integer NOT NULL CHECK (guests_count > 0),
    status          reservation_status NOT NULL DEFAULT 'pending',
    comment         varchar(500),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      integer REFERENCES employees(employee_id),
    CONSTRAINT ck_reservation_period CHECK (reserved_to > reserved_from)
);

-- ---------------------------------------------------------------------
-- 7. menu_categories — категорії меню
-- ---------------------------------------------------------------------
CREATE TABLE menu_categories (
    category_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         varchar(80) NOT NULL UNIQUE,
    sort_order   integer NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- 8. dishes — страви (SOFT DELETE + AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE dishes (
    dish_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id       integer NOT NULL REFERENCES menu_categories(category_id),
    name              varchar(120) NOT NULL,
    description       varchar(500),
    price             numeric(10,2) NOT NULL CHECK (price >= 0),
    cooking_time_min  integer NOT NULL DEFAULT 10 CHECK (cooking_time_min > 0),
    is_available      boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        integer REFERENCES employees(employee_id),
    is_deleted        boolean NOT NULL DEFAULT false,
    deleted_at        timestamptz,
    deleted_by        integer REFERENCES employees(employee_id),
    CONSTRAINT ck_dishes_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 9. ingredients — інгредієнти / складські залишки (SOFT DELETE + AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE ingredients (
    ingredient_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           varchar(100) NOT NULL,
    unit           varchar(10)  NOT NULL,            -- кг, л, шт
    stock_qty      numeric(12,3) NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),
    min_stock_qty  numeric(12,3) NOT NULL DEFAULT 0 CHECK (min_stock_qty >= 0),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     integer REFERENCES employees(employee_id),
    is_deleted     boolean NOT NULL DEFAULT false,
    deleted_at     timestamptz,
    deleted_by     integer REFERENCES employees(employee_id),
    CONSTRAINT ck_ingredients_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 10. dish_ingredients — рецептура (зв'язок M:N)
-- ---------------------------------------------------------------------
CREATE TABLE dish_ingredients (
    dish_id        integer NOT NULL REFERENCES dishes(dish_id) ON DELETE CASCADE,
    ingredient_id  integer NOT NULL REFERENCES ingredients(ingredient_id),
    quantity       numeric(12,3) NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (dish_id, ingredient_id)
);

-- ---------------------------------------------------------------------
-- 11. suppliers — постачальники (SOFT DELETE + AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE suppliers (
    supplier_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            varchar(120) NOT NULL,
    contact_person  varchar(120),
    phone           varchar(20),
    email           varchar(120),
    address         varchar(255),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      integer REFERENCES employees(employee_id),
    is_deleted      boolean NOT NULL DEFAULT false,
    deleted_at      timestamptz,
    deleted_by      integer REFERENCES employees(employee_id),
    CONSTRAINT ck_suppliers_deleted CHECK (is_deleted = (deleted_at IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 12. deliveries — поставки
-- ---------------------------------------------------------------------
CREATE TABLE deliveries (
    delivery_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id    integer NOT NULL REFERENCES suppliers(supplier_id),
    received_by    integer NOT NULL REFERENCES employees(employee_id),
    delivery_date  timestamptz NOT NULL DEFAULT now(),
    total_amount   numeric(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

-- ---------------------------------------------------------------------
-- 13. delivery_items — позиції поставки
-- ---------------------------------------------------------------------
CREATE TABLE delivery_items (
    delivery_item_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delivery_id       bigint  NOT NULL REFERENCES deliveries(delivery_id) ON DELETE CASCADE,
    ingredient_id     integer NOT NULL REFERENCES ingredients(ingredient_id),
    quantity          numeric(12,3) NOT NULL CHECK (quantity > 0),
    unit_price        numeric(10,2) NOT NULL CHECK (unit_price >= 0)
);

-- ---------------------------------------------------------------------
-- 14. discounts — знижки / промокоди
-- ---------------------------------------------------------------------
CREATE TABLE discounts (
    discount_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         varchar(30) NOT NULL UNIQUE,
    description  varchar(255),
    percent      numeric(5,2) NOT NULL CHECK (percent > 0 AND percent <= 100),
    valid_from   date NOT NULL,
    valid_to     date NOT NULL,
    is_active    boolean NOT NULL DEFAULT true,
    CONSTRAINT ck_discount_period CHECK (valid_to >= valid_from)
);

-- ---------------------------------------------------------------------
-- 15. shifts — робочі зміни
-- ---------------------------------------------------------------------
CREATE TABLE shifts (
    shift_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id  integer NOT NULL REFERENCES employees(employee_id),
    started_at   timestamptz NOT NULL DEFAULT now(),
    ended_at     timestamptz,
    CONSTRAINT ck_shift_period CHECK (ended_at IS NULL OR ended_at > started_at)
);

-- ---------------------------------------------------------------------
-- 16. orders — замовлення (AUDIT)
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_id         integer NOT NULL REFERENCES restaurant_tables(table_id),
    waiter_id        integer NOT NULL REFERENCES employees(employee_id),
    customer_id      integer REFERENCES customers(customer_id),
    discount_id      integer REFERENCES discounts(discount_id),
    status           order_status NOT NULL DEFAULT 'open',
    opened_at        timestamptz NOT NULL DEFAULT now(),
    closed_at        timestamptz,
    subtotal         numeric(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_amount  numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount     numeric(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    comment          varchar(500),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       integer REFERENCES employees(employee_id),
    CONSTRAINT ck_order_closed CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

-- ---------------------------------------------------------------------
-- 17. order_items — позиції замовлення
-- ---------------------------------------------------------------------
CREATE TABLE order_items (
    order_item_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id       bigint  NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    dish_id        integer NOT NULL REFERENCES dishes(dish_id),
    quantity       integer NOT NULL CHECK (quantity > 0),
    unit_price     numeric(10,2) NOT NULL CHECK (unit_price >= 0),
    status         order_item_status NOT NULL DEFAULT 'new'
);

-- ---------------------------------------------------------------------
-- 18. payments — оплати
-- ---------------------------------------------------------------------
CREATE TABLE payments (
    payment_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    bigint  NOT NULL REFERENCES orders(order_id),
    cashier_id  integer NOT NULL REFERENCES employees(employee_id),
    amount      numeric(12,2) NOT NULL CHECK (amount > 0),
    method      payment_method NOT NULL,
    paid_at     timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 19. audit_log — журнал змін (заповнюється тригерами)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name  varchar(63) NOT NULL,
    record_id   varchar(40) NOT NULL,
    operation   varchar(10) NOT NULL,
    old_data    jsonb,
    new_data    jsonb,
    changed_by  integer,
    changed_at  timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- ІНДЕКСИ (B-tree, partial B-tree, Hash, GIN, GiST, BRIN)
-- =====================================================================

-- B-tree (часткові, унікальні лише серед "живих" записів)
CREATE UNIQUE INDEX ux_employees_email_active  ON employees (lower(email))
    WHERE NOT is_deleted AND email IS NOT NULL;
CREATE UNIQUE INDEX ux_customers_phone_active  ON customers (phone)
    WHERE NOT is_deleted;
CREATE INDEX ix_employees_role      ON employees (role_id)     WHERE NOT is_deleted;
CREATE INDEX ix_dishes_category     ON dishes (category_id)    WHERE NOT is_deleted;

-- B-tree по зовнішніх ключах / частих фільтрах
CREATE INDEX ix_orders_status_opened ON orders (status, opened_at DESC);
CREATE INDEX ix_orders_waiter        ON orders (waiter_id);
CREATE INDEX ix_orders_table         ON orders (table_id);
CREATE INDEX ix_order_items_order    ON order_items (order_id);
CREATE INDEX ix_order_items_dish     ON order_items (dish_id);
CREATE INDEX ix_payments_order       ON payments (order_id);
CREATE INDEX ix_delivery_items_deliv ON delivery_items (delivery_id);
CREATE INDEX ix_shifts_employee_open ON shifts (employee_id) WHERE ended_at IS NULL;

-- HASH — швидкий пошук за точним збігом
CREATE INDEX hx_customers_email ON customers USING hash (lower(email));
CREATE INDEX hx_discounts_code  ON discounts USING hash (code);

-- GIN — повнотекстовий пошук по стравах
CREATE INDEX gx_dishes_fts ON dishes
    USING gin (to_tsvector('simple', name || ' ' || coalesce(description, '')));

-- GiST — перевірка перетину інтервалів бронювань
CREATE INDEX gix_reservations_period ON reservations
    USING gist (tstzrange(reserved_from, reserved_to));

-- BRIN — великі "append-only" таблиці, впорядковані за часом
CREATE INDEX brin_audit_changed_at ON audit_log USING brin (changed_at);
CREATE INDEX brin_payments_paid_at ON payments  USING brin (paid_at);
