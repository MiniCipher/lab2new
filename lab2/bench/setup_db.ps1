# Windows (PowerShell): перестворити й заповнити БД restaurant у Docker-контейнері.
#   .\bench\setup_db.ps1                      # 1 000 000 історичних замовлень, 800 за сьогодні
#   .\bench\setup_db.ps1 -HistOrders 10000
#   .\bench\setup_db.ps1 -HistOrders 100000 -TodayOrders 4000
# SQL-файли читаються всередині контейнера (папка sql/ змонтована в /sql),
# тому немає проблем із кодуванням кирилиці при передачі через конвеєр PowerShell.
param(
    [int]$HistOrders = 1000000,
    [int]$TodayOrders = 800
)

Set-Location (Join-Path $PSScriptRoot "..")

function Invoke-Psql {
    docker compose exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -q @args
    if ($LASTEXITCODE -ne 0) { throw "psql error: $args" }
}

Invoke-Psql -d postgres -c "DROP DATABASE IF EXISTS restaurant WITH (FORCE)"
Invoke-Psql -d postgres -c "CREATE DATABASE restaurant"

foreach ($f in "01_schema", "02_logic", "03_seed", "04_live_service") {
    Write-Host ">> $f.sql"
    Invoke-Psql -d restaurant -f "/sql/$f.sql"
}

Write-Host ">> 05_bench_data.sql (hist_orders=$HistOrders, today_orders=$TodayOrders)"
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Psql -d restaurant -v "hist_orders=$HistOrders" -v "today_orders=$TodayOrders" -f /sql/05_bench_data.sql
Write-Host ("   done in {0:N0} s" -f $sw.Elapsed.TotalSeconds)

Invoke-Psql -d restaurant -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
