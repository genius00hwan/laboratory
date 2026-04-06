#!/usr/bin/env python3
import argparse
import pathlib
import random
import time
from typing import Iterable

try:
    import pymysql
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "PyMySQL가 필요합니다. `pip install -r requirements.txt` 후 다시 실행하세요."
    ) from exc


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_SQL = ROOT / "sql" / "set_user_match.sql"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Seed skewed benchmark data.")
    parser.add_argument("--rows", type=int, default=500_000)
    parser.add_argument("--batch-size", type=int, default=5_000)
    parser.add_argument("--truncate", action="store_true")
    parser.add_argument("--seed", type=int, default=20260406)
    parser.add_argument("--university-count", type=int, default=32)
    parser.add_argument("--mysql-host", default="127.0.0.1")
    parser.add_argument("--mysql-port", type=int, default=3310)
    parser.add_argument("--mysql-user", default="lab")
    parser.add_argument("--mysql-password", default="lab")
    parser.add_argument("--mysql-database", default="read_inmemory_data")
    args = parser.parse_args()

    if args.rows <= 0:
        raise SystemExit("--rows must be > 0")
    if args.batch_size <= 0:
        raise SystemExit("--batch-size must be > 0")
    if args.university_count < 4:
        raise SystemExit("--university-count must be >= 4")
    return args


def mysql_connect(args: argparse.Namespace):
    return pymysql.connect(
        host=args.mysql_host,
        port=args.mysql_port,
        user=args.mysql_user,
        password=args.mysql_password,
        database=args.mysql_database,
        charset="utf8mb4",
        autocommit=False,
    )


def execute_sql_file(conn, path: pathlib.Path) -> None:
    statements = [chunk.strip() for chunk in path.read_text(encoding="utf-8").split(";") if chunk.strip()]
    with conn.cursor() as cur:
        for statement in statements:
            cur.execute(statement)
    conn.commit()


def university_id_for(rng: random.Random, university_count: int) -> int:
    bucket = rng.random()
    if bucket < 0.35:
        return 1
    if bucket < 0.55:
        return 2
    if bucket < 0.70:
        return 3
    return 4 + int(rng.random() * (university_count - 3))


def build_rows(
    start_user_id: int,
    row_count: int,
    rng: random.Random,
    university_count: int,
) -> Iterable[tuple[int, str, int, float]]:
    for offset in range(row_count):
        user_id = start_user_id + offset
        university_id = university_id_for(rng, university_count)
        gender = "M" if rng.random() < 0.58 else "F"

        base_score = 55.0 if university_id == 1 else 48.0
        if university_id in (2, 3):
            base_score += 4.0
        if gender == "F":
            base_score += 2.5

        match_score = min(99.9999, round(base_score + rng.random() * 35.0, 4))
        yield (university_id, gender, user_id, match_score)


def main() -> None:
    args = parse_args()
    rng = random.Random(args.seed)

    conn = mysql_connect(args)
    try:
        execute_sql_file(conn, SCHEMA_SQL)

        with conn.cursor() as cur:
            if args.truncate:
                cur.execute("TRUNCATE TABLE user_match")
                conn.commit()

            cur.execute("SELECT COALESCE(MAX(user_id), 0) FROM user_match")
            max_user_id = int(cur.fetchone()[0])

        inserted = 0
        next_user_id = max_user_id + 1
        started = time.perf_counter()

        while inserted < args.rows:
            take = min(args.batch_size, args.rows - inserted)
            rows = list(
                build_rows(
                    start_user_id=next_user_id,
                    row_count=take,
                    rng=rng,
                    university_count=args.university_count,
                )
            )
            with conn.cursor() as cur:
                cur.executemany(
                    """
                    INSERT INTO user_match (
                      university_id,
                      gender,
                      user_id,
                      match_score
                    )
                    VALUES (%s, %s, %s, %s)
                    """,
                    rows,
                )
            conn.commit()

            inserted += take
            next_user_id += take

            if inserted % max(args.batch_size * 10, 50_000) == 0 or inserted == args.rows:
                elapsed = time.perf_counter() - started
                print(
                    f"seeded={inserted} rows elapsed_s={elapsed:.2f} "
                    f"rows_per_sec={inserted / max(elapsed, 1e-9):.0f}"
                )

        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM user_match")
            final_count = int(cur.fetchone()[0])

        elapsed = time.perf_counter() - started
        print(
            f"done rows_inserted={inserted} table_rows={final_count} "
            f"elapsed_s={elapsed:.2f}"
        )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
