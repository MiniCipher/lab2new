#!/usr/bin/env bash
# Перестворити БД restaurant і заповнити її для бенчмарку.
#   bench/setup_db.sh [HIST_ORDERS] [TODAY_ORDERS]   (типово 1000000 800)
# Для Docker:  PSQL="docker compose exec -T postgres psql -U postgres" bench/setup_db.sh 1000000
set -euo pipefail
HIST=${1:-1000000}
TODAY=${2:-800}
DB=${PGDATABASE:-restaurant}
PSQL=${PSQL:-"psql -h ${PGHOST:-127.0.0.1} -p ${PGPORT:-5432} -U ${PGUSER:-postgres}"}
cd "$(dirname "$0")/../sql"

$PSQL -d postgres -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)"
$PSQL -d postgres -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $DB"
for f in 01_schema 02_logic 03_seed 04_live_service; do
  echo ">> $f.sql"
  $PSQL -d "$DB" -v ON_ERROR_STOP=1 -q < "$f.sql" 2>&1 | grep -v NOTICE || true
done
echo ">> 05_bench_data.sql (hist_orders=$HIST, today_orders=$TODAY)"
time $PSQL -d "$DB" -v ON_ERROR_STOP=1 -q -v hist_orders="$HIST" -v today_orders="$TODAY" < 05_bench_data.sql
$PSQL -d "$DB" -q -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" \
  || echo "!! pg_stat_statements недоступний: серверний час PostgreSQL не буде виміряно"
