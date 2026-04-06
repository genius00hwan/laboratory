#!/usr/bin/env python3
import argparse
import json
import pathlib
import statistics
import subprocess
import sys
from dataclasses import dataclass

try:
    import pymysql
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "PyMySQL가 필요합니다. `pip install -r requirements.txt` 후 다시 실행하세요."
    ) from exc


ROOT = pathlib.Path(__file__).resolve().parent.parent
BENCH_SCRIPT = ROOT / "tools" / "bench_user_match.py"


@dataclass(frozen=True)
class Scenario:
    name: str
    description: str
    requests: int
    warmup: int
    concurrency: int


SCENARIOS = [
    Scenario(
        name="interactive_single",
        description="단건 응답 시간 위주. 사용자 한 명이 반복해서 조회하는 상황.",
        requests=3_000,
        warmup=300,
        concurrency=1,
    ),
    Scenario(
        name="steady_api",
        description="일반적인 API 핫패스. 적당한 동시성으로 꾸준히 반복되는 상황.",
        requests=8_000,
        warmup=500,
        concurrency=8,
    ),
    Scenario(
        name="burst_hot_key",
        description="같은 조회가 짧은 시간에 몰리는 버스트 상황.",
        requests=16_000,
        warmup=1_000,
        concurrency=32,
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a multi-scenario benchmark suite for MySQL vs Redis."
    )
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--university-id", type=int, default=1)
    parser.add_argument("--gender", default="M")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--mysql-host", default="127.0.0.1")
    parser.add_argument("--mysql-port", type=int, default=3310)
    parser.add_argument("--mysql-user", default="lab")
    parser.add_argument("--mysql-password", default="lab")
    parser.add_argument("--mysql-database", default="read_inmemory_data")
    args = parser.parse_args()

    if args.repeats <= 0:
        raise SystemExit("--repeats must be > 0")
    if len(args.gender) != 1:
        raise SystemExit("--gender must be a single character")
    if args.limit <= 0:
        raise SystemExit("--limit must be > 0")
    return args


def mysql_connect(args: argparse.Namespace):
    return pymysql.connect(
        host=args.mysql_host,
        port=args.mysql_port,
        user=args.mysql_user,
        password=args.mysql_password,
        database=args.mysql_database,
        charset="utf8mb4",
        autocommit=True,
        cursorclass=pymysql.cursors.DictCursor,
    )


def fetch_dataset_stats(args: argparse.Namespace) -> dict:
    conn = mysql_connect(args)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS total_rows FROM user_match")
            total_rows = int(cur.fetchone()["total_rows"])
            cur.execute(
                """
                SELECT COUNT(*) AS matched_rows
                FROM user_match
                WHERE university_id = %s
                  AND gender = %s
                """,
                (args.university_id, args.gender),
            )
            matched_rows = int(cur.fetchone()["matched_rows"])
    finally:
        conn.close()

    return {
        "total_rows": total_rows,
        "matched_rows": matched_rows,
        "match_ratio": matched_rows / total_rows if total_rows else 0.0,
    }


def run_once(
    args: argparse.Namespace,
    scenario: Scenario,
    repeat: int,
    scenario_dir: pathlib.Path,
) -> dict:
    json_path = scenario_dir / f"{scenario.name}.run{repeat}.json"
    md_path = scenario_dir / f"{scenario.name}.run{repeat}.md"

    cmd = [
        sys.executable,
        str(BENCH_SCRIPT),
        "--case",
        "all",
        "--requests",
        str(scenario.requests),
        "--warmup",
        str(scenario.warmup),
        "--concurrency",
        str(scenario.concurrency),
        "--university-id",
        str(args.university_id),
        "--gender",
        args.gender,
        "--limit",
        str(args.limit),
        "--markdown-out",
        str(md_path),
        "--json-out",
        str(json_path),
    ]
    subprocess.run(cmd, check=True, cwd=ROOT)
    return json.loads(json_path.read_text(encoding="utf-8"))


def aggregate_case_results(run_payloads: list[dict]) -> list[dict]:
    by_case: dict[str, list[dict]] = {}
    for payload in run_payloads:
        for result in payload["results"]:
            by_case.setdefault(result["case"], []).append(result)

    aggregated = []
    for case_name in ("plain", "covering", "redis"):
        items = by_case[case_name]
        aggregated.append(
            {
                "case": case_name,
                "requests": int(statistics.fmean(item["requests"] for item in items)),
                "avg_ms": statistics.fmean(item["avg_ms"] for item in items),
                "p95_ms": statistics.fmean(item["p95_ms"] for item in items),
                "max_ms": statistics.fmean(item["max_ms"] for item in items),
                "tps": statistics.fmean(item["tps"] for item in items),
            }
        )
    return aggregated


def build_suite_markdown(
    args: argparse.Namespace,
    dataset_stats: dict,
    scenario_runs: list[dict],
) -> str:
    lines = [
        "# Benchmark Suite",
        "",
        f"- total_rows: {dataset_stats['total_rows']}",
        f"- matched_rows: {dataset_stats['matched_rows']}",
        f"- matched_ratio: {dataset_stats['match_ratio'] * 100:.2f}%",
        f"- query: university_id={args.university_id}, gender='{args.gender}', limit={args.limit}",
        "",
        "## Scenarios",
        "",
        "| scenario | description | requests | warmup | concurrency |",
        "|---|---|---:|---:|---:|",
    ]

    for item in scenario_runs:
        scenario = item["scenario"]
        lines.append(
            f"| {scenario.name} | {scenario.description} | {scenario.requests} | "
            f"{scenario.warmup} | {scenario.concurrency} |"
        )

    lines.extend(
        [
            "",
            "## Results",
            "",
            "| scenario | case | avg_ms | p95_ms | max_ms | tps |",
            "|---|---|---:|---:|---:|---:|",
        ]
    )

    for item in scenario_runs:
        for result in item["aggregated_results"]:
            lines.append(
                f"| {item['scenario'].name} | {result['case']} | "
                f"{result['avg_ms']:.3f} | {result['p95_ms']:.3f} | "
                f"{result['max_ms']:.3f} | {result['tps']:.2f} |"
            )

    lines.extend(
        [
            "",
            "## Relative Improvement",
            "",
            "| scenario | covering_vs_plain_avg | covering_vs_plain_p95 | redis_vs_covering_avg | redis_vs_covering_p95 | redis_vs_covering_tps |",
            "|---|---:|---:|---:|---:|---:|",
        ]
    )

    for item in scenario_runs:
        results = {result["case"]: result for result in item["aggregated_results"]}
        plain = results["plain"]
        covering = results["covering"]
        redis_case = results["redis"]

        def improve_pct(old: float, new: float) -> float:
            return ((old - new) / old) * 100 if old else 0.0

        def gain_pct(old: float, new: float) -> float:
            return ((new - old) / old) * 100 if old else 0.0

        lines.append(
            f"| {item['scenario'].name} | "
            f"{improve_pct(plain['avg_ms'], covering['avg_ms']):.1f}% | "
            f"{improve_pct(plain['p95_ms'], covering['p95_ms']):.1f}% | "
            f"{improve_pct(covering['avg_ms'], redis_case['avg_ms']):.1f}% | "
            f"{improve_pct(covering['p95_ms'], redis_case['p95_ms']):.1f}% | "
            f"{gain_pct(covering['tps'], redis_case['tps']):.1f}% |"
        )

    return "\n".join(lines) + "\n"


def main() -> None:
    args = parse_args()
    out_dir = ROOT / "out" / "suite_2m"
    out_dir.mkdir(parents=True, exist_ok=True)

    dataset_stats = fetch_dataset_stats(args)
    if dataset_stats["total_rows"] == 0:
        raise SystemExit("user_match 테이블이 비어 있습니다. 먼저 seed_user_match.py를 실행하세요.")

    scenario_runs: list[dict] = []
    for scenario in SCENARIOS:
        run_payloads = []
        for repeat in range(1, args.repeats + 1):
            run_payloads.append(run_once(args, scenario, repeat, out_dir))

        scenario_runs.append(
            {
                "scenario": scenario,
                "aggregated_results": aggregate_case_results(run_payloads),
                "raw_runs": run_payloads,
            }
        )

    markdown = build_suite_markdown(args, dataset_stats, scenario_runs)
    (out_dir / "summary.md").write_text(markdown, encoding="utf-8")

    json_payload = {
        "dataset_stats": dataset_stats,
        "scenarios": [
            {
                "scenario": {
                    "name": item["scenario"].name,
                    "description": item["scenario"].description,
                    "requests": item["scenario"].requests,
                    "warmup": item["scenario"].warmup,
                    "concurrency": item["scenario"].concurrency,
                },
                "aggregated_results": item["aggregated_results"],
                "raw_runs": item["raw_runs"],
            }
            for item in scenario_runs
        ],
    }
    (out_dir / "summary.json").write_text(
        json.dumps(json_payload, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8",
    )

    print(markdown, end="")


if __name__ == "__main__":
    main()
