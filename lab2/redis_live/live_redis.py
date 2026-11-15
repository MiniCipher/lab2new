"""
Redis-реалізація модуля «Live Service» (ЛР2, частина 3).

Схема ключів (простір імен = тип сутності, роздільник «:»):
  menu:json                  STRING  повне меню для QR-меню гостя (кеш, TTL 600 с)
  menu:dish:{dish_id}        HASH    name, price_minor, station, available   (кеш для перевірок)
  hall:tables                HASH    table_id -> JSON {table_id, hall, table_number, seats}
  hall:occupied              HASH    table_id -> order_id (зайняті столи)
  orders:open                SET     id відкритих чеків
  order:{oid}                HASH    шапка чека: table/waiter/status/opened_at/subtotal_minor/ready_cnt/item_seq
  order:{oid}:items          HASH    item_id -> JSON позиції (знімок назви й ціни на момент замовлення)
  kds:{station}              ZSET    "{oid}:{iid}" , score = sent_at (мс)  -> черга екрана кухні
  stats:dishes:{YYYY-MM-DD}  ZSET    dish_id, score = порцій за день       -> рейтинг дня (TTL 3 доби)
  notify:{waiter_id}         STREAM  сповіщення «страва готова» (MAXLEN ~1000)
  audit:orders               STREAM  журнал змін чеків (MAXLEN ~1e6)

Відповідність таблицям PostgreSQL (NoSQL-структура -> кілька SQL-таблиць):
  order:{oid} + order:{oid}:items  -> orders, order_items, dishes, restaurant_tables, halls, employees
  kds:{station}                    -> order_items, kitchen_stations, dishes, orders, restaurant_tables, halls
  menu:json / menu:dish:*          -> dishes, menu_categories, kitchen_stations, dish_ingredients, ingredients
  hall:tables + hall:occupied      -> restaurant_tables, halls, orders, employees, order_items
  stats:dishes:{day}               -> order_items, dishes (агрегація)
  notify:{waiter}                  -> item_ready_events, order_items, dishes, restaurant_tables

PostgreSQL лишається системою запису: видає order_id, зберігає оплачені чеки,
гроші, склад. Redis тримає «гарячий» робочий набір відкритих чеків (обмежений
кількістю столів) і після оплати переносить чек у PostgreSQL (pay_and_flush).
"""
from __future__ import annotations

import datetime as dt
import decimal
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
from dbclient import PgConnection, RedisConnection, RedisError  # noqa: E402

try:
    from zoneinfo import ZoneInfo
    APP_TZ = ZoneInfo(os.getenv("APP_TZ", "Europe/Kyiv"))
except Exception:  # немає tzdata (Windows без пакета tzdata)
    APP_TZ = dt.timezone(dt.timedelta(hours=2))

LUA_DIR = Path(__file__).resolve().parent / "lua"
MENU_TTL = 600


def today_str() -> str:
    return dt.datetime.now(APP_TZ).date().isoformat()


def to_minor(price) -> int:
    return int((decimal.Decimal(price) * 100).to_integral_value())


class LiveRedis:
    def __init__(self, r: RedisConnection):
        self.r = r
        self.s = {p.stem: r.script(p.read_text(encoding="utf-8")) for p in LUA_DIR.glob("*.lua")}

    # ------------------------------------------------------------------
    # Побудова кешів із PostgreSQL (cache-aside / прогрів після рестарту)
    # ------------------------------------------------------------------
    def build_menu_cache(self, pg: PgConnection) -> int:
        rows = pg.query("""SELECT dish_id, category_id, category_name, name, description, price,
                                  cooking_time_min, station, available
                           FROM v_menu ORDER BY sort_order, category_id, name""")
        cats: dict[int, dict] = {}
        cmds = [["MULTI"]]
        for (did, cid, cname, name, descr, price, ctime, station, avail) in rows:
            c = cats.setdefault(cid, {"category_id": cid, "category": cname, "dishes": []})
            c["dishes"].append({"dish_id": did, "name": name, "description": descr,
                                "price_minor": to_minor(price), "cooking_time_min": ctime,
                                "available": avail})
            cmds.append(["HSET", f"menu:dish:{did}", "name", name, "price_minor", to_minor(price),
                         "station", station or "hot", "available", int(bool(avail))])
        cmds.append(["SET", "menu:json", json.dumps(list(cats.values()), ensure_ascii=False), "EX", MENU_TTL])
        cmds.append(["EXEC"])
        self.r.pipeline(cmds)
        return len(rows)

    def build_hall_cache(self, pg: PgConnection) -> int:
        rows = pg.query("""SELECT t.table_id, h.name, t.table_number, t.seats
                           FROM restaurant_tables t JOIN halls h ON h.hall_id = t.hall_id
                           WHERE NOT t.is_deleted ORDER BY h.hall_id, t.table_number""")
        cmds = [["MULTI"], ["DEL", "hall:tables"]]
        for tid, hall, num, seats in rows:
            cmds.append(["HSET", "hall:tables", tid, json.dumps(
                {"table_id": tid, "hall": hall, "table_number": num, "seats": seats}, ensure_ascii=False)])
        cmds.append(["EXEC"])
        self.r.pipeline(cmds)
        return len(rows)

    def rebuild_today_stats(self, pg: PgConnection, day: str | None = None) -> int:
        day = day or today_str()
        rows = pg.query("SELECT dish_id, qty FROM fn_top_dishes_today(100000)")
        key = f"stats:dishes:{day}"
        cmds = [["MULTI"], ["DEL", key]]
        if rows:
            flat = []
            for did, qty in rows:
                flat += [qty, did]
            cmds.append(["ZADD", key, *flat])
            cmds.append(["EXPIRE", key, 259200])
        cmds.append(["EXEC"])
        self.r.pipeline(cmds)
        return len(rows)

    # ------------------------------------------------------------------
    # Операції модуля (1:1 з LiveSQL)
    # ------------------------------------------------------------------
    def menu(self):
        raw = self.r.call("GET", "menu:json")
        return json.loads(raw) if raw is not None else None   # None -> cache miss: викликати build_menu_cache

    def open_order(self, order_id, table_id, waiter_id, waiter_name, customer_id=None, opened_at_ms=None):
        opened_at_ms = opened_at_ms or int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
        return self.s["open_order"](
            ["hall:tables", "hall:occupied", f"order:{order_id}", "orders:open"],
            [order_id, table_id, waiter_id, waiter_name, customer_id or "", opened_at_ms])

    def add_item(self, order_id, dish_id, qty, comment=""):
        return self.s["add_item"](
            [f"order:{order_id}", f"order:{order_id}:items", f"menu:dish:{dish_id}", "audit:orders"],
            [order_id, dish_id, qty, comment or ""])

    def send_to_kitchen(self, order_id, day: str | None = None):
        return self.s["send_to_kitchen"](
            [f"order:{order_id}", f"order:{order_id}:items", f"stats:dishes:{day or today_str()}"], [order_id])

    def kds_queue(self, station, limit=30):
        flat = self.s["kds_queue"]([f"kds:{station}"], [limit])
        out = []
        for i in range(0, len(flat), 4):
            it = json.loads(flat[i + 1])
            it["order_id"], it["table_number"], it["hall"] = int(flat[i]), int(flat[i + 2]), flat[i + 3]
            out.append(it)
        return out

    def kds_start(self, order_id, item_id, cook_id):
        return self.s["kds_start"]([f"order:{order_id}:items"], [item_id, cook_id])

    def kds_ready(self, order_id, item_id):
        return self.s["kds_ready"]([f"order:{order_id}", f"order:{order_id}:items"], [order_id, item_id])

    def mark_served(self, order_id, item_id):
        return self.s["mark_served"]([f"order:{order_id}", f"order:{order_id}:items"], [item_id])

    def order_check(self, order_id):
        head, items = self.r.pipeline([["HGETALL", f"order:{order_id}"], ["HGETALL", f"order:{order_id}:items"]])
        if not head:
            return None
        h = dict(zip(head[::2], head[1::2]))
        its = sorted((json.loads(v) for v in items[1::2]), key=lambda x: x["id"])
        return {"order": h, "items": its}

    def hall_map(self):
        tabs, busy = self.s["hall_map"](["hall:tables", "hall:occupied"])
        occ = {busy[i]: busy[i + 1:i + 6] for i in range(0, len(busy), 6)}
        out = []
        for i in range(0, len(tabs), 2):
            t = json.loads(tabs[i + 1])
            o = occ.get(tabs[i])
            if o:
                t.update(order_id=int(o[0]), waiter_name=o[1], opened_at=int(o[2]),
                         subtotal_minor=int(o[3]), ready_items=int(o[4] or 0))
            out.append(t)
        return out

    def top_dishes(self, n=10, day: str | None = None):
        return json.loads(self.s["top_dishes"]([f"stats:dishes:{day or today_str()}"], [n]))

    def notifications(self, waiter_id, after="-", count=100):
        start = after if after == "-" else f"({after}"
        return self.r.call("XRANGE", f"notify:{waiter_id}", start, "+", "COUNT", count)

    # ------------------------------------------------------------------
    # Оплата: перенесення чека в PostgreSQL (система запису), потім очищення Redis
    # ------------------------------------------------------------------
    def pay_and_flush(self, pg: PgConnection, order_id, method="card", cashier_id=3):
        chk = self.order_check(order_id)
        if chk is None:
            raise ValueError(f"order {order_id} is not live in Redis")
        ts = lambda ms: None if ms is None else dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc)  # noqa: E731
        values = []
        for it in chk["items"]:
            values.append("(" + ",".join(map(_lit, [
                int(order_id), it["dish_id"], it["qty"], decimal.Decimal(it["price_minor"]) / 100,
                it["status"], it.get("station"), it.get("comment") or None,
                ts(it.get("added_at")), ts(it.get("sent_at")), ts(it.get("started_at")),
                ts(it.get("ready_at")), it.get("cook_id")])) + ")")
        total = decimal.Decimal(int(chk["order"]["subtotal_minor"])) / 100
        sql = ["BEGIN;"]
        if values:
            sql.append(f"""
                INSERT INTO order_items(order_id, dish_id, quantity, unit_price, status, station_id, comment,
                                        added_at, sent_at, started_at, ready_at, cook_id)
                SELECT v.oid, v.did, v.qty, v.price, v.st::order_item_status,
                       (SELECT station_id FROM kitchen_stations WHERE code = v.station), v.cmt,
                       v.added::timestamptz, v.sent::timestamptz, v.started::timestamptz,
                       v.ready::timestamptz, v.cook::integer
                FROM (VALUES {",".join(values)})
                     AS v(oid, did, qty, price, st, station, cmt, added, sent, started, ready, cook);""")
        sql.append(f"CALL sp_pay_order({int(order_id)}, {total}, {_lit(method)}, {int(cashier_id)});")
        sql.append("COMMIT;")
        try:
            pg.query("\n".join(sql))
        except Exception:
            pg.query("ROLLBACK")   # чек лишається «живим» у Redis, можна повторити
            raise
        # PostgreSQL зафіксував оплату -> прибираємо чек із Redis (ідемпотентно; при збої — повтор)
        self.s["close_order"]([f"order:{order_id}", f"order:{order_id}:items", "hall:occupied", "orders:open"],
                              [order_id])
        return total


def _lit(v):
    from dbclient import pg_literal
    return pg_literal(v)


__all__ = ["LiveRedis", "today_str", "to_minor", "RedisError"]
