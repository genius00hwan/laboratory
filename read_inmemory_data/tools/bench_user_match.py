#!/usr/bin/env python3
import argparse
import json
import math
import pathlib
import statistics
import time
from concurrent.futures import ThreadPoolExecutor
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


QUERY_SQL = """
SELECT user_id, match_score
FROM user_match
WHERE university_id = %s
  AND gender = %s
ORDER BY match_score DESC
LIMIT %s
"""


@dataclass
class MysqlConfig:
    host: str
    port: int
    user: str
    password: str
    database: str


@dataclass
class RedisConfig:
    host: str
    port: int
    db: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark plain MySQL vs covering index vs Redis cache."
    )
    parser.add_argument("--case", choices=["plain", "covering", "redis", "all"], default="all")
    parser.add_argument("--requests", type=int, default=1_000)
    parser.add_argument("--warmup", type=int, default=100)
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--university-id", type=int, default=1)
    parser.add_argument("--gender", default="M")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument(
        "--cache-key",
        default="user_match:u={university_id}:g={gender}:limit={limit}",
    )
    parser.add_argument("--markdown-out")
    parser.add_argument("--json-out")
    parser.add_argument("--mysql-host", default="127.0.0.1")
    parser.add_argument("--mysql-port", type=int, default=3310)
    parser.add_argument("--mysql-user", default="lab")
    parser.add_argument("--mysql-password", default="lab")
    parser.add_argument("--mysql-database", default="read_inmemory_data")
    parser.add_argument("--redis-host", default="127.0.0.1")
    parser.add_argument("--redis-port", type=int, default=6381)
    parser.add_argument("--redis-db", type=int, default=0)
    args = parser.parse_args()

    if args.requests <= 0:
        raise SystemExit("--requests must be > 0")
    if args.warmup < 0:
        raise SystemExit("--warmup must be >= 0")
    if args.concurrency <= 0:
        raise SystemExit("--concurrency must be > 0")
    if args.limit <= 0:
        raise SystemExit("--limit must be > 0")
    if len(args.gender) != 1:
        raise SystemExit("--gender must be a single character")
    return args


def mysql_connect(config: MysqlConfig):
    return pymysql.connect(
        host=config.host,
        port=config.port,
        user=config.user,
        password=config.password,
        database=config.database,
        charset="utf8mb4",
        autocommit=True,
        cursorclass=pymysql.cursors.DictCursor,
    )


def redis_connect(config: RedisConfig):
    return redis.Redis(
        host=config.host,
        port=config.port,
        db=config.db,
        decode_responses=True,
    )


def ensure_base_table(conn) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM information_schema.tables
            WHERE table_schema = DATABASE()
              AND table_name = 'user_match'
            """
        )
        if int(cur.fetchone()["cnt"]) == 0:
            raise SystemExit("user_match 테이블이 없습니다. 먼저 sql/set_user_match.sql을 적용하세요.")


def query_row_count(conn) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS cnt FROM user_match")
        return int(cur.fetchone()["cnt"])


def index_exists(conn, index_name: str) -> bool:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM information_schema.statistics
            WHERE table_schema = DATABASE()
              AND table_name = 'user_match'
              AND index_name = %s
            """,
            (index_name,),
        )
        return int(cur.fetchone()["cnt"]) > 0


def prepare_plain_index(conn) -> None:
    for name in ("idx_user_match_covering", "idx_user_match_plain"):
        if index_exists(conn, name):
            with conn.cursor() as cur:
                cur.execute(f"DROP INDEX {name} ON user_match")
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE INDEX idx_user_match_plain
            ON user_match (university_id, gender, match_score DESC)
            """
        )
        cur.execute("ANALYZE TABLE user_match")


def prepare_covering_index(conn) -> None:
    for name in ("idx_user_match_plain", "idx_user_match_covering"):
        if index_exists(conn, name):
            with conn.cursor() as cur:
                cur.execute(f"DROP INDEX {name} ON user_match")
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE INDEX idx_user_match_covering
            ON user_match (university_id, gender, match_score DESC, user_id)
            """
        )
        cur.execute("ANALYZE TABLE user_match")


def run_explain(conn, params: tuple[int, str, int]) -> dict:
    with conn.cursor() as cur:
        cur.execute(f"EXPLAIN {QUERY_SQL}", params)
        rows = cur.fetchall()

    extra_tokens: list[str] = []
    for row in rows:
        extra = row.get("Extra") or ""
        extra_tokens.extend(token.strip() for token in extra.split(";") if token.strip())
    return {
        "rows": rows,
        "using_index": "Using index" in extra_tokens,
        "using_filesort": "Using filesort" in extra_tokens,
    }


def fetch_mysql_result(conn, params: tuple[int, str, int]) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(QUERY_SQL, params)
        rows = cur.fetchall()
    return [
        {
            "user_id": int(row["user_id"]),
            "match_score": float(row["match_score"]),
        }
        for row in rows
    ]


def split_counts(total: int, buckets: int) -> list[int]:
    base = total // buckets
    remainder = total % buckets
    return [base + (1 if i < remainder else 0) for i in range(buckets)]


def warmup_mysql(config: MysqlConfig, params: tuple[int, str, int], requests: int) -> None:
    if requests == 0:
        return
    conn = mysql_connect(config)
    try:
        for _ in range(requests):
            fetch_mysql_result(conn, params)
    finally:
        conn.close()


def warmup_redis(config: RedisConfig, key: str, requests: int) -> None:
    if requests == 0:
        return
    client = redis_connect(config)
    for _ in range(requests):
        payload = client.get(key)
        if payload is None:
            raise RuntimeError(f"cache miss for key={key}")
        json.loads(payload)


def mysql_worker(request_count: int, config: MysqlConfig, params: tuple[int, str, int]) -> list[int]:
    conn = mysql_connect(config)
    latencies_ns: list[int] = []
    try:
        for _ in range(request_count):
            started = time.perf_counter_ns()
            fetch_mysql_result(conn, params)
            latencies_ns.append(time.perf_counter_ns() - started)
    finally:
        conn.close()
    return latencies_ns


def redis_worker(request_count: int, config: RedisConfig, key: str) -> list[int]:
    client = redis_connect(config)
    latencies_ns: list[int] = []
    for _ in range(request_count):
        started = time.perf_counter_ns()
        payload = client.get(key)
        if payload is None:
            raise RuntimeError(f"cache miss for key={key}")
        json.loads(payload)
        latencies_ns.append(time.perf_counter_ns() - started)
    return latencies_ns


def percentile_ms(latencies_ms: list[float], percentile: float) -> float:
    if not latencies_ms:
        return 0.0
    ordered = sorted(latencies_ms)
    rank = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[rank]


def summarize_case(case_name: str, latencies_ns: list[int], wall_ns: int) -> dict:
    latencies_ms = [value / 1_000_000 for value in latencies_ns]
    requests = len(latencies_ms)
    return {
        "case": case_name,
        "requests": requests,
        "avg_ms": statistics.fmean(latencies_ms) if latencies_ms else 0.0,
        "p95_ms": percentile_ms(latencies_ms, 0.95),
        "max_ms": max(latencies_ms) if latencies_ms else 0.0,
        "tps": requests / max(wall_ns / 1_000_000_000, 1e-9),
    }


def run_parallel(worker_fn, counts: list[int]) -> tuple[list[int], int]:
    active_counts = [count for count in counts if count > 0]
    if not active_counts:
        return [], 0

    started = time.perf_counter_ns()
    with ThreadPoolExecutor(max_workers=len(active_counts)) as executor:
        futures = [executor.submit(worker_fn, count) for count in active_counts]
        latencies_ns: list[int] = []
        for future in futures:
            latencies_ns.extend(future.result())
    return latencies_ns, time.perf_counter_ns() - started


def benchmark_mysql_case(
    case_name: str,
    mysql_config: MysqlConfig,
    params: tuple[int, str, int],
    warmup: int,
    request_counts: list[int],
) -> dict:
    warmup_mysql(mysql_config, params, warmup)
    latencies_ns, wall_ns = run_parallel(
        lambda count: mysql_worker(count, mysql_config, params),
        request_counts,
    )
    return summarize_case(case_name, latencies_ns, wall_ns)


def benchmark_redis_case(
    redis_config: RedisConfig,
    key: str,
    warmup: int,
    request_counts: list[int],
) -> dict:
    warmup_redis(redis_config, key, warmup)
    latencies_ns, wall_ns = run_parallel(
        lambda count: redis_worker(count, redis_config, key),
        request_counts,
    )
    return summarize_case("redis", latencies_ns, wall_ns)


def cache_key_for(args: argparse.Namespace) -> str:
    return args.cache_key.format(
        university_id=args.university_id,
        gender=args.gender,
        limit=args.limit,
    )


def warm_redis_from_mysql(
    mysql_config: MysqlConfig,
    redis_config: RedisConfig,
    params: tuple[int, str, int],
    key: str,
) -> None:
    conn = mysql_connect(mysql_config)
    try:
        payload = json.dumps(fetch_mysql_result(conn, params), separators=(",", ":"))
    finally:
        conn.close()

    client = redis_connect(redis_config)
    client.set(key, payload)


def format_markdown(results: list[dict], explains: dict[str, dict]) -> str:
    lines = [
        "## Query",
        "",
        "```sql",
        QUERY_SQL.strip(),
        "```",
        "",
        "## Metrics",
        "",
        "| case | requests | avg_ms | p95_ms | max_ms | tps |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for result in results:
        lines.append(
            "| {case} | {requests} | {avg_ms:.3f} | {p95_ms:.3f} | {max_ms:.3f} | {tps:.2f} |".format(
                **result
            )
        )

    for name in ("plain", "covering"):
        if name not in explains:
            continue
        explain = explains[name]
        lines.extend(
            [
                "",
                f"## EXPLAIN {name}",
                "",
                f"- using_index: {'yes' if explain['using_index'] else 'no'}",
                f"- using_filesort: {'yes' if explain['using_filesort'] else 'no'}",
                "",
                "| id | type | key | rows | Extra |",
                "|---:|---|---|---:|---|",
            ]
        )
        for row in explain["rows"]:
            lines.append(
                f"| {row['id']} | {row['type']} | {row.get('key') or ''} | "
                f"{row['rows']} | {row.get('Extra') or ''} |"
            )

    return "\n".join(lines) + "\n"


def write_optional_output(path_str: str | None, content: str) -> None:
    if not path_str:
        return
    path = pathlib.Path(path_str)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main() -> None:
    args = parse_args()
    mysql_config = MysqlConfig(
        host=args.mysql_host,
        port=args.mysql_port,
        user=args.mysql_user,
        password=args.mysql_password,
        database=args.mysql_database,
    )
    redis_config = RedisConfig(
        host=args.redis_host,
        port=args.redis_port,
        db=args.redis_db,
    )
    params = (args.university_id, args.gender, args.limit)
    request_counts = split_counts(args.requests, args.concurrency)

    conn = mysql_connect(mysql_config)
    try:
        ensure_base_table(conn)
        if query_row_count(conn) == 0:
            raise SystemExit("user_match 테이블이 비어 있습니다. 먼저 seed_user_match.py를 실행하세요.")
    finally:
        conn.close()

    case_order = ["plain", "covering", "redis"] if args.case == "all" else [args.case]
    results: list[dict] = []
    explains: dict[str, dict] = {}
    key = cache_key_for(args)

    for case_name in case_order:
        conn = mysql_connect(mysql_config)
        try:
            if case_name == "plain":
                prepare_plain_index(conn)
                explains["plain"] = run_explain(conn, params)
                results.append(
                    benchmark_mysql_case("plain", mysql_config, params, args.warmup, request_counts)
                )
            elif case_name == "covering":
                prepare_covering_index(conn)
                explains["covering"] = run_explain(conn, params)
                results.append(
                    benchmark_mysql_case("covering", mysql_config, params, args.warmup, request_counts)
                )
            else:
                if not index_exists(conn, "idx_user_match_covering"):
                    prepare_covering_index(conn)
                    explains.setdefault("covering", run_explain(conn, params))
        finally:
            conn.close()

        if case_name == "redis":
            warm_redis_from_mysql(mysql_config, redis_config, params, key)
            results.append(
                benchmark_redis_case(redis_config, key, args.warmup, request_counts)
            )

    markdown = format_markdown(results, explains)
    print(markdown, end="")
    write_optional_output(args.markdown_out, markdown)

    json_payload = json.dumps(
        {
            "results": results,
            "explains": explains,
            "params": {
                "university_id": args.university_id,
                "gender": args.gender,
                "limit": args.limit,
                "requests": args.requests,
                "warmup": args.warmup,
                "concurrency": args.concurrency,
                "cache_key": key,
            },
        },
        ensure_ascii=False,
        indent=2,
        default=str,
    )
    write_optional_output(args.json_out, json_payload)


if __name__ == "__main__":
    main()
