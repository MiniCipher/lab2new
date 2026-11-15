"""
SQL-реалізація модуля «Live Service» (ЛР2, частина 4) — тонка обгортка над
функціями з sql/04_live_service.sql. Інтерфейс збігається з LiveRedis,
тож бенчмарк і перевірка узгодженості викликають обидві реалізації однаково.

Кожна операція = один запит = один мережевий обмін (як і в Redis:
один EVALSHA або один конвеєр). Запити підготовлені на сервері (PREPARE).
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from dbclient import PgConnection  # noqa: E402

STATEMENTS = {
    "menu":        ("SELECT dish_id, category_id, category_name, name, description, price, cooking_time_min, "
                    "available FROM v_menu ORDER BY sort_order, category_id, name", 0),
    "add_item":    ("SELECT fn_live_add_item($1::bigint, $2::int, $3::int, $4::varchar)", 4),
    "send":        ("SELECT fn_live_send_to_kitchen($1::bigint)", 1),
    "kds_queue":   ("SELECT * FROM fn_kds_queue($1::varchar, $2::int)", 2),
    "kds_start":   ("SELECT fn_kds_start($1::bigint, $2::int)", 2),
    "kds_ready":   ("SELECT fn_kds_ready($1::bigint)", 1),
    "served":      ("SELECT fn_live_mark_served($1::bigint)", 1),
    "order_check": ("SELECT * FROM fn_order_check($1::bigint)", 1),
    "hall_map":    ("SELECT * FROM fn_hall_map()", 0),
    "top":         ("SELECT * FROM fn_top_dishes_today($1::int)", 1),
    "notif":       ("SELECT * FROM fn_waiter_notifications($1::int, $2::bigint)", 2),
}


class LiveSQL:
    def __init__(self, pg: PgConnection):
        self.pg = pg
        for name, (sql, _) in STATEMENTS.items():
            pg.prepare(f"live_{name}", sql)

    def _x(self, name, *args):
        return self.pg.execute_prepared(f"live_{name}", args)

    def _dicts(self, name, *args):
        rows = self._x(name, *args)
        cols = self.pg.columns
        return [dict(zip(cols, r)) for r in rows]

    def menu(self):
        rows = self._x("menu")
        cats: dict[int, dict] = {}
        for (did, cid, cname, name, descr, price, ctime, avail) in rows:
            c = cats.setdefault(cid, {"category_id": cid, "category": cname, "dishes": []})
            c["dishes"].append({"dish_id": did, "name": name, "description": descr,
                                "price_minor": int(price * 100), "cooking_time_min": ctime, "available": avail})
        return list(cats.values())

    def open_order(self, table_id, waiter_id, customer_id=None):
        return self.pg.scalar("SELECT fn_create_order(%s, %s, %s)", (table_id, waiter_id, customer_id))

    def add_item(self, order_id, dish_id, qty, comment=""):
        return self._x("add_item", order_id, dish_id, qty, comment or "")[0][0]

    def send_to_kitchen(self, order_id):
        return self._x("send", order_id)[0][0]

    def kds_queue(self, station, limit=30):
        return self._dicts("kds_queue", station, limit)

    def kds_start(self, item_id, cook_id):
        self._x("kds_start", item_id, cook_id)
        return 1

    def kds_ready(self, item_id):
        return self._x("kds_ready", item_id)[0][0]

    def mark_served(self, item_id):
        self._x("served", item_id)
        return 1

    def order_check(self, order_id):
        rows = self._x("order_check", order_id)
        if not rows:
            return None
        r0 = rows[0]
        head = {"order_id": r0[0], "status": r0[1], "opened_at": r0[2], "table_number": r0[3],
                "hall": r0[4], "waiter_name": r0[5], "subtotal": r0[6]}
        items = [{"id": r[7], "dish_id": r[8], "name": r[9], "qty": r[10], "price": r[11],
                  "status": r[12], "comment": r[13], "added_at": r[14], "sent_at": r[15], "ready_at": r[16]}
                 for r in rows if r[7] is not None]
        return {"order": head, "items": items}

    def hall_map(self):
        return self._dicts("hall_map")

    def top_dishes(self, n=10):
        return self._dicts("top", n)

    def notifications(self, waiter_id, after=0):
        return self._dicts("notif", waiter_id, after)
