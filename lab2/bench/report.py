"""
Побудова графіків і зведених таблиць із результатів бенчмарку.
  python bench/report.py            -> bench/results/*.png, bench/results/summary.md
"""
import json
import statistics
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

R = Path(__file__).resolve().parent / "results"
PG, RD = "#2a78d6", "#eb6834"            # категоріальні слоти 1–2 (валідована палітра)
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": INK2,
    "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False, "figure.facecolor": SURF, "axes.facecolor": SURF,
    "legend.frameon": False, "axes.titleweight": "bold", "axes.titlecolor": INK, "axes.axisbelow": True,
})
LABEL = {"S1_menu": "S1 Меню (QR)", "S2_order_check": "S2 Живий чек", "S4_kds_queue": "S4 Екран кухні",
         "S6_hall_map": "S6 Мапа залу", "S7_top_dishes": "S7 ТОП-10 дня",
         "S3_add_item": "S3 Додати страву", "S5_kds_ready": "S5 Страва готова"}
ORDER = ["S1_menu", "S2_order_check", "S4_kds_queue", "S6_hall_map", "S7_top_dishes", "S3_add_item", "S5_kds_ready"]


def load(name):
    p = R / name
    return json.loads(p.read_text()) if p.exists() else None


def pooled(data, scen, store, mode):
    """Перцентилі по всіх вибірках усіх повторів + медіана серверного часу."""
    xs = sorted(data["samples"][f"{scen}|{store}|{mode}"])
    q = lambda p: xs[min(len(xs) - 1, int(p / 100 * len(xs)))]  # noqa: E731
    srv = [r["server_us"] for r in data["results"]
           if r["scenario"] == scen and r["store"] == store and r["mode"] == mode and r["server_us"]]
    p50s = [r["p50"] for r in data["results"] if r["scenario"] == scen and r["store"] == store and r["mode"] == mode]
    return dict(n=len(xs), p50=q(50), p95=q(95), p99=q(99), mean=statistics.fmean(xs),
                server=statistics.median(srv) if srv else None,
                p50_spread=(max(p50s) - min(p50s)) / statistics.median(p50s) * 100)


def bar_label(ax, rects, fmt):
    for r in rects:
        ax.annotate(fmt(r.get_width()), (r.get_width(), r.get_y() + r.get_height() / 2),
                    xytext=(4, 0), textcoords="offset points", va="center", fontsize=8, color=INK2)


def chart_latency(data, out):
    rows = []
    for s in ORDER:
        modes = ["durable", "relaxed"] if s in ("S3_add_item", "S5_kds_ready") else ["durable"]
        for m in modes:
            if f"{s}|postgres|{m}" in data["samples"]:
                lab = LABEL[s] + ("" if len(modes) == 1 else (" · durable" if m == "durable" else " · relaxed"))
                rows.append((lab, pooled(data, s, "postgres", m), pooled(data, s, "redis", m)))
    rows = rows[::-1]
    fig, axes = plt.subplots(1, 2, figsize=(13, 6.2), sharey=True, gridspec_kw={"wspace": 0.08})
    y = range(len(rows))
    h = 0.38
    for ax, key, ttl in [(axes[0], "p50", "Медіана (p50), мкс"), (axes[1], "server", "Серверний час, мкс")]:
        a = ax.barh([i + h / 2 + 0.01 for i in y], [r[1][key] for r in rows], h, color=PG, label="PostgreSQL")
        b = ax.barh([i - h / 2 - 0.01 for i in y], [r[2][key] for r in rows], h, color=RD, label="Redis")
        ax.set_xscale("log")
        ax.set_title(ttl, loc="left", fontsize=11)
        ax.grid(axis="y", visible=False)
        bar_label(ax, a, lambda v: f"{v:,.0f}".replace(",", " "))
        bar_label(ax, b, lambda v: f"{v:,.0f}".replace(",", " "))
        ax.set_xlim(right=ax.get_xlim()[1] * 3)
    axes[0].set_yticks(list(y), [r[0] for r in rows])
    axes[0].legend(loc="lower right")
    fig.suptitle("Затримка операцій модуля Live Service (1 клієнт, 1 млн замовлень в історії)",
                 x=0.01, ha="left", fontweight="bold", color=INK)
    fig.text(0.01, 0.005, "Логарифмічна шкала. Медіана — час, який бачить клієнт (мережа + сервер + розбір відповіді); "
             "серверний — pg_stat_statements / Redis INFO commandstats.", fontsize=8, color=INK2)
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)


def chart_mixed(data, out):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.4), sharey=True)
    for ax, mode, ttl in [(axes[0], "durable", "durable: sync_commit=on ↔ appendfsync always"),
                          (axes[1], "relaxed", "relaxed: sync_commit=off ↔ appendfsync everysec")]:
        for store, col, name in [("postgres", PG, "PostgreSQL"), ("redis", RD, "Redis")]:
            rs = sorted((r for r in data["results"] if r["mode"] == mode and r["store"] == store),
                        key=lambda r: r["procs"])
            xs, ys = [r["procs"] for r in rs], [r["throughput"] for r in rs]
            ax.plot(xs, ys, color=col, lw=2, marker="o", ms=7, mec=SURF, mew=2, label=name)
            ax.annotate(f"{ys[-1]:,.0f}".replace(",", " "), (xs[-1], ys[-1]), xytext=(6, 0),
                        textcoords="offset points", va="center", fontsize=8, color=INK2)
        ax.set_xscale("log", base=2)
        ax.set_xticks([1, 2, 4, 8, 16], ["1", "2", "4", "8", "16"])
        ax.set_xlabel("паралельних клієнтів (процесів)")
        ax.set_title(ttl, loc="left", fontsize=10)
        ax.set_ylim(bottom=0, top=max(r["throughput"] for r in data["results"]) * 1.15)
    axes[0].set_ylabel("операцій/с")
    axes[0].legend(loc="upper left")
    fig.suptitle("Змішане навантаження (70% читань / 30% записів), пропускна здатність",
                 x=0.01, ha="left", fontweight="bold", color=INK)
    fig.tight_layout()
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)


def chart_today(points, out):
    fig, ax = plt.subplots(figsize=(7.5, 4.2))
    xs = [p[0] for p in points]
    for idx, col, name in [(1, PG, "PostgreSQL — агрегація GROUP BY"), (2, RD, "Redis — ZREVRANGE готового рейтингу")]:
        ys = [p[idx] for p in points]
        ax.plot(xs, ys, color=col, lw=2, marker="o", ms=7, mec=SURF, mew=2, label=name)
        for x, v in zip(xs, ys):
            ax.annotate(f"{v / 1000:.2f} мс", (x, v), xytext=(0, 8), textcoords="offset points",
                        ha="center", fontsize=8, color=INK2)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("позицій, відправлених на кухню за сьогодні")
    ax.set_ylabel("p50, мкс")
    ax.legend(loc="upper left")
    ax.set_title("S7 «ТОП-10 страв дня»: залежність від обсягу продажів за день", loc="left", fontsize=11)
    fig.tight_layout()
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)


def fmt(v):
    return "—" if v is None else f"{v:,.0f}".replace(",", " ")


def main():
    md = []
    lat = load("latency_1M.json")
    if lat:
        chart_latency(lat, R / "latency_1M.png")
        md.append("## Затримка, 1 клієнт, історія 1 млн замовлень (мкс)\n")
        md.append(f"Обсяги: {lat['meta']['rows']}\n")
        md.append("| Сценарій | Режим | PG p50 | PG p95 | PG p99 | PG сервер | Redis p50 | Redis p95 | Redis p99 "
                  "| Redis сервер | PG/Redis (p50) | розкид p50 між повторами PG / Redis |")
        md.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for s in ORDER:
            for m in (["durable", "relaxed"] if s in ("S3_add_item", "S5_kds_ready") else ["durable"]):
                if f"{s}|postgres|{m}" not in lat["samples"]:
                    continue
                a, b = pooled(lat, s, "postgres", m), pooled(lat, s, "redis", m)
                md.append(f"| {LABEL[s]} | {m if s in ('S3_add_item', 'S5_kds_ready') else '—'} | {fmt(a['p50'])} "
                          f"| {fmt(a['p95'])} | {fmt(a['p99'])} | {fmt(a['server'])} | {fmt(b['p50'])} "
                          f"| {fmt(b['p95'])} | {fmt(b['p99'])} | {fmt(b['server'])} | ×{a['p50'] / b['p50']:.1f} "
                          f"| {a['p50_spread']:.0f}% / {b['p50_spread']:.0f}% |")
    scale = [(n, load(f"latency_{n}.json")) for n in ("10000", "100000", "1M")]
    if all(d for _, d in scale):
        md.append("\n## Вплив обсягу історії (p50 / серверний час PG, мкс)\n")
        md.append("| Сценарій | " + " | ".join(f"{n} замовлень" for n, _ in scale) + " | Redis (1M) |")
        md.append("|---|---|---|---|---|")
        for s in ORDER[:5]:
            cells = []
            for _, d in scale:
                a = pooled(d, s, "postgres", "durable")
                cells.append(f"{fmt(a['p50'])} / {fmt(a['server'])}")
            b = pooled(scale[-1][1], s, "redis", "durable")
            md.append(f"| {LABEL[s]} | " + " | ".join(cells) + f" | {fmt(b['p50'])} / {fmt(b['server'])} |")
        md.append("\nРядків order_items: " + ", ".join(f"{n}: {d['meta']['rows']['order_items']:,}" for n, d in scale))
    pts = []
    for name in ("latency_100000.json", "today_4000.json", "today_20000.json"):
        d = load(name)
        if d:
            pts.append((d["meta"]["rows"]["items_today"], pooled(d, "S7_top_dishes", "postgres", "durable")["p50"],
                        pooled(d, "S7_top_dishes", "redis", "durable")["p50"]))
    if len(pts) >= 2:
        chart_today(sorted(pts), R / "top_today.png")
        md.append("\n## S7 залежно від обсягу продажів за день (p50, мкс)\n")
        md.append("| Позицій за день | PostgreSQL | Redis |\n|---|---|---|")
        for x, a, b in sorted(pts):
            md.append(f"| {x:,} | {fmt(a)} | {fmt(b)} |")
    mixed = load("mixed_1M.json")
    if mixed:
        chart_mixed(mixed, R / "mixed_1M.png")
        md.append("\n## Змішане навантаження (оп/с; p95, мкс)\n")
        md.append("| Режим | Клієнтів | PG оп/с | PG p95 | Redis оп/с | Redis p95 | Redis/PG |")
        md.append("|---|---|---|---|---|---|---|")
        for mode in ("durable", "relaxed"):
            for p in sorted({r["procs"] for r in mixed["results"]}):
                a = next(r for r in mixed["results"] if r["mode"] == mode and r["procs"] == p and r["store"] == "postgres")
                b = next(r for r in mixed["results"] if r["mode"] == mode and r["procs"] == p and r["store"] == "redis")
                md.append(f"| {mode} | {p} | {fmt(a['throughput'])} | {fmt(a['p95'])} | {fmt(b['throughput'])} "
                          f"| {fmt(b['p95'])} | ×{b['throughput'] / a['throughput']:.1f} |")
    abl = load("ablation_1M.json")
    if abl:
        md.append("\n## Абляція індексів (PostgreSQL, 1 млн замовлень, p50, мкс)\n")
        md.append("| Сценарій | Індекс | з індексом | без індексу | сповільнення |\n|---|---|---|---|---|")
        for s in dict.fromkeys(r["scenario"] for r in abl["results"]):
            w = next(r for r in abl["results"] if r["scenario"] == s and r["variant"] == "with_index")
            wo = next(r for r in abl["results"] if r["scenario"] == s and r["variant"] == "without_index")
            md.append(f"| {LABEL[s]} | {w['index']} | {fmt(w['p50'])} | {fmt(wo['p50'])} | ×{wo['p50'] / w['p50']:,.0f} |")
    (R / "summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md))


if __name__ == "__main__":
    main()
