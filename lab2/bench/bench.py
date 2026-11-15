"""
Бенчмарк: PostgreSQL (SQL-реалізація) vs Redis (NoSQL-реалізація) модуля «Live Service».

Підкоманди:
  latency   — затримка окремих операцій (1 клієнт): p50/p95/p99, + серверний час
  mixed     — пропускна здатність змішаного навантаження, 1..N паралельних клієнтів
  ablation  — що буде з SQL без спеціальних індексів (обґрунтування індексів)
  explain   — плани виконання SQL-запитів (EXPLAIN ANALYZE, BUFFERS)

Приклади:
  python bench/bench.py latency  --out bench/results/latency_1M.json
  python bench/bench.py mixed    --procs 1,2,4,8 --duration 10 --out bench/results/mixed_1M.json
  python bench/bench.py ablation --out bench/results/ablation_1M.json
  python bench/bench.py explain  --out bench/results/plans_1M.txt

Методика (коротко; детально — у звіті):
  * обидві СКБД на тій самій машині, доступ через TCP localhost, однаковий клієнт;
  * кожна операція = 1 мережевий обмін (SQL: prepared-запит/функція; Redis: EVALSHA або конвеєр);
  * у вимірюваний час входить і декодування відповіді у структури Python (як у реальному застосунку);
  * параметри (id чеків, страви, станції) генеруються ЗАЗДАЛЕГІДЬ і однакові для обох СКБД;
  * прогрів (warm-up) перед вимірюванням; кілька повторів; GC вимкнено під час вимірювання;
  * кожен сценарій стартує з ідентичного «живого» стану (reset + seed з фіксованим зерном);
  * записи вимірюються в двох режимах довговічності з паритетом:
      durable: PG synchronous_commit=on      <-> Redis AOF appendfsync=always
      relaxed: PG synchronous_commit=off     <-> Redis AOF appendfsync=everysec
"""
from __future__ import annotations

import argparse
import gc
import json
import multiprocessing as mp
import os
import platform
import random
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "common"), str(ROOT / "redis_live"), str(ROOT / "bench")]
from dbclient import pg_connect, redis_connect  # noqa: E402
from live_redis import LiveRedis  # noqa: E402
from live_sql import LiveSQL  # noqa: E402
import live_seed  # noqa: E402

STATIONS = live_seed.STATIONS

# ---------------------------------------------------------------------------
# Сценарії. Для кожного: які SQL-таблиці задіяні і яка Redis-структура їм відповідає.
# ---------------------------------------------------------------------------
SCENARIOS = {
    "S1_menu": dict(kind="read", stmt="live_menu",
                    title="Меню для гостя (QR)",
                    sql_tables="dishes, menu_categories, kitchen_stations, dish_ingredients, ingredients",
                    redis="GET menu:json"),
    "S2_order_check": dict(kind="read", stmt="live_order_check",
                           title="Живий чек столу",
                           sql_tables="orders, order_items, dishes, restaurant_tables, halls, employees",
                           redis="pipeline: HGETALL order:{id} + HGETALL order:{id}:items"),
    "S4_kds_queue": dict(kind="read", stmt="live_kds_queue",
                         title="Екран кухні (30 найстаріших позицій станції)",
                         sql_tables="kitchen_stations, order_items, dishes, orders, restaurant_tables, halls",
                         redis="EVALSHA kds_queue: ZRANGE kds:{st} + HGET/HMGET"),
    "S6_hall_map": dict(kind="read", stmt="live_hall_map",
                        title="Мапа залу (100 столів)",
                        sql_tables="restaurant_tables, halls, orders, employees, order_items",
                        redis="EVALSHA hall_map: HGETALL hall:tables/hall:occupied + HMGET order:*"),
    "S7_top_dishes": dict(kind="read", stmt="live_top",
                          title="ТОП-10 страв за сьогодні",
                          sql_tables="order_items (агрегація за день), dishes",
                          redis="EVALSHA top_dishes: ZREVRANGE stats:dishes:{day}"),
    "S3_add_item": dict(kind="write", stmt="live_add_item",
                        title="Додати страву в чек",
                        sql_tables="orders (lock+UPDATE суми), order_items (INSERT), dishes, dish_ingredients, "
                                   "ingredients, audit_log",
                        redis="EVALSHA add_item: HGET/HMGET + HSET + HINCRBY + XADD audit"),
    "S5_kds_ready": dict(kind="write", stmt="live_kds_ready",
                         title="Позиція готова + сповіщення офіціанту",
                         sql_tables="order_items (UPDATE), orders, item_ready_events (INSERT)",
                         redis="EVALSHA kds_ready: HSET + ZREM + HINCRBY + XADD notify:{waiter}"),
}
READS = [k for k, v in SCENARIOS.items() if v["kind"] == "read"]
WRITES = [k for k, v in SCENARIOS.items() if v["kind"] == "write"]
MODES = {"durable": ("on", "always"), "relaxed": ("off", "everysec")}


# ---------------------------------------------------------------------------
# Утиліти
# ---------------------------------------------------------------------------
def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def summarize(lat_ns):
    us = sorted(x / 1000 for x in lat_ns)
    return dict(n=len(us), p50=pct(us, 50), p95=pct(us, 95), p99=pct(us, 99),
                mean=statistics.fmean(us), stdev=statistics.pstdev(us), min=us[0], max=us[-1])


def set_durability(pg, r, mode):
    sc, fsync = MODES[mode]
    pg.query(f"SET synchronous_commit = {sc}")
    if r.call("CONFIG", "GET", "appendonly")[1] != "yes":
        r.call("CONFIG", "SET", "appendonly", "yes")
    r.call("CONFIG", "SET", "appendfsync", fsync)
    for _ in range(600):   # дочекатися завершення фонового переписування AOF
        info = r.call("INFO", "persistence")
        if "aof_rewrite_in_progress:0" in info and "aof_rewrite_scheduled:0" in info:
            break
        time.sleep(0.1)


def redis_server_us(r, n_ops):
    """Сумарний серверний час Redis (усі команди, крім службових) на одну операцію."""
    stats = {}
    for line in r.call("INFO", "commandstats").splitlines():
        if line.startswith("cmdstat_"):
            name, rest = line[8:].split(":", 1)
            if name in ("info", "config", "ping"):
                continue
            stats[name] = int(dict(x.split("=") for x in rest.split(","))["usec"])
    # команди, викликані зі скрипта, теж потрапляють у commandstats, а їхній час уже
    # входить у час EVALSHA -> для скриптових операцій беремо лише EVALSHA
    total = stats["evalsha"] if "evalsha" in stats else sum(stats.values())
    return total / max(n_ops, 1)


def pg_server_us(pg, stmt):
    row = pg.query_one("SELECT sum(calls), sum(total_exec_time) FROM pg_stat_statements "
                       "WHERE query LIKE %s", (f"PREPARE {stmt} AS%",))
    if not row or not row[0]:
        return None
    return float(row[1]) * 1000 / int(row[0])


def reset_stats(pg, r):
    try:
        pg.query("SELECT pg_stat_statements_reset()")
    except Exception:
        pass
    r.call("CONFIG", "RESETSTAT")


def env_meta(pg, r):
    counts = dict(pg.query("""SELECT 'orders', count(*) FROM orders UNION ALL
                              SELECT 'order_items', count(*) FROM order_items UNION ALL
                              SELECT 'payments', count(*) FROM payments UNION ALL
                              SELECT 'dishes', count(*) FROM dishes UNION ALL
                              SELECT 'customers', count(*) FROM customers UNION ALL
                              SELECT 'items_today', count(*) FROM order_items
                                     WHERE sent_at >= date_trunc('day', now())"""))
    return dict(
        timestamp=time.strftime("%Y-%m-%d %H:%M:%S"),
        python=platform.python_version(), platform=platform.platform(), cpus=os.cpu_count(),
        postgres=pg.scalar("SHOW server_version"), redis=r.call("INFO", "server").split("redis_version:")[1].split()[0],
        pg_size=pg.scalar("SELECT pg_size_pretty(pg_database_size(current_database()))"),
        pg_shared_buffers=pg.scalar("SHOW shared_buffers"),
        rows=counts,
    )


# ---------------------------------------------------------------------------
# Генерація однакових аргументів для обох СКБД
# ---------------------------------------------------------------------------
def make_ops(name, st, rng, n, pool=None):
    """Повертає два списки викликів (sql, redis) однакової довжини з однаковими параметрами."""
    if name == "S1_menu":
        return [("menu", ())] * n, [("menu", ())] * n
    if name == "S2_order_check":
        oids = [rng.choice(st.orders)[0] for _ in range(n)]
        return [("order_check", (o,)) for o in oids], [("order_check", (o,)) for o in oids]
    if name == "S4_kds_queue":
        sts = [rng.choice(STATIONS) for _ in range(n)]
        return [("kds_queue", (s, 30)) for s in sts], [("kds_queue", (s, 30)) for s in sts]
    if name == "S6_hall_map":
        return [("hall_map", ())] * n, [("hall_map", ())] * n
    if name == "S7_top_dishes":
        return [("top_dishes", (10,))] * n, [("top_dishes", (10,))] * n
    if name == "S3_add_item":
        args = [(rng.choice(st.orders)[0], rng.choice(st.dishes)) for _ in range(n)]
        return ([("add_item", (o, d, 1, "")) for o, d in args],
                [("add_item", (o, d, 1, "")) for o, d in args])
    if name == "S5_kds_ready":
        assert pool and len(pool) >= n
        return ([("kds_ready", (it.sql_id,)) for it in pool[:n]],
                [("kds_ready", (it.oid, it.rid)) for it in pool[:n]])
    raise KeyError(name)


def run_ops(impl, ops):
    lat = []
    gc.disable()
    try:
        for meth, args in ops:
            f = getattr(impl, meth)
            t0 = time.perf_counter_ns()
            f(*args)
            lat.append(time.perf_counter_ns() - t0)
    finally:
        gc.enable()
    return lat


# ---------------------------------------------------------------------------
# latency
# ---------------------------------------------------------------------------
def cmd_latency(a):
    pg, r = pg_connect(), redis_connect()
    meta = env_meta(pg, r)
    print(json.dumps(meta, ensure_ascii=False, indent=1))
    results, samples = [], {}
    scen = a.scenarios.split(",") if a.scenarios else READS + WRITES
    modes = ["durable", "relaxed"] if a.durability == "both" else [a.durability]
    for name in scen:
        kind = SCENARIOS[name]["kind"]
        for mode in (modes if kind == "write" else ["durable"]):
            warm = a.warmup if kind == "read" else a.write_warmup
            iters = a.iters if kind == "read" else a.write_iters
            for store in ("postgres", "redis"):
                all_lat = []
                for rep in range(a.repeats):
                    # однаковий стартовий стан; для читань — один раз, для записів — перед кожним повтором
                    if rep == 0 or kind == "write":
                        live_seed.reset(pg, r)
                        st = live_seed.seed(pg, r)
                        pool = live_seed.make_cooking_pool(pg, r, st, warm + iters) if name == "S5_kds_ready" else None
                    set_durability(pg, r, mode)
                    impl = LiveSQL(pg) if store == "postgres" else LiveRedis(r)
                    rng = random.Random(1000 + rep)
                    sql_ops, red_ops = make_ops(name, st, rng, warm + iters, pool)
                    ops = sql_ops if store == "postgres" else red_ops
                    run_ops(impl, ops[:warm])
                    reset_stats(pg, r)
                    lat = run_ops(impl, ops[warm:])
                    server = pg_server_us(pg, SCENARIOS[name]["stmt"]) if store == "postgres" \
                        else redis_server_us(r, len(lat))
                    s = summarize(lat)
                    s.update(scenario=name, store=store, mode=mode, repeat=rep, server_us=server)
                    results.append(s)
                    all_lat += lat
                    print(f"{name:16s} {store:8s} {mode:8s} rep{rep}  p50={s['p50']:9.1f}us  "
                          f"p95={s['p95']:9.1f}us  p99={s['p99']:9.1f}us  server={server and round(server, 1)}us")
                samples[f"{name}|{store}|{mode}"] = [round(x / 1000, 1) for x in all_lat]
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dict(meta=meta, args=vars(a), scenarios=SCENARIOS, results=results,
                                   samples=samples), ensure_ascii=False))
    print("saved", out)


# ---------------------------------------------------------------------------
# mixed (кілька процесів-клієнтів)
# ---------------------------------------------------------------------------
MIX = [("order_check", 30), ("kds_queue", 25), ("hall_map", 10), ("menu", 10),
       ("top_dishes", 5), ("add_item", 15), ("send_to_kitchen", 5)]


def _worker(store, mode, orders, dishes, seed_value, start_at, duration, q):
    pg, r = pg_connect(), redis_connect()
    sc, _ = MODES[mode]
    pg.query(f"SET synchronous_commit = {sc}")
    impl = LiveSQL(pg) if store == "postgres" else LiveRedis(r)
    rng = random.Random(seed_value)
    names, weights = zip(*MIX)
    lat = {n: [] for n in names}
    while time.time() < start_at:
        time.sleep(0.001)
    end = start_at + duration
    errors = 0
    while True:
        op = rng.choices(names, weights)[0]
        if op == "order_check":
            args = (rng.choice(orders),)
        elif op == "kds_queue":
            args = (rng.choice(STATIONS), 30)
        elif op == "top_dishes":
            args = (10,)
        elif op == "add_item":
            args = (rng.choice(orders), rng.choice(dishes), 1, "")
        elif op == "send_to_kitchen":
            args = (rng.choice(orders),)
        else:
            args = ()
        t0 = time.perf_counter_ns()
        try:
            getattr(impl, op)(*args)
        except Exception:
            errors += 1
        t1 = time.perf_counter_ns()
        if time.time() > end:
            break
        lat[op].append(t1 - t0)
    q.put((lat, errors))


def cmd_mixed(a):
    pg, r = pg_connect(), redis_connect()
    meta = env_meta(pg, r)
    ctx = mp.get_context("spawn")
    procs = [int(x) for x in a.procs.split(",")]
    modes = ["durable", "relaxed"] if a.durability == "both" else [a.durability]
    results = []
    for mode in modes:
        for p in procs:
            for store in ("postgres", "redis"):
                live_seed.reset(pg, r)
                st = live_seed.seed(pg, r)
                set_durability(pg, r, mode)
                orders = [o for o, _, _ in st.orders]
                q = ctx.Queue()
                start_at = time.time() + 1.5 + 0.2 * p
                ws = [ctx.Process(target=_worker, args=(store, mode, orders, st.dishes, 500 + i, start_at,
                                                        a.duration, q)) for i in range(p)]
                for w in ws:
                    w.start()
                merged = {n: [] for n, _ in MIX}
                errors = 0
                for _ in ws:
                    lat, e = q.get()
                    errors += e
                    for k, v in lat.items():
                        merged[k] += v
                for w in ws:
                    w.join()
                all_lat = [x for v in merged.values() for x in v]
                s = summarize(all_lat)
                s.update(store=store, mode=mode, procs=p, ops=len(all_lat), errors=errors,
                         throughput=len(all_lat) / a.duration,
                         per_op={k: summarize(v) for k, v in merged.items() if v})
                results.append(s)
                print(f"mixed {mode:8s} procs={p:3d} {store:8s} {s['throughput']:9.0f} ops/s  "
                      f"p50={s['p50']:8.1f}us p95={s['p95']:8.1f}us p99={s['p99']:8.1f}us err={errors}")
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dict(meta=meta, args=vars(a), mix=MIX, results=results), ensure_ascii=False))
    print("saved", out)


# ---------------------------------------------------------------------------
# ablation: SQL без спеціальних індексів
# ---------------------------------------------------------------------------
ABLATION = [
    ("S4_kds_queue", "ix_oi_kds_queue",
     "CREATE INDEX ix_oi_kds_queue ON order_items (station_id, sent_at, order_item_id) "
     "WHERE status IN ('new', 'cooking') AND sent_at IS NOT NULL"),
    ("S7_top_dishes", "ix_oi_sent_at", "CREATE INDEX ix_oi_sent_at ON order_items (sent_at)"),
    ("S6_hall_map", "ix_orders_open_by_table",
     "CREATE INDEX ix_orders_open_by_table ON orders (table_id) WHERE status IN ('open', 'in_kitchen', 'served')"),
]


def cmd_ablation(a):
    pg, r = pg_connect(), redis_connect()
    meta = env_meta(pg, r)
    live_seed.reset(pg, r)
    st = live_seed.seed(pg, r)
    impl = LiveSQL(pg)
    results = []
    for name, idx, ddl in ABLATION:
        for variant in ("with_index", "without_index"):
            if variant == "without_index":
                pg.query(f"DROP INDEX IF EXISTS {idx}")
                pg.query("ANALYZE order_items; ANALYZE orders")
            pg.deallocate_all()      # план має бути перебудований під новий набір індексів
            impl = LiveSQL(pg)
            # без індексу запит може тривати секунди -> менше повторів (повний прохід стабільний за часом)
            warm, iters = (a.warmup, a.iters) if variant == "with_index" else (1, a.slow_iters)
            sql_ops, _ = make_ops(name, st, random.Random(5), warm + iters)
            run_ops(impl, sql_ops[:warm])
            s = summarize(run_ops(impl, sql_ops[warm:]))
            s.update(scenario=name, index=idx, variant=variant)
            results.append(s)
            print(f"{name:16s} {variant:14s} p50={s['p50']:10.1f}us p95={s['p95']:10.1f}us")
        pg.query(ddl)
        pg.query("ANALYZE order_items; ANALYZE orders")
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dict(meta=meta, results=results), ensure_ascii=False))
    print("saved", out)


# ---------------------------------------------------------------------------
# explain
# ---------------------------------------------------------------------------
def cmd_explain(a):
    pg, r = pg_connect(), redis_connect()
    live_seed.reset(pg, r)
    st = live_seed.seed(pg, r)
    oid = st.orders[0][0]
    queries = [
        ("S1_menu", "SELECT * FROM v_menu ORDER BY sort_order, category_id, name"),
        ("S2_order_check", f"SELECT * FROM fn_order_check({oid})"),
        ("S4_kds_queue", "SELECT * FROM fn_kds_queue('hot', 30)"),
        ("S6_hall_map", "SELECT * FROM fn_hall_map()"),
        ("S7_top_dishes", "SELECT * FROM fn_top_dishes_today(10)"),
    ]
    lines = []
    for name, q in queries:
        pg.query(q)  # прогрів кешу
        plan = pg.query(f"EXPLAIN (ANALYZE, BUFFERS) {q}")
        lines.append(f"===== {name}: {q}\n" + "\n".join(p[0] for p in plan) + "\n")
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("latency")
    p.add_argument("--scenarios", default="")
    p.add_argument("--warmup", type=int, default=300)
    p.add_argument("--iters", type=int, default=3000)
    p.add_argument("--write-warmup", type=int, default=100)
    p.add_argument("--write-iters", type=int, default=1000)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--durability", choices=["durable", "relaxed", "both"], default="both")
    p.add_argument("--out", default="bench/results/latency.json")
    p = sub.add_parser("mixed")
    p.add_argument("--procs", default="1,2,4,8,16")
    p.add_argument("--duration", type=float, default=10)
    p.add_argument("--durability", choices=["durable", "relaxed", "both"], default="both")
    p.add_argument("--out", default="bench/results/mixed.json")
    p = sub.add_parser("ablation")
    p.add_argument("--warmup", type=int, default=20)
    p.add_argument("--iters", type=int, default=300)
    p.add_argument("--slow-iters", type=int, default=10)
    p.add_argument("--out", default="bench/results/ablation.json")
    p = sub.add_parser("explain")
    p.add_argument("--out", default="bench/results/plans.txt")
    a = ap.parse_args()
    {"latency": cmd_latency, "mixed": cmd_mixed, "ablation": cmd_ablation, "explain": cmd_explain}[a.cmd](a)


if __name__ == "__main__":
    main()
