"""
Демонстрація модуля «Live Service» в обох реалізаціях + перевірка, що вони
повертають однаковий бізнес-результат.

  python redis_live/demo.py

Сценарій: стіл 7 (гостей обслуговує офіціант 2) -> гість додає страви ->
відправка на кухню -> кухар бере й готує -> офіціант отримує сповіщення ->
мапа залу / рейтинг -> оплата (Redis-чек переноситься в PostgreSQL).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from dbclient import pg_connect, redis_connect, RedisError, PgError  # noqa: E402
from live_redis import LiveRedis  # noqa: E402
from live_sql import LiveSQL  # noqa: E402


def title(t):
    print("\n" + "=" * 70 + f"\n{t}\n" + "=" * 70)


def main():
    pg, r = pg_connect(), redis_connect()
    pg.query("SELECT set_config('app.current_user_id', '1', false)")
    sql, red = LiveSQL(pg), LiveRedis(r)

    title("0. Прогрів кешів Redis із PostgreSQL")
    print("страв у кеші меню :", red.build_menu_cache(pg))
    print("столів у мапі залу:", red.build_hall_cache(pg))
    print("страв у рейтингу дня:", red.rebuild_today_stats(pg))

    # вільні столи для демонстрації
    t_sql, t_red = [row[0] for row in pg.query(
        "SELECT table_id FROM v_free_tables ORDER BY table_id LIMIT 2")]
    waiter = pg.query_one("SELECT employee_id, full_name FROM v_active_employees WHERE role_id = 2 ORDER BY 1 LIMIT 1")

    title("1. Відкрити чек (order_id видає PostgreSQL)")
    o_sql = sql.open_order(t_sql, waiter[0])
    o_red = pg.scalar("SELECT fn_create_order(%s, %s)", (t_red, waiter[0]))
    red.open_order(o_red, t_red, waiter[0], waiter[1])
    print(f"SQL-чек #{o_sql} (стіл {t_sql}),  Redis-чек #{o_red} (стіл {t_red})")

    title("2. Додати страви (однаковий набір в обидві реалізації)")
    dishes = [r_[0] for r_ in pg.query("SELECT dish_id FROM v_menu WHERE available ORDER BY dish_id LIMIT 4")]
    plan = [(dishes[0], 2, ""), (dishes[1], 1, "без цибулі"), (dishes[2], 1, ""), (dishes[3], 3, "")]
    for d, q, c in plan:
        sql.add_item(o_sql, d, q, c)
        red.add_item(o_red, d, q, c)
    print("SQL  :", [(i["name"], i["qty"], str(i["price"])) for i in sql.order_check(o_sql)["items"]])
    print("Redis:", [(i["name"], i["qty"], i["price_minor"] / 100) for i in red.order_check(o_red)["items"]])

    title("3. Помилки бізнес-правил")
    bad = pg.scalar("SELECT dish_id FROM v_menu WHERE NOT available LIMIT 1")
    for label, f in [("SQL  недоступна страва", lambda: sql.add_item(o_sql, bad, 1)),
                     ("Redis недоступна страва", lambda: red.add_item(o_red, bad, 1)),
                     ("SQL  qty=0", lambda: sql.add_item(o_sql, dishes[0], 0)),
                     ("Redis qty=0", lambda: red.add_item(o_red, dishes[0], 0)),
                     ("Redis неіснуючий чек", lambda: red.add_item(99999999, dishes[0], 1))]:
        try:
            f()
            print(f"{label}: !!! помилки немає")
        except (RedisError, PgError) as e:
            print(f"{label}: {str(e).splitlines()[0]}")

    title("4. Відправка на кухню")
    print("SQL  відправлено позицій:", sql.send_to_kitchen(o_sql))
    print("Redis відправлено позицій:", red.send_to_kitchen(o_red))

    title("5. Кухня: взяти в роботу й віддати першу позицію")
    st = pg.scalar("SELECT s.code FROM dishes d JOIN kitchen_stations s USING (station_id) WHERE dish_id = %s",
                   (dishes[0],))
    q_sql = [i for i in sql.kds_queue(st, 1000) if i["order_id"] == o_sql]
    q_red = [i for i in red.kds_queue(st, 1000) if i["order_id"] == o_red]
    print(f"черга станції '{st}': SQL {len(q_sql)} позицій нашого чека, Redis {len(q_red)}")
    sql.kds_start(q_sql[0]["order_item_id"], 5)
    sql_ev = sql.kds_ready(q_sql[0]["order_item_id"])
    red.kds_start(o_red, q_red[0]["id"], 5)
    red_ev = red.kds_ready(o_red, q_red[0]["id"])
    print("SQL  подія сповіщення:", sql_ev, sql.notifications(waiter[0], sql_ev - 1))
    print("Redis подія сповіщення:", red_ev, red.notifications(waiter[0], "-")[-1:])

    title("6. Мапа залу (наші столи)")
    print("SQL  :", [m for m in sql.hall_map() if m["table_id"] == t_sql])
    print("Redis:", [m for m in red.hall_map() if m["table_id"] == t_red])

    title("7. Узгодженість реалізацій")
    a, b = sql.order_check(o_sql), red.order_check(o_red)
    norm_a = sorted((i["dish_id"], i["qty"], int(i["price"] * 100), i["status"]) for i in a["items"])
    norm_b = sorted((i["dish_id"], i["qty"], i["price_minor"], i["status"]) for i in b["items"])
    print("позиції чека збігаються:", norm_a == norm_b)
    print("сума збігається:", int(a["order"]["subtotal"] * 100) == int(b["order"]["subtotal_minor"]))
    ts, tr = sql.top_dishes(10), red.top_dishes(10)
    print("рейтинг дня, кількості збігаються:", [x["qty"] for x in ts] == [x["qty"] for x in tr])

    title("8. Оплата: Redis-чек -> PostgreSQL (система запису)")
    total = red.pay_and_flush(pg, o_red, "card", 3)
    print("оплачено:", total, "| статус у PG:", pg.scalar("SELECT status FROM orders WHERE order_id = %s", (o_red,)),
          "| позицій у PG:", pg.scalar("SELECT count(*) FROM order_items WHERE order_id = %s", (o_red,)),
          "| ключ у Redis існує:", r.call("EXISTS", f"order:{o_red}"))
    total_sql = pg.scalar("SELECT total_amount FROM orders WHERE order_id = %s", (o_sql,))
    pg.query("CALL sp_pay_order(%s, %s, 'cash', 3)", (o_sql, total_sql))
    print("SQL-чек оплачено, статус:", pg.scalar("SELECT status FROM orders WHERE order_id = %s", (o_sql,)))


if __name__ == "__main__":
    main()
