#!/usr/bin/env python3
import argparse
import json
import pathlib
import subprocess
import sys
import time
from dataclasses import dataclass

try:
    import pymysql
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "PyMySQL가 필요합니다. `pip install -r requirements.txt` 후 다시 실행하세요."
    ) from exc

try:
    import redis
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "redis-py가 필요합니다. `pip install -r requirements.txt` 후 다시 실행하세요."
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
        description="단건 응답 시간 위주. 사용자 한 명이 반복 조회.",
        requests=3_000,
        warmup=300,
        concurrency=1,
    ),
    Scenario(
        name="steady_api",
        description="일반적인 API 핫패스.",
        requests=8_000,
        warmup=500,
        concurrency=8,
    ),
    Scenario(
        name="burst_hot_key",
        description="같은 조회가 짧은 시간에 몰리는 버스트.",
        requests=16_000,
        warmup=1_000,
        concurrency=32,
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a strict cold-vs-warm benchmark suite with buffer-pool verification."
    )
    parser.add_argument("--university-id", type=int, default=1)
    parser.add_argument("--gender", default="M")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--mysql-host", default="127.0.0.1")
    parser.add_argument("--mysql-port", type=int, default=3310)
    parser.add_argument("--mysql-user", default="lab")
    parser.add_argument("--mysql-password", default="lab")
    parser.add_argument("--mysql-database", default="read_inmemory_data")
    parser.add_argument("--redis-host", default="127.0.0.1")
    parser.add_argument("--redis-port", type=int, default=6381)
    parser.add_argument("--redis-db", type=int, default=0)
    args = parser.parse_args()

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


def fetch_memory_budget(args: argparse.Namespace) -> dict[str, int]:
    conn = mysql_connect(args)
    try:
        with conn.cursor() as cur:
            cur.execute("SHOW VARIABLES LIKE 'innodb_buffer_pool_size'")
            mysql_buffer_pool_size = int(cur.fetchone()["Value"])
    finally:
        conn.close()

    client = redis.Redis(
        host=args.redis_host,
        port=args.redis_port,
        db=args.redis_db,
        decode_responses=True,
    )
    redis_maxmemory = int(client.config_get("maxmemory").get("maxmemory", "0"))

    return {
        "mysql_innodb_buffer_pool_size": mysql_buffer_pool_size,
        "redis_maxmemory": redis_maxmemory,
    }


def ensure_equal_memory_budget(memory_budget: dict[str, int]) -> None:
    mysql_bp = memory_budget["mysql_innodb_buffer_pool_size"]
    redis_maxmemory = memory_budget["redis_maxmemory"]
    if mysql_bp != redis_maxmemory:
        raise SystemExit(
            "MySQL innodb_buffer_pool_size and Redis maxmemory must match for this suite: "
            f"{mysql_bp} != {redis_maxmemory}"
        )


def set_index_state(args: argparse.Namespace, case_name: str) -> None:
    conn = mysql_connect(args)
    try:
        with conn.cursor() as cur:
            for name in ("idx_user_match_plain", "idx_user_match_covering"):
                cur.execute(
                    """
                    SELECT COUNT(*) AS cnt
                    FROM information_schema.statistics
                    WHERE table_schema = DATABASE()
                      AND table_name = 'user_match'
                      AND index_name = %s
                    """,
                    (name,),
                )
                if int(cur.fetchone()["cnt"]) > 0:
                    cur.execute(f"DROP INDEX {name} ON user_match")

            if case_name == "plain":
                cur.execute(
                    """
                    CREATE INDEX idx_user_match_plain
                    ON user_match (university_id, gender, match_score DESC)
                    """
                )
            else:
                cur.execute(
                    """
                    CREATE INDEX idx_user_match_covering
                    ON user_match (university_id, gender, match_score DESC, user_id)
                    """
                )
            cur.execute("ANALYZE TABLE user_match")
    finally:
        conn.close()


def restart_mysql() -> None:
    subprocess.run(
        ["docker", "compose", "restart", "mysql"],
        check=True,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def wait_for_mysql(args: argparse.Namespace, timeout_s: float = 60.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            conn = mysql_connect(args)
            conn.close()
            return
        except pymysql.MySQLError:
            time.sleep(1.0)
    raise SystemExit("MySQL did not become ready in time after restart")


def ensure_buffer_pool_restart_policy(args: argparse.Namespace) -> dict[str, str]:
    conn = mysql_connect(args)
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SHOW VARIABLES
                WHERE Variable_name IN (
                  'innodb_buffer_pool_dump_at_shutdown',
                  'innodb_buffer_pool_load_at_startup'
                )
                """
            )
            rows = cur.fetchall()
    finally:
        conn.close()
    return {row["Variable_name"]: row["Value"] for row in rows}


def run_bench_case(
    args: argparse.Namespace,
    scenario: Scenario,
    cache_state: str,
    case_name: str,
    out_dir: pathlib.Path,
    warmup_override: int | None = None,
    suffix: str = "",
) -> dict:
    file_stem = f"{scenario.name}.{cache_state}.{case_name}{suffix}"
    json_path = out_dir / f"{file_stem}.json"
    md_path = out_dir / f"{file_stem}.md"

    warmup = warmup_override if warmup_override is not None else (
        0 if cache_state == "cold" else scenario.warmup
    )
    cmd = [
        sys.executable,
        str(BENCH_SCRIPT),
        "--case",
        case_name,
        "--requests",
        str(scenario.requests),
        "--warmup",
        str(warmup),
        "--concurrency",
        str(scenario.concurrency),
        "--university-id",
        str(args.university_id),
        "--gender",
        args.gender,
        "--limit",
        str(args.limit),
        "--skip-index-prepare",
        "--markdown-out",
        str(md_path),
        "--json-out",
        str(json_path),
    ]
    subprocess.run(cmd, check=True, cwd=ROOT)
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    result = payload["results"][0]
    result["cache_state"] = cache_state
    result["scenario"] = scenario.name
    result["description"] = scenario.description
    return result


def run_warm_case(
    args: argparse.Namespace,
    scenario: Scenario,
    case_name: str,
    out_dir: pathlib.Path,
    max_attempts: int = 4,
) -> dict:
    last_result = None
    for attempt in range(1, max_attempts + 1):
        warmup = scenario.warmup if attempt == 1 else 0
        result = run_bench_case(
            args=args,
            scenario=scenario,
            cache_state="warm",
            case_name=case_name,
            out_dir=out_dir,
            warmup_override=warmup,
            suffix=f".attempt{attempt}",
        )
        result["warm_attempts"] = attempt
        last_result = result
        if result.get("benchmark_buffer_pool_reads_delta", 0) == 0:
            return result
    return last_result


def run_redis_case(args: argparse.Namespace, scenario: Scenario, out_dir: pathlib.Path) -> dict:
    json_path = out_dir / f"{scenario.name}.redis.json"
    md_path = out_dir / f"{scenario.name}.redis.md"
    cmd = [
        sys.executable,
        str(BENCH_SCRIPT),
        "--case",
        "redis",
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
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    result = payload["results"][0]
    result["cache_state"] = "n/a"
    result["scenario"] = scenario.name
    result["description"] = scenario.description
    return result


def mib(value: int) -> float:
    return value / (1024 * 1024)


def build_markdown(
    policy: dict[str, str], dataset_stats: dict, memory_budget: dict[str, int], rows: list[dict]
) -> str:
    lines = [
        "# Buffer Pool Verified Benchmark Suite",
        "",
        "## Method",
        "",
        "- Premise: compare Redis and MySQL only when both are constrained to the same memory budget",
        "- MySQL restart policy:",
        f"  - innodb_buffer_pool_dump_at_shutdown={policy.get('innodb_buffer_pool_dump_at_shutdown')}",
        f"  - innodb_buffer_pool_load_at_startup={policy.get('innodb_buffer_pool_load_at_startup')}",
        "- `cold`: index prepared first, then MySQL restarted, then benchmark run with warmup=0",
        "- `warm`: index prepared first, then MySQL restarted, then warmup query executed before measurement",
        "- `benchmark_buffer_pool_reads_delta=0`이면 측정 구간에서 디스크 miss 없이 버퍼 풀 hit만으로 처리됐다고 본다",
        "",
        "## Memory Budget",
        "",
        f"- MySQL innodb_buffer_pool_size: {memory_budget['mysql_innodb_buffer_pool_size']} bytes ({mib(memory_budget['mysql_innodb_buffer_pool_size']):.2f} MiB)",
        f"- Redis maxmemory: {memory_budget['redis_maxmemory']} bytes ({mib(memory_budget['redis_maxmemory']):.2f} MiB)",
        "",
        "## Dataset",
        "",
        f"- total_rows: {dataset_stats['total_rows']}",
        f"- matched_rows: {dataset_stats['matched_rows']}",
        f"- matched_ratio: {dataset_stats['match_ratio'] * 100:.2f}%",
        "",
        "## Results",
        "",
        "| scenario | cache_state | case | avg_ms | p95_ms | max_ms | tps | warm_attempts | warmup_bp_reads | benchmark_bp_reads |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]

    for row in rows:
        lines.append(
            f"| {row['scenario']} | {row['cache_state']} | {row['case']} | "
            f"{row['avg_ms']:.3f} | {row['p95_ms']:.3f} | {row['max_ms']:.3f} | "
            f"{row['tps']:.2f} | {row.get('warm_attempts', 1)} | "
            f"{row.get('warmup_buffer_pool_reads_delta', 0)} | "
            f"{row.get('benchmark_buffer_pool_reads_delta', 0)} |"
        )

    return "\n".join(lines) + "\n"


def main() -> None:
    args = parse_args()
    out_dir = ROOT / "out" / "suite_2m_buffer_pool"
    out_dir.mkdir(parents=True, exist_ok=True)

    dataset_stats = fetch_dataset_stats(args)
    if dataset_stats["total_rows"] == 0:
        raise SystemExit("user_match 테이블이 비어 있습니다. 먼저 seed_user_match.py를 실행하세요.")

    policy = ensure_buffer_pool_restart_policy(args)
    memory_budget = fetch_memory_budget(args)
    ensure_equal_memory_budget(memory_budget)
    rows: list[dict] = []

    for scenario in SCENARIOS:
        for case_name in ("plain", "covering"):
            set_index_state(args, case_name)
            restart_mysql()
            wait_for_mysql(args)
            rows.append(run_bench_case(args, scenario, "cold", case_name, out_dir))

            set_index_state(args, case_name)
            restart_mysql()
            wait_for_mysql(args)
            rows.append(run_warm_case(args, scenario, case_name, out_dir))

        rows.append(run_redis_case(args, scenario, out_dir))

    markdown = build_markdown(policy, dataset_stats, memory_budget, rows)
    (out_dir / "summary.md").write_text(markdown, encoding="utf-8")
    (out_dir / "summary.json").write_text(
        json.dumps(
            {
                "buffer_pool_restart_policy": policy,
                "dataset_stats": dataset_stats,
                "memory_budget": memory_budget,
                "results": rows,
            },
            ensure_ascii=False,
            indent=2,
            default=str,
        ),
        encoding="utf-8",
    )
    print(markdown, end="")


if __name__ == "__main__":
    main()
