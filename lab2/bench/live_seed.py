"""
Скидання та засів ОДНАКОВОГО «живого» стану в PostgreSQL і Redis.

Кожен сценарій бенчмарку стартує з ідентичного, відтворюваного стану
(фіксоване зерно ГПВЧ): ті самі столи, чеки, страви, кількості, статуси.
Усі зміни проходять через API обох реалізацій (LiveSQL / LiveRedis),
тобто засів — це водночас і функціональний тест.
"""
from __future__ import annotations

import random
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "common"), str(ROOT / "redis_live")]
from dbclient import PgConnection, RedisConnection  # noqa: E402
from live_redis import LiveRedis  # noqa: E402
from live_sql import LiveSQL  # noqa: E402

COMMENTS = ["", "", "", "", "без цибулі", "гостріше", "без глютену", "подати разом"]
STATIONS = ["hot", "cold", "bar", "pastry"]


@dataclass
class Item:
    sql_id: int
    oid: int
    rid: int          # id позиції всередині order:{oid}:items
    status: str = "new"
    sent: bool = False


@dataclass
class LiveState:
    orders: list = field(default_factory=list)          # [(oid, table_id, waiter_id)]
    items: list = field(default_factory=list)           # [Item]
    dishes: list = field(default_factory=list)          # доступні dish_id
    waiters: list = field(default_factory=list)
    cooks: list = field(default_factory=list)


def reset(pg: PgConnection, r: RedisConnection):
    """Прибрати весь живий стан з обох сховищ і перебудувати кеші Redis."""
    pg.query("""
        BEGIN;
        CREATE TEMP TABLE IF NOT EXISTS _live(order_id bigint) ON COMMIT DROP;
        INSERT INTO _live SELECT order_id FROM orders WHERE status IN ('open', 'in_kitchen', 'served');
        DELETE FROM item_ready_events;
        DELETE FROM order_items WHERE order_id IN (SELECT order_id FROM _live);
        DELETE FROM audit_log  WHERE table_name = 'orders' AND record_id IN (SELECT order_id::text FROM _live);
        DELETE FROM orders     WHERE order_id IN (SELECT order_id FROM _live);
        UPDATE restaurant_tables SET is_available = true WHERE NOT is_available;
        COMMIT;""")
    r.call("FLUSHDB")
    red = LiveRedis(r)
    red.build_menu_cache(pg)
    red.build_hall_cache(pg)
    red.rebuild_today_stats(pg)


def seed(pg: PgConnection, r: RedisConnection, n_orders=80, seed_value=42) -> LiveState:
    """Пікове навантаження: n_orders зайнятих столів, у кожному 6–12 позицій,
    ~75% чеків уже відправлено на кухню, частина позицій готується/готова/винесена."""
    rng = random.Random(seed_value)
    pg.query("SET synchronous_commit = off")      # засів не вимірюється — пришвидшуємо
    sql, red = LiveSQL(pg), LiveRedis(r)
    st = LiveState()
    st.dishes = [d for (d,) in pg.query("SELECT dish_id FROM v_menu WHERE available ORDER BY dish_id")]
    w = pg.query("SELECT employee_id, full_name FROM v_active_employees WHERE role_id = 2 ORDER BY 1")
    st.waiters = w
    st.cooks = [c for (c,) in pg.query("SELECT employee_id FROM v_active_employees WHERE role_id = 4 ORDER BY 1")]
    tables = [t for (t,) in pg.query("SELECT table_id FROM v_free_tables ORDER BY table_id")]
    rng.shuffle(tables)
    # популярність страв нерівномірна (як в історії)
    weights = [1 / (i + 1) ** 0.8 for i in range(len(st.dishes))]

    for tid in tables[:n_orders]:
        wid, wname = rng.choice(w)
        oid = sql.open_order(tid, wid)
        red.open_order(oid, tid, wid, wname)
        st.orders.append((oid, tid, wid))
        n_items = rng.randint(6, 12)
        cut = rng.randint(3, n_items) if rng.random() < 0.75 else None
        for k in range(n_items):
            if cut is not None and k == cut:
                _send(sql, red, st, oid)
            d = rng.choices(st.dishes, weights)[0]
            q = 2 if rng.random() < 0.2 else 1
            c = rng.choice(COMMENTS)
            st.items.append(Item(sql.add_item(oid, d, q, c), oid, red.add_item(oid, d, q, c)))
        if cut is not None and cut == n_items:
            _send(sql, red, st, oid)

    for it in st.items:                              # прогрес кухні
        if not it.sent or rng.random() > 0.35:
            continue
        cook = rng.choice(st.cooks)
        sql.kds_start(it.sql_id, cook); red.kds_start(it.oid, it.rid, cook); it.status = "cooking"
        if rng.random() < 0.4:
            sql.kds_ready(it.sql_id); red.kds_ready(it.oid, it.rid); it.status = "ready"
            if rng.random() < 0.5:
                sql.mark_served(it.sql_id); red.mark_served(it.oid, it.rid); it.status = "served"
    pg.query("SET synchronous_commit = on")
    # однакова фізична картина для всіх прогонів: прибрати «мертві» версії рядків
    # після reset і оновити статистику планувальника
    pg.query("VACUUM (ANALYZE) order_items")
    pg.query("VACUUM (ANALYZE) orders")
    pg.query("VACUUM (ANALYZE) item_ready_events")
    return st


def _send(sql, red, st, oid):
    a, b = sql.send_to_kitchen(oid), red.send_to_kitchen(oid)
    assert a == b, (a, b)
    for it in st.items:
        if it.oid == oid:
            it.sent = True


def make_cooking_pool(pg, r, st: LiveState, n: int, seed_value=7) -> list[Item]:
    """n позицій у статусі 'cooking' (для сценарію «позиція готова»)."""
    rng = random.Random(seed_value)
    pg.query("SET synchronous_commit = off")
    sql, red = LiveSQL(pg), LiveRedis(r)
    pool = []
    for _ in range(n):
        oid = rng.choice(st.orders)[0]
        d = rng.choice(st.dishes)
        it = Item(sql.add_item(oid, d, 1, ""), oid, red.add_item(oid, d, 1, ""))
        st.items.append(it)
        _send(sql, red, st, oid)
        cook = rng.choice(st.cooks)
        sql.kds_start(it.sql_id, cook); red.kds_start(oid, it.rid, cook)
        it.status = "cooking"
        pool.append(it)
    pg.query("SET synchronous_commit = on")
    return pool


def verify(pg, r, st: LiveState) -> dict:
    """Перевірка узгодженості: обидві реалізації повертають однакові бізнес-дані."""
    sql, red = LiveSQL(pg), LiveRedis(r)
    res = {}
    ok = True
    for oid, _, _ in st.orders:
        a, b = sql.order_check(oid), red.order_check(oid)
        na = sorted((i["dish_id"], i["qty"], int(i["price"] * 100), i["status"], i["comment"] or "") for i in a["items"])
        nb = sorted((i["dish_id"], i["qty"], i["price_minor"], i["status"], i["comment"] or "") for i in b["items"])
        ok &= na == nb and int(a["order"]["subtotal"] * 100) == int(b["order"]["subtotal_minor"])
    res["order_checks"] = ok
    q_ok = True
    for s in STATIONS:
        qa = sorted((x["order_id"], x["dish_name"], x["quantity"], x["status"]) for x in sql.kds_queue(s, 100000))
        qb = sorted((x["order_id"], x["name"], x["qty"], x["status"]) for x in red.kds_queue(s, 100000))
        q_ok &= qa == qb
    res["kds_queues"] = q_ok
    ha = {x["table_id"]: (x["order_id"], int((x["subtotal"] or 0) * 100), x["ready_items"]) for x in sql.hall_map()}
    hb = {x["table_id"]: (x.get("order_id"), x.get("subtotal_minor", 0), x.get("ready_items", 0)) for x in red.hall_map()}
    res["hall_map"] = ha == hb
    res["top_qty"] = [x["qty"] for x in sql.top_dishes(10)] == [x["qty"] for x in red.top_dishes(10)]
    res["menu"] = sql.menu() == red.menu()
    return res
