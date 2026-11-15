# ЛР2 — NoSQL у системі управління ресторанним бізнесом

Основна NoSQL-БД: **Redis** (ключ–значення) — модуль «Live Service» (живий чек столу, черга кухні KDS,
сповіщення офіціантів, мапа залу, кеш меню, рейтинг страв дня).
Та сама функціональність у **PostgreSQL** — для порівняння швидкодії.
Друга NoSQL-БД іншого типу: **MongoDB** (документна) — відгуки гостей.

## Структура

```
sql/01_schema.sql, 02_logic.sql, 03_seed.sql   — БД з ЛР1 (без змін)
sql/04_live_service.sql   — SQL-реалізація модуля Live Service (+2 оптимізації ЛР1)
sql/05_bench_data.sql     — генератор великого обсягу (psql -v hist_orders=N -v today_orders=M)
common/dbclient.py        — мінімальні клієнти PostgreSQL і Redis (лише stdlib Python)
redis_live/lua/*.lua      — атомарні операції Redis (Lua-скрипти)
redis_live/live_redis.py  — Redis-реалізація модуля (схема ключів — у docstring)
redis_live/live_sql.py    — SQL-реалізація з тим самим інтерфейсом
redis_live/demo.py        — демонстрація сценарію + перевірка узгодженості обох реалізацій
redis_live/redis_cli_examples.redis — базові команди Redis для захисту
bench/setup_db.sh         — перестворити й заповнити БД заданого обсягу (Linux/macOS)
bench/setup_db.ps1        — те саме для Windows PowerShell
bench/live_seed.py        — однаковий «живий» стан у PG і Redis + verify()
bench/bench.py            — бенчмарк: latency | mixed | ablation | explain
bench/report.py           — графіки й таблиці -> bench/results/
bench/results/            — сюди пишуться ВАШІ результати (порожня в архіві)
bench/results_reference/  — еталонний прогін автора, лише для порівняння
mongo/01_setup.js         — колекції з $jsonSchema, тестові дані, індекси
mongo/02_queries.js       — CRUD, оператори, агрегації, explain
docker-compose.yml        — PostgreSQL 16 + Redis 7 + MongoDB 7
```

## Запуск

Потрібно: Docker, Python 3.9+ (жодних pip-пакетів), bash (Linux/macOS/WSL/Git Bash).

```bash
docker compose up -d
export PGPASSWORD=postgres
export PSQL="docker compose exec -T postgres psql -U postgres"   # або локальний psql

# 1) БД: схема ЛР1 + модуль ЛР2 + 1 млн історичних замовлень (~1.5 хв)
bench/setup_db.sh 1000000

# 2) Демонстрація обох реалізацій + перевірка, що вони дають однаковий результат
python redis_live/demo.py

# 3) Бенчмарк (~6 + ~5 хв) і звіт
python bench/bench.py latency  --out bench/results/latency_1M.json
python bench/bench.py mixed    --procs 1,2,4,8,16 --duration 8 --out bench/results/mixed_1M.json
python bench/bench.py ablation --out bench/results/ablation_1M.json
python bench/bench.py explain  --out bench/results/plans_1M.txt
#   вплив обсягу історії:
bench/setup_db.sh 10000  && python bench/bench.py latency --scenarios S1_menu,S2_order_check,S4_kds_queue,S6_hall_map,S7_top_dishes --out bench/results/latency_10000.json
bench/setup_db.sh 100000 && python bench/bench.py latency --scenarios S1_menu,S2_order_check,S4_kds_queue,S6_hall_map,S7_top_dishes --out bench/results/latency_100000.json
#   вплив обсягу продажів за день:
bench/setup_db.sh 100000 4000  && python bench/bench.py latency --scenarios S7_top_dishes --out bench/results/today_4000.json
bench/setup_db.sh 100000 20000 && python bench/bench.py latency --scenarios S7_top_dishes --out bench/results/today_20000.json
python bench/report.py

# 4) MongoDB
docker compose exec mongo mongosh --quiet /scripts/01_setup.js      # папка mongo/ змонтована в /scripts
docker compose exec mongo mongosh --quiet /scripts/02_queries.js

# 5) Redis вручну
grep -v '^#' redis_live/redis_cli_examples.redis | docker compose exec -T redis redis-cli
```

Змінні середовища клієнта: `PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE REDIS_HOST REDIS_PORT REDIS_PASSWORD APP_TZ`.

> `05_bench_data.sql` використовує `SET session_replication_role = replica` (вимкнення тригерів на час
> масової вставки) — потрібен суперкористувач `postgres`.

## Windows (PowerShell)

Потрібно: Docker Desktop (WSL 2), Python 3.9+ з python.org (галочка «Add to PATH»).

```powershell
pip install tzdata matplotlib          # часовий пояс для Python на Windows + графіки
docker compose up -d
$env:PGPASSWORD = "postgres"

.\bench\setup_db.ps1                    # якщо скрипти заблоковано: Set-ExecutionPolicy -Scope Process Bypass
python redis_live\demo.py
python bench\bench.py latency  --out bench\results\latency_1M.json
python bench\bench.py mixed    --procs 1,2,4,8,16 --duration 8 --out bench\results\mixed_1M.json
python bench\bench.py ablation --out bench\results\ablation_1M.json
python bench\bench.py explain  --out bench\results\plans_1M.txt
.\bench\setup_db.ps1 -HistOrders 10000
python bench\bench.py latency --scenarios S1_menu,S2_order_check,S4_kds_queue,S6_hall_map,S7_top_dishes --out bench\results\latency_10000.json
.\bench\setup_db.ps1 -HistOrders 100000
python bench\bench.py latency --scenarios S1_menu,S2_order_check,S4_kds_queue,S6_hall_map,S7_top_dishes --out bench\results\latency_100000.json
.\bench\setup_db.ps1 -HistOrders 100000 -TodayOrders 4000
python bench\bench.py latency --scenarios S7_top_dishes --out bench\results\today_4000.json
.\bench\setup_db.ps1 -HistOrders 100000 -TodayOrders 20000
python bench\bench.py latency --scenarios S7_top_dishes --out bench\results\today_20000.json
python bench\report.py

docker compose exec mongo mongosh --quiet /scripts/01_setup.js
docker compose exec mongo mongosh --quiet /scripts/02_queries.js
Get-Content redis_live\redis_cli_examples.redis | Where-Object { $_ -notmatch '^#' -and $_ } | docker compose exec -T redis redis-cli
```
